param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDirectory
)

$ErrorActionPreference = "Stop"
$serviceName = "KoliWadaDhabaPostgreSQL"
$databaseName = "koli_wada_dhaba"
$appRole = "kwd_app"
$port = 5433
$programDataRoot = Join-Path $env:ProgramData "Koli Wada Dhaba POS"
$dataDirectory = Join-Path $programDataRoot "Data"
$backupDirectory = Join-Path $programDataRoot "Backups"
$configDirectory = Join-Path $programDataRoot "config"
$markerPath = Join-Path $configDirectory "installation.json"
$appSecretPath = Join-Path $configDirectory "database-secrets.dpapi"
$adminSecretPath = Join-Path $configDirectory "postgres-admin.dpapi"
$postgresBin = Join-Path $InstallDirectory "resources\postgresql17\bin"
$electronPath = Join-Path $InstallDirectory "Koli Wada Dhaba POS.exe"
$apiDirectory = Join-Path $InstallDirectory "resources\api"
$toolsDirectory = Join-Path $InstallDirectory "resources\installer-tools\node_modules"
$prismaCli = Join-Path $toolsDirectory "prisma\build\index.js"
$tsxCli = Join-Path $toolsDirectory "tsx\dist\cli.mjs"
$seedScript = Join-Path $apiDirectory "prisma\seed.ts"
$backupScript = Join-Path $InstallDirectory "resources\installer\Backup-LocalPos.ps1"
$pgCtl = Join-Path $postgresBin "pg_ctl.exe"
$postgres = Join-Path $postgresBin "postgres.exe"
$initdb = Join-Path $postgresBin "initdb.exe"
$psql = Join-Path $postgresBin "psql.exe"
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$tempPasswordFile = $null
$adminPassword = $null
$appPassword = $null
$jwtSecret = $null
$databaseUrl = $null
$environmentToRestore = @("PGPASSWORD", "DATABASE_URL", "DIRECT_URL", "NODE_ENV", "ELECTRON_RUN_AS_NODE", "NODE_PATH")
$oldEnvironment = @{}

foreach ($name in $environmentToRestore) {
  $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join " "
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
    $output = $stdoutTask.GetAwaiter().GetResult()
    $errorOutput = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      $detail = ($errorOutput + "`n" + $output).Trim()
      if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) }
      throw "$FailureMessage (exit code $($process.ExitCode)). $detail"
    }
    return $output
  }
  finally {
    $process.Dispose()
  }
}

function Set-DirectoryAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Grants
  )

  $arguments = @($Path, "/inheritance:r", "/grant:r") + $Grants
  $result = & icacls.exe @arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not apply restrictive permissions to the local POS data directory."
  }
}

function Set-FileAcl {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Sids
  )

  $acl = Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) {
    [void]$acl.RemoveAccessRuleAll($rule)
  }
  foreach ($sid in $Sids) {
    $identity = [Security.Principal.SecurityIdentifier]::new($sid)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $identity,
      [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function Protect-Secret {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string[]]$AllowedSids
  )

  Add-Type -AssemblyName System.Security
  $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
  try {
    $protected = [Security.Cryptography.ProtectedData]::Protect(
      $bytes,
      $null,
      [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    [IO.File]::WriteAllBytes($Path, $protected)
  }
  finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
  }
  Set-FileAcl -Path $Path -Sids $AllowedSids
}

function Unprotect-Secret {
  param([Parameter(Mandatory = $true)][string]$Path)

  Add-Type -AssemblyName System.Security
  $protected = [IO.File]::ReadAllBytes($Path)
  $plain = [Security.Cryptography.ProtectedData]::Unprotect(
    $protected,
    $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine
  )
  try {
    return [Text.Encoding]::UTF8.GetString($plain)
  }
  finally {
    [Array]::Clear($protected, 0, $protected.Length)
    [Array]::Clear($plain, 0, $plain.Length)
  }
}

function New-RandomHex {
  param([int]$ByteCount = 32)
  $bytes = New-Object byte[] $ByteCount
  try {
    $random.GetBytes($bytes)
    return [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
  }
  finally {
    [Array]::Clear($bytes, 0, $bytes.Length)
  }
}

function Invoke-Psql {
  param(
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Sql
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $psql
  $startInfo.Arguments = (@(
    "-X", "-w", "-h", "127.0.0.1", "-p", "$port", "-U", "postgres", "-d", $Database,
    "-v", "ON_ERROR_STOP=1", "-tA", "-f", "-"
  ) | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join " "
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.EnvironmentVariables["PGPASSWORD"] = $adminPassword
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "Could not start the PostgreSQL client." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine($Sql)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(60000)) {
      $process.Kill()
      $process.WaitForExit()
      throw "A PostgreSQL command timed out."
    }
    $output = $stdoutTask.GetAwaiter().GetResult()
    $errorOutput = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      $detail = ($errorOutput + "`n" + $output).Trim()
      if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
      throw "A PostgreSQL command failed (exit code $($process.ExitCode)). $detail"
    }
    return $output.Trim()
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

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $electronPath
  $startInfo.Arguments = ((@($ScriptPath) + $Arguments) | ForEach-Object {
      ConvertTo-WindowsArgument -Value $_
    }) -join " "
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $startInfo.EnvironmentVariables["ELECTRON_RUN_AS_NODE"] = "1"
  $startInfo.EnvironmentVariables["NODE_PATH"] = "$toolsDirectory;$($apiDirectory)\node_modules"
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "$FailureMessage (process could not start)." }
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
      if ($detail.Length -gt 1600) { $detail = $detail.Substring(0, 1600) }
      throw "$FailureMessage (exit code $($process.ExitCode)). $detail"
    }
  }
  finally {
    $process.Dispose()
  }
}

function Get-ServiceDataDirectory {
  param([Parameter(Mandatory = $true)][string]$PathName)
  $match = [regex]::Match($PathName, '(?i)\s-D\s+(?:"([^"]+)"|(\S+))')
  if (-not $match.Success) { return $null }
  if ($match.Groups[1].Success) { return $match.Groups[1].Value }
  return $match.Groups[2].Value
}

function Set-ServiceRecovery {
  $result = & sc.exe failure $serviceName "reset=" "86400" "actions=" "restart/5000/restart/5000/restart/5000" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not configure PostgreSQL service recovery." }
  $result = & sc.exe failureflag $serviceName "1" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not configure PostgreSQL service recovery actions." }
}

function Wait-PostgresService {
  $service = Get-Service -Name $serviceName -ErrorAction Stop
  if ($service.Status -ne "Running") {
    Start-Service -Name $serviceName
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $service.WaitForStatus(
      [ServiceProcess.ServiceControllerStatus]::Running,
      [TimeSpan]::FromSeconds(90)
    )
  }
}

if (-not [Environment]::Is64BitOperatingSystem) {
  throw "Koli Wada Dhaba POS requires 64-bit Windows."
}
if (-not (Test-IsAdministrator)) {
  throw "The local PostgreSQL setup requires administrator permission."
}
if (-not (Test-Path -LiteralPath $electronPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $initdb -PathType Leaf) -or
    -not (Test-Path -LiteralPath $pgCtl -PathType Leaf) -or
    -not (Test-Path -LiteralPath $postgres -PathType Leaf) -or
    -not (Test-Path -LiteralPath $psql -PathType Leaf) -or
    -not (Test-Path -LiteralPath $prismaCli -PathType Leaf) -or
    -not (Test-Path -LiteralPath $tsxCli -PathType Leaf) -or
    -not (Test-Path -LiteralPath $seedScript -PathType Leaf)) {
  throw "The installer is missing a required PostgreSQL, Prisma, Node, or seed runtime file."
}
$serverVersion = & $postgres --version 2>$null
if ($LASTEXITCODE -ne 0 -or $serverVersion -notmatch '\b17\.') {
  throw "The bundled PostgreSQL runtime is not version 17."
}

$installDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$expectedPgCtl = [IO.Path]::GetFullPath($pgCtl)
$expectedDataDirectory = [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\')
$existingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
$programDataRootExisted = Test-Path -LiteralPath $programDataRoot -PathType Container
$dataPathExisted = Test-Path -LiteralPath $dataDirectory -PathType Container
$marker = $null
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$appSecretSids = @("S-1-5-18", "S-1-5-32-544", $currentSid)
$serviceSid = "NT SERVICE\$serviceName"

if ($existingService) {
  $serviceExeMatch = [regex]::Match($existingService.PathName, '^(?:"([^"]+)"|(\S+))')
  $serviceExecutable = if ($serviceExeMatch.Groups[1].Success) {
    $serviceExeMatch.Groups[1].Value
  } else {
    $serviceExeMatch.Groups[2].Value
  }
  $serviceData = Get-ServiceDataDirectory -PathName $existingService.PathName
  if (-not $serviceData -or
      -not [string]::Equals([IO.Path]::GetFullPath($serviceData).TrimEnd('\'), $expectedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([IO.Path]::GetFullPath($serviceExecutable), $expectedPgCtl, [StringComparison]::OrdinalIgnoreCase)) {
    throw "A service named '$serviceName' exists but does not point to this POS installation and ProgramData database. It was left unchanged."
  }
}

if (-not $dataPathExisted -and (
    $existingService -or
    (Test-Path -LiteralPath $markerPath) -or
    (Test-Path -LiteralPath $adminSecretPath) -or
    (Test-Path -LiteralPath $appSecretPath)
  )) {
  throw "Existing POS service or provisioning metadata was found without its database directory. No cluster was initialized."
}
if (-not $dataPathExisted -and $programDataRootExisted -and
    @(Get-ChildItem -LiteralPath $programDataRoot -Force -ErrorAction Stop).Count -gt 0) {
  throw "The POS ProgramData folder already contains files but no verified database cluster. The installer will not initialize into or alter it."
}

if ($dataPathExisted) {
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $dataDirectory "PG_VERSION") -PathType Leaf)) {
    throw "The ProgramData Data directory already exists without a verified Koli Wada Dhaba cluster marker. It was not initialized, changed, or deleted."
  }
  $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
  if ($marker.ServiceName -ne $serviceName -or
      $marker.DataDirectory -ne $expectedDataDirectory -or
      $marker.PostgreSQLMajor -ne "17" -or
      $marker.WindowsUserSid -ne $currentSid -or
      -not $marker.InstanceId) {
    throw "The existing ProgramData cluster marker does not match this POS installation. No existing data was changed."
  }
  if ((Get-Content -LiteralPath (Join-Path $dataDirectory "PG_VERSION") -Raw).Trim() -ne "17") {
    throw "The existing ProgramData cluster is not PostgreSQL 17. No existing data was changed."
  }
  if (-not (Test-Path -LiteralPath $adminSecretPath -PathType Leaf) -or
      -not (Test-Path -LiteralPath $appSecretPath -PathType Leaf)) {
    throw "Protected PostgreSQL credentials are missing for the existing cluster. No credentials or database records were replaced."
  }
  Set-DirectoryAcl -Path $configDirectory -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F", "$currentSid:(OI)(CI)F"
  )
  Set-FileAcl -Path $adminSecretPath -Sids @("S-1-5-18", "S-1-5-32-544")
  Set-FileAcl -Path $appSecretPath -Sids $appSecretSids
  $adminPassword = Unprotect-Secret -Path $adminSecretPath
  $appConfiguration = Unprotect-Secret -Path $appSecretPath | ConvertFrom-Json
  if ($appConfiguration.InstanceId -ne $marker.InstanceId -or
      $appConfiguration.DATABASE_URL -notmatch '@127\.0\.0\.1:5433/') {
    throw "The protected application credentials do not match the existing POS cluster."
  }
  $appPassword = $appConfiguration.AppPassword
  $jwtSecret = $appConfiguration.JWT_SECRET
  $databaseUrl = $appConfiguration.DATABASE_URL
}
else {
  try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
    try { $listener.Start() } finally { $listener.Stop() }
  }
  catch {
    throw "Local port $port is already in use. The installer will not change another PostgreSQL service or choose a conflicting port."
  }
  New-Item -ItemType Directory -Path $programDataRoot -Force | Out-Null
  Set-DirectoryAcl -Path $programDataRoot -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F"
  )
  New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
  Set-DirectoryAcl -Path $configDirectory -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F", "$currentSid:(OI)(CI)F"
  )
  New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
  Set-DirectoryAcl -Path $backupDirectory -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F", "$currentSid:(OI)(CI)M"
  )
  New-Item -ItemType Directory -Path $dataDirectory | Out-Null
  Set-DirectoryAcl -Path $dataDirectory -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F"
  )
  $adminPassword = New-RandomHex
  $appPassword = New-RandomHex
  $jwtSecret = New-RandomHex
  $instanceId = [guid]::NewGuid().ToString("N")
  $marker = [ordered]@{
    ServiceName = $serviceName
    DataDirectory = $expectedDataDirectory
    PostgreSQLMajor = "17"
    Port = $port
    InstanceId = $instanceId
    WindowsUserSid = $currentSid
    Seeded = $false
    CreatedUtc = [DateTime]::UtcNow.ToString("o")
  }
  $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
  $marker | ConvertTo-Json | Out-Null
  Protect-Secret -Path $adminSecretPath -Value $adminPassword -AllowedSids @("S-1-5-18", "S-1-5-32-544")
  $databaseUrl = "postgresql://${appRole}:$appPassword@127.0.0.1:${port}/${databaseName}?schema=public"
  $appConfiguration = [ordered]@{
    InstanceId = $instanceId
    DATABASE_URL = $databaseUrl
    AppPassword = $appPassword
    JWT_SECRET = $jwtSecret
    NODE_ENV = "production"
    API_HOST = "127.0.0.1"
    PORT = "4000"
  }
  Protect-Secret -Path $appSecretPath -Value ($appConfiguration | ConvertTo-Json -Compress) -AllowedSids $appSecretSids
  Set-FileAcl -Path $markerPath -Sids @("S-1-5-18", "S-1-5-32-544", $currentSid)

  $tempPasswordFile = Join-Path ([IO.Path]::GetTempPath()) "kwd-pg-$([guid]::NewGuid().ToString('N')).txt"
  [IO.File]::WriteAllText($tempPasswordFile, "$adminPassword`r`n", [Text.Encoding]::ASCII)
  Set-FileAcl -Path $tempPasswordFile -Sids @("S-1-5-18", "S-1-5-32-544", $currentSid)
  [void](Invoke-LocalExecutable -FilePath $initdb -Arguments @(
    "-D", $dataDirectory, "-U", "postgres", "--pwfile=$tempPasswordFile",
    "--auth-host=scram-sha-256", "--auth-local=scram-sha-256", "--encoding=UTF8"
  ) -FailureMessage "Could not initialize the new, empty POS PostgreSQL cluster")
  Remove-Item -LiteralPath $tempPasswordFile -Force
  $tempPasswordFile = $null
  $postgresConfig = Join-Path $dataDirectory "postgresql.conf"
  Add-Content -LiteralPath $postgresConfig -Encoding ASCII -Value @(
    "",
    "# Koli Wada Dhaba POS local-only settings",
    "listen_addresses = '127.0.0.1'",
    "port = $port",
    "password_encryption = 'scram-sha-256'"
  )
  Set-Content -LiteralPath (Join-Path $dataDirectory "pg_hba.conf") -Encoding ASCII -Value @(
    "local all all scram-sha-256",
    "host all all 127.0.0.1/32 scram-sha-256",
    "host all all 0.0.0.0/0 reject",
    "host all all ::/0 reject"
  )
}

if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
  New-Item -ItemType Directory -Path $backupDirectory | Out-Null
}

try {
  if (-not $existingService) {
    if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory "PG_VERSION") -PathType Leaf)) {
      throw "The new cluster did not finish initialization; the database directory was preserved for inspection."
    }
    [void](Invoke-LocalExecutable -FilePath $pgCtl -Arguments @(
      "register", "-N", $serviceName, "-D", $dataDirectory,
      "-U", "NT AUTHORITY\NetworkService", "-S", "auto", "-o", "-p $port"
    ) -FailureMessage "Could not register the dedicated PostgreSQL Windows service")
    $existingService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
  }

  $result = & sc.exe sidtype $serviceName "unrestricted" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not enable the dedicated PostgreSQL service SID." }
  Set-DirectoryAcl -Path $programDataRoot -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F", "$serviceSid:(RX)"
  )
  Set-DirectoryAcl -Path $dataDirectory -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F", "$serviceSid:(OI)(CI)M"
  )
  Set-DirectoryAcl -Path $backupDirectory -Grants @(
    "S-1-5-18:(OI)(CI)F", "S-1-5-32-544:(OI)(CI)F", "$currentSid:(OI)(CI)M"
  )

  $verifiedData = Get-ServiceDataDirectory -PathName $existingService.PathName
  if (-not $verifiedData -or
      -not [string]::Equals([IO.Path]::GetFullPath($verifiedData).TrimEnd('\'), $expectedDataDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The registered POS service does not use the verified ProgramData database directory."
  }
  Set-Service -Name $serviceName -StartupType Automatic
  Set-ServiceRecovery
  Wait-PostgresService

  $serverConfiguration = Invoke-Psql -Database "postgres" `
    -Sql "SELECT current_setting('data_directory'), current_setting('listen_addresses'), current_setting('port')"
  $settings = $serverConfiguration -split '\|'
  if ($settings.Count -ne 3 -or
      -not [string]::Equals([IO.Path]::GetFullPath($settings[0]).TrimEnd('\'), $expectedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
      $settings[1] -ne "127.0.0.1" -or $settings[2] -ne "$port") {
    throw "The running POS database failed its data-path, loopback-listener, or port verification."
  }

  $roleExists = (Invoke-Psql -Database "postgres" -Sql "SELECT 1 FROM pg_roles WHERE rolname = '$appRole'") -eq "1"
  $databaseExists = (Invoke-Psql -Database "postgres" -Sql "SELECT 1 FROM pg_database WHERE datname = '$databaseName'") -eq "1"
  if (-not $roleExists -and -not $databaseExists) {
    [void](Invoke-Psql -Database "postgres" `
      -Sql "CREATE ROLE $appRole WITH LOGIN PASSWORD '$appPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION")
    [void](Invoke-Psql -Database "postgres" -Sql "CREATE DATABASE $databaseName OWNER $appRole")
  }
  elseif (-not $roleExists -or -not $databaseExists) {
    throw "The existing POS database has a partial role/database setup. No role, database, or business data was removed or overwritten."
  }

  $env:DATABASE_URL = $databaseUrl
  $env:DIRECT_URL = $databaseUrl
  $env:NODE_ENV = "production"
  $env:NODE_PATH = "$toolsDirectory;$($apiDirectory)\node_modules"
  Invoke-InstallerNode -ScriptPath $prismaCli -Arguments @("migrate", "deploy") `
    -WorkingDirectory $apiDirectory -FailureMessage "Prisma migrations could not be applied safely"

  if (-not $marker.Seeded) {
    $appEnvironment = $env:PGPASSWORD
    $env:PGPASSWORD = $appPassword
    try {
      $counts = & $psql -X -w -h 127.0.0.1 -p $port -U $appRole -d $databaseName `
        -v ON_ERROR_STOP=1 -tA -c `
        'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User"), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment")' 2>&1
      if ($LASTEXITCODE -ne 0) { throw "Could not verify the new database before seeding." }
      $masterCounts = ($counts | Out-String).Trim()
      if ($masterCounts -eq "0|0|0|0|0|0") {
        Invoke-InstallerNode -ScriptPath $tsxCli -Arguments @($seedScript) `
          -WorkingDirectory $apiDirectory -FailureMessage "Initial menu and table seeding failed"
        $marker.Seeded = $true
      }
      elseif ($masterCounts -eq "70|13|120|0|0|0") {
        $marker.Seeded = $true
      }
      else {
        throw "The database contains unexpected data; initial seeding was not run."
      }
    }
    finally {
      $env:PGPASSWORD = $appEnvironment
    }
  }

  if ($marker.Seeded) {
    $env:PGPASSWORD = $appPassword
    try {
      $verifiedCounts = & $psql -X -w -h 127.0.0.1 -p $port -U $appRole -d $databaseName `
        -v ON_ERROR_STOP=1 -tA -c `
        'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem")' 2>&1
      if ($LASTEXITCODE -ne 0 -or (($verifiedCounts | Out-String).Trim() -ne "70|13|120")) {
        throw "The POS master-data verification failed; existing data was preserved."
      }
    }
    finally {
      Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
  }

  $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
  Set-FileAcl -Path $markerPath -Sids @("S-1-5-18", "S-1-5-32-544", $currentSid)
  $taskName = "Koli Wada Dhaba POS Daily Backup"
  $taskPath = "\Koli Wada Dhaba POS\"
  $scheduler = New-Object -ComObject "Schedule.Service"
  $scheduler.Connect()
  try {
    [void]$scheduler.GetFolder($taskPath)
  }
  catch {
    [void]$scheduler.GetFolder("\").CreateFolder("Koli Wada Dhaba POS", $null)
  }
  $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
  if ($existingTask) {
    $taskCommand = $existingTask.Actions | Where-Object { $_.Execute -match 'powershell' } | Select-Object -First 1
    if (-not $taskCommand -or $taskCommand.Arguments -notlike "*$backupScript*") {
      throw "A scheduled task with the POS backup name exists but does not belong to this installation."
    }
  }
  $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  $backupAction = New-ScheduledTaskAction -Execute $powershellExe `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$backupScript`""
  $backupTrigger = New-ScheduledTaskTrigger -Daily -At "11:00PM"
  $backupPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $backupSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $backupAction `
    -Trigger $backupTrigger -Principal $backupPrincipal -Settings $backupSettings -Force | Out-Null

  Write-Output "Koli Wada Dhaba PostgreSQL 17 service is installed and verified on 127.0.0.1:$port."
  Write-Output "Existing POS data, if present, was preserved. Menu and table master counts are 70 / 13 / 120."
  Write-Output "A daily local backup task is scheduled. No Owner account, bills, or payments were created."
}
finally {
  if ($tempPasswordFile -and (Test-Path -LiteralPath $tempPasswordFile)) {
    Remove-Item -LiteralPath $tempPasswordFile -Force
  }
  foreach ($name in $environmentToRestore) {
    [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], "Process")
  }
  $adminPassword = $null
  $appPassword = $null
  $jwtSecret = $null
  $databaseUrl = $null
  $random.Dispose()
}
