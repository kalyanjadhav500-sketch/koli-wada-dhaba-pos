[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BackupId,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedSHA256,

  [Parameter(Mandatory = $true)]
  [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$serviceName = 'KoliWadaDhabaPostgreSQL'
$serviceAccount = 'NT AUTHORITY\NetworkService'
$databaseName = 'koli_wada_dhaba'
$appRole = 'kwd_app'
$port = 5433
$programDataRoot = Join-Path $env:ProgramData 'Koli Wada Dhaba POS'
$dataDirectory = Join-Path $programDataRoot 'Data'
$backupDirectory = Join-Path $programDataRoot 'Backups'
$configDirectory = Join-Path $programDataRoot 'config'
$logDirectory = Join-Path $programDataRoot 'Logs'
$markerPath = Join-Path $configDirectory 'installation.json'
$adminSecretPath = Join-Path $configDirectory 'postgres-admin.dpapi'
$statusPath = Join-Path $logDirectory 'restore-status.json'
$backupLockPath = Join-Path $logDirectory 'backup-restore.lock'
$postgresBin = Join-Path (Split-Path -Parent $PSScriptRoot) 'postgresql17\bin'
$pgCtl = Join-Path $postgresBin 'pg_ctl.exe'
$pgRestore = Join-Path $postgresBin 'pg_restore.exe'
$psql = Join-Path $postgresBin 'psql.exe'
$backupScript = Join-Path $PSScriptRoot 'Backup-LocalPos.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$resultFullPath = $null
$adminPassword = $null
$preRestoreBackupId = $null
$restoreStarted = $false
$rollbackStatus = 'NotRequired'
$preRestorePath = $null
$createdLocal = Get-Date
$backupLock = $null

function Assert-RegularFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'A required POS restore file is missing.' }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A reparse point was found in a protected POS restore file.' }
}

function Assert-RegularDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'A required POS restore folder is missing.' }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A reparse point was found in a protected POS restore folder.' }
}

function ConvertFrom-WindowsCommandLine {
  param([Parameter(Mandatory = $true)][string]$CommandLine)
  if (-not ('KwdPosRestore.NativeCommandLine' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace KwdPosRestore {
  public static class NativeCommandLine {
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argc);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    public static string[] Split(string commandLine) {
      int argc;
      IntPtr argv = CommandLineToArgvW(commandLine, out argc);
      if (argv == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      try {
        var result = new string[argc];
        for (int i = 0; i < argc; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
        return result;
      }
      finally { LocalFree(argv); }
    }
  }
}
'@
  }
  return [KwdPosRestore.NativeCommandLine]::Split($CommandLine)
}

function Assert-OwnedPostgresService {
  $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
  if (-not $service -or $service.Name -cne $serviceName) { throw 'The dedicated POS PostgreSQL service is not installed.' }
  $arguments = @(ConvertFrom-WindowsCommandLine -CommandLine ([string]$service.PathName))
  if ($arguments.Count -ne 9) { throw 'The POS PostgreSQL service command line is invalid.' }
  $actualExecutable = [IO.Path]::GetFullPath($arguments[0])
  $actualDataDirectory = [IO.Path]::GetFullPath($arguments[5]).TrimEnd('\')
  $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
  if (-not [string]::Equals($actualExecutable, [IO.Path]::GetFullPath($pgCtl), [StringComparison]::OrdinalIgnoreCase) -or
      $arguments[1] -ine 'runservice' -or $arguments[2] -ine '-N' -or $arguments[3] -cne $serviceName -or
      $arguments[4] -ine '-D' -or -not [string]::Equals($actualDataDirectory, $expectedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
      $arguments[6] -ine '-w' -or $arguments[7] -ine '-o' -or $arguments[8] -cne "-p $port") {
    throw 'The PostgreSQL service command line does not match the dedicated POS instance.'
  }
  if (-not [string]::Equals([string]$service.StartName, $serviceAccount, [StringComparison]::OrdinalIgnoreCase) -or
      [string]$service.StartMode -ne 'Auto' -or [string]$service.State -ne 'Running') {
    throw 'The dedicated POS PostgreSQL service is not running with its approved account and startup settings.'
  }
}

function ConvertTo-WindowsArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') { $slashes++; continue }
    if ($character -eq '"') {
      [void]$builder.Append(('\' * (($slashes * 2) + 1)))
      [void]$builder.Append('"')
    }
    else {
      if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
      [void]$builder.Append($character)
    }
    $slashes = 0
  }
  if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Invoke-NativeTool {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$FailureMessage,
    [hashtable]$Environment = @{},
    [int]$TimeoutSeconds = 180
  )
  Assert-RegularFile -Path $FilePath
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' ')
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  foreach ($name in $Environment.Keys) { $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name] }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "$FailureMessage (process could not start)." }
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
      if ($detail.Length -gt 1400) { $detail = $detail.Substring(0, 1400) }
      throw "$FailureMessage (exit code $($process.ExitCode)). $detail"
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
  }
  finally { $process.Dispose() }
}

function Unprotect-AdminConfiguration {
  Assert-RegularFile -Path $adminSecretPath
  $protectedBytes = [IO.File]::ReadAllBytes($adminSecretPath)
  $plainBytes = $null
  $plainText = $null
  try {
    Add-Type -AssemblyName System.Security
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
      $protectedBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    $plainText = [Text.Encoding]::UTF8.GetString($plainBytes)
  }
  finally {
    [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
  }
  try { $configuration = $plainText | ConvertFrom-Json -ErrorAction Stop }
  catch { throw 'The protected POS PostgreSQL configuration is unreadable.' }
  if ($configuration.InstanceId -cne [string]$script:installationMarker.InstanceId -or
      [string]::IsNullOrWhiteSpace([string]$configuration.AdminPassword)) {
    throw 'The protected POS PostgreSQL configuration does not match this installation.'
  }
  $script:adminPassword = [string]$configuration.AdminPassword
  $plainText = $null
}

function Assert-DatabaseIdentity {
  $query = "SELECT current_database(), current_setting('data_directory'), current_setting('listen_addresses'), current_setting('port'), current_user, (SELECT count(*) FROM pg_roles WHERE rolname = '$appRole');"
  $identity = Invoke-NativeTool -FilePath $psql -Arguments @(
    '-X','-w','-h','127.0.0.1','-p',"$port",'-U','postgres','-d',$databaseName,
    '-v','ON_ERROR_STOP=1','-A','-t','-F','|','-c',$query
  ) -FailureMessage 'The POS database identity check failed' -Environment @{ PGPASSWORD = $adminPassword } -TimeoutSeconds 45
  $line = ($identity.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
  $columns = $line -split '\|'
  if ($columns.Count -ne 6 -or $columns[0] -cne $databaseName -or
      -not [string]::Equals([IO.Path]::GetFullPath($columns[1]).TrimEnd('\'), [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
      $columns[2] -cne '127.0.0.1' -or $columns[3] -cne "$port" -or $columns[4] -cne 'postgres' -or $columns[5] -cne '1') {
    throw 'The live database did not match the dedicated POS database, role, port and Data directory.'
  }
}

function Write-JsonAtomic {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  $temporary = Join-Path (Split-Path -Parent $Path) ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
  $json = $Value | ConvertTo-Json -Depth 8
  $encoding = [Text.UTF8Encoding]::new($false)
  try {
    [IO.File]::WriteAllText($temporary, $json, $encoding)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, $null) }
    else { [IO.File]::Move($temporary, $Path) }
  }
  finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
  }
}

function Write-Result {
  param([Parameter(Mandatory = $true)]$Result)
  if (-not $resultFullPath) { return }
  Write-JsonAtomic -Path $resultFullPath -Value $Result
}

function Invoke-ValidatedArchiveRestore {
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$Description
  )

  [void](Invoke-NativeTool -FilePath $pgRestore -Arguments @(
    '--no-password','--clean','--if-exists','--exit-on-error','--single-transaction',
    '--no-owner','--no-acl','--host=127.0.0.1',"--port=$port",'--username=postgres',
    "--dbname=$databaseName",$ArchivePath
  ) -FailureMessage "The $Description restore failed; its PostgreSQL transaction was rolled back" `
    -Environment @{ PGPASSWORD = $adminPassword } -TimeoutSeconds 7200)

  # The production archives deliberately omit owner/ACL metadata. Reapply the
  # fixed least-privilege application grants before the role-level validation.
  $applicationGrants = @'
GRANT CONNECT ON DATABASE koli_wada_dhaba TO kwd_app;
GRANT USAGE, CREATE ON SCHEMA public TO kwd_app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO kwd_app;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO kwd_app;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO kwd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO kwd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO kwd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO kwd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kwd_app IN SCHEMA public GRANT ALL ON TABLES TO kwd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kwd_app IN SCHEMA public GRANT ALL ON SEQUENCES TO kwd_app;
ALTER DEFAULT PRIVILEGES FOR ROLE kwd_app IN SCHEMA public GRANT ALL ON FUNCTIONS TO kwd_app;
'@
  [void](Invoke-NativeTool -FilePath $psql -Arguments @(
    '-X','-w','-h','127.0.0.1','-p',"$port",'-U','postgres','-d',$databaseName,
    '-v','ON_ERROR_STOP=1','-c',$applicationGrants
  ) -FailureMessage "The $Description application database permissions could not be restored" `
    -Environment @{ PGPASSWORD = $adminPassword } -TimeoutSeconds 60)
  Assert-DatabaseIdentity

  $applicationCheck = Invoke-NativeTool -FilePath $psql -Arguments @(
    '-X','-w','-h','127.0.0.1','-p',"$port",'-U','postgres','-d',$databaseName,
    '-v','ON_ERROR_STOP=1','-A','-t','-F','|','-c',
    'SET ROLE kwd_app; SELECT current_database(), current_setting(''data_directory''), current_setting(''port''), current_user, (SELECT count(*) FROM "RestaurantTable"); RESET ROLE;'
  ) -FailureMessage "The $Description application role could not read restaurant data" `
    -Environment @{ PGPASSWORD = $adminPassword } -TimeoutSeconds 60
  $applicationLine = ($applicationCheck.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
  $applicationParts = $applicationLine -split '\|'
  if ($applicationParts.Count -ne 5 -or $applicationParts[0] -cne $databaseName -or
      -not [string]::Equals([IO.Path]::GetFullPath($applicationParts[1]).TrimEnd('\'), [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
      $applicationParts[2] -cne "$port" -or $applicationParts[3] -cne $appRole -or
      [int]$applicationParts[4] -le 0) {
    throw "The $Description database failed application-role permission or business-data validation."
  }
}

try {
  if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
    throw 'The production restore utility can run only inside the protected POS SYSTEM broker.'
  }
  if ($BackupId -notmatch '^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$' -or
      $ExpectedSHA256 -notmatch '^[0-9a-f]{64}$') {
    throw 'The selected POS backup identity is invalid.'
  }
  foreach ($directory in @($programDataRoot,$dataDirectory,$backupDirectory,$configDirectory,$logDirectory)) {
    Assert-RegularDirectory -Path $directory
  }
  foreach ($file in @($markerPath,(Join-Path $dataDirectory 'PG_VERSION'),$adminSecretPath,$pgCtl,$pgRestore,$psql,$backupScript)) {
    Assert-RegularFile -Path $file
  }
  $resultFullPath = [IO.Path]::GetFullPath($ResultFile)
  $expectedLogRoot = [IO.Path]::GetFullPath($logDirectory).TrimEnd('\') + '\'
  if (-not $resultFullPath.StartsWith($expectedLogRoot, [StringComparison]::OrdinalIgnoreCase) -or
      [IO.Path]::GetExtension($resultFullPath) -ine '.json' -or (Test-Path -LiteralPath $resultFullPath)) {
    throw 'The restore result destination is outside the protected POS Logs folder.'
  }

  $script:installationMarker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  if ($script:installationMarker.ServiceName -cne $serviceName -or
      $script:installationMarker.PostgreSQLMajor -cne '17' -or [int]$script:installationMarker.Port -ne $port -or
      -not [string]::Equals([IO.Path]::GetFullPath([string]$script:installationMarker.DataDirectory).TrimEnd('\'), [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
      [IO.File]::ReadAllText((Join-Path $dataDirectory 'PG_VERSION')).Trim() -cne '17') {
    throw 'The POS installation marker does not match the installed PostgreSQL 17 Data directory.'
  }
  Assert-OwnedPostgresService
  Unprotect-AdminConfiguration
  Assert-DatabaseIdentity

  $archivePath = Join-Path $backupDirectory $BackupId
  Assert-RegularFile -Path $archivePath
  $archive = Get-Item -LiteralPath $archivePath -Force -ErrorAction Stop
  if ($archive.Length -le 0) { throw 'The selected POS backup archive is empty.' }
  $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  if ($archiveHash -cne $ExpectedSHA256) { throw 'The selected POS backup failed its SHA256 integrity check.' }
  $archiveListing = Invoke-NativeTool -FilePath $pgRestore -Arguments @('--list',$archivePath) `
    -FailureMessage 'The selected POS backup failed PostgreSQL archive validation' -TimeoutSeconds 180
  if ($archiveListing.StdOut -notmatch '(?m)^;\s+Format: CUSTOM\s*$' -or
      $archiveListing.StdOut -notmatch '(?m)^;\s+dbname:\s*koli_wada_dhaba\s*$') {
    throw 'The selected backup archive is not a valid backup of the POS database.'
  }

  $preRestoreResultFile = Join-Path $logDirectory ("pre-restore-$([guid]::NewGuid().ToString('N')).json")
  $preRestore = Invoke-NativeTool -FilePath $powershellExe -Arguments @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$backupScript,
    '-Purpose','PreRestore','-ResultFile',$preRestoreResultFile
  ) -FailureMessage 'A verified pre-restore backup could not be created' -TimeoutSeconds 7200
  if (-not (Test-Path -LiteralPath $preRestoreResultFile -PathType Leaf)) {
    throw 'A verified pre-restore backup result was not created. No restore was started.'
  }
  $preResult = Get-Content -LiteralPath $preRestoreResultFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  if ($preRestore.ExitCode -ne 0 -or $preResult.Status -cne 'Success' -or
      $preResult.ServiceName -cne $serviceName -or [int]$preResult.Port -ne $port -or
      $preResult.DatabaseName -cne $databaseName -or [string]$preResult.InstanceId -cne [string]$script:installationMarker.InstanceId) {
    throw 'A verified pre-restore backup could not be confirmed. No restore was started.'
  }
  $preRestorePath = [IO.Path]::GetFullPath([string]$preResult.BackupPath)
  if (-not $preRestorePath.StartsWith($expectedLogRoot, [StringComparison]::OrdinalIgnoreCase)) {
    # Backup archives are siblings of Logs, so compare against their separate fixed root.
    $expectedBackupRoot = [IO.Path]::GetFullPath($backupDirectory).TrimEnd('\') + '\'
    if (-not $preRestorePath.StartsWith($expectedBackupRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'The pre-restore backup result points outside the protected POS backup folder.'
    }
  }
  $preRestoreBackupId = [IO.Path]::GetFileName($preRestorePath)
  $preRestoreInfo = Get-Item -LiteralPath $preRestorePath -Force -ErrorAction Stop
  if (($preRestoreInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $preRestoreInfo.Length -le 0 -or
      (Get-FileHash -LiteralPath $preRestorePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$preResult.SHA256) {
    throw 'The verified pre-restore backup failed its final size or SHA256 check. No restore was started.'
  }
  if (Test-Path -LiteralPath $preRestoreResultFile -PathType Leaf) { Remove-Item -LiteralPath $preRestoreResultFile -Force -ErrorAction SilentlyContinue }

  if (Test-Path -LiteralPath $backupLockPath -PathType Leaf) {
    $lockItem = Get-Item -LiteralPath $backupLockPath -Force -ErrorAction Stop
    if (($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'The POS backup/restore lock file is not a regular local file. Restore was not started.'
    }
  }
  try {
    $backupLock = [IO.FileStream]::new($backupLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  }
  catch [IO.IOException] {
    throw 'Another POS backup or restore is in progress. The database was not changed; retry when it finishes.'
  }

  # The running Electron process stops its local API before this operation.
  # A failed restore/permission/data check triggers a verified pre-restore
  # recovery attempt before the broker reports failure to the Owner.
  $restoreStarted = $true
  Invoke-ValidatedArchiveRestore -ArchivePath $archivePath -Description 'selected backup'

  $success = [ordered]@{
    SchemaVersion = 1
    Status = 'Success'
    BackupId = $BackupId
    SHA256 = $archiveHash
    RestoredLocal = (Get-Date).ToString('o')
    PreRestoreBackupId = $preRestoreBackupId
    PreRestoreBackupSHA256 = [string]$preResult.SHA256
    DatabaseName = $databaseName
    InstanceId = [string]$script:installationMarker.InstanceId
    Message = 'The POS database restore completed and passed identity verification.'
  }
  Write-JsonAtomic -Path $statusPath -Value $success
  Write-Result -Result $success
}
catch {
  $safeMessage = $_.Exception.Message
  if ($safeMessage -match '(?i)password|PGPASSWORD|DATABASE_URL|secret') {
    $safeMessage = 'The protected POS restore operation failed during a credential or database identity check.'
  }
  if ($restoreStarted -and $backupLock -and $preRestorePath -and (Test-Path -LiteralPath $preRestorePath -PathType Leaf)) {
    try {
      $preRestoreHash = (Get-FileHash -LiteralPath $preRestorePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
      if ($preRestoreHash -cne [string]$preResult.SHA256) {
        throw 'The protected pre-restore archive no longer matches its verified SHA256.'
      }
      Invoke-ValidatedArchiveRestore -ArchivePath $preRestorePath -Description 'pre-restore recovery'
      $rollbackStatus = 'Success'
      $safeMessage += ' The restore did not pass validation, so the verified pre-restore backup was restored and checked.'
    }
    catch {
      $rollbackStatus = 'Failure'
      $safeMessage += ' Automatic recovery from the pre-restore archive also failed. Keep the verified pre-restore archive and contact support before using the POS.'
    }
  }
  $failure = [ordered]@{
    SchemaVersion = 1
    Status = 'Failure'
    RollbackStatus = $rollbackStatus
    BackupId = $BackupId
    RestoredLocal = (Get-Date).ToString('o')
    RestoreStarted = $restoreStarted
    PreRestoreBackupId = $preRestoreBackupId
    Message = $safeMessage
  }
  try {
    if ($resultFullPath -and (Test-Path -LiteralPath $logDirectory -PathType Container)) {
      Write-JsonAtomic -Path $statusPath -Value $failure
      Write-Result -Result $failure
    }
  }
  catch { }
  throw $safeMessage
}
finally {
  $adminPassword = $null
  if ($backupLock) { $backupLock.Dispose() }
  if ($preRestoreResultFile -and (Test-Path -LiteralPath $preRestoreResultFile -PathType Leaf)) {
    Remove-Item -LiteralPath $preRestoreResultFile -Force -ErrorAction SilentlyContinue
  }
}
