[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# This test creates and destroys only a uniquely named temporary PostgreSQL
# cluster under the Windows TEMP directory. It never queries, starts, stops,
# or modifies either the developer PostgreSQL service or the production POS service.
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('KWD-Phase1-Isolated-{0}' -f [guid]::NewGuid().ToString('N'))
$dataDirectory = Join-Path $tempRoot 'data'
$backupDirectory = Join-Path $tempRoot 'backups'
$preRestoreDirectory = Join-Path $tempRoot 'pre-restore'
$serverLog = Join-Path $tempRoot 'postgres.log'
$apiOut = Join-Path $tempRoot 'api.out.log'
$apiErr = Join-Path $tempRoot 'api.err.log'
$npmOut = Join-Path $tempRoot 'npm.out.log'
$npmErr = Join-Path $tempRoot 'npm.err.log'

$postgresBin = Join-Path $workspaceRoot 'build-runtime\postgresql17\bin'
$postgres = Join-Path $postgresBin 'postgres.exe'
$initdb = Join-Path $postgresBin 'initdb.exe'
$pgCtl = Join-Path $postgresBin 'pg_ctl.exe'
$psql = Join-Path $postgresBin 'psql.exe'
$pgDump = Join-Path $postgresBin 'pg_dump.exe'
$pgRestore = Join-Path $postgresBin 'pg_restore.exe'

$databaseName = 'koli_wada_dhaba'
$roleName = 'kwd_app'
$databasePassword = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$jwtBytes = New-Object byte[] 48
$jwtGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
$jwtGenerator.GetBytes($jwtBytes)
$jwtSecret = [Convert]::ToBase64String($jwtBytes)
[Array]::Clear($jwtBytes, 0, $jwtBytes.Length)
$jwtGenerator.Dispose()
$ownerPassword = [guid]::NewGuid().ToString('N') + 'Aa1!'
$ownerUsername = 'phase1test' + [guid]::NewGuid().ToString('N').Substring(0, 8)

$dbPort = 0
$apiPort = 0
$apiProcess = $null
$postgresStarted = $false
$postgresStartAttempted = $false
$serverStopped = $false
$testPassed = $false
$testDatabaseUrl = $null

$variablesToRestore = @(
  'DATABASE_URL', 'DIRECT_URL', 'JWT_SECRET', 'NODE_ENV', 'API_HOST',
  'API_PORT', 'PORT', 'CORS_ORIGINS', 'PGPASSWORD', 'PGCONNECT_TIMEOUT', 'PATH'
)
$oldEnvironment = @{}
foreach ($name in $variablesToRestore) {
  $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Get-NormalizedPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [IO.Path]::GetFullPath($Path).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
}

function Get-FreeLoopbackPort {
  param([int[]]$ExcludedPorts = @())

  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
      $listener.Start()
      $candidate = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
      $listener.Stop()
    }

    if ($candidate -notin $ExcludedPorts -and $candidate -notin @(5432, 5433)) {
      return $candidate
    }
  }

  throw 'Could not allocate a disposable loopback port distinct from 5432 and 5433.'
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
      if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * $backslashCount))
      }
      [void]$builder.Append($character)
    }
    $backslashCount = 0
  }
  if ($backslashCount -gt 0) {
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
    [int]$TimeoutSeconds = 120
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = ($Arguments | ForEach-Object {
    ConvertTo-TestProcessArgument -Argument $_
  }) -join ' '
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
      throw "$FailureMessage (timed out after $TimeoutSeconds seconds)."
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
    return $stdout
  }
  finally {
    $process.Dispose()
  }
}

function Invoke-TestPsql {
  param(
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Sql
  )

  $output = Invoke-TestNative -Executable $psql -Arguments @(
    '-X', '-w', '-h', '127.0.0.1', '-p', "$dbPort", '-U', $roleName, '-d', $Database,
    '-v', 'ON_ERROR_STOP=1', '-tA', '-c', $Sql
  ) -FailureMessage 'Isolated database verification failed' -TimeoutSeconds 60
  return $output.Trim()
}

function Invoke-TestNpm {
  param([Parameter(Mandatory = $true)][string]$ScriptName)

  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $nodeExecutable $npmCliPath run $ScriptName --workspace=@koliwada/api 1>$npmOut 2>$npmErr
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
  }

  if ($exitCode -ne 0) {
    $details = @()
    if (Test-Path -LiteralPath $npmErr) { $details += Get-Content -LiteralPath $npmErr -Tail 30 }
    if (Test-Path -LiteralPath $npmOut) { $details += Get-Content -LiteralPath $npmOut -Tail 30 }
    throw "The npm $ScriptName command failed (exit code $exitCode). $($details -join "`n")"
  }
}

function ConvertFrom-SingleJsonOutput {
  param(
    [Parameter(Mandatory = $true)][string[]]$OutputLines,
    [Parameter(Mandatory = $true)][string]$Description
  )

  $jsonLine = @($OutputLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ($jsonLine.Count -ne 1) {
    throw "$Description did not return its expected JSON result."
  }
  try {
    return ($jsonLine[0] | ConvertFrom-Json -ErrorAction Stop)
  }
  catch {
    throw "$Description returned an invalid JSON result."
  }
}

try {
  foreach ($requiredPath in @(
    $postgres, $initdb, $pgCtl, $psql, $pgDump, $pgRestore
  )) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "Required staged PostgreSQL 17 test tool is missing: $requiredPath"
    }
  }

  $nodeCommand = Get-Command 'node.exe' -ErrorAction Stop
  $npmCommand = Get-Command 'npm.cmd' -ErrorAction Stop
  $nodeExecutable = $nodeCommand.Source
  $npmDirectory = Split-Path -Parent $npmCommand.Source
  $npmCliPath = Join-Path $npmDirectory 'node_modules\npm\bin\npm-cli.js'
  if (-not (Test-Path -LiteralPath $npmCliPath -PathType Leaf)) {
    throw "Could not locate npm-cli.js beside the active npm.cmd installation: $npmCliPath"
  }

  $tsxCandidates = @(
    (Join-Path $workspaceRoot 'node_modules\tsx\dist\cli.mjs'),
    (Join-Path $workspaceRoot 'apps\api\node_modules\tsx\dist\cli.mjs')
  )
  $tsx = $tsxCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $tsx) {
    throw 'The tsx CLI was not found in the workspace or API workspace node_modules.'
  }

  $serverScript = Join-Path $workspaceRoot 'apps\api\src\server.ts'
  $backupScript = Join-Path $workspaceRoot 'scripts\backup-postgres.ps1'
  $restoreScript = Join-Path $workspaceRoot 'scripts\restore-postgres.ps1'
  foreach ($requiredPath in @($serverScript, $backupScript, $restoreScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "Required isolated test source file is missing: $requiredPath"
    }
  }

  $versionOutput = Invoke-TestNative -Executable $postgres -Arguments @('--version') -FailureMessage 'Could not verify the staged PostgreSQL runtime'
  if ($versionOutput -notmatch '\b17\.') {
    throw "The isolated test requires PostgreSQL 17. Detected: $versionOutput"
  }

  $dbPort = Get-FreeLoopbackPort
  $apiPort = Get-FreeLoopbackPort -ExcludedPorts @($dbPort)

  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  Write-Output 'Phase 1 test: initializing a unique temporary PostgreSQL 17 cluster.'
  [void](Invoke-TestNative -Executable $initdb -Arguments @(
    '-D', $dataDirectory, '-U', 'postgres', '--auth-local=trust', '--auth-host=trust',
    '--encoding=UTF8', '--locale=C'
  ) -FailureMessage 'Could not initialize the temporary isolated PostgreSQL cluster' -TimeoutSeconds 300)

  if ((Get-Content -LiteralPath (Join-Path $dataDirectory 'PG_VERSION') -Raw).Trim() -ne '17') {
    throw 'The newly initialized temporary cluster did not identify itself as PostgreSQL 17.'
  }

  Write-Output "Phase 1 test: starting only the temporary cluster on 127.0.0.1:$dbPort."
  $postgresStartAttempted = $true
  [void](Invoke-TestNative -Executable $pgCtl -Arguments @(
    '-D', $dataDirectory, '-l', $serverLog, '-o', "-h 127.0.0.1 -p $dbPort",
    '-w', '-t', '60', 'start'
  ) -FailureMessage 'Could not start the temporary isolated PostgreSQL cluster' -TimeoutSeconds 120)
  $postgresStarted = $true

  Write-Output 'Phase 1 test: creating the test-only role and database.'
  $env:PGPASSWORD = ''
  [void](Invoke-TestNative -Executable $psql -Arguments @(
    '-X', '-w', '-h', '127.0.0.1', '-p', "$dbPort", '-U', 'postgres', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-c', "CREATE ROLE $roleName WITH LOGIN PASSWORD '$databasePassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
  ) -FailureMessage 'Could not create the isolated application role')
  [void](Invoke-TestNative -Executable $psql -Arguments @(
    '-X', '-w', '-h', '127.0.0.1', '-p', "$dbPort", '-U', 'postgres', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-c', "CREATE DATABASE $databaseName OWNER $roleName"
  ) -FailureMessage 'Could not create the isolated application database')

  $testDatabaseUrl = "postgresql://${roleName}:$databasePassword@127.0.0.1:${dbPort}/${databaseName}?schema=public"
  $env:DATABASE_URL = $testDatabaseUrl
  $env:DIRECT_URL = $testDatabaseUrl
  $env:NODE_ENV = 'development'
  $env:JWT_SECRET = $jwtSecret
  $env:API_HOST = '127.0.0.1'
  $env:API_PORT = "$apiPort"
  $env:PORT = "$apiPort"
  $env:PATH = (Split-Path -Parent $nodeExecutable) + [IO.Path]::PathSeparator + $postgresBin + [IO.Path]::PathSeparator + $env:PATH
  Remove-Item Env:\CORS_ORIGINS -ErrorAction SilentlyContinue
  $env:PGPASSWORD = $databasePassword

  Write-Output 'Phase 1 test: applying the existing Prisma migrations.'
  Invoke-TestNpm -ScriptName 'db:deploy'

  Write-Output 'Phase 1 test: applying the existing idempotent menu/table seed.'
  Invoke-TestNpm -ScriptName 'db:seed'

  Write-Output 'Phase 1 test: verifying the required 70/13/120 master data.'
  $initialCounts = Invoke-TestPsql -Database $databaseName -Sql 'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User"), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment")'
  if ($initialCounts -ne '70|13|120|0|0|0') {
    throw "The isolated database master-data verification failed. Counts: $initialCounts"
  }

  Write-Output 'Phase 1 test: creating a custom-format backup through the explicit isolated-only path.'
  $backupOutput = @(& $backupScript -IsolatedTestMode -DataDirectory $dataDirectory -Port $dbPort `
    -DatabaseUrl $testDatabaseUrl -PostgresBinDirectory $postgresBin -OutputDirectory $backupDirectory)
  $backupResult = ConvertFrom-SingleJsonOutput -OutputLines $backupOutput -Description 'The isolated backup script'

  if ($backupResult.status -ne 'verified' -or
      $backupResult.purpose -ne 'isolated-test' -or
      $backupResult.port -ne $dbPort -or
      $backupResult.sizeBytes -le 0 -or
      -not (Test-Path -LiteralPath $backupResult.archivePath -PathType Leaf)) {
    throw 'The isolated backup script returned an incomplete or unverified result.'
  }
  if (-not [string]::Equals(
      (Get-NormalizedPath $backupResult.archivePath),
      (Get-NormalizedPath (Join-Path $backupDirectory (Split-Path -Leaf $backupResult.archivePath))),
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The reported backup archive path could not be normalized safely.'
  }
  $backupFile = Get-Item -LiteralPath $backupResult.archivePath
  if ($backupFile.Length -ne [long]$backupResult.sizeBytes) {
    throw 'The isolated backup archive size does not match the backup result.'
  }
  $actualBackupHash = (Get-FileHash -LiteralPath $backupResult.archivePath -Algorithm SHA256).Hash
  if ($actualBackupHash -ne $backupResult.sha256) {
    throw 'The isolated backup SHA256 checksum did not match.'
  }

  Write-Output 'Phase 1 test: changing isolated menu category data to prove restore behavior.'
  [void](Invoke-TestPsql -Database $databaseName -Sql 'UPDATE "MenuCategory" SET "sortOrder" = "sortOrder" + 1000')
  if ((Invoke-TestPsql -Database $databaseName -Sql 'SELECT count(*) FROM "MenuCategory" WHERE "sortOrder" >= 1000') -ne '13') {
    throw 'Could not apply the isolated restore test marker.'
  }

  Write-Output 'Phase 1 test: restoring only into the disposable cluster with a validated pre-restore backup.'
  $restoreOutput = @(& $restoreScript -BackupPath $backupResult.archivePath -IsolatedTestMode `
    -DataDirectory $dataDirectory -Port $dbPort -DatabaseUrl $testDatabaseUrl `
    -PostgresBinDirectory $postgresBin -ConfirmationText 'RESTORE ISOLATED KWD TEST DATABASE' `
    -PreRestoreBackupDirectory $preRestoreDirectory)
  $restoreResult = ConvertFrom-SingleJsonOutput -OutputLines $restoreOutput -Description 'The isolated restore script'

  if ($restoreResult.status -ne 'restored-and-verified' -or
      $restoreResult.purpose -ne 'isolated-test' -or
      $restoreResult.port -ne $dbPort -or
      -not (Test-Path -LiteralPath $restoreResult.preRestoreArchive -PathType Leaf) -or
      $restoreResult.preRestoreSizeBytes -le 0) {
    throw 'The isolated restore script returned an incomplete post-restore result.'
  }
  $preRestoreHash = (Get-FileHash -LiteralPath $restoreResult.preRestoreArchive -Algorithm SHA256).Hash
  if ($preRestoreHash -ne $restoreResult.preRestoreSha256) {
    throw 'The isolated pre-restore archive SHA256 checksum did not match.'
  }
  if ((Invoke-TestPsql -Database $databaseName -Sql 'SELECT count(*) FROM "MenuCategory" WHERE "sortOrder" >= 1000') -ne '0') {
    throw 'The isolated restore did not return menu category values to their backed-up state.'
  }

  $restoredCounts = Invoke-TestPsql -Database $databaseName -Sql 'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User"), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment")'
  if ($restoredCounts -ne '70|13|120|0|0|0') {
    throw "The restored isolated master-data verification failed. Counts: $restoredCounts"
  }
  Write-Output 'PASS: isolated custom-format backup, SHA256 validation, pre-restore backup and restore all succeeded.'

  Write-Output 'Phase 1 test: starting the API against only the disposable database.'
  $apiArguments = '"{0}" "{1}"' -f $tsx, $serverScript
  $apiProcess = Start-Process -FilePath $nodeExecutable -ArgumentList $apiArguments `
    -WorkingDirectory $workspaceRoot -PassThru -RedirectStandardOutput $apiOut -RedirectStandardError $apiErr -WindowStyle Hidden
  $apiBase = "http://127.0.0.1:$apiPort"
  $healthReady = $false

  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($apiProcess.HasExited) {
      $apiDetails = @()
      if (Test-Path -LiteralPath $apiErr) { $apiDetails += Get-Content -LiteralPath $apiErr -Tail 30 }
      if (Test-Path -LiteralPath $apiOut) { $apiDetails += Get-Content -LiteralPath $apiOut -Tail 30 }
      throw "The isolated API process exited before becoming healthy. $($apiDetails -join "`n")"
    }

    try {
      $health = Invoke-RestMethod -Uri "$apiBase/api/health" -TimeoutSec 2
      if ($health.status -eq 'ok' -and $health.database -eq 'connected') {
        $healthReady = $true
        break
      }
    }
    catch {
      Start-Sleep -Milliseconds 500
    }
  }

  if (-not $healthReady) {
    $apiDetails = @()
    if (Test-Path -LiteralPath $apiErr) { $apiDetails += Get-Content -LiteralPath $apiErr -Tail 30 }
    if (Test-Path -LiteralPath $apiOut) { $apiDetails += Get-Content -LiteralPath $apiOut -Tail 30 }
    throw "The isolated API did not report a healthy PostgreSQL connection. $($apiDetails -join "`n")"
  }

  Write-Output 'Phase 1 test: checking first-Owner setup and login.'
  $setupStatus = Invoke-RestMethod -Uri "$apiBase/api/auth/setup-status" -TimeoutSec 5
  if (-not $setupStatus.setupRequired) {
    throw 'The isolated database should require first-Owner setup before account creation.'
  }

  $ownerBody = @{
    name = 'Isolated Test Owner'
    username = $ownerUsername
    email = 'owner@example.invalid'
    password = $ownerPassword
  } | ConvertTo-Json -Compress

  $ownerResponse = Invoke-RestMethod -Method Post -Uri "$apiBase/api/auth/setup" `
    -ContentType 'application/json' -Body $ownerBody -TimeoutSec 10
  if ($ownerResponse.user.role -ne 'OWNER' -or -not $ownerResponse.token) {
    throw 'The existing first-Owner setup flow did not return an authenticated Owner.'
  }

  $loginBody = @{ username = $ownerUsername; password = $ownerPassword } | ConvertTo-Json -Compress
  $loginResponse = Invoke-RestMethod -Method Post -Uri "$apiBase/api/auth/login" `
    -ContentType 'application/json' -Body $loginBody -TimeoutSec 10
  if ($loginResponse.user.role -ne 'OWNER' -or -not $loginResponse.token) {
    throw 'The newly created isolated Owner could not sign in.'
  }

  $finalCounts = Invoke-TestPsql -Database $databaseName -Sql 'SELECT (SELECT count(*) FROM "User" WHERE "role" = ''OWNER''), (SELECT count(*) FROM "Bill"), (SELECT count(*) FROM "Payment"), (SELECT count(*) FROM "AuditLog" WHERE "action" = ''OWNER_SETUP''), (SELECT count(*) FROM "AuditLog" WHERE "action" = ''LOGIN'')'
  if ($finalCounts -ne '1|0|0|1|1') {
    throw "The isolated Owner/audit/business-data verification failed. Counts: $finalCounts"
  }

  $testPassed = $true
  Write-Output 'PASS: PostgreSQL 17 temporary cluster migrated and seeded 70 tables, 13 categories and 120 menu items.'
  Write-Output 'PASS: custom-format backup and isolated restore succeeded; both archive checksums matched.'
  Write-Output 'PASS: API health, first-Owner setup and Owner login succeeded.'
  Write-Output 'PASS: test created one Owner and no bills or payments.'
  Write-Output 'The developer PostgreSQL and production POS Windows services were not queried, started, stopped or modified.'
}
finally {
  if ($apiProcess -and -not $apiProcess.HasExited) {
    Stop-Process -Id $apiProcess.Id -Force -ErrorAction SilentlyContinue
    try { $apiProcess.WaitForExit() } catch { }
  }

  if ($postgresStartAttempted -and (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
    try {
      $statusOutput = & $pgCtl -D $dataDirectory status 2>&1
      $statusExitCode = $LASTEXITCODE
      if ($statusExitCode -eq 0 -and (($statusOutput | Out-String) -match '(?i)server is running')) {
        [void](Invoke-TestNative -Executable $pgCtl -Arguments @(
          '-D', $dataDirectory, '-m', 'fast', '-w', '-t', '60', 'stop'
        ) -FailureMessage 'Could not stop the temporary isolated PostgreSQL cluster' -TimeoutSeconds 90)
      }
      $serverStopped = $true
    }
    catch {
      Write-Warning "Temporary isolated PostgreSQL did not stop cleanly. Its data was retained for inspection at: $tempRoot"
    }
  }
  else {
    $serverStopped = $true
  }

  foreach ($name in $variablesToRestore) {
    [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
  }

  $databasePassword = $null
  $jwtSecret = $null
  $ownerPassword = $null
  $testDatabaseUrl = $null
  $apiProcess = $null

  if ($serverStopped -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

if (-not $testPassed) {
  throw 'Isolated Phase 1 database validation did not pass.'
}
