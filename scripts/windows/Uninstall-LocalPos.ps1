[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDirectory
)

$ErrorActionPreference = 'Stop'

# The uninstaller is deliberately limited to these exact POS-owned resources.
# It never discovers, stops, unregisters, or changes any other PostgreSQL service.
$serviceName = 'KoliWadaDhabaPostgreSQL'
$serviceAccount = 'NT AUTHORITY\NetworkService'
$databaseName = 'koli_wada_dhaba'
$appRole = 'kwd_app'
$port = 5433
$backupTaskName = 'Koli Wada Dhaba POS Daily Backup'
$brokerTaskName = 'Koli Wada Dhaba POS Maintenance Broker'
$backupTaskPath = '\Koli Wada Dhaba POS\'
$brokerTaskPath = $backupTaskPath
$backupTime = [TimeSpan]::FromMinutes(90) # 01:30 AM local Windows time

$programDataRoot = Join-Path $env:ProgramData 'Koli Wada Dhaba POS'
$dataDirectory = Join-Path $programDataRoot 'Data'
$configDirectory = Join-Path $programDataRoot 'config'
$markerPath = Join-Path $configDirectory 'installation.json'
$appSecretPath = Join-Path $configDirectory 'database-secrets.dpapi'
$adminSecretPath = Join-Path $configDirectory 'postgres-admin.dpapi'

$installDirectoryFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$postgresBin = Join-Path $installDirectoryFull 'resources\postgresql17\bin'
$pgCtl = Join-Path $postgresBin 'pg_ctl.exe'
$backupScript = Join-Path $installDirectoryFull 'resources\installer\Backup-LocalPos.ps1'
$brokerScript = Join-Path $installDirectoryFull 'resources\installer\Pos-Maintenance-Broker.ps1'
$restoreScript = Join-Path $installDirectoryFull 'resources\installer\Restore-LocalPos.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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
    throw "A reparse point was found in a protected POS path. The uninstaller stopped: $Path"
  }
}

function ConvertFrom-WindowsCommandLine {
  param([Parameter(Mandatory = $true)][string]$CommandLine)

  if (-not ('KwdPosUninstall.NativeCommandLine' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace KwdPosUninstall {
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

  return [KwdPosUninstall.NativeCommandLine]::Split($CommandLine)
}

function Assert-OwnedPostgresService {
  param([Parameter(Mandatory = $true)]$Service)

  if ([string]$Service.Name -cne $serviceName) {
    throw 'The PostgreSQL service name is not the dedicated POS service. No service changes were made.'
  }

  $arguments = @(ConvertFrom-WindowsCommandLine -CommandLine ([string]$Service.PathName))
  if ($arguments.Count -ne 9) {
    throw 'The POS PostgreSQL service command line contains unexpected or missing arguments. The service was left unchanged.'
  }

  try {
    $actualExecutable = [IO.Path]::GetFullPath($arguments[0])
    $expectedExecutable = [IO.Path]::GetFullPath($pgCtl)
    $actualDataDirectory = [IO.Path]::GetFullPath($arguments[5]).TrimEnd('\')
    $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
  }
  catch {
    throw 'The POS PostgreSQL service command line contains an invalid executable or Data path. The service was left unchanged.'
  }

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
    throw 'The service command line does not exactly match the packaged pg_ctl runservice identity, name, Data directory, wait flag and port. It was left unchanged.'
  }

  if (-not [string]::Equals([string]$Service.StartName, $serviceAccount, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The POS PostgreSQL service is not running as NT AUTHORITY\NetworkService. It was left unchanged.'
  }

  if ([string]$Service.StartMode -ne 'Auto') {
    throw 'The POS PostgreSQL service is not configured for Automatic startup. It was left unchanged.'
  }
}

function Unprotect-LocalSecret {
  param([Parameter(Mandatory = $true)][string]$Path)

  Add-Type -AssemblyName System.Security
  $protectedBytes = [IO.File]::ReadAllBytes($Path)
  $plainBytes = $null

  try {
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
      $protectedBytes,
      $null,
      [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    return [Text.Encoding]::UTF8.GetString($plainBytes)
  }
  finally {
    [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    if ($plainBytes) {
      [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
  }
}

function Assert-InstallationIdentity {
  Assert-NotReparsePoint -Path $programDataRoot -PathType Container
  Assert-NotReparsePoint -Path $dataDirectory -PathType Container
  Assert-NotReparsePoint -Path $configDirectory -PathType Container
  Assert-NotReparsePoint -Path $markerPath -PathType Leaf
  Assert-NotReparsePoint -Path $appSecretPath -PathType Leaf
  Assert-NotReparsePoint -Path $adminSecretPath -PathType Leaf

  $expectedData = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
  $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

  if ([string]$marker.ServiceName -cne $serviceName -or
      -not [string]::Equals([IO.Path]::GetFullPath([string]$marker.DataDirectory).TrimEnd('\'), $expectedData, [StringComparison]::OrdinalIgnoreCase) -or
      [string]$marker.PostgreSQLMajor -ne '17' -or
      [int]$marker.Port -ne $port -or
      [string]::IsNullOrWhiteSpace([string]$marker.InstanceId)) {
    throw 'The machine-wide POS installation marker does not match the expected service, PostgreSQL version, port, Data directory and InstanceId. Nothing was uninstalled.'
  }

  $pgVersionPath = Join-Path $dataDirectory 'PG_VERSION'
  Assert-NotReparsePoint -Path $pgVersionPath -PathType Leaf
  if ((Get-Content -LiteralPath $pgVersionPath -Raw).Trim() -ne '17') {
    throw 'The ProgramData Data directory is not PostgreSQL 17. Nothing was uninstalled.'
  }

  $appConfiguration = $null
  $adminConfiguration = $null
  try {
    $appConfiguration = (Unprotect-LocalSecret -Path $appSecretPath) | ConvertFrom-Json -ErrorAction Stop
    $adminConfiguration = (Unprotect-LocalSecret -Path $adminSecretPath) | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw 'The protected POS configuration could not be decrypted or parsed. The service and scheduled task were left unchanged.'
  }

  if ([string]$appConfiguration.InstanceId -ne [string]$marker.InstanceId -or
      [string]$adminConfiguration.InstanceId -ne [string]$marker.InstanceId) {
    throw 'The protected application/admin configuration InstanceId does not match the installation marker. Nothing was uninstalled.'
  }

  $databaseUrl = [string]$appConfiguration.DATABASE_URL
  $validDatabaseUrl = $databaseUrl -match '^postgresql://kwd_app:[0-9a-fA-F]{64}@127\.0\.0\.1:5433/koli_wada_dhaba\?schema=public$'
  if (-not $validDatabaseUrl -or
      [string]::IsNullOrWhiteSpace([string]$appConfiguration.AppPassword) -or
      [string]$appConfiguration.AppPassword -notmatch '^[0-9a-fA-F]{64}$' -or
      [string]::IsNullOrWhiteSpace([string]$appConfiguration.JWT_SECRET) -or
      [string]$appConfiguration.JWT_SECRET -notmatch '^[0-9a-fA-F]{64}$' -or
      [string]::IsNullOrWhiteSpace([string]$adminConfiguration.AdminPassword) -or
      [string]$adminConfiguration.AdminPassword -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'The protected POS configuration does not identify the expected local database and credentials. Nothing was uninstalled.'
  }

  return $marker
}

function Test-DailyBackupTask {
  param([Parameter(Mandatory = $true)]$Task)

  if ([string]$Task.TaskName -cne $backupTaskName -or [string]$Task.TaskPath -cne $backupTaskPath) {
    throw 'The scheduled task identity does not match the approved Koli Wada Dhaba POS backup task.'
  }

  if (@($Task.Actions).Count -ne 1) {
    throw 'The POS backup task must contain exactly one action. It was left unchanged.'
  }

  $action = $Task.Actions[0]
  try {
    $actualPowerShell = [IO.Path]::GetFullPath([string]$action.Execute)
    $expectedPowerShell = [IO.Path]::GetFullPath($powershellExe)
  }
  catch {
    throw 'The POS backup task PowerShell executable path is invalid. It was left unchanged.'
  }

  $actualArguments = ([string]$action.Arguments).Replace('"', '').Trim()
  $expectedArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $backupScript"

  if (-not [string]::Equals($actualPowerShell, $expectedPowerShell, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals($actualArguments, $expectedArguments, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The POS backup task action does not exactly match the packaged Backup-LocalPos.ps1 script. It was left unchanged.'
  }

  $principal = $Task.Principal
  if ([string]$principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
      [string]$principal.LogonType -ne 'ServiceAccount' -or
      [string]$principal.RunLevel -ne 'Highest') {
    throw 'The POS backup task is not configured for SYSTEM / ServiceAccount / Highest. It was left unchanged.'
  }

  if ([string]$Task.State -eq 'Disabled' -or [string]$Task.State -eq 'Running') {
    throw "The POS backup task is disabled or currently running (state: $($Task.State)). It was left unchanged."
  }

  if ([bool]$Task.Settings.StartWhenAvailable) {
    throw 'The POS backup task is configured to start missed work during Windows startup. It was left unchanged.'
  }

  if (@($Task.Triggers).Count -ne 1) {
    throw 'The POS backup task must contain exactly one daily trigger. It was left unchanged.'
  }

  $trigger = $Task.Triggers[0]
  if ([string]$trigger.CimClass.CimClassName -ne 'MSFT_TaskDailyTrigger' -or
      [int]$trigger.DaysInterval -ne 1 -or
      -not [bool]$trigger.Enabled) {
    throw 'The POS backup task is not one enabled daily trigger with interval 1. It was left unchanged.'
  }

  $boundary = [DateTime]::MinValue
  $parsed = [DateTime]::TryParse(
    [string]$trigger.StartBoundary,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeLocal,
    [ref]$boundary
  )

  if (-not $parsed -or $boundary.TimeOfDay -ne $backupTime) {
    throw 'The POS backup task is not scheduled for 01:30 AM local Windows time. It was left unchanged.'
  }

  $scheduler = New-Object -ComObject 'Schedule.Service'
  $scheduler.Connect()
  $registeredTask = $scheduler.GetFolder($backupTaskPath).GetTask($backupTaskName)
  if ([string]$registeredTask.GetSecurityDescriptor(4) -cne 'D:P(A;;FA;;;SY)(A;;FA;;;BA)') {
    throw 'The POS backup task DACL is not limited to SYSTEM and Administrators.'
  }
}

function Test-MaintenanceBrokerTask {
  param([Parameter(Mandatory = $true)]$Task)
  if ([string]$Task.TaskName -cne $brokerTaskName -or [string]$Task.TaskPath -cne $brokerTaskPath -or
      @($Task.Actions).Count -ne 1 -or @($Task.Triggers).Count -ne 1) {
    throw 'The scheduled task identity does not match the approved POS maintenance broker.'
  }
  $action = $Task.Actions[0]
  $actualPowerShell = [IO.Path]::GetFullPath([string]$action.Execute)
  $expectedPowerShell = [IO.Path]::GetFullPath($powershellExe)
  $actualArguments = ([string]$action.Arguments).Replace('"', '').Trim()
  $expectedArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $brokerScript"
  if (-not [string]::Equals($actualPowerShell, $expectedPowerShell, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals($actualArguments, $expectedArguments, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The maintenance broker task action is unexpected. It was left unchanged.'
  }
  $principal = $Task.Principal
  if ([string]$principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18') -or
      [string]$principal.LogonType -ne 'ServiceAccount' -or [string]$principal.RunLevel -ne 'Highest') {
    throw 'The maintenance broker task is not configured for SYSTEM / ServiceAccount / Highest.'
  }
  if ([string]$Task.State -eq 'Disabled' -or [bool]$Task.Settings.StartWhenAvailable -or
      [int]$Task.Settings.RestartCount -ne 3 -or [TimeSpan]$Task.Settings.RestartInterval -ne [TimeSpan]::FromMinutes(1)) {
    throw 'The maintenance broker task has an unexpected state or startup policy.'
  }
  if ([string]$Task.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskBootTrigger' -or
      -not [bool]$Task.Triggers[0].Enabled) {
    throw 'The maintenance broker task is not registered for Windows startup.'
  }
  $scheduler = New-Object -ComObject 'Schedule.Service'
  $scheduler.Connect()
  $registeredTask = $scheduler.GetFolder($brokerTaskPath).GetTask($brokerTaskName)
  if ([string]$registeredTask.GetSecurityDescriptor(4) -cne 'D:P(A;;FA;;;SY)(A;;FA;;;BA)') {
    throw 'The maintenance broker task DACL is not limited to SYSTEM and Administrators.'
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

function Invoke-PostgresControl {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  if (-not (Test-Path -LiteralPath $pgCtl -PathType Leaf)) {
    throw 'The packaged PostgreSQL pg_ctl.exe is missing. The service registration was retained.'
  }

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $pgCtl
  $startInfo.Arguments = ($Arguments | ForEach-Object {
    ConvertTo-WindowsArgument -Value $_
  }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo

  try {
    if (-not $process.Start()) {
      throw 'Could not start the packaged PostgreSQL control tool.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit(90000)) {
      $process.Kill()
      $process.WaitForExit()
      throw 'The PostgreSQL service unregistration command timed out.'
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
      $detail = ($stderr + "`n" + $stdout).Trim()
      if ($detail.Length -gt 1200) {
        $detail = $detail.Substring(0, 1200)
      }
      throw "The PostgreSQL service operation failed (exit code $($process.ExitCode)). $detail"
    }
  }
  finally {
    $process.Dispose()
  }
}

function Register-VerifiedBackupTask {
  # Used only as rollback if service unregistration fails after a previously
  # validated POS task was removed. It recreates only the approved 01:30 task.
  $existingTask = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction SilentlyContinue
  if ($existingTask) {
    Test-DailyBackupTask -Task $existingTask
    return
  }

  $scheduler = New-Object -ComObject 'Schedule.Service'
  $scheduler.Connect()
  try {
    [void]$scheduler.GetFolder($backupTaskPath)
  }
  catch {
    [void]$scheduler.GetFolder('\').CreateFolder('Koli Wada Dhaba POS', $null)
  }

  $backupArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $backupScript + '"'
  $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $backupArguments
  $trigger = New-ScheduledTaskTrigger -Daily -At '1:30AM'
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable:$false -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)

  Register-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null

  $scheduler = New-Object -ComObject 'Schedule.Service'
  $scheduler.Connect()
  $registeredTask = $scheduler.GetFolder($backupTaskPath).GetTask($backupTaskName)
  $taskSddl = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'
  $registeredTask.SetSecurityDescriptor($taskSddl, 4)
  if ([string]$registeredTask.GetSecurityDescriptor(4) -cne $taskSddl) {
    throw 'The restored POS backup task DACL could not be restricted to SYSTEM and Administrators.'
  }

  $restoredTask = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction Stop
  Test-DailyBackupTask -Task $restoredTask
}

function Register-VerifiedMaintenanceBrokerTask {
  $existingTask = Get-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction SilentlyContinue
  if ($existingTask) {
    Test-MaintenanceBrokerTask -Task $existingTask
    if ([string]$existingTask.State -eq 'Running') { Stop-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction Stop }
  }
  $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $brokerScript + '"'
  $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable:$false `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  $scheduler = New-Object -ComObject 'Schedule.Service'
  $scheduler.Connect()
  $registeredTask = $scheduler.GetFolder($brokerTaskPath).GetTask($brokerTaskName)
  $taskSddl = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'
  $registeredTask.SetSecurityDescriptor($taskSddl, 4)
  if ([string]$registeredTask.GetSecurityDescriptor(4) -cne $taskSddl) {
    throw 'The restored maintenance broker task DACL could not be restricted to SYSTEM and Administrators.'
  }
  $restoredTask = Get-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction Stop
  Test-MaintenanceBrokerTask -Task $restoredTask
  Start-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction Stop
}

if (-not [Environment]::Is64BitOperatingSystem) {
  throw 'The Koli Wada Dhaba POS uninstaller requires 64-bit Windows.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'The POS service can only be unregistered by an elevated Windows Administrator.'
}

if (-not (Test-Path -LiteralPath $installDirectoryFull -PathType Container)) {
  throw 'The selected installation directory does not exist. No POS service or data was changed.'
}

$service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
$task = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction SilentlyContinue
$brokerTask = Get-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction SilentlyContinue

# If neither machine-wide resource exists, do not infer ownership from a folder
# name and do not touch ProgramData. Any retained database files are preserved.
if (-not $service -and -not $task -and -not $brokerTask) {
  Write-Output 'No dedicated Koli Wada Dhaba POS service or maintenance task is registered.'
  Write-Output 'ProgramData database files, business records, Owner configuration and backups were preserved.'
  exit 0
}

# Validate every resource and the machine-wide marker before making any change.
# No current Administrator SID is compared with a historical per-user marker.
$marker = Assert-InstallationIdentity

Assert-NotReparsePoint -Path $installDirectoryFull -PathType Container

if ($service) {
  Assert-OwnedPostgresService -Service $service
  Assert-NotReparsePoint -Path $pgCtl -PathType Leaf
}

if ($task) {
  if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf) -or
      -not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
    throw 'The packaged PowerShell or POS backup script is missing. The scheduled task and PostgreSQL service were left unchanged.'
  }
  Assert-NotReparsePoint -Path $backupScript -PathType Leaf
  Test-DailyBackupTask -Task $task
}

if ($brokerTask) {
  foreach ($requiredBrokerFile in @($brokerScript,$restoreScript,$powershellExe)) {
    if (-not (Test-Path -LiteralPath $requiredBrokerFile -PathType Leaf)) {
      throw 'A packaged POS maintenance broker file is missing. The task and PostgreSQL service were left unchanged.'
    }
    Assert-NotReparsePoint -Path $requiredBrokerFile -PathType Leaf
  }
  Test-MaintenanceBrokerTask -Task $brokerTask
}

if ($service -and -not (Test-Path -LiteralPath $pgCtl -PathType Leaf)) {
  throw 'The packaged PostgreSQL pg_ctl.exe is missing. The service registration was retained.'
}

$taskRemoved = $false
$brokerTaskRemoved = $false
$serviceStopAttempted = $false
$initialServiceWasRunning = if ($service) { [string]$service.State -eq 'Running' } else { $false }

try {
  # Stop/remove only the exact validated POS tasks before service removal.
  # Rollback restores both tasks if service shutdown or unregistration fails.
  if ($brokerTask) {
    $brokerRecheck = Get-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction Stop
    Test-MaintenanceBrokerTask -Task $brokerRecheck
    if ([string]$brokerRecheck.State -eq 'Running') {
      Stop-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction Stop
    }
    Unregister-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -Confirm:$false -ErrorAction Stop
    $brokerTaskRemoved = $true
    if (Get-ScheduledTask -TaskName $brokerTaskName -TaskPath $brokerTaskPath -ErrorAction SilentlyContinue) {
      throw 'The validated POS maintenance broker task still exists after unregistration.'
    }
  }

  if ($task) {
    $taskRecheck = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction Stop
    Test-DailyBackupTask -Task $taskRecheck
    Unregister-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -Confirm:$false -ErrorAction Stop
    $taskRemoved = $true

    $taskAfterRemoval = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction SilentlyContinue
    if ($taskAfterRemoval) {
      throw 'The validated POS backup task still exists after unregistration.'
    }
  }

  if ($service) {
    # Re-read and revalidate immediately before stopping the named service.
    $serviceRecheck = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
    if (-not $serviceRecheck) {
      throw 'The validated POS PostgreSQL service disappeared before shutdown. No other service was touched.'
    }
    Assert-OwnedPostgresService -Service $serviceRecheck

    $serviceController = Get-Service -Name $serviceName -ErrorAction Stop
    if ($serviceController.Status -ne 'Stopped') {
      $serviceStopAttempted = $true
      Stop-Service -Name $serviceName -ErrorAction Stop
      $serviceController = Get-Service -Name $serviceName -ErrorAction Stop
      $serviceController.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(90)
      )
    }

    # Confirm the service registration still has the exact expected identity
    # after shutdown and immediately before pg_ctl unregister.
    $stoppedService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
    if (-not $stoppedService) {
      throw 'The POS PostgreSQL service registration disappeared unexpectedly before unregistration.'
    }
    Assert-OwnedPostgresService -Service $stoppedService

    Invoke-PostgresControl -Arguments @('unregister', '-N', $serviceName)

    $remainingService = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      $remainingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
      if (-not $remainingService) { break }
      Start-Sleep -Milliseconds 500
    }
    if ($remainingService) {
      throw 'The POS PostgreSQL service still exists after the unregister command. ProgramData was preserved.'
    }
  }
}
catch {
  $primaryError = $_.Exception.Message
  $rollbackErrors = @()

  # If shutdown was attempted, restart only the previously-running POS service
  # and only after its exact registration identity is revalidated.
  $serviceStillRegistered = $true
  if ($service) {
    try {
      $remainingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
      if (-not $remainingService) {
        $serviceStillRegistered = $false
      }
      elseif ($serviceStopAttempted -and $initialServiceWasRunning) {
        Assert-OwnedPostgresService -Service $remainingService
        $currentService = Get-Service -Name $serviceName -ErrorAction Stop
        if ($currentService.Status -ne 'Running') {
          Start-Service -Name $serviceName -ErrorAction Stop
          (Get-Service -Name $serviceName -ErrorAction Stop).WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromSeconds(90)
          )
        }
      }
    }
    catch {
      $serviceStillRegistered = $false
      $rollbackErrors += "Could not restore the POS PostgreSQL service to its original running state: $($_.Exception.Message)"
    }
  }

  if ($taskRemoved) {
    if (-not $serviceStillRegistered) {
      $rollbackErrors += 'The POS PostgreSQL service registration is no longer present, so the automatic backup task was not recreated.'
    }
    else {
      try {
        Register-VerifiedBackupTask
      }
      catch {
        $rollbackErrors += "Could not restore the verified 01:30 AM backup task: $($_.Exception.Message)"
      }
    }
  }

  if ($brokerTaskRemoved) {
    if (-not $serviceStillRegistered) {
      $rollbackErrors += 'The POS PostgreSQL service registration is no longer present, so the maintenance broker task was not recreated.'
    }
    else {
      try { Register-VerifiedMaintenanceBrokerTask }
      catch { $rollbackErrors += "Could not restore the verified POS maintenance broker task: $($_.Exception.Message)" }
    }
  }

  if ($rollbackErrors.Count -gt 0) {
    throw ($primaryError + ' Rollback warning: ' + ($rollbackErrors -join ' | ') + ' The ProgramData database and backups were not deleted.')
  }

  throw ($primaryError + ' The previously validated POS resources were restored where necessary. ProgramData database and backups were not deleted.')
}

Write-Output 'The verified Koli Wada Dhaba POS PostgreSQL service, 01:30 AM backup task and SYSTEM maintenance broker task were unregistered.'
Write-Output 'ProgramData database files, business records, Owner configuration and backups were preserved.'
