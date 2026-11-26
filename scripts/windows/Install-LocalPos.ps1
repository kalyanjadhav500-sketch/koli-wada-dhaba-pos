param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDirectory
)

$ErrorActionPreference = "Stop"

# Production-only POS database identity. The development PostgreSQL service is
# deliberately never queried, started, stopped, reconfigured, or used here.
$serviceName = "KoliWadaDhabaPostgreSQL"
$databaseName = "koli_wada_dhaba"
$appRole = "kwd_app"
$port = 5433
$serviceAccount = "NT AUTHORITY\NetworkService"
$backupTaskName = "Koli Wada Dhaba POS Daily Backup"
$backupTaskPath = "\Koli Wada Dhaba POS\"
$backupTime = [TimeSpan]::FromMinutes(90) # 01:30 AM local Windows time

$programDataRoot = Join-Path $env:ProgramData "Koli Wada Dhaba POS"
$dataDirectory = Join-Path $programDataRoot "Data"
$backupDirectory = Join-Path $programDataRoot "Backups"
$configDirectory = Join-Path $programDataRoot "config"
$logDirectory = Join-Path $programDataRoot "Logs"
$markerPath = Join-Path $configDirectory "installation.json"
$appSecretPath = Join-Path $configDirectory "database-secrets.dpapi"
$adminSecretPath = Join-Path $configDirectory "postgres-admin.dpapi"

$installDirectoryFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$postgresBin = Join-Path $installDirectoryFull "resources\postgresql17\bin"
$electronPath = Join-Path $installDirectoryFull "Koli Wada Dhaba POS.exe"
$apiDirectory = Join-Path $installDirectoryFull "resources\api"
$toolsDirectory = Join-Path $installDirectoryFull "resources\installer-tools\node_modules"
$prismaCli = Join-Path $toolsDirectory "prisma\build\index.js"
$tsxCli = Join-Path $toolsDirectory "tsx\dist\cli.mjs"
$seedScript = Join-Path $apiDirectory "prisma\seed.ts"
$backupScript = Join-Path $installDirectoryFull "resources\installer\Backup-LocalPos.ps1"
$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$pgCtl = Join-Path $postgresBin "pg_ctl.exe"
$postgres = Join-Path $postgresBin "postgres.exe"
$initdb = Join-Path $postgresBin "initdb.exe"
$psql = Join-Path $postgresBin "psql.exe"
$pgRestore = Join-Path $postgresBin "pg_restore.exe"
$pgDump = Join-Path $postgresBin "pg_dump.exe"

$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$tempPasswordFile = $null
$backupResultFile = $null
$adminPassword = $null
$appPassword = $null
$jwtSecret = $null
$databaseUrl = $null
$marker = $null
$isNewCluster = $false

$environmentToRestore = @(
  "PGPASSWORD",
  "DATABASE_URL",
  "DIRECT_URL",
  "NODE_ENV",
  "ELECTRON_RUN_AS_NODE",
  "NODE_PATH"
)
$oldEnvironment = @{}
foreach ($name in $environmentToRestore) {
  $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InteractiveUserSid {
  # The API child process runs as the signed-in desktop user, not as SYSTEM.
  # Resolve that interactive account independently of the elevated installer
  # account so the app configuration remains readable after installation.
  $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  $userName = [string]$computer.UserName
  if ([string]::IsNullOrWhiteSpace($userName)) {
    throw "A signed-in Windows desktop user could not be identified. Sign in to the intended POS Windows account before installing."
  }

  try {
    $account = [Security.Principal.NTAccount]::new($userName)
    return $account.Translate([Security.Principal.SecurityIdentifier]).Value
  }
  catch {
    throw "The signed-in Windows user could not be resolved to a security identifier. No POS data was provisioned."
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
    [int]$TimeoutSeconds = 120
  )

  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    throw "$FailureMessage (required executable is missing)."
  }

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = ($Arguments | ForEach-Object {
    ConvertTo-WindowsArgument -Value $_
  }) -join " "
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

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
      if ($detail.Length -gt 1500) {
        $detail = $detail.Substring(0, 1500)
      }
      throw "$FailureMessage (exit code $($process.ExitCode)). $detail"
    }

    return $stdout
  }
  finally {
    $process.Dispose()
  }
}

function Resolve-Sid {
  param([Parameter(Mandatory = $true)][string]$Identity)

  if ($Identity -match '^S-1-[0-9-]+$') {
    return [Security.Principal.SecurityIdentifier]::new($Identity)
  }

  return ([Security.Principal.NTAccount]::new($Identity)).Translate(
    [Security.Principal.SecurityIdentifier]
  )
}

function ConvertTo-AclGrant {
  param([Parameter(Mandatory = $true)][string]$Grant)

  $match = [regex]::Match(
    $Grant,
    '^(?<identity>[^:]+):(?<flags>(?:\([A-Z]+\))*)(?<rights>RX|R|M|F)$'
  )
  if (-not $match.Success) {
    throw "Invalid ACL grant specification: $Grant"
  }

  $identity = Resolve-Sid -Identity $match.Groups['identity'].Value
  $inheritance = [Security.AccessControl.InheritanceFlags]::None
  $propagation = [Security.AccessControl.PropagationFlags]::None

  foreach ($flagMatch in [regex]::Matches($match.Groups['flags'].Value, '\(([A-Z]+)\)')) {
    switch ($flagMatch.Groups[1].Value) {
      'OI' { $inheritance = $inheritance -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit }
      'CI' { $inheritance = $inheritance -bor [Security.AccessControl.InheritanceFlags]::ContainerInherit }
      'IO' { $propagation = $propagation -bor [Security.AccessControl.PropagationFlags]::InheritOnly }
      'NP' { $propagation = $propagation -bor [Security.AccessControl.PropagationFlags]::NoPropagateInherit }
      default { throw "Unsupported ACL inheritance flag in: $Grant" }
    }
  }

  $rights = switch ($match.Groups['rights'].Value) {
    'F'  { [Security.AccessControl.FileSystemRights]::FullControl }
    'M'  { [Security.AccessControl.FileSystemRights]::Modify }
    'R'  { [Security.AccessControl.FileSystemRights]::Read }
    'RX' { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
  }

  return [pscustomobject]@{
    Sid = $identity.Value
    Identity = $identity
    Rights = $rights
    Inheritance = $inheritance
    Propagation = $propagation
    Type = [Security.AccessControl.AccessControlType]::Allow
  }
}

function Set-DirectoryAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Grants
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Cannot secure a directory that does not exist: $Path"
  }

  $expected = @($Grants | ForEach-Object { ConvertTo-AclGrant -Grant $_ })
  $expectedSids = @($expected | ForEach-Object { $_.Sid })
  if (@($expectedSids | Select-Object -Unique).Count -ne $expected.Count) {
    throw "Duplicate identities were supplied for the directory ACL: $Path"
  }

  # Disable inheritance and discard inherited entries, then remove every
  # remaining explicit ACE before applying the approved allow-list.
  $acl = Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) {
    $acl.RemoveAccessRuleAll($rule)
  }

  foreach ($entry in $expected) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $entry.Identity,
      $entry.Rights,
      $entry.Inheritance,
      $entry.Propagation,
      $entry.Type
    )
    [void]$acl.AddAccessRule($rule)
  }

  Set-Acl -LiteralPath $Path -AclObject $acl

  # Independently read the DACL back and compare SID, allow/deny, exact rights,
  # inheritance, propagation and inherited/explicit state.
  $actualAcl = Get-Acl -LiteralPath $Path
  if (-not $actualAcl.AreAccessRulesProtected) {
    throw "Directory ACL verification failed: inheritance remains enabled on $Path"
  }

  $actual = @($actualAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if ($actual.Count -ne $expected.Count) {
    throw "Directory ACL verification failed: expected $($expected.Count) ACEs but found $($actual.Count) on $Path"
  }

  foreach ($entry in $expected) {
    $matches = @($actual | Where-Object {
      $_.IdentityReference.Value -eq $entry.Sid -and
      $_.AccessControlType -eq $entry.Type -and
      [int]$_.FileSystemRights -eq [int]$entry.Rights -and
      $_.InheritanceFlags -eq $entry.Inheritance -and
      $_.PropagationFlags -eq $entry.Propagation -and
      -not $_.IsInherited
    })

    if ($matches.Count -ne 1) {
      throw "Directory ACL verification failed for SID $($entry.Sid) on $Path"
    }
  }

  foreach ($entry in $actual) {
    if ($entry.IsInherited -or
        $entry.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $entry.IdentityReference.Value -notin $expectedSids) {
      throw "Directory ACL verification found an unexpected ACE on $Path"
    }
  }
}

function Set-FileAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Grants
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Cannot secure a file that does not exist: $Path"
  }

  $expected = @($Grants | ForEach-Object { ConvertTo-AclGrant -Grant $_ })
  $expectedSids = @($expected | ForEach-Object { $_.Sid })
  if (@($expectedSids | Select-Object -Unique).Count -ne $expected.Count) {
    throw "Duplicate identities were supplied for the file ACL: $Path"
  }

  $acl = Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) {
    $acl.RemoveAccessRuleAll($rule)
  }

  foreach ($entry in $expected) {
    if ($entry.Inheritance -ne [Security.AccessControl.InheritanceFlags]::None -or
        $entry.Propagation -ne [Security.AccessControl.PropagationFlags]::None) {
      throw "File ACL entries must not contain inheritance flags: $Path"
    }

    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $entry.Identity,
      $entry.Rights,
      $entry.Type
    )
    [void]$acl.AddAccessRule($rule)
  }

  Set-Acl -LiteralPath $Path -AclObject $acl

  $actualAcl = Get-Acl -LiteralPath $Path
  if (-not $actualAcl.AreAccessRulesProtected) {
    throw "File ACL verification failed: inheritance remains enabled on $Path"
  }

  $actual = @($actualAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
  if ($actual.Count -ne $expected.Count) {
    throw "File ACL verification failed: unexpected ACE count on $Path"
  }

  foreach ($entry in $expected) {
    $matches = @($actual | Where-Object {
      $_.IdentityReference.Value -eq $entry.Sid -and
      $_.AccessControlType -eq $entry.Type -and
      [int]$_.FileSystemRights -eq [int]$entry.Rights -and
      $_.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None -and
      $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None -and
      -not $_.IsInherited
    })

    if ($matches.Count -ne 1) {
      throw "File ACL verification failed for SID $($entry.Sid) on $Path"
    }
  }
}

function Set-DirectoryTreeAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$DirectoryGrants,
    [Parameter(Mandatory = $true)][string[]]$FileGrants
  )

  Set-DirectoryAcl -Path $Path -Grants $DirectoryGrants
  $children = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)

  foreach ($child in $children) {
    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "A reparse point was found in a protected POS directory. ACL traversal was stopped safely: $($child.FullName)"
    }

    if ($child.PSIsContainer) {
      Set-DirectoryAcl -Path $child.FullName -Grants $DirectoryGrants
    }
    else {
      Set-FileAcl -Path $child.FullName -Grants $FileGrants
    }
  }
}

function Protect-Secret {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string[]]$AllowedSids
  )

  Add-Type -AssemblyName System.Security
  $plainBytes = [Text.Encoding]::UTF8.GetBytes($Value)
  $protectedBytes = $null

  try {
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
      $plainBytes,
      $null,
      [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    [IO.File]::WriteAllBytes($Path, $protectedBytes)
  }
  finally {
    [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    if ($protectedBytes) {
      [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    }
  }

  Set-FileAcl -Path $Path -Grants $AllowedSids
}

function Unprotect-Secret {
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

function New-RandomHex {
  param([int]$ByteCount = 32)

  $bytes = New-Object byte[] $ByteCount
  try {
    $random.GetBytes($bytes)
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
  }
  finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
  }
}

function ConvertFrom-WindowsCommandLine {
  param([Parameter(Mandatory = $true)][string]$CommandLine)

  if (-not ('KwdPos.NativeCommandLine' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace KwdPos {
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

  return [KwdPos.NativeCommandLine]::Split($CommandLine)
}

function Get-ServiceDataDirectory {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  for ($index = 0; $index -lt ($Arguments.Count - 1); $index++) {
    if ($Arguments[$index] -ieq '-D') {
      return $Arguments[$index + 1]
    }
  }
  return $null
}

function Assert-OwnedPostgresService {
  param([Parameter(Mandatory = $true)]$Service)

  if ($Service.Name -ne $serviceName) {
    throw "The PostgreSQL service name is not the dedicated POS service. No service changes were made."
  }

  $arguments = @(ConvertFrom-WindowsCommandLine -CommandLine ([string]$Service.PathName))
  if ($arguments.Count -ne 9) {
    throw "The dedicated POS service command line contains unexpected or missing arguments. It was left unchanged."
  }

  $actualExe = [IO.Path]::GetFullPath($arguments[0])
  $expectedExe = [IO.Path]::GetFullPath($pgCtl)
  $actualData = [IO.Path]::GetFullPath($arguments[5]).TrimEnd('\')
  $expectedData = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')

  $validCommand =
    [string]::Equals($actualExe, $expectedExe, [StringComparison]::OrdinalIgnoreCase) -and
    $arguments[1] -ieq 'runservice' -and
    $arguments[2] -ieq '-N' -and
    $arguments[3] -ceq $serviceName -and
    $arguments[4] -ieq '-D' -and
    [string]::Equals($actualData, $expectedData, [StringComparison]::OrdinalIgnoreCase) -and
    $arguments[6] -ieq '-w' -and
    $arguments[7] -ieq '-o' -and
    $arguments[8] -ceq "-p $port"

  if (-not $validCommand) {
    throw "The service command line does not exactly match the packaged pg_ctl runservice identity, name, Data directory, wait flag and port. It was left unchanged."
  }

  if (-not [string]::Equals([string]$Service.StartName, $serviceAccount, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The POS PostgreSQL service is not running as NT AUTHORITY\NetworkService. It was left unchanged."
  }

  if ([string]$Service.StartMode -ne 'Auto') {
    throw "The POS PostgreSQL service is not configured for Automatic startup. It was left unchanged."
  }
}

function Set-ServiceRecovery {
  $result = & sc.exe failure $serviceName 'reset=' '86400' 'actions=' 'restart/5000/restart/5000/restart/5000' 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not configure recovery actions for the verified POS PostgreSQL service."
  }

  $result = & sc.exe failureflag $serviceName '1' 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not enable recovery actions for the verified POS PostgreSQL service."
  }
}

function Wait-PostgresService {
  $service = Get-Service -Name $serviceName -ErrorAction Stop

  if ($service.Status -ne 'Running') {
    Start-Service -Name $serviceName
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $service.WaitForStatus(
      [System.ServiceProcess.ServiceControllerStatus]::Running,
      [TimeSpan]::FromSeconds(90)
    )
  }
}

function Invoke-Psql {
  param(
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Sql,
    [string]$Password = $adminPassword
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $psql
  $args = @(
    '-X', '-w', '-h', '127.0.0.1', '-p', "$port", '-U', 'postgres', '-d', $Database,
    '-v', 'ON_ERROR_STOP=1', '-tA', '-f', '-'
  )
  $startInfo.Arguments = ($args | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.EnvironmentVariables['PGPASSWORD'] = $Password

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo

  try {
    if (-not $process.Start()) {
      throw 'Could not start the packaged PostgreSQL client.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine($Sql)
    $process.StandardInput.Close()

    if (-not $process.WaitForExit(60000)) {
      $process.Kill()
      $process.WaitForExit()
      throw 'A PostgreSQL administration command timed out.'
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
      $detail = ($stderr + "`n" + $stdout).Trim()
      if ($detail.Length -gt 1000) {
        $detail = $detail.Substring(0, 1000)
      }
      throw "A PostgreSQL administration command failed (exit code $($process.ExitCode)). $detail"
    }

    return $stdout.Trim()
  }
  finally {
    $process.Dispose()
  }
}

function Invoke-InstallerNode {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$FailureMessage
  )

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "$FailureMessage (script is missing)."
  }

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $electronPath
  $startInfo.Arguments = ((@($ScriptPath) + $Arguments) | ForEach-Object {
    ConvertTo-WindowsArgument -Value $_
  }) -join ' '
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
  $startInfo.EnvironmentVariables['NODE_PATH'] = "$toolsDirectory;$apiDirectory\node_modules"

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo

  try {
    if (-not $process.Start()) {
      throw "$FailureMessage (process could not start)."
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit(180000)) {
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
  }
  finally {
    $process.Dispose()
  }
}

function Test-DailyBackupTask {
  param(
    [Parameter(Mandatory = $true)]$Task,
    [TimeSpan]$ExpectedTime = $backupTime,
    [switch]$AllowStartWhenAvailable
  )

  if ($Task.TaskName -ne $backupTaskName -or $Task.TaskPath -ne $backupTaskPath) {
    throw 'The scheduled backup task identity does not match the approved POS task.'
  }

  if (@($Task.Actions).Count -ne 1) {
    throw 'The existing POS backup task must have exactly one action.'
  }

  $action = $Task.Actions[0]
  $actualPowerShell = [IO.Path]::GetFullPath([string]$action.Execute)
  $expectedPowerShell = [IO.Path]::GetFullPath($powershellExe)
  $actualArguments = ([string]$action.Arguments).Replace('"', '').Trim()
  $expectedArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $backupScript"

  if (-not [string]::Equals($actualPowerShell, $expectedPowerShell, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals($actualArguments, $expectedArguments, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The existing POS backup task action does not exactly match the packaged Backup-LocalPos.ps1 script.'
  }

  $principal = $Task.Principal
  if ([string]$principal.UserId -notin @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'S-1-5-18') -or
      [string]$principal.LogonType -ne 'ServiceAccount' -or
      [string]$principal.RunLevel -ne 'Highest') {
    throw 'The existing POS backup task is not configured for SYSTEM / ServiceAccount / Highest.'
  }

  if ([string]$Task.State -eq 'Disabled') {
    throw 'The existing POS backup task is disabled.'
  }
  if (-not $AllowStartWhenAvailable -and [bool]$Task.Settings.StartWhenAvailable) {
    throw 'The existing POS backup task is configured to start missed work during Windows startup.'
  }

  if (@($Task.Triggers).Count -ne 1) {
    throw 'The existing POS backup task must contain exactly one trigger.'
  }

  $trigger = $Task.Triggers[0]
  if ([string]$trigger.CimClass.CimClassName -ne 'MSFT_TaskDailyTrigger' -or
      [int]$trigger.DaysInterval -ne 1 -or
      -not [bool]$trigger.Enabled) {
    throw 'The existing POS backup task is not one enabled daily trigger with interval 1.'
  }

  $boundary = [DateTime]::MinValue
  $parsed = [DateTime]::TryParse(
    [string]$trigger.StartBoundary,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeLocal,
    [ref]$boundary
  )
  if (-not $parsed -or $boundary.TimeOfDay -ne $ExpectedTime) {
    throw "The existing POS backup task is not scheduled for $($ExpectedTime.ToString()) local Windows time."
  }
}

function Assert-ExistingBackupTaskSafe {
  $script:upgradeBackupTask = $false
  $existingTask = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction SilentlyContinue
  if (-not $existingTask) {
    return
  }

  # Accept the final schedule without changing it.
  try {
    Test-DailyBackupTask -Task $existingTask
    return
  }
  catch {
    $currentScheduleError = $_.Exception.Message
  }

  # A prior release created this exact POS-owned task at 11:00 PM with
  # StartWhenAvailable enabled. Upgrade only that known task after verifying
  # every identity/action/principal/trigger attribute; never replace an
  # unrelated or otherwise unexpected task.
  try {
    Test-DailyBackupTask -Task $existingTask `
      -ExpectedTime ([TimeSpan]::FromHours(23)) -AllowStartWhenAvailable
    $script:upgradeBackupTask = $true
    Write-Output 'A verified legacy POS backup task will be upgraded to 01:30 AM with missed-start execution disabled.'
    return
  }
  catch {
    throw "An unexpected scheduled task is using the POS backup task name/path. It was left unchanged. Current task validation: $currentScheduleError"
  }
}

function Register-AndVerifyBackupTask {
  $existingTask = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction SilentlyContinue

  if (-not $existingTask -or $script:upgradeBackupTask) {
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

    # StartWhenAvailable is deliberately false: a laptop that misses 01:30 AM
    # must not launch a backup unexpectedly during restaurant operating hours.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable:$false `
      -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath `
      -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
      -Force | Out-Null
  }

  $verifiedTask = Get-ScheduledTask -TaskName $backupTaskName -TaskPath $backupTaskPath -ErrorAction Stop
  Test-DailyBackupTask -Task $verifiedTask
}

function Invoke-PreMigrationBackup {
  if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
    throw 'The packaged backup utility is missing. Prisma migration was not started.'
  }

  New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
  $script:backupResultFile = Join-Path $logDirectory "pre-migration-$([guid]::NewGuid().ToString('N')).json"

  # This is a machine-readable contract with Backup-LocalPos.ps1. The next
  # file update adds -Purpose and -ResultFile support; no localized console
  # text is used to decide whether migration may proceed.
  [void](Invoke-LocalExecutable -FilePath $powershellExe -Arguments @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', $backupScript,
    '-Purpose', 'PreMigration',
    '-ResultFile', $backupResultFile
  ) -FailureMessage 'The required pre-migration backup failed' -TimeoutSeconds 1800)

  if (-not (Test-Path -LiteralPath $script:backupResultFile -PathType Leaf)) {
    throw 'The backup utility did not create its required result file. Prisma migration was not started.'
  }

  $result = Get-Content -LiteralPath $script:backupResultFile -Raw | ConvertFrom-Json
  if ($result.Status -ne 'Success' -or
      $result.ServiceName -ne $serviceName -or
      [int]$result.Port -ne $port -or
      $result.DatabaseName -ne $databaseName -or
      -not [string]::Equals(
        [IO.Path]::GetFullPath([string]$result.DataDirectory).TrimEnd('\'),
        [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
      )) {
    throw 'The backup result did not prove that the dedicated POS database was backed up successfully. Prisma migration was not started.'
  }

  $backupPath = [IO.Path]::GetFullPath([string]$result.BackupPath)
  $backupRoot = [IO.Path]::GetFullPath($backupDirectory).TrimEnd('\') + '\'
  if (-not $backupPath.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    throw 'The reported backup archive is missing or outside the approved POS backup directory. Prisma migration was not started.'
  }

  $backupInfo = Get-Item -LiteralPath $backupPath
  if ($backupInfo.Length -le 0 -or [long]$result.Length -ne $backupInfo.Length) {
    throw 'The backup archive has an invalid or unexpected file size. Prisma migration was not started.'
  }

  $listing = Invoke-LocalExecutable -FilePath $pgRestore -Arguments @('--list', $backupPath) `
    -FailureMessage 'The pre-migration archive failed pg_restore validation' -TimeoutSeconds 180

  if ($listing -notmatch '(?m)^;\s+Archive created at ' -or
      $listing -notmatch '(?m)^;\s+Format: CUSTOM\s*$') {
    throw 'The pre-migration archive is not a valid PostgreSQL custom-format archive. Prisma migration was not started.'
  }

  Write-Output 'The existing POS database has a verified pre-migration backup.'
}

try {
  if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Koli Wada Dhaba POS requires 64-bit Windows.'
  }

  if (-not (Test-IsAdministrator)) {
    throw 'The local PostgreSQL setup requires Administrator permission.'
  }

  if (-not (Test-Path -LiteralPath $installDirectoryFull -PathType Container)) {
    throw 'The selected application installation directory does not exist.'
  }

  # Validate every packaged dependency before changing ProgramData, a service,
  # a scheduled task, or a PostgreSQL cluster.
  $requiredFiles = @(
    $electronPath,
    $postgres,
    $pgCtl,
    $initdb,
    $psql,
    $pgDump,
    $pgRestore,
    $prismaCli,
    $tsxCli,
    $seedScript,
    $backupScript,
    $powershellExe
  )
  foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
      throw "A required packaged runtime file is missing: $requiredFile. No database provisioning was started."
    }
  }

  $serverVersion = & $postgres --version 2>$null
  if ($LASTEXITCODE -ne 0 -or $serverVersion -notmatch '\b17\.') {
    throw 'The packaged PostgreSQL server runtime is not version 17.'
  }

  $consoleUserSid = Get-InteractiveUserSid
  $systemSid = 'S-1-5-18'
  $administratorsSid = 'S-1-5-32-544'
  $serviceSid = "NT SERVICE\$serviceName"

  $appConfigGrants = @(
    "${systemSid}:F",
    "${administratorsSid}:F",
    "${consoleUserSid}:R"
  )
  $adminConfigGrants = @(
    "${systemSid}:F",
    "${administratorsSid}:F"
  )
  $markerGrants = @(
    "${systemSid}:F",
    "${administratorsSid}:F"
  )
  $backupDirectoryGrants = @(
    "${systemSid}:(OI)(CI)F",
    "${administratorsSid}:(OI)(CI)F"
  )
  $logDirectoryGrants = @(
    "${systemSid}:(OI)(CI)F",
    "${administratorsSid}:(OI)(CI)F",
    "${consoleUserSid}:(OI)(CI)RX"
  )
  $logFileGrants = @(
    "${systemSid}:F",
    "${administratorsSid}:F",
    "${consoleUserSid}:R"
  )

  # Reject an unrelated task before performing any database upgrade work.
  Assert-ExistingBackupTaskSafe

  $existingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
  $programDataRootExisted = Test-Path -LiteralPath $programDataRoot -PathType Container
  $dataPathExisted = Test-Path -LiteralPath $dataDirectory -PathType Container
  $isNewCluster = -not $dataPathExisted
  $marker = $null

  if ($programDataRootExisted) {
    $rootItem = Get-Item -LiteralPath $programDataRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'The POS ProgramData root is a reparse point. No service or database files were changed.'
    }
  }
  if ($dataPathExisted) {
    $dataItem = Get-Item -LiteralPath $dataDirectory -Force -ErrorAction Stop
    if (($dataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'The POS Data directory is a reparse point. No service or database files were changed.'
    }
  }

  if (-not $dataPathExisted -and (
      $existingService -or
      (Test-Path -LiteralPath $markerPath) -or
      (Test-Path -LiteralPath $adminSecretPath) -or
      (Test-Path -LiteralPath $appSecretPath)
    )) {
    throw 'POS service or provisioning metadata exists without its Data directory. No cluster was initialized.'
  }

  if (-not $dataPathExisted -and $programDataRootExisted -and
      @(Get-ChildItem -LiteralPath $programDataRoot -Force -ErrorAction Stop).Count -gt 0) {
    throw 'The POS ProgramData root already contains files but no verified Data directory. The installer will not initialize into or alter it.'
  }

  if ($dataPathExisted) {
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf)) {
      throw 'The existing Data directory has no verified POS marker or PostgreSQL version file. Existing files were preserved.'
    }

    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')

    if ($marker.ServiceName -ne $serviceName -or
        $marker.DataDirectory -ne $expectedDataDirectory -or
        $marker.PostgreSQLMajor -ne '17' -or
        [int]$marker.Port -ne $port -or
        [string]::IsNullOrWhiteSpace([string]$marker.InstanceId)) {
      throw 'The existing POS installation marker does not match the machine-wide service, Data directory, PostgreSQL version, port or InstanceId. Existing files were preserved.'
    }

    if ((Get-Content -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -Raw).Trim() -ne '17') {
      throw 'The existing POS Data directory is not PostgreSQL 17. Existing files were preserved.'
    }

    if (-not (Test-Path -LiteralPath $adminSecretPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $appSecretPath -PathType Leaf)) {
      throw 'Protected POS application or administrative configuration is missing. Existing credentials and records were preserved.'
    }

    # Machine-wide identity: do not compare the current Administrator SID with
    # a historical WindowsUserSid marker field.
    $appConfiguration = Unprotect-Secret -Path $appSecretPath | ConvertFrom-Json
    if ($appConfiguration.InstanceId -ne $marker.InstanceId -or
        $appConfiguration.DATABASE_URL -notmatch '^postgresql://kwd_app:[^@]+@127\.0\.0\.1:5433/koli_wada_dhaba\?schema=public$' -or
        [string]::IsNullOrWhiteSpace([string]$appConfiguration.AppPassword) -or
        [string]::IsNullOrWhiteSpace([string]$appConfiguration.JWT_SECRET)) {
      throw 'The DPAPI application configuration does not match the protected machine-wide InstanceId or local POS database endpoint.'
    }

    $databaseUrl = [string]$appConfiguration.DATABASE_URL
    $appPassword = [string]$appConfiguration.AppPassword
    $jwtSecret = [string]$appConfiguration.JWT_SECRET

    $adminPayloadText = Unprotect-Secret -Path $adminSecretPath
    $adminPayload = $null
    try {
      $adminPayload = $adminPayloadText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
      # Backward compatibility for the previous DPAPI format, which stored
      # only the raw generated PostgreSQL administrator password.
      $adminPayload = $null
    }

    if ($adminPayload -and $adminPayload.InstanceId -and $adminPayload.AdminPassword) {
      if ($adminPayload.InstanceId -ne $marker.InstanceId) {
        throw 'The protected PostgreSQL administrative configuration belongs to a different POS InstanceId.'
      }
      $adminPassword = [string]$adminPayload.AdminPassword
    }
    else {
      if ([string]::IsNullOrWhiteSpace($adminPayloadText)) {
        throw 'The protected PostgreSQL administrative password is empty.'
      }
      $adminPassword = $adminPayloadText
      $newAdminPayload = [ordered]@{
        InstanceId = $marker.InstanceId
        AdminPassword = $adminPassword
      }
      Protect-Secret -Path $adminSecretPath -Value ($newAdminPayload | ConvertTo-Json -Compress) -AllowedSids $adminConfigGrants
    }
  }
  else {
    # Check only the dedicated POS port. Do not query or manage the developer
    # PostgreSQL service or its 5432 data directory.
    try {
      $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
      try {
        $listener.Start()
      }
      finally {
        $listener.Stop()
      }
    }
    catch {
      throw "Local port $port is already in use. The installer will not modify another service or choose a different port."
    }

    $adminPassword = New-RandomHex
    $appPassword = New-RandomHex
    $jwtSecret = New-RandomHex
    $instanceId = [guid]::NewGuid().ToString('N')
    $databaseUrl = "postgresql://${appRole}:$appPassword@127.0.0.1:${port}/${databaseName}?schema=public"

    if (-not $programDataRootExisted) {
      New-Item -ItemType Directory -Path $programDataRoot -Force | Out-Null
    }

    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $dataDirectory | Out-Null

    # Secure parent and child folders before writing credentials or data.
    Set-DirectoryAcl -Path $programDataRoot -Grants @(
      "${systemSid}:(OI)(CI)F",
      "${administratorsSid}:(OI)(CI)F",
      "${consoleUserSid}:(OI)(CI)RX"
    )
    Set-DirectoryAcl -Path $configDirectory -Grants @(
      "${systemSid}:(OI)(CI)F",
      "${administratorsSid}:(OI)(CI)F",
      "${consoleUserSid}:(OI)(CI)RX"
    )
    Set-DirectoryAcl -Path $backupDirectory -Grants $backupDirectoryGrants
    Set-DirectoryAcl -Path $logDirectory -Grants $logDirectoryGrants
    Set-DirectoryAcl -Path $dataDirectory -Grants @(
      "${systemSid}:(OI)(CI)F",
      "${administratorsSid}:(OI)(CI)F"
    )

    # All provisioning, including initdb and temporary plaintext password
    # creation, is inside the outer try/finally below.
    $tempPasswordFile = Join-Path ([IO.Path]::GetTempPath()) "kwd-pg-$([guid]::NewGuid().ToString('N')).txt"
    [IO.File]::WriteAllText($tempPasswordFile, "$adminPassword`r`n", [Text.Encoding]::ASCII)
    Set-FileAcl -Path $tempPasswordFile -Grants @(
      "${systemSid}:F",
      "${administratorsSid}:F"
    )

    [void](Invoke-LocalExecutable -FilePath $initdb -Arguments @(
      '-D', $dataDirectory,
      '-U', 'postgres',
      "--pwfile=$tempPasswordFile",
      '--auth-host=scram-sha-256',
      '--auth-local=scram-sha-256',
      '--encoding=UTF8'
    ) -FailureMessage 'Could not initialize the new empty POS PostgreSQL cluster' -TimeoutSeconds 600)

    Remove-Item -LiteralPath $tempPasswordFile -Force
    $tempPasswordFile = $null

    $postgresConfig = Join-Path $dataDirectory 'postgresql.conf'
    Add-Content -LiteralPath $postgresConfig -Encoding ASCII -Value @(
      '',
      '# Koli Wada Dhaba POS local-only settings',
      "listen_addresses = '127.0.0.1'",
      "port = $port",
      "password_encryption = 'scram-sha-256'"
    )

    Set-Content -LiteralPath (Join-Path $dataDirectory 'pg_hba.conf') -Encoding ASCII -Value @(
      'local all all scram-sha-256',
      'host all all 127.0.0.1/32 scram-sha-256',
      'host all all 0.0.0.0/0 reject',
      'host all all ::/0 reject'
    )

    $marker = [ordered]@{
      InstallationSchemaVersion = 2
      ServiceName = $serviceName
      DataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
      PostgreSQLMajor = '17'
      Port = $port
      InstanceId = $instanceId
      Seeded = $false
      CreatedUtc = [DateTime]::UtcNow.ToString('o')
    }

    $appConfiguration = [ordered]@{
      InstanceId = $instanceId
      DATABASE_URL = $databaseUrl
      AppPassword = $appPassword
      JWT_SECRET = $jwtSecret
      NODE_ENV = 'production'
      API_HOST = '127.0.0.1'
      PORT = '4000'
    }

    $adminConfiguration = [ordered]@{
      InstanceId = $instanceId
      AdminPassword = $adminPassword
    }

    # Write protected configuration first; the marker is written last so a
    # partial/interrupted init cannot be mistaken for a completed install.
    Protect-Secret -Path $appSecretPath -Value ($appConfiguration | ConvertTo-Json -Compress) -AllowedSids $appConfigGrants
    Protect-Secret -Path $adminSecretPath -Value ($adminConfiguration | ConvertTo-Json -Compress) -AllowedSids $adminConfigGrants
    $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding UTF8
    Set-FileAcl -Path $markerPath -Grants $markerGrants
  }

  # Refuse unexpected files, directories and reparse points before creating
  # missing child folders or applying inherited permissions.
  $approvedRootNames = @('Data', 'Backups', 'config', 'Logs')
  foreach ($rootEntry in @(Get-ChildItem -LiteralPath $programDataRoot -Force -ErrorAction Stop)) {
    if (-not $rootEntry.PSIsContainer -or $rootEntry.Name -notin $approvedRootNames -or
        ($rootEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "An unexpected file or directory exists in the protected POS ProgramData root: $($rootEntry.Name)"
    }
  }

  # Ensure the approved support directories exist on older installations
  # only after the existing ProgramData children have passed the check above.
  New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
  New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

  # Re-apply machine-wide parent/child ACLs on upgrades. Backup files are
  # accessible only to SYSTEM and Administrators, never to Owner/Cashier OS
  # accounts. The normal POS user can read only the application configuration.
  Set-DirectoryAcl -Path $programDataRoot -Grants @(
    "${systemSid}:(OI)(CI)F",
    "${administratorsSid}:(OI)(CI)F",
    "${consoleUserSid}:(OI)(CI)RX"
  )
  $allowedConfigNames = @(
    [IO.Path]::GetFileName($markerPath),
    [IO.Path]::GetFileName($appSecretPath),
    [IO.Path]::GetFileName($adminSecretPath)
  )
  foreach ($configEntry in @(Get-ChildItem -LiteralPath $configDirectory -Force -ErrorAction Stop)) {
    if ($configEntry.PSIsContainer -or $configEntry.Name -notin $allowedConfigNames) {
      throw "An unexpected file or directory exists in the protected POS configuration folder: $($configEntry.Name)"
    }
  }

  Set-DirectoryAcl -Path $configDirectory -Grants @(
    "${systemSid}:(OI)(CI)F",
    "${administratorsSid}:(OI)(CI)F",
    "${consoleUserSid}:(OI)(CI)RX"
  )
  Set-DirectoryTreeAcl -Path $backupDirectory `
    -DirectoryGrants $backupDirectoryGrants `
    -FileGrants @("${systemSid}:F", "${administratorsSid}:F")
  Set-DirectoryTreeAcl -Path $logDirectory `
    -DirectoryGrants $logDirectoryGrants `
    -FileGrants $logFileGrants

  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    Set-FileAcl -Path $markerPath -Grants $markerGrants
  }
  if (Test-Path -LiteralPath $adminSecretPath -PathType Leaf) {
    Set-FileAcl -Path $adminSecretPath -Grants $adminConfigGrants
  }
  if (Test-Path -LiteralPath $appSecretPath -PathType Leaf) {
    Set-FileAcl -Path $appSecretPath -Grants $appConfigGrants
  }

  if (-not $dataPathExisted -and -not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf)) {
    throw 'The new PostgreSQL cluster initialization did not complete. Its files were preserved for diagnosis.'
  }

  $expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
  $existingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue

  if ($existingService) {
    Assert-OwnedPostgresService -Service $existingService
  }
  else {
    if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -PathType Leaf)) {
      throw 'A verified PostgreSQL 17 Data directory is required before service registration.'
    }

    [void](Invoke-LocalExecutable -FilePath $pgCtl -Arguments @(
      'register',
      '-N', $serviceName,
      '-D', $dataDirectory,
      '-U', $serviceAccount,
      '-S', 'auto',
      '-o', "-p $port"
    ) -FailureMessage 'Could not register the dedicated POS PostgreSQL service' -TimeoutSeconds 120)

    $existingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
    Assert-OwnedPostgresService -Service $existingService
  }

  # Only after the exact service command, account, Data path and startup type
  # have passed validation may service-specific configuration be changed.
  # Changing ServiceSidType does not retrofit the token of a running process,
  # so a verified POS service is stopped only when its SID type must change.
  $serviceSidRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
  $serviceSidType = 0
  try {
    $serviceSidType = [int](Get-ItemProperty -LiteralPath $serviceSidRegistryPath -Name ServiceSidType -ErrorAction Stop).ServiceSidType
  }
  catch {
    $serviceSidType = 0
  }

  $sidTypeNeedsRestart = $serviceSidType -ne 1
  if ($sidTypeNeedsRestart) {
    $sidTypeResult = & sc.exe sidtype $serviceName 'unrestricted' 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw 'Could not enable the POS PostgreSQL service SID.'
    }

    $serviceState = Get-Service -Name $serviceName -ErrorAction Stop
    if ($serviceState.Status -eq 'Running') {
      Stop-Service -Name $serviceName
      $serviceState = Get-Service -Name $serviceName -ErrorAction Stop
      $serviceState.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(90)
      )
    }
  }

  # Stop only the identity-verified POS service before recursively replacing
  # Data-file ACLs. PostgreSQL then starts with a fresh token containing the
  # enabled service SID. No other PostgreSQL service is queried or stopped.
  $serviceState = Get-Service -Name $serviceName -ErrorAction Stop
  if ($serviceState.Status -eq 'Running') {
    Stop-Service -Name $serviceName
    $serviceState = Get-Service -Name $serviceName -ErrorAction Stop
    $serviceState.WaitForStatus(
      [System.ServiceProcess.ServiceControllerStatus]::Stopped,
      [TimeSpan]::FromSeconds(90)
    )
  }

  Set-DirectoryAcl -Path $programDataRoot -Grants @(
    "${systemSid}:(OI)(CI)F",
    "${administratorsSid}:(OI)(CI)F",
    "${consoleUserSid}:(OI)(CI)RX",
    "${serviceSid}:(OI)(CI)RX"
  )
  Set-DirectoryTreeAcl -Path $dataDirectory `
    -DirectoryGrants @(
      "${systemSid}:(OI)(CI)F",
      "${administratorsSid}:(OI)(CI)F",
      "${serviceSid}:(OI)(CI)M"
    ) `
    -FileGrants @(
      "${systemSid}:F",
      "${administratorsSid}:F",
      "${serviceSid}:M"
    )

  Set-ServiceRecovery
  Wait-PostgresService

  $serverConfiguration = Invoke-Psql -Database 'postgres' `
    -Sql "SELECT current_setting('data_directory'), current_setting('listen_addresses'), current_setting('port')"
  $settings = $serverConfiguration -split '\|'

  if ($settings.Count -ne 3 -or
      -not [string]::Equals(
        [IO.Path]::GetFullPath($settings[0]).TrimEnd('\'),
        $expectedDataDirectory,
        [StringComparison]::OrdinalIgnoreCase
      ) -or
      $settings[1] -ne '127.0.0.1' -or
      $settings[2] -ne "$port") {
    throw 'The running POS PostgreSQL instance failed its exact Data directory, loopback listener and port verification.'
  }

  $roleExists = (Invoke-Psql -Database 'postgres' -Sql "SELECT 1 FROM pg_roles WHERE rolname = '$appRole'") -eq '1'
  $databaseExists = (Invoke-Psql -Database 'postgres' -Sql "SELECT 1 FROM pg_database WHERE datname = '$databaseName'") -eq '1'

  if (-not $roleExists -and -not $databaseExists) {
    [void](Invoke-Psql -Database 'postgres' -Sql "CREATE ROLE $appRole WITH LOGIN PASSWORD '$appPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION")
    [void](Invoke-Psql -Database 'postgres' -Sql "CREATE DATABASE $databaseName OWNER $appRole")
  }
  elseif (-not $roleExists -or -not $databaseExists) {
    throw 'The existing POS cluster has only one of the application role/database objects. Nothing was dropped or recreated.'
  }

  if (-not $isNewCluster) {
    # The current Backup-LocalPos.ps1 is updated in the next file step to emit
    # the required ResultFile JSON contract. Until that file is replaced, this
    # call will safely fail closed rather than run Prisma migrations unbacked.
    [void](Invoke-PreMigrationBackup)
  }
  else {
    Write-Output 'New empty POS cluster detected; no existing business database required a pre-migration backup.'
  }

  $env:DATABASE_URL = $databaseUrl
  $env:DIRECT_URL = $databaseUrl
  $env:NODE_ENV = 'production'
  $env:NODE_PATH = "$toolsDirectory;$apiDirectory\node_modules"

  Invoke-InstallerNode -ScriptPath $prismaCli -Arguments @('migrate', 'deploy') `
    -WorkingDirectory $apiDirectory -FailureMessage 'Prisma migrations could not be applied safely'

  $previousPassword = $env:PGPASSWORD
  $env:PGPASSWORD = $appPassword
  try {
    $counts = & $psql -X -w -h 127.0.0.1 -p $port -U $appRole -d $databaseName `
      -v ON_ERROR_STOP=1 -tA -c `
      'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User"), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment")' 2>&1

    if ($LASTEXITCODE -ne 0) {
      throw 'Could not read POS master and business record counts after migration.'
    }

    $allCounts = ($counts | Out-String).Trim()
    $countParts = $allCounts -split '\|'

    if ($countParts.Count -ne 6 -or @($countParts | Where-Object { $_ -notmatch '^\d+$' }).Count -gt 0) {
      throw 'The POS database returned invalid record counts. Existing data was preserved; no seed was run.'
    }

    $masterCounts = $countParts[0..2] -join '|'

    if (-not $marker.Seeded) {
      if ($allCounts -eq '0|0|0|0|0|0') {
        Invoke-InstallerNode -ScriptPath $tsxCli -Arguments @($seedScript) `
          -WorkingDirectory $apiDirectory -FailureMessage 'Initial POS menu and table seeding failed'
        $marker.Seeded = $true
      }
      elseif ($masterCounts -eq '70|13|120') {
        # A stale/missing Seeded marker is not permission to seed again.
        # Preserve all User, Bill, BillItem, Payment and AuditLog records.
        $marker.Seeded = $true
      }
      else {
        throw 'Restaurant master data is partial/inconsistent or business records exist without master data. No seed, delete or recreation was performed.'
      }
    }

    $verifiedMasters = & $psql -X -w -h 127.0.0.1 -p $port -U $appRole -d $databaseName `
      -v ON_ERROR_STOP=1 -tA -c `
      'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem")' 2>&1

    if ($LASTEXITCODE -ne 0 -or (($verifiedMasters | Out-String).Trim() -ne '70|13|120')) {
      throw 'Final POS master-data verification failed. No business records were deleted or reseeded.'
    }
  }
  finally {
    if ($null -eq $previousPassword) {
      Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
    else {
      $env:PGPASSWORD = $previousPassword
    }
  }

  Register-AndVerifyBackupTask

  # Update marker metadata only after the cluster identity, migrations, master
  # records and scheduled backup task have all been verified.
  $marker.InstallationSchemaVersion = 2
  $marker.ServiceName = $serviceName
  $marker.DataDirectory = $expectedDataDirectory
  $marker.PostgreSQLMajor = '17'
  $marker.Port = $port
  $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding UTF8
  Set-FileAcl -Path $markerPath -Grants $markerGrants

  Write-Output "Dedicated PostgreSQL 17 service verified on 127.0.0.1:$port."
  Write-Output 'Restaurant master data verified: 70 tables, 13 categories and 120 menu items.'
  Write-Output 'Automatic backup task verified for 01:30 AM local Windows time.'
  Write-Output 'StartWhenAvailable is disabled; a missed backup will not interrupt restaurant operating hours.'
}
finally {
  # This outer finally covers initdb success, failure, and timeout, as well as
  # every later provisioning/migration step.
  if ($tempPasswordFile -and (Test-Path -LiteralPath $tempPasswordFile)) {
    Remove-Item -LiteralPath $tempPasswordFile -Force -ErrorAction SilentlyContinue
  }

  if ($backupResultFile -and (Test-Path -LiteralPath $backupResultFile)) {
    Remove-Item -LiteralPath $backupResultFile -Force -ErrorAction SilentlyContinue
  }

  foreach ($name in $environmentToRestore) {
    [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
  }

  $adminPassword = $null
  $appPassword = $null
  $jwtSecret = $null
  $databaseUrl = $null

  if ($random) {
    $random.Dispose()
  }
}
