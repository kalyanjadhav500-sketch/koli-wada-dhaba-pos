$ErrorActionPreference = "Stop"

$serviceName = "postgresql-x64-17"
$databaseName = "koli_wada_dhaba"
$appRole = "kwd_app"
$port = 5432
$programDataRoot = Join-Path $env:ProgramData "Koli Wada Dhaba POS"
$expectedDataDirectory = Join-Path $programDataRoot "PostgreSQL17\data"
$configDirectory = Join-Path $programDataRoot "config"
$secretFile = Join-Path $configDirectory "database-secrets.dpapi"
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$menuPath = Join-Path $workspaceRoot "apps\shared\menu.json"

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Psql {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Executable,
    [Parameter(Mandatory = $true)]
    [string]$Database,
    [Parameter(Mandatory = $true)]
    [string]$Sql
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = "-X -w -h 127.0.0.1 -p $port -U postgres -d `"$Database`" -v ON_ERROR_STOP=1 -tA -f -"
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  if ($env:PGPASSWORD) {
    $startInfo.EnvironmentVariables["PGPASSWORD"] = $env:PGPASSWORD
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) {
      throw "Could not start the PostgreSQL client."
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine($Sql)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $output = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      throw "A PostgreSQL command failed. No existing database or cluster was removed."
    }
  }
  finally {
    $process.Dispose()
  }
  return $output.Trim()
}

function Invoke-PosNpmScript {
  param([Parameter(Mandatory = $true)][string]$ScriptName)

  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $nodeExecutable $npmCliPath run $ScriptName --workspace=@koliwada/api 1>$null 2>$null
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "The npm $ScriptName command failed (exit code $exitCode)."
  }
}

function Set-RestrictedDirectoryAcl {
  param([Parameter(Mandatory = $true)][string]$Path)

  $result = & icacls.exe $Path /inheritance:r `
    /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not restrict access to the application configuration directory."
  }
}

if (-not [Environment]::Is64BitOperatingSystem) {
  throw "The local POS database requires 64-bit Windows."
}
if (-not (Test-IsAdministrator)) {
  throw "Run this one-time database provisioning step from an elevated PowerShell window."
}
if (-not (Test-Path -LiteralPath $expectedDataDirectory -PathType Container)) {
  throw "The dedicated PostgreSQL data directory was not found. Install PostgreSQL 17 with its data directory under ProgramData first."
}
if (-not (Test-Path -LiteralPath (Join-Path $expectedDataDirectory "PG_VERSION") -PathType Leaf)) {
  throw "The expected ProgramData directory is not an initialized PostgreSQL cluster."
}
$clusterVersion = (Get-Content -LiteralPath (Join-Path $expectedDataDirectory "PG_VERSION") -Raw).Trim()
if ($clusterVersion -ne "17") {
  throw "The ProgramData cluster is not PostgreSQL 17. No service or data was changed."
}

$service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
if (-not $service) {
  throw "The PostgreSQL 17 Windows service '$serviceName' is not installed."
}
$dataPathMatch = [regex]::Match($service.PathName, '(?i)\s-D\s+(?:"([^"]+)"|(\S+))')
if (-not $dataPathMatch.Success) {
  throw "Could not verify the PostgreSQL service data directory. No service was changed."
}
$serviceDataDirectory = if ($dataPathMatch.Groups[1].Success) {
  $dataPathMatch.Groups[1].Value
}
else {
  $dataPathMatch.Groups[2].Value
}
if (-not [string]::Equals(
    [IO.Path]::GetFullPath($serviceDataDirectory).TrimEnd('\'),
    [IO.Path]::GetFullPath($expectedDataDirectory).TrimEnd('\'),
    [StringComparison]::OrdinalIgnoreCase
  )) {
  throw "The PostgreSQL 17 service does not use this application's ProgramData cluster. It was left unchanged."
}
if ($service.PathName -notmatch '(?i)PostgreSQL\\17\\bin\\pg_ctl\.exe') {
  throw "The service executable is not the expected PostgreSQL 17 installation. No service was changed."
}
if ($service.StartName -notmatch '(?i)(^|\\)postgres$') {
  throw "The PostgreSQL service does not run as its dedicated postgres identity. No service was changed."
}

$psqlPath = [regex]::Match($service.PathName, '^(?:"([^"]+)"|(\S+))').Groups
$pgCtlExecutable = if ($psqlPath[1].Success) { $psqlPath[1].Value } else { $psqlPath[2].Value }
$postgresBinDirectory = Split-Path -Parent $pgCtlExecutable
$psql = Join-Path $postgresBinDirectory "psql.exe"
$postgres = Join-Path $postgresBinDirectory "postgres.exe"
if (-not (Test-Path -LiteralPath $psql) -or -not (Test-Path -LiteralPath $postgres)) {
  throw "PostgreSQL 17 command-line tools were not found beside the verified service executable."
}
$serverVersion = & $postgres --version 2>$null
if ($LASTEXITCODE -ne 0 -or $serverVersion -notmatch '\b17\.') {
  throw "The PostgreSQL service binaries are not version 17."
}
if (-not (Test-Path -LiteralPath $menuPath -PathType Leaf)) {
  throw "The shared menu source is missing; no database was created."
}
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
  throw "npm.cmd is required to apply the existing Prisma migrations and seed."
}
if (Test-Path -LiteralPath $secretFile) {
  throw "An application database credential file already exists. It was left unchanged."
}

$roleExists = $false
$databaseExists = $false
$adminSecure = Read-Host "Enter the PostgreSQL postgres administrator password" -AsSecureString
$adminPasswordPointer = [IntPtr]::Zero
$appPassword = $null
$jwtSecret = $null
$previousPassword = [Environment]::GetEnvironmentVariable("PGPASSWORD", "Process")
$previousDatabaseUrl = [Environment]::GetEnvironmentVariable("DATABASE_URL", "Process")
$previousDirectUrl = [Environment]::GetEnvironmentVariable("DIRECT_URL", "Process")
$previousNodeEnv = [Environment]::GetEnvironmentVariable("NODE_ENV", "Process")
$previousPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
$configCreated = $false

try {
  $service = Get-Service -Name $serviceName -ErrorAction Stop
  if ($service.Status -ne "Running") {
    Start-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus(
      [ServiceProcess.ServiceControllerStatus]::Running,
      [TimeSpan]::FromSeconds(60)
    )
  }
  if ($service.StartType -ne "Automatic") {
    Set-Service -Name $serviceName -StartupType Automatic
  }

  $adminPasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminSecure)
  $adminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($adminPasswordPointer)
  $env:PGPASSWORD = $adminPassword

  $serverConfiguration = Invoke-Psql -Executable $psql -Database "postgres" `
    -Sql "SELECT current_setting('data_directory'), current_setting('listen_addresses'), current_setting('port')"
  $configurationParts = $serverConfiguration -split '\|'
  if ($configurationParts.Count -ne 3) {
    throw "Could not verify the PostgreSQL runtime configuration."
  }
  if (-not [string]::Equals(
      [IO.Path]::GetFullPath($configurationParts[0]).TrimEnd('\'),
      [IO.Path]::GetFullPath($expectedDataDirectory).TrimEnd('\'),
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "The running PostgreSQL server did not confirm the expected ProgramData cluster."
  }
  $listenAddresses = @($configurationParts[1] -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() })
  if (-not $listenAddresses.Count -or @($listenAddresses | Where-Object { $_ -notin @("localhost", "127.0.0.1", "::1") }).Count) {
    throw "PostgreSQL is not restricted to loopback addresses. Its configuration was left unchanged."
  }
  if ($configurationParts[2] -ne "$port") {
    throw "The application PostgreSQL cluster must listen on port $port."
  }

  $roleExists = (Invoke-Psql -Executable $psql -Database "postgres" `
    -Sql "SELECT 1 FROM pg_roles WHERE rolname = '$appRole'") -eq "1"
  $databaseExists = (Invoke-Psql -Executable $psql -Database "postgres" `
    -Sql "SELECT 1 FROM pg_database WHERE datname = '$databaseName'") -eq "1"
  if ($roleExists -or $databaseExists) {
    throw "The POS role or database already exists. Provisioning stopped without changing either."
  }

  $menu = Get-Content -LiteralPath $menuPath -Raw | ConvertFrom-Json
  $expectedCategoryCount = @($menu).Count
  $expectedMenuItemCount = 0
  foreach ($category in $menu) {
    $expectedMenuItemCount += @($category.items).Count
  }
  if ($expectedCategoryCount -ne 13 -or $expectedMenuItemCount -ne 120) {
    throw "The checked-in menu does not match the approved 13-category, 120-item inventory."
  }

  New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
  Set-RestrictedDirectoryAcl -Path $configDirectory
  Add-Type -AssemblyName System.Security

  $randomBytes = New-Object byte[] 32
  $randomGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $randomGenerator.GetBytes($randomBytes)
    $appPassword = [BitConverter]::ToString($randomBytes).Replace("-", "").ToLowerInvariant()
    $randomGenerator.GetBytes($randomBytes)
    $jwtSecret = [Convert]::ToBase64String($randomBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
  }
  finally {
    $randomGenerator.Dispose()
    [Array]::Clear($randomBytes, 0, $randomBytes.Length)
  }

  $databaseUrl = "postgresql://${appRole}:$appPassword@127.0.0.1:${port}/${databaseName}?schema=public"
  $secretPayload = @{
    DATABASE_URL = $databaseUrl
    JWT_SECRET = $jwtSecret
    NODE_ENV = "production"
    API_HOST = "127.0.0.1"
    PORT = "4000"
  } | ConvertTo-Json -Compress
  $protectedPayload = [Security.Cryptography.ProtectedData]::Protect(
    [Text.Encoding]::UTF8.GetBytes($secretPayload),
    $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine
  )
  [IO.File]::WriteAllBytes($secretFile, $protectedPayload)
  $configCreated = $true
  $fileAcl = Get-Acl -LiteralPath $secretFile
  $fileAcl.SetAccessRuleProtection($true, $false)
  $fileAcl.Access | ForEach-Object { [void]$fileAcl.RemoveAccessRuleAll($_) }
  foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
    $identity = [Security.Principal.SecurityIdentifier]::new($sid)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
      $identity,
      [Security.AccessControl.FileSystemRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$fileAcl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $secretFile -AclObject $fileAcl

  $env:PGPASSWORD = $adminPassword
  [void](Invoke-Psql -Executable $psql -Database "postgres" `
    -Sql "CREATE ROLE $appRole WITH LOGIN PASSWORD '$appPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION")
  [void](Invoke-Psql -Executable $psql -Database "postgres" `
    -Sql "CREATE DATABASE $databaseName OWNER $appRole")

  $env:DATABASE_URL = $databaseUrl
  $env:DIRECT_URL = $databaseUrl
  $env:NODE_ENV = "production"
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue

  $nodeExecutable = Join-Path $env:ProgramFiles "nodejs\node.exe"
  $npmCliPath = Join-Path $env:ProgramFiles "nodejs\node_modules\npm\bin\npm-cli.js"
  if (-not (Test-Path -LiteralPath $nodeExecutable -PathType Leaf) -or
      -not (Test-Path -LiteralPath $npmCliPath -PathType Leaf)) {
    throw "The local Node.js/npm runtime required for Prisma was not found."
  }
  $env:PATH = (Split-Path -Parent $nodeExecutable) + [IO.Path]::PathSeparator + $env:PATH
  Invoke-PosNpmScript -ScriptName "db:deploy"
  Invoke-PosNpmScript -ScriptName "db:seed"

  $appPasswordPointer = [IntPtr]::Zero
  $env:PGPASSWORD = $appPassword
  $counts = Invoke-Psql -Executable $psql -Database $databaseName `
    -Sql 'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User"), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment")'
  if ($counts -ne "70|13|120|0|0|0") {
    throw "The new database failed its post-seed verification. It was preserved; no cleanup was attempted."
  }

  Write-Output "Local POS database provisioned and verified: 70 tables, 13 categories, and 120 menu items."
  Write-Output "No Owner, bills, or payments were created. Complete first-Owner setup through the application after API installation."
  Write-Output "Database credentials are encrypted with Windows DPAPI under ProgramData; this file is accessible only to SYSTEM and Administrators."
}
finally {
  Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
  [Environment]::SetEnvironmentVariable("PGPASSWORD", $previousPassword, "Process")
  [Environment]::SetEnvironmentVariable("DATABASE_URL", $previousDatabaseUrl, "Process")
  [Environment]::SetEnvironmentVariable("DIRECT_URL", $previousDirectUrl, "Process")
  [Environment]::SetEnvironmentVariable("NODE_ENV", $previousNodeEnv, "Process")
  [Environment]::SetEnvironmentVariable("PATH", $previousPath, "Process")
  $adminPassword = $null
  $databaseUrl = $null
  $secretPayload = $null
  $protectedPayload = $null
  $appPassword = $null
  $jwtSecret = $null
  if ($adminPasswordPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($adminPasswordPointer)
  }
  if ($adminSecure) {
    $adminSecure.Dispose()
  }
}
