[CmdletBinding()]
param(
  [ValidateSet('Scheduled', 'PreMigration', 'PreRestore', 'Manual')]
  [string]$Purpose = 'Scheduled',

  [string]$ResultFile
)

$ErrorActionPreference = 'Stop'

# This script is packaged beside the PostgreSQL runtime. It manages only the
# dedicated Koli Wada Dhaba POS instance; it never discovers or uses another
# local PostgreSQL service or database.
$serviceName = 'KoliWadaDhabaPostgreSQL'
$serviceAccount = 'NT AUTHORITY\NetworkService'
$databaseName = 'koli_wada_dhaba'
$appRole = 'kwd_app'
$port = 5433
# The Windows Task Scheduler owns the 01:30 AM trigger. This script records
# backup outcomes and never schedules or catches up a missed run itself.
$backupLabel = 'KWD POS BACKUP'

$programDataRoot = Join-Path $env:ProgramData 'Koli Wada Dhaba POS'
$dataDirectory = Join-Path $programDataRoot 'Data'
$backupDirectory = Join-Path $programDataRoot 'Backups'
$configDirectory = Join-Path $programDataRoot 'config'
$logDirectory = Join-Path $programDataRoot 'Logs'
$markerPath = Join-Path $configDirectory 'installation.json'
$adminSecretPath = Join-Path $configDirectory 'postgres-admin.dpapi'
$statusPath = Join-Path $logDirectory 'backup-status.json'
$historyPath = Join-Path $logDirectory 'backup-history.json'
$backupLockPath = Join-Path $logDirectory 'backup-restore.lock'
$logPath = Join-Path $logDirectory 'backup.log'

# PSScriptRoot is <InstallDirectory>\resources\installer. The PostgreSQL
# binaries are staged in the sibling <InstallDirectory>\resources folder.
$installerResources = Split-Path -Parent $PSScriptRoot
$pgBin = Join-Path $installerResources 'postgresql17\bin'
$pgCtl = Join-Path $pgBin 'pg_ctl.exe'
$pgDump = Join-Path $pgBin 'pg_dump.exe'
$pgRestore = Join-Path $pgBin 'pg_restore.exe'
$psql = Join-Path $pgBin 'psql.exe'

$partialPath = $null
$backupPath = $null
$adminPassword = $null
$createdUtc = [DateTime]::UtcNow
$createdLocal = Get-Date
$usbStatus = 'NotChecked'
$usbAvailable = $false
$sha256 = $null
$backupLength = 0L
$retentionRemoved = 0
$missedDates = @()
$previousStatus = $null
$statusMetadataWritable = $true
$resultFileFull = $null
$resultTempPath = $null
$statusTempPath = $null
$backupLock = $null
$backupLockAcquired = $false

function Write-BackupLog {
  param([Parameter(Mandatory = $true)][string]$Message)

  $line = '{0} | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Assert-NotReparsePoint {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][ValidateSet('Container', 'Leaf')][string]$PathType
  )

  if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) {
    throw "A required POS installation path is missing: $Path"
  }

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "A reparse point was found in a protected POS path. Backup was stopped: $Path"
  }
}

function ConvertFrom-WindowsCommandLine {
  param([Parameter(Mandatory = $true)][string]$CommandLine)

  if (-not ('KwdPosBackup.NativeCommandLine' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace KwdPosBackup {
  public static class NativeCommandLine {
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argc);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Split(string commandLine) {
      int argc;
      IntPtr argv = CommandLineToArgvW(commandLine, out argc);
      if (argv == IntPtr.Zero) {
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      }

      try {
        var result = new string[argc];
        for (int i = 0; i < argc; i++) {
          IntPtr item = Marshal.ReadIntPtr(argv, i * IntPtr.Size);
          result[i] = Marshal.PtrToStringUni(item);
        }
        return result;
      }
      finally {
        LocalFree(argv);
      }
    }
  }
}
'@
  }

  return [KwdPosBackup.NativeCommandLine]::Split($CommandLine)
}

function Assert-OwnedPostgresService {
  param([Parameter(Mandatory = $true)]$Service)

  if ($Service.Name -ne $serviceName) {
    throw 'The PostgreSQL service is not the dedicated Koli Wada Dhaba POS service.'
  }

  $arguments = @(ConvertFrom-WindowsCommandLine -CommandLine ([string]$Service.PathName))
  if ($arguments.Count -ne 9) {
    throw 'The POS PostgreSQL service command line has an unexpected argument count.'
  }

  $actualExecutable = [IO.Path]::GetFullPath($arguments[0])
  $expectedExecutable = [IO.Path]::GetFullPath($pgCtl)
  $actualDataDirectory = [IO.Path]::GetFullPath($arguments[5]).TrimEnd('\')
  $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')

  $validCommand =
    [string]::Equals($actualExecutable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase) -and
    $arguments[1] -ieq 'runservice' -and
    $arguments[2] -ieq '-N' -and
    $arguments[3] -ceq $serviceName -and
    $arguments[4] -ieq '-D' -and
    [string]::Equals($actualDataDirectory, $expectedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -and
    $arguments[6] -ieq '-w' -and
    $arguments[7] -ieq '-o' -and
    $arguments[8] -ceq "-p $port"

  if (-not $validCommand) {
    throw 'The PostgreSQL service command line does not match the approved packaged pg_ctl runservice configuration.'
  }

  if (-not [string]::Equals([string]$Service.StartName, $serviceAccount, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The POS PostgreSQL service account is not NT AUTHORITY\NetworkService.'
  }

  if ([string]$Service.StartMode -ne 'Auto') {
    throw 'The POS PostgreSQL service is not configured for Automatic startup.'
  }

  if ([string]$Service.State -ne 'Running') {
    throw 'The dedicated POS PostgreSQL service is not running. The backup script will not start or modify it.'
  }
}

function ConvertTo-WindowsArgument {
  param([Parameter(Mandatory = $true)][string]$Value)

  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $slashes = 0

  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') {
      $slashes++
      continue
    }

    if ($character -eq '"') {
      [void]$builder.Append(('\' * (($slashes * 2) + 1)))
      [void]$builder.Append('"')
    }
    else {
      if ($slashes -gt 0) {
        [void]$builder.Append(('\' * $slashes))
      }
      [void]$builder.Append($character)
    }

    $slashes = 0
  }

  if ($slashes -gt 0) {
    [void]$builder.Append(('\' * ($slashes * 2)))
  }

  [void]$builder.Append('"')
  return $builder.ToString()
}

function Invoke-LocalExecutable {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$FailureMessage,
    [hashtable]$Environment = @{},
    [int]$TimeoutSeconds = 180
  )

  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    throw "$FailureMessage (required executable is missing)."
  }

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = ($Arguments | ForEach-Object {
    ConvertTo-WindowsArgument -Value $_
  }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  foreach ($name in $Environment.Keys) {
    $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo

  try {
    if (-not $process.Start()) {
      throw "$FailureMessage (process could not start)."
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill()
      $process.WaitForExit()
      throw "$FailureMessage (timed out)."
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
      $detail = ($stderr + "`n" + $stdout).Trim()
      if ($detail.Length -gt 1600) {
        $detail = $detail.Substring(0, 1600)
      }
      throw "$FailureMessage (exit code $($process.ExitCode)). $detail"
    }

    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      StdOut = $stdout
      StdErr = $stderr
    }
  }
  finally {
    $process.Dispose()
  }
}

function Unprotect-AdminConfiguration {
  if (-not (Test-Path -LiteralPath $adminSecretPath -PathType Leaf)) {
    throw 'The protected POS PostgreSQL administrative configuration is missing.'
  }

  $protectedBytes = [IO.File]::ReadAllBytes($adminSecretPath)
  $plainBytes = $null
  $plainText = $null

  try {
    Add-Type -AssemblyName System.Security
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
      $protectedBytes,
      $null,
      [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    $plainText = [Text.Encoding]::UTF8.GetString($plainBytes)
  }
  finally {
    [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    if ($plainBytes) {
      [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
  }

  try {
    $payload = $plainText | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw 'The protected PostgreSQL administrative configuration is not in the expected machine-wide JSON format.'
  }

  if ($payload.InstanceId -ne $script:installationMarker.InstanceId -or
      [string]::IsNullOrWhiteSpace([string]$payload.AdminPassword)) {
    throw 'The protected PostgreSQL administrative configuration does not match the installed POS InstanceId.'
  }

  $script:adminPassword = [string]$payload.AdminPassword
  $plainText = $null
}

function Invoke-PsqlIdentityCheck {
  $query = @'
SELECT
  current_database(),
  current_setting('data_directory'),
  current_setting('listen_addresses'),
  current_setting('port'),
  current_user,
  (SELECT count(*) FROM pg_roles WHERE rolname = 'kwd_app');
'@

  $output = Invoke-LocalExecutable -FilePath $psql -Arguments @(
    '-X',
    '-w',
    '-h', '127.0.0.1',
    '-p', "$port",
    '-U', 'postgres',
    '-d', $databaseName,
    '-v', 'ON_ERROR_STOP=1',
    '-A',
    '-t',
    '-F', '|',
    '-c', $query
  ) -Environment @{ PGPASSWORD = $adminPassword } -FailureMessage 'The dedicated POS PostgreSQL identity check failed' -TimeoutSeconds 45

  $line = ($output.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
  $columns = $line -split '\|'
  if ($columns.Count -ne 6) {
    throw 'The dedicated POS PostgreSQL identity query returned an invalid result.'
  }

  $actualDataDirectory = [IO.Path]::GetFullPath($columns[1]).TrimEnd('\')
  $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')

  if ($columns[0] -ne $databaseName -or
      -not [string]::Equals($actualDataDirectory, $expectedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
      $columns[2] -ne '127.0.0.1' -or
      $columns[3] -ne "$port" -or
      $columns[4] -ne 'postgres' -or
      $columns[5] -ne '1') {
    throw 'The running PostgreSQL server did not match the expected POS database, Data directory, loopback listener, port and application role.'
  }
}

function Write-JsonAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value,
    [switch]$AllowReplace
  )

  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    throw "The metadata directory does not exist: $directory"
  }

  $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
  $json = $Value | ConvertTo-Json -Depth 8
  $encoding = [Text.UTF8Encoding]::new($false)

  try {
    [IO.File]::WriteAllText($temporary, $json, $encoding)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      if (-not $AllowReplace) {
        throw "The result metadata file already exists and will not be overwritten: $Path"
      }
      [IO.File]::Replace($temporary, $Path, $null)
    }
    else {
      [IO.File]::Move($temporary, $Path)
    }
  }
  finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-PreviousBackupStatus {
  if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    return $null
  }

  Assert-NotReparsePoint -Path $statusPath -PathType Leaf

  try {
    return (Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
  }
  catch {
    $script:statusMetadataWritable = $false
    Write-BackupLog -Message 'WARNING | prior backup-status.json could not be read; it was preserved for inspection and will not be replaced.'
    return $null
  }
}

function Add-BackupHistoryRecord {
  param([Parameter(Mandatory = $true)]$Record)

  $entries = @()
  if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
    Assert-NotReparsePoint -Path $historyPath -PathType Leaf
    $existing = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$existing.SchemaVersion -ne 1 -or $null -eq $existing.Backups) {
      throw 'The protected backup-history.json has an unsupported format and was preserved.'
    }
    $entries = @($existing.Backups)
  }

  $entries = @($entries | Where-Object { [string]$_.BackupId -cne [string]$Record.BackupId })
  $entries += $Record
  $presentNames = @(
    Get-ChildItem -LiteralPath $backupDirectory -File -Filter '*.dump' -ErrorAction Stop |
      Where-Object { $_.Name -match '^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$' } |
      ForEach-Object { $_.Name }
  )
  $entries = @($entries | Where-Object { [string]$_.BackupId -in $presentNames } |
    Sort-Object { [string]$_.CreatedUtc } -Descending | Select-Object -First 100)
  Write-JsonAtomic -Path $historyPath -Value ([ordered]@{
    SchemaVersion = 1
    Backups = $entries
    UpdatedUtc = [DateTime]::UtcNow.ToString('o')
  }) -AllowReplace
}

function Get-MissedScheduledDates {
  param(
    $Previous,
    [DateTime]$Now
  )

  $dates = @()
  if (-not $Previous -or [string]::IsNullOrWhiteSpace([string]$Previous.LastScheduledBackupLocal)) {
    return $dates
  }

  $lastSuccess = [DateTime]::MinValue
  $parsed = [DateTime]::TryParse(
    [string]$Previous.LastScheduledBackupLocal,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeLocal,
    [ref]$lastSuccess
  )
  if (-not $parsed) {
    return $dates
  }

  $date = $lastSuccess.Date.AddDays(1)
  $lastExpectedDate = $Now.Date.AddDays(-1)
  while ($date -le $lastExpectedDate) {
    $dates += $date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $date = $date.AddDays(1)
  }

  return $dates
}

function Invoke-UsbCopy {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$ExpectedHash,
    [Parameter(Mandatory = $true)][string]$FileName
  )

  $volumes = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop)
  $volume = $volumes | Where-Object { $_.VolumeName -eq $backupLabel } | Select-Object -First 1

  if (-not $volume) {
    return [pscustomobject]@{
      Available = $false
      Status = 'No removable drive with the approved volume label was found.'
    }
  }

  if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{
      Available = $false
      Status = 'BitLocker status could not be checked; USB copy was skipped.'
    }
  }

  $bitLocker = Get-BitLockerVolume -MountPoint $volume.DeviceID -ErrorAction Stop
  if ($bitLocker.VolumeStatus -ne 'FullyEncrypted' -or $bitLocker.ProtectionStatus -ne 'On') {
    return [pscustomobject]@{
      Available = $false
      Status = 'The labeled removable drive is not confirmed fully encrypted and protected; USB copy was skipped.'
    }
  }

  $usbDirectory = Join-Path $volume.DeviceID 'Koli Wada Dhaba POS Backups'
  if (-not (Test-Path -LiteralPath $usbDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $usbDirectory -Force | Out-Null
  }

  $usbDirectoryItem = Get-Item -LiteralPath $usbDirectory -Force
  if (($usbDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    return [pscustomobject]@{
      Available = $false
      Status = 'The USB backup folder is a reparse point; USB copy was skipped.'
    }
  }

  $destination = Join-Path $usbDirectory $FileName
  if (Test-Path -LiteralPath $destination) {
    return [pscustomobject]@{
      Available = $false
      Status = 'A USB backup with this name already exists; it was not overwritten.'
    }
  }

  Copy-Item -LiteralPath $SourcePath -Destination $destination -ErrorAction Stop
  $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($destinationHash -ne $ExpectedHash) {
    Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    throw 'The copied USB backup did not pass SHA256 verification.'
  }

  return [pscustomobject]@{
    Available = $true
    Status = 'Encrypted USB copy created and SHA256-verified.'
  }
}

function Write-ResultFile {
  param([Parameter(Mandatory = $true)]$Result)

  if ([string]::IsNullOrWhiteSpace($ResultFile)) {
    return
  }

  $fullPath = [IO.Path]::GetFullPath($ResultFile)
  $expectedRoot = [IO.Path]::GetFullPath($logDirectory).TrimEnd('\') + '\'
  if (-not $fullPath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetExtension($fullPath) -ine '.json') {
    throw 'ResultFile must be a JSON file inside the protected POS Logs directory.'
  }

  if (Test-Path -LiteralPath $fullPath) {
    throw 'ResultFile already exists; the backup utility will not overwrite it.'
  }

  Write-JsonAtomic -Path $fullPath -Value $Result
  $script:resultFileFull = $fullPath
}

try {
  # The installer creates all protected folders before registering the service.
  # The backup task is not allowed to create or repair production identity.
  Assert-NotReparsePoint -Path $programDataRoot -PathType Container
  Assert-NotReparsePoint -Path $dataDirectory -PathType Container
  Assert-NotReparsePoint -Path $backupDirectory -PathType Container
  Assert-NotReparsePoint -Path $configDirectory -PathType Container
  Assert-NotReparsePoint -Path $logDirectory -PathType Container
  Assert-NotReparsePoint -Path $markerPath -PathType Leaf
  Assert-NotReparsePoint -Path $adminSecretPath -PathType Leaf

  if (Test-Path -LiteralPath $backupLockPath -PathType Leaf) {
    Assert-NotReparsePoint -Path $backupLockPath -PathType Leaf
  }
  try {
    $backupLock = [IO.FileStream]::new($backupLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $backupLockAcquired = $true
  }
  catch [IO.IOException] {
    throw 'Another POS backup or restore is in progress. No data was changed; retry when it finishes.'
  }

  foreach ($binary in @($pgCtl, $pgDump, $pgRestore, $psql)) {
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
      throw "A required packaged PostgreSQL utility is missing: $binary"
    }
  }

  foreach ($utility in @($pgCtl, $pgDump, $pgRestore, $psql)) {
    $utilityVersion = & $utility --version 2>$null
    if ($LASTEXITCODE -ne 0 -or $utilityVersion -notmatch '\b17\.') {
      throw "A packaged PostgreSQL utility is not version 17: $utility"
    }
  }

  $script:installationMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -ErrorAction Stop
  $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
  if ($script:installationMarker.ServiceName -ne $serviceName -or
      $script:installationMarker.PostgreSQLMajor -ne '17' -or
      [int]$script:installationMarker.Port -ne $port -or
      -not [string]::Equals(
        [IO.Path]::GetFullPath([string]$script:installationMarker.DataDirectory).TrimEnd('\'),
        $expectedDataDirectory,
        [StringComparison]::OrdinalIgnoreCase
      ) -or
      [string]::IsNullOrWhiteSpace([string]$script:installationMarker.InstanceId)) {
    throw 'The POS installation marker does not prove the expected machine-wide PostgreSQL service, version, port, Data directory and InstanceId.'
  }

  if (-not [string]::IsNullOrWhiteSpace($ResultFile)) {
    $requestedResult = [IO.Path]::GetFullPath($ResultFile)
    $expectedLogRoot = [IO.Path]::GetFullPath($logDirectory).TrimEnd('\') + '\'
    if (-not $requestedResult.StartsWith($expectedLogRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'ResultFile must be inside the protected POS Logs directory.'
    }
  }

  $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
  if (-not $service) {
    throw 'The dedicated Koli Wada Dhaba PostgreSQL service is not installed.'
  }
  Assert-OwnedPostgresService -Service $service

  Unprotect-AdminConfiguration
  Invoke-PsqlIdentityCheck

  $previousStatus = Get-PreviousBackupStatus
  if ($Purpose -eq 'Scheduled') {
    $missedDates = @(Get-MissedScheduledDates -Previous $previousStatus -Now $createdLocal)
    foreach ($missedDate in $missedDates) {
      Write-BackupLog -Message "MISSED | scheduled backup at 01:30 local time was not recorded for $missedDate. No automatic catch-up was started during restaurant operating hours."
    }
  }

  Write-BackupLog -Message "START | purpose=$Purpose | database=$databaseName | scheduled-time=01:30-local"

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $uniquePart = [guid]::NewGuid().ToString('N')
  $partialPath = Join-Path $backupDirectory "koli-wada-dhaba-$timestamp-$uniquePart.partial"
  $backupPath = Join-Path $backupDirectory "koli-wada-dhaba-$timestamp-$uniquePart.dump"

  $dump = Invoke-LocalExecutable -FilePath $pgDump -Arguments @(
    '--no-password',
    '--format=custom',
    '--no-owner',
    '--no-acl',
    '--lock-wait-timeout=30s',
    '--host=127.0.0.1',
    "--port=$port",
    '--username=postgres',
    "--dbname=$databaseName",
    "--file=$partialPath"
  ) -Environment @{ PGPASSWORD = $adminPassword } -FailureMessage 'The dedicated POS PostgreSQL dump failed' -TimeoutSeconds 1800

  if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
    throw 'pg_dump returned success but did not create the expected temporary archive.'
  }

  $partialInfo = Get-Item -LiteralPath $partialPath
  if ($partialInfo.Length -le 0) {
    throw 'pg_dump created an empty archive. It was not accepted as a backup.'
  }

  $listing = Invoke-LocalExecutable -FilePath $pgRestore -Arguments @('--list', $partialPath) `
    -FailureMessage 'The generated PostgreSQL archive failed pg_restore --list validation' -TimeoutSeconds 180

  if ($listing.StdOut -notmatch '(?m)^;\s+Archive created at ' -or
      $listing.StdOut -notmatch '(?m)^;\s+Format: CUSTOM\s*$' -or
      $listing.StdOut -notmatch '(?m)^;\s+dbname:\s*koli_wada_dhaba\s*$') {
    throw 'The generated archive did not identify itself as a valid custom-format backup of the POS database.'
  }

  # File.Move on the same volume is non-overwriting. The generated GUID also
  # prevents normal timestamp collisions without replacing any prior archive.
  [IO.File]::Move($partialPath, $backupPath)
  $partialPath = $null

  $backupInfo = Get-Item -LiteralPath $backupPath
  if ($backupInfo.Length -le 0) {
    throw 'The finalized PostgreSQL backup archive is empty.'
  }

  $backupLength = [long]$backupInfo.Length
  $sha256 = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()

  try {
    $usbResult = Invoke-UsbCopy -SourcePath $backupPath -ExpectedHash $sha256 -FileName $backupInfo.Name
    $usbAvailable = [bool]$usbResult.Available
    $usbStatus = [string]$usbResult.Status
  }
  catch {
    $usbAvailable = $false
    $usbStatus = 'USB backup could not be verified or written; the verified local backup was retained.'
    Write-BackupLog -Message "WARNING | $usbStatus"
  }

  if (-not $usbAvailable) {
    Write-BackupLog -Message "WARNING | $usbStatus"
  }

  # Retention applies only to named POS backup archives, never to folders,
  # metadata, logs, source files or database content.
  $cutoffUtc = [DateTime]::UtcNow.AddDays(-30)
  $expiredBackups = @(
    Get-ChildItem -LiteralPath $backupDirectory -File -ErrorAction Stop |
      Where-Object {
        $_.Name -match '^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$' -and
        $_.LastWriteTimeUtc -lt $cutoffUtc -and
        -not $_.PSIsContainer
      }
  )

  foreach ($expiredBackup in $expiredBackups) {
    Remove-Item -LiteralPath $expiredBackup.FullName -Force -ErrorAction Stop
    $retentionRemoved++
  }

  try {
    Add-BackupHistoryRecord -Record ([ordered]@{
      BackupId = $backupInfo.Name
      Purpose = $Purpose
      CreatedLocal = $createdLocal.ToString('o')
      CreatedUtc = $createdUtc.ToString('o')
      Length = $backupLength
      SHA256 = $sha256
      UsbAvailable = $usbAvailable
      UsbStatus = $usbStatus
    })
  }
  catch {
    # The verified archive remains a successful backup even if its optional
    # history index cannot be updated. The Owner broker can still discover the
    # protected archive by its fixed name and validate it before restore.
    Write-BackupLog -Message 'WARNING | verified backup succeeded but backup-history.json was not updated; the prior index was preserved.'
  }

  $result = [ordered]@{
    SchemaVersion = 1
    Status = 'Success'
    Purpose = $Purpose
    ServiceName = $serviceName
    Port = $port
    DatabaseName = $databaseName
    DataDirectory = $expectedDataDirectory
    InstanceId = [string]$script:installationMarker.InstanceId
    BackupPath = [IO.Path]::GetFullPath($backupPath)
    Length = $backupLength
    SHA256 = $sha256
    CreatedLocal = $createdLocal.ToString('o')
    CreatedUtc = $createdUtc.ToString('o')
    UsbAvailable = $usbAvailable
    UsbStatus = $usbStatus
    RetentionRemovedCount = $retentionRemoved
  }

  if ($Purpose -eq 'Scheduled' -and $statusMetadataWritable) {
    $oldMissed = @()
    if ($previousStatus -and $previousStatus.MissedScheduledDates) {
      $oldMissed = @($previousStatus.MissedScheduledDates | ForEach-Object { [string]$_ })
    }
    $allMissed = @($oldMissed + $missedDates | Select-Object -Unique)

    $status = [ordered]@{
      SchemaVersion = 1
      Status = 'Success'
      LastAttemptStatus = 'Success'
      LastAttemptPurpose = $Purpose
      LastAttemptError = $null
      LastScheduledBackupStatus = 'Success'
      ScheduleLocalTime = '01:30'
      LastAttemptLocal = $createdLocal.ToString('o')
      LastScheduledBackupLocal = $createdLocal.ToString('o')
      LastScheduledBackupPath = [IO.Path]::GetFullPath($backupPath)
      LastScheduledBackupSHA256 = $sha256
      LastScheduledBackupLength = $backupLength
      MissedScheduledDates = $allMissed
      LastMissedBackupCheckedLocal = $createdLocal.ToString('o')
      UsbAvailable = $usbAvailable
      UsbStatus = $usbStatus
      UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path $statusPath -Value $status -AllowReplace
  }
  elseif ($statusMetadataWritable) {
    $oldMissed = @()
    if ($previousStatus -and $previousStatus.MissedScheduledDates) {
      $oldMissed = @($previousStatus.MissedScheduledDates | ForEach-Object { [string]$_ })
    }

    $status = [ordered]@{
      SchemaVersion = 1
      Status = 'Success'
      LastAttemptStatus = 'Success'
      LastAttemptPurpose = $Purpose
      LastAttemptError = $null
      ScheduleLocalTime = '01:30'
      LastAttemptLocal = $createdLocal.ToString('o')
      LastScheduledBackupLocal = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupLocal } else { $null }
      LastScheduledBackupStatus = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupStatus } else { $null }
      LastScheduledBackupPath = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupPath } else { $null }
      LastScheduledBackupSHA256 = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupSHA256 } else { $null }
      LastScheduledBackupLength = if ($previousStatus) { [long]$previousStatus.LastScheduledBackupLength } else { 0L }
      LastManualOrMaintenanceBackupLocal = $createdLocal.ToString('o')
      LastManualOrMaintenanceBackupPath = [IO.Path]::GetFullPath($backupPath)
      MissedScheduledDates = $oldMissed
      UsbAvailable = $usbAvailable
      UsbStatus = $usbStatus
      UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path $statusPath -Value $status -AllowReplace
  }

  if (-not $statusMetadataWritable) {
    Write-BackupLog -Message 'WARNING | verified backup succeeded but backup-status.json was not replaced because the previous status file could not be read.'
  }

  Write-BackupLog -Message ("SUCCESS | purpose={0} | archive={1} | bytes={2} | sha256={3} | usb={4} | retention-removed={5}" -f $Purpose, $backupInfo.Name, $backupLength, $sha256, $usbAvailable, $retentionRemoved)

  Write-ResultFile -Result $result

  Write-Output ([ordered]@{
    Status = 'Success'
    BackupPath = [IO.Path]::GetFullPath($backupPath)
    Length = $backupLength
    SHA256 = $sha256
    UsbAvailable = $usbAvailable
    UsbStatus = $usbStatus
  } | ConvertTo-Json -Compress)
}
catch {
  $safeMessage = $_.Exception.Message
  if ($safeMessage -match '(?i)password|PGPASSWORD|DATABASE_URL') {
    $safeMessage = 'The backup operation failed during a protected credential or connection step.'
  }

  if (-not $backupLockAcquired) {
    $safeMessage = 'Another POS backup or restore is in progress. No data was changed; retry when it finishes.'
  }

  try {
    if ($backupLockAcquired) {
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
      Write-BackupLog -Message "FAILURE | purpose=$Purpose | $safeMessage"
    }
    }
  }
  catch {
    # Do not hide the primary backup error if logging is unavailable.
  }

  try {
    if (-not $backupLockAcquired) { throw 'Backup lock was unavailable; the active operation status was preserved.' }
    if ($statusMetadataWritable -and (Test-Path -LiteralPath $statusPath -PathType Leaf) -and -not $previousStatus) {
      $previousStatus = Get-PreviousBackupStatus
    }

    if ($statusMetadataWritable) {
      $oldMissed = @()
      if ($previousStatus -and $previousStatus.MissedScheduledDates) {
        $oldMissed = @($previousStatus.MissedScheduledDates | ForEach-Object { [string]$_ })
      }

      $newMissed = @($missedDates)
      if ($Purpose -eq 'Scheduled') {
        $newMissed += $createdLocal.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
      }
      $allMissed = @($oldMissed + $newMissed | Select-Object -Unique)

      $failureStatus = [ordered]@{
        SchemaVersion = 1
        Status = 'Failure'
        ScheduleLocalTime = '01:30'
        LastAttemptLocal = (Get-Date).ToString('o')
        LastAttemptStatus = 'Failure'
        LastAttemptPurpose = $Purpose
        LastAttemptError = $safeMessage
        LastScheduledBackupStatus = if ($Purpose -eq 'Scheduled') { 'Failure' } elseif ($previousStatus) { [string]$previousStatus.LastScheduledBackupStatus } else { $null }
        LastScheduledBackupLocal = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupLocal } else { $null }
        LastScheduledBackupPath = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupPath } else { $null }
        LastScheduledBackupSHA256 = if ($previousStatus) { [string]$previousStatus.LastScheduledBackupSHA256 } else { $null }
        LastScheduledBackupLength = if ($previousStatus) { [long]$previousStatus.LastScheduledBackupLength } else { 0L }
        MissedScheduledDates = $allMissed
        UsbAvailable = $false
        UsbStatus = 'USB backup was not attempted because the local backup operation failed.'
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
      }
      Write-JsonAtomic -Path $statusPath -Value $failureStatus -AllowReplace
    }
  }
  catch {
    try {
      if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        Write-BackupLog -Message 'WARNING | failure status metadata could not be updated; the previous status file was preserved where possible.'
      }
    }
    catch {
      # Preserve the original backup failure.
    }
  }

  if ($partialPath -and (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
  }

  if (-not $ResultFile) {
    throw
  }

  $failureResult = [ordered]@{
    SchemaVersion = 1
    Status = 'Failure'
    Purpose = $Purpose
    ServiceName = $serviceName
    Port = $port
    DatabaseName = $databaseName
    DataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
    Error = $safeMessage
    CreatedLocal = (Get-Date).ToString('o')
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
  }

  try {
    Write-ResultFile -Result $failureResult
  }
  catch {
    # Installer will also enforce a non-zero exit code from this process.
  }

  throw $safeMessage
}
finally {
  if ($partialPath -and (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
  }

  $adminPassword = $null
  if ($backupLock) { $backupLock.Dispose() }
}
