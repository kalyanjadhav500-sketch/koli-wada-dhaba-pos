$ErrorActionPreference = "Stop"
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $workspaceRoot ".env"

if (-not (Test-Path $envPath)) {
  throw "Missing .env. Run npm run env:init first."
}

$envText = [System.IO.File]::ReadAllText($envPath)
$adminPasswordPath = Join-Path $workspaceRoot ".pgadmin-password"
$envValues = @{}
foreach ($line in ($envText -split "`r?`n")) {
  if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
    $value = $Matches[2].Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $envValues[$Matches[1]] = $value
  }
}

$appPassword = $envValues["POSTGRES_PASSWORD"]
if (-not $appPassword -or $appPassword -notmatch '^[a-f0-9]{64}$') {
  throw "POSTGRES_PASSWORD must be the generated 64-character hexadecimal secret."
}

$adminPassword = if (Test-Path $adminPasswordPath) {
  [System.IO.File]::ReadAllText($adminPasswordPath).Trim()
}
else {
  $envValues["PG_ADMIN_PASSWORD"]
}
if (-not $adminPassword -or $adminPassword -notmatch '^[a-f0-9]{64}$') {
  $randomBytes = New-Object byte[] 32
  $randomGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $randomGenerator.GetBytes($randomBytes)
  $adminPassword = [System.BitConverter]::ToString($randomBytes).Replace("-", "").ToLowerInvariant()
  $randomGenerator.Dispose()
}
if (-not (Test-Path $adminPasswordPath)) {
  [System.IO.File]::WriteAllText($adminPasswordPath, $adminPassword, (New-Object System.Text.UTF8Encoding($false)))
}
if ($envValues.ContainsKey("PG_ADMIN_PASSWORD")) {
  $envText = [System.Text.RegularExpressions.Regex]::Replace($envText, '(?m)^PG_ADMIN_PASSWORD=.*(?:\r?\n)?', "")
  [System.IO.File]::WriteAllText($envPath, $envText, (New-Object System.Text.UTF8Encoding($false)))
}

$postgresDirectory = "C:\Program Files\PostgreSQL\17"
$psql = Join-Path $postgresDirectory "bin\psql.exe"
$pgHba = Join-Path $postgresDirectory "data\pg_hba.conf"
$serviceName = "postgresql-x64-17"
if (-not (Test-Path $psql) -or -not (Test-Path $pgHba)) {
  throw "PostgreSQL 17 was not found in its default Windows installation directory."
}
$service = Get-Service -Name $serviceName -ErrorAction Stop
if ($service.Status -ne "Running") {
  Start-Service -Name $serviceName
}

function Initialize-PosDatabase {
  param(
    [string]$PsqlPath,
    [string]$AdminPassword,
    [string]$AppPassword
  )

  $env:PGPASSWORD = $AdminPassword
  $roleState = ((& $PsqlPath -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc `
        "SELECT rolsuper::text FROM pg_roles WHERE rolname = 'kwd_app'") | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect local PostgreSQL roles."
  }
  if ($roleState -eq "true") {
    throw "The kwd_app account is a superuser; it was left unchanged."
  }
  if ($roleState) {
    & $PsqlPath -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 `
      -c "ALTER ROLE kwd_app WITH LOGIN PASSWORD '$AppPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" | Out-Null
  }
  else {
    & $PsqlPath -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 `
      -c "CREATE ROLE kwd_app WITH LOGIN PASSWORD '$AppPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" | Out-Null
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create or update the POS database role."
  }

  $databaseExists = ((& $PsqlPath -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc `
        "SELECT 1 FROM pg_database WHERE datname = 'koli_wada_dhaba'") | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect local PostgreSQL databases."
  }
  if ($databaseExists) {
    $databaseOwner = ((& $PsqlPath -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc `
          "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'koli_wada_dhaba'") | Out-String).Trim()
    if ($databaseOwner -ne "kwd_app") {
      throw "The existing koli_wada_dhaba database is not owned by kwd_app; it was left unchanged."
    }
  }
  else {
    & $PsqlPath -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 `
      -c "CREATE DATABASE koli_wada_dhaba OWNER kwd_app" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Could not create the POS database."
    }
  }

  $env:PGPASSWORD = $AppPassword
  & $PsqlPath -w -h 127.0.0.1 -p 5432 -U kwd_app -d koli_wada_dhaba -v ON_ERROR_STOP=1 -tAc "SELECT 1" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "The POS database account could not connect to its database."
  }
  $env:PGPASSWORD = ""
}

$env:PGPASSWORD = $adminPassword
$adminProbe = & $psql -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc "SELECT 1" 2>&1
$adminAuthenticated = $LASTEXITCODE -eq 0
$env:PGPASSWORD = ""
if ($adminAuthenticated) {
  Initialize-PosDatabase -PsqlPath $psql -AdminPassword $adminPassword -AppPassword $appPassword
  Write-Output "PostgreSQL is configured with a loopback-only POS database account."
  exit 0
}

if (-not [System.Security.Principal.WindowsPrincipal]::new(
    [System.Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  $elevated = Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") `
    -Verb RunAs -ArgumentList $arguments -Wait -PassThru
  exit $elevated.ExitCode
}

$backupPath = Join-Path ([System.IO.Path]::GetTempPath()) "kwd-pg-hba-$([guid]::NewGuid().ToString('N')).conf"
Copy-Item $pgHba $backupPath
$temporaryTrustInstalled = $false
try {
  # Temporarily permit only loopback access so the unknown installer bootstrap password can be reset.
  $pgHbaLines = Get-Content $pgHba
  Set-Content -Path $pgHba -Encoding ASCII -Value (@("host all all 127.0.0.1/32 trust") + $pgHbaLines)
  $temporaryTrustInstalled = $true
  Restart-Service -Name $serviceName -Force
  (Get-Service -Name $serviceName).WaitForStatus(
    [System.ServiceProcess.ServiceControllerStatus]::Running,
    [TimeSpan]::FromSeconds(60)
  )

  $env:PGPASSWORD = ""
  & $psql -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 `
    -c "ALTER ROLE postgres WITH PASSWORD '$adminPassword'"
  if ($LASTEXITCODE -ne 0) {
    throw "Could not set the local PostgreSQL administrator password."
  }

  Initialize-PosDatabase -PsqlPath $psql -AdminPassword $adminPassword -AppPassword $appPassword
}
finally {
  $env:PGPASSWORD = ""
  if (Test-Path $backupPath) {
    Copy-Item $backupPath $pgHba -Force
    Remove-Item $backupPath -Force
    if ($temporaryTrustInstalled) {
      Restart-Service -Name $serviceName -Force
      (Get-Service -Name $serviceName).WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(60)
      )
    }
  }
}

Write-Output "PostgreSQL is configured with a loopback-only POS database account."
