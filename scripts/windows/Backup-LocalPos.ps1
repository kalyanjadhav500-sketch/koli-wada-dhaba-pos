$ErrorActionPreference = "Stop"
$serviceName = "KoliWadaDhabaPostgreSQL"
$programDataRoot = Join-Path $env:ProgramData "Koli Wada Dhaba POS"
$secretPath = Join-Path $programDataRoot "config\database-secrets.dpapi"
$backupDirectory = Join-Path $programDataRoot "Backups"
$logDirectory = Join-Path $programDataRoot "Logs"
$logPath = Join-Path $logDirectory "backup.log"
$installerResources = Split-Path -Parent $PSScriptRoot
$pgBin = Join-Path $installerResources "postgresql17\bin"
$pgDump = Join-Path $pgBin "pg_dump.exe"
$pgRestore = Join-Path $pgBin "pg_restore.exe"
$backupLabel = "KWD POS BACKUP"

function Write-BackupLog {
  param([Parameter(Mandatory = $true)][string]$Message)
  $line = "{0} {1}" -f [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss"), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
  throw "The protected POS database configuration is missing."
}
if (-not (Test-Path -LiteralPath $pgDump -PathType Leaf) -or
    -not (Test-Path -LiteralPath $pgRestore -PathType Leaf)) {
  throw "The bundled PostgreSQL backup utilities are missing."
}
$service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
if (-not $service -or $service.State -ne "Running") {
  throw "The dedicated Koli Wada Dhaba PostgreSQL service is not running."
}

Add-Type -AssemblyName System.Security
$protectedConfiguration = [IO.File]::ReadAllBytes($secretPath)
$configurationBytes = [Security.Cryptography.ProtectedData]::Unprotect(
  $protectedConfiguration,
  $null,
  [Security.Cryptography.DataProtectionScope]::LocalMachine
)
try {
  $configuration = [Text.Encoding]::UTF8.GetString($configurationBytes) | ConvertFrom-Json
}
finally {
  [Array]::Clear($protectedConfiguration, 0, $protectedConfiguration.Length)
  [Array]::Clear($configurationBytes, 0, $configurationBytes.Length)
}
$databaseUrl = [string]$configuration.DATABASE_URL
try {
  $connection = [uri]$databaseUrl
  if ($connection.Scheme -notin @("postgres", "postgresql") -or
      $connection.Host -ne "127.0.0.1" -or $connection.Port -ne 5433) {
    throw "The protected database URL is not the expected local POS endpoint."
  }
}
catch {
  throw "The protected local POS database URL is invalid."
}

New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$partialPath = Join-Path $backupDirectory "koli-wada-dhaba-$([guid]::NewGuid().ToString('N')).partial"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $backupDirectory "koli-wada-dhaba-$timestamp.dump"
if (Test-Path -LiteralPath $backupPath) {
  throw "A backup already exists for this timestamp; no file was overwritten."
}

$pgDatabaseUrl = [regex]::Replace($databaseUrl, '([?&])schema=[^&]*', '')
$pgDatabaseUrl = $pgDatabaseUrl -replace '\?&', '?'
$pgDatabaseUrl = $pgDatabaseUrl -replace '[?&]$', ''
$env:PGCONNECT_TIMEOUT = "10"
try {
  $dumpOutput = & $pgDump --no-password --format=custom --no-owner --no-acl `
    "--file=$partialPath" "--dbname=$pgDatabaseUrl" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "The POS database backup command failed."
  }
  $listing = & $pgRestore --list $partialPath 2>&1
  if ($LASTEXITCODE -ne 0 -or -not $listing) {
    throw "The generated backup did not pass archive validation."
  }
  Move-Item -LiteralPath $partialPath -Destination $backupPath
}
catch {
  if (Test-Path -LiteralPath $partialPath) {
    Remove-Item -LiteralPath $partialPath -Force
  }
  Write-BackupLog -Message "ERROR: local PostgreSQL backup failed; inspect Task Scheduler and PostgreSQL service status."
  throw
}

$backupInfo = Get-Item -LiteralPath $backupPath
Write-BackupLog -Message ("Verified local backup created: {0} ({1} bytes)." -f $backupInfo.Name, $backupInfo.Length)
$cutoff = (Get-Date).AddDays(-30)
$expiredBackups = Get-ChildItem -LiteralPath $backupDirectory -File |
  Where-Object {
    $_.Name -match '^koli-wada-dhaba-\d{8}-\d{6}\.dump$' -and $_.LastWriteTime -lt $cutoff
  }
foreach ($expiredBackup in $expiredBackups) {
  Remove-Item -LiteralPath $expiredBackup.FullName -Force
}

$usbAvailable = $false
try {
  $removableVolumes = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2"
  foreach ($volume in $removableVolumes) {
    if ($volume.VolumeName -ne $backupLabel) { continue }
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { break }
    $bitLocker = Get-BitLockerVolume -MountPoint $volume.DeviceID -ErrorAction Stop
    if ($bitLocker.VolumeStatus -ne "FullyEncrypted" -or
        $bitLocker.ProtectionStatus -ne "On") {
      Write-BackupLog -Message "WARNING: labeled removable drive is not confirmed fully BitLocker-encrypted; USB copy skipped."
      break
    }
    $usbDirectory = Join-Path $volume.DeviceID "Koli Wada Dhaba POS Backups"
    New-Item -ItemType Directory -Path $usbDirectory -Force | Out-Null
    $usbCopy = Join-Path $usbDirectory $backupInfo.Name
    if (Test-Path -LiteralPath $usbCopy) {
      throw "An external backup with the same name already exists; it was not overwritten."
    }
    Copy-Item -LiteralPath $backupPath -Destination $usbCopy
    $usbAvailable = $true
    Write-BackupLog -Message "Verified backup copied to the configured encrypted removable drive."
    break
  }
}
catch {
  Write-BackupLog -Message "WARNING: external USB backup could not be verified or written; the local backup remains available."
}
if (-not $usbAvailable) {
  Write-BackupLog -Message "WARNING: encrypted USB backup unavailable; verified local backup was retained."
}
Write-Output ("Verified local PostgreSQL backup: {0} ({1:N1} MB)" -f $backupInfo.FullName, ($backupInfo.Length / 1MB))
