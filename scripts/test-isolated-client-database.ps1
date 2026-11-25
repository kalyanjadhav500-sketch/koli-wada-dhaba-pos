$ErrorActionPreference = "Stop"

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$postgresBin = Join-Path $workspaceRoot "build-runtime\postgresql17\bin"
$node = "C:\Program Files\nodejs\node.exe"
$tsx = Join-Path $workspaceRoot "node_modules\tsx\dist\cli.mjs"
$npmCli = "C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js"
$postgres = Join-Path $postgresBin "postgres.exe"
$initdb = Join-Path $postgresBin "initdb.exe"
$pgCtl = Join-Path $postgresBin "pg_ctl.exe"
$psql = Join-Path $postgresBin "psql.exe"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "KWD-Phase1-Isolated-$([guid]::NewGuid().ToString('N'))"
$dataDirectory = Join-Path $tempRoot "data"
$serverLog = Join-Path $tempRoot "postgres.log"
$apiOut = Join-Path $tempRoot "api.out.log"
$apiErr = Join-Path $tempRoot "api.err.log"
$npmOut = Join-Path $tempRoot "npm.out.log"
$npmErr = Join-Path $tempRoot "npm.err.log"
$databaseName = "koli_wada_dhaba"
$roleName = "kwd_app"
$databasePassword = [guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
$jwtBytes = New-Object byte[] 48
$jwtGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
$jwtGenerator.GetBytes($jwtBytes)
$jwtSecret = [Convert]::ToBase64String($jwtBytes)
[Array]::Clear($jwtBytes, 0, $jwtBytes.Length)
$jwtGenerator.Dispose()
$ownerPassword = [guid]::NewGuid().ToString("N") + "Aa1!"
$ownerUsername = "phase1test" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$dbPort = 0
$apiPort = 0
$apiProcess = $null
$postgresStarted = $false
$testPassed = $false
$variablesToRestore = @("DATABASE_URL", "DIRECT_URL", "JWT_SECRET", "NODE_ENV", "API_HOST", "API_PORT", "PORT", "CORS_ORIGINS", "PGPASSWORD", "PATH")
$oldEnvironment = @{}
$serverStopped = $false

foreach ($name in $variablesToRestore) {
  $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Get-FreeLoopbackPort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  }
  finally {
    $listener.Stop()
  }
}

function ConvertTo-TestProcessArgument {
  param([Parameter(Mandatory = $true)][string]$Argument)

  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $backslashCount = 0
  foreach ($character in $Argument.ToCharArray()) {
    if ($character -eq '\') {
      $backslashCount++
      continue
    }
    if ($character -eq '"') {
      [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
      [void]$builder.Append('"')
    }
    else {
      if ($backslashCount) {
        [void]$builder.Append(('\' * $backslashCount))
      }
      [void]$builder.Append($character)
    }
    $backslashCount = 0
  }
  if ($backslashCount) {
    [void]$builder.Append(('\' * ($backslashCount * 2)))
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Invoke-TestNative {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$FailureMessage,
    [switch]$CaptureOutput
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-TestProcessArgument -Argument $_ }) -join " "
  $startInfo.UseShellExecute = $false
  if ($CaptureOutput) {
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
  }
  $startInfo.CreateNoWindow = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) {
      throw "$FailureMessage (could not start process)."
    }
    if ($CaptureOutput) {
      $stdoutTask = $process.StandardOutput.ReadToEndAsync()
      $stderrTask = $process.StandardError.ReadToEndAsync()
    }
    if (-not $process.WaitForExit(90000)) {
      $process.Kill()
      $process.WaitForExit()
      throw "$FailureMessage (timed out after 90 seconds)."
    }
    if ($CaptureOutput) {
      $output = $stdoutTask.GetAwaiter().GetResult()
      $null = $stderrTask.GetAwaiter().GetResult()
    }
    $exitCode = $process.ExitCode
  }
  finally {
    $process.Dispose()
  }
  if ($exitCode -ne 0) {
    throw "$FailureMessage (exit code $exitCode)."
  }
  if ($CaptureOutput) {
    return $output
  }
}

function Invoke-TestPsql {
  param([Parameter(Mandatory = $true)][string]$Database, [Parameter(Mandatory = $true)][string]$Sql)
  $output = Invoke-TestNative -Executable $psql -Arguments @(
    "-X", "-w", "-h", "127.0.0.1", "-p", "$dbPort", "-U", $roleName, "-d", $Database,
    "-v", "ON_ERROR_STOP=1", "-tA", "-c", $Sql
  ) -FailureMessage "Isolated database verification failed" -CaptureOutput
  return (($output | ForEach-Object { "$_" }) -join "").Trim()
}

function Invoke-TestNpm {
  param([Parameter(Mandatory = $true)][string]$ScriptName)

  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    & $node $npmCli run $ScriptName --workspace=@koliwada/api 1>$npmOut 2>$npmErr
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "The npm $ScriptName command failed (exit code $exitCode)."
  }
}

try {
  foreach ($path in @($postgres, $initdb, $pgCtl, $psql, $node, $tsx, $npmCli)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required local test tool is missing: $path"
    }
  }
  $dbPort = Get-FreeLoopbackPort
  do {
    $apiPort = Get-FreeLoopbackPort
  } while ($apiPort -eq $dbPort)
  if (Get-CimInstance Win32_Service -Filter "Name='postgresql-x64-17'" -ErrorAction SilentlyContinue |
      Where-Object { $_.State -eq "Stopped" }) {
    throw "The developer PostgreSQL service is stopped. The isolated test will not start, stop, or alter it."
  }

  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  Write-Output "Phase 1 test: initializing a temporary PostgreSQL cluster."
  [void](Invoke-TestNative -Executable $initdb -Arguments @(
    "-D", $dataDirectory, "-U", "postgres", "--auth-local=trust", "--auth-host=trust",
    "--encoding=UTF8", "--locale=C"
  ) -FailureMessage "Could not initialize the temporary isolated cluster")

  Write-Output "Phase 1 test: starting the isolated PostgreSQL cluster."
  [void](Invoke-TestNative -Executable $pgCtl -Arguments @(
    "-D", $dataDirectory, "-l", $serverLog, "-o", "-h 127.0.0.1 -p $dbPort",
    "-w", "-t", "60", "start"
  ) -FailureMessage "Could not start the temporary isolated cluster")
  $postgresStarted = $true

  Write-Output "Phase 1 test: creating the isolated role and database."
  $env:PGPASSWORD = ""
  [void](Invoke-TestNative -Executable $psql -Arguments @(
    "-X", "-w", "-h", "127.0.0.1", "-p", "$dbPort", "-U", "postgres", "-d", "postgres",
    "-v", "ON_ERROR_STOP=1", "-c", "CREATE ROLE $roleName WITH LOGIN PASSWORD '$databasePassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
  ) -FailureMessage "Could not create the isolated test role")
  [void](Invoke-TestNative -Executable $psql -Arguments @(
    "-X", "-w", "-h", "127.0.0.1", "-p", "$dbPort", "-U", "postgres", "-d", "postgres",
    "-v", "ON_ERROR_STOP=1", "-c", "CREATE DATABASE $databaseName OWNER $roleName"
  ) -FailureMessage "Could not create the isolated test database")

  $testDatabaseUrl = "postgresql://${roleName}:$databasePassword@127.0.0.1:${dbPort}/${databaseName}?schema=public"
  $env:DATABASE_URL = $testDatabaseUrl
  $env:DIRECT_URL = $testDatabaseUrl
  $env:NODE_ENV = "development"
  $env:JWT_SECRET = $jwtSecret
  $env:API_HOST = "127.0.0.1"
  $env:API_PORT = "$apiPort"
  $env:PATH = (Split-Path -Parent $node) + [IO.Path]::PathSeparator +
    $postgresBin + [IO.Path]::PathSeparator + $env:PATH
  Remove-Item Env:\PORT -ErrorAction SilentlyContinue
  Remove-Item Env:\CORS_ORIGINS -ErrorAction SilentlyContinue
  $env:PGPASSWORD = $databasePassword

  Write-Output "Phase 1 test: applying existing Prisma migrations."
  Invoke-TestNpm -ScriptName "db:deploy"
  Write-Output "Phase 1 test: seeding menu and table master records."
  Invoke-TestNpm -ScriptName "db:seed"

  Write-Output "Phase 1 test: verifying master-data counts."
  $counts = Invoke-TestPsql -Database $databaseName -Sql `
    'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User"), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment")'
  if ($counts -ne "70|13|120|0|0|0") {
    throw "The isolated database master-data check failed."
  }

  Write-Output "Phase 1 test: creating and validating an isolated custom-format backup."
  $backupDirectory = Join-Path $tempRoot "backups"
  $preRestoreDirectory = Join-Path $tempRoot "pre-restore"
  $backupScript = Join-Path $workspaceRoot "scripts\backup-postgres.ps1"
  $restoreScript = Join-Path $workspaceRoot "scripts\restore-postgres.ps1"
  & $backupScript -OutputDirectory $backupDirectory | Out-Host
  $testBackup = Get-ChildItem -LiteralPath $backupDirectory -Filter "koli-wada-dhaba-*.dump" |
    Select-Object -First 1
  if (-not $testBackup -or $testBackup.Length -le 0) {
    throw "The isolated PostgreSQL backup was not created."
  }
  [void](Invoke-TestPsql -Database $databaseName -Sql 'UPDATE "MenuCategory" SET "sortOrder" = "sortOrder" + 1000')
  if ((Invoke-TestPsql -Database $databaseName -Sql 'SELECT count(*) FROM "MenuCategory" WHERE "sortOrder" >= 1000') -ne "13") {
    throw "Could not apply the isolated restore test marker."
  }
  Write-Output "Phase 1 test: restoring only into the isolated cluster with a verified pre-restore backup."
  & $restoreScript -BackupPath $testBackup.FullName `
    -ConfirmationText "RESTORE LOCAL POS DATABASE" `
    -PreRestoreBackupDirectory $preRestoreDirectory | Out-Host
  if ((Invoke-TestPsql -Database $databaseName -Sql 'SELECT count(*) FROM "MenuCategory" WHERE "sortOrder" >= 1000') -ne "0") {
    throw "The isolated restore did not restore the expected category values."
  }
  $preRestoreBackup = Get-ChildItem -LiteralPath $preRestoreDirectory -Filter "koli-wada-dhaba-pre-restore-*.dump" |
    Select-Object -First 1
  if (-not $preRestoreBackup -or $preRestoreBackup.Length -le 0) {
    throw "The restore workflow did not retain its verified pre-restore backup."
  }
  Write-Output "PASS: isolated backup validation, pre-restore backup, and restore all succeeded."

  Write-Output "Phase 1 test: starting the API against the isolated database."
  $apiProcess = Start-Process -FilePath $node -ArgumentList @($tsx, (Join-Path $workspaceRoot "apps\api\src\server.ts")) `
    -WorkingDirectory $workspaceRoot -PassThru -RedirectStandardOutput $apiOut -RedirectStandardError $apiErr
  $apiBase = "http://127.0.0.1:$apiPort"
  $healthReady = $false
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($apiProcess.HasExited) {
      throw "The isolated API test process exited before becoming healthy."
    }
    try {
      $health = Invoke-RestMethod -Uri "$apiBase/api/health" -TimeoutSec 2
      if ($health.status -eq "ok" -and $health.database -eq "connected") {
        $healthReady = $true
        break
      }
    }
    catch {
      Start-Sleep -Milliseconds 500
    }
  }
  if (-not $healthReady) {
    throw "The isolated API did not report a healthy PostgreSQL connection."
  }

  Write-Output "Phase 1 test: checking API health and first-Owner setup."
  $setupStatus = Invoke-RestMethod -Uri "$apiBase/api/auth/setup-status" -TimeoutSec 5
  if (-not $setupStatus.setupRequired) {
    throw "The isolated database should require first-Owner setup before account creation."
  }
  $ownerBody = @{
    name = "Isolated Test Owner"
    username = $ownerUsername
    email = "owner@example.invalid"
    password = $ownerPassword
  } | ConvertTo-Json -Compress
  $ownerResponse = Invoke-RestMethod -Method Post -Uri "$apiBase/api/auth/setup" `
    -ContentType "application/json" -Body $ownerBody -TimeoutSec 10
  if ($ownerResponse.user.role -ne "OWNER" -or -not $ownerResponse.token) {
    throw "The existing first-Owner setup flow did not return an authenticated Owner."
  }
  $loginBody = @{ username = $ownerUsername; password = $ownerPassword } | ConvertTo-Json -Compress
  $loginResponse = Invoke-RestMethod -Method Post -Uri "$apiBase/api/auth/login" `
    -ContentType "application/json" -Body $loginBody -TimeoutSec 10
  if ($loginResponse.user.role -ne "OWNER" -or -not $loginResponse.token) {
    throw "The newly created isolated Owner could not sign in."
  }

  $finalCounts = Invoke-TestPsql -Database $databaseName -Sql `
    'SELECT (SELECT count(*) FROM "User" WHERE "role" = ''OWNER''), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment"), (SELECT count(*) FROM "AuditLog" WHERE "action" = ''OWNER_SETUP''), (SELECT count(*) FROM "AuditLog" WHERE "action" = ''LOGIN'')'
  if ($finalCounts -ne "1|0|0|1|1") {
    throw "The isolated Owner/audit/business-data verification failed (counts: $finalCounts)."
  }
  $testPassed = $true
  Write-Output "PASS: isolated PostgreSQL 17 cluster migrated and seeded 70 tables, 13 categories, and 120 menu items."
  Write-Output "PASS: first-Owner setup and sign-in succeeded; no bills or payments were created."
  Write-Output "PASS: API health confirmed its connection to the isolated database."
  Write-Output "The developer PostgreSQL Windows service was not used, started, stopped, or modified."
}
finally {
  if ($apiProcess -and -not $apiProcess.HasExited) {
    Stop-Process -Id $apiProcess.Id -Force
    $apiProcess.WaitForExit()
  }
  if ($postgresStarted) {
    try {
      [void](Invoke-TestNative -Executable $pgCtl -Arguments @(
        "-D", $dataDirectory, "-m", "fast", "-w", "-t", "60", "stop"
      ) -FailureMessage "Could not stop the temporary isolated cluster")
      $serverStopped = $true
    }
    catch {
      Write-Error "Temporary isolated PostgreSQL did not stop cleanly; its directory was retained at $tempRoot."
    }
  }
  else {
    $serverStopped = $true
  }
  foreach ($name in $variablesToRestore) {
    [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], "Process")
  }
  $databasePassword = $null
  $jwtSecret = $null
  $ownerPassword = $null
  $testDatabaseUrl = $null
  if ($serverStopped -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

if (-not $testPassed) {
  throw "Isolated Phase 1 database validation did not pass."
}
