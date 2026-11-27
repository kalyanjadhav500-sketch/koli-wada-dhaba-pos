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
    [int]$TimeoutSeconds = 120,
    [switch]$AllowChildProcess
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Executable
  $startInfo.Arguments = ($Arguments | ForEach-Object {
    ConvertTo-TestProcessArgument -Argument $_
  }) -join ' '
  $startInfo.UseShellExecute = $false
  # pg_ctl start launches postgres.exe and returns after readiness. On Windows,
  # the detached server can inherit redirected pipe handles from pg_ctl, which
  # leaves ReadToEndAsync waiting forever even after pg_ctl exits. Leave the
  # handles attached for that one daemon-start operation; PostgreSQL writes its
  # detailed startup log to the explicit -l file above.
  $startInfo.RedirectStandardOutput = -not $AllowChildProcess
  $startInfo.RedirectStandardError = -not $AllowChildProcess
  $startInfo.CreateNoWindow = $true

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) {
      throw "$FailureMessage (process could not start)."
    }
    $stdoutTask = $null
    $stderrTask = $null
    if (-not $AllowChildProcess) {
      $stdoutTask = $process.StandardOutput.ReadToEndAsync()
      $stderrTask = $process.StandardError.ReadToEndAsync()
    }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill()
      $process.WaitForExit()
      throw "$FailureMessage (timed out after $TimeoutSeconds seconds)."
    }

    $stdout = if ($stdoutTask) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
    $stderr = if ($stderrTask) { $stderrTask.GetAwaiter().GetResult() } else { '' }
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

function Invoke-TestApi {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('Get', 'Post', 'Patch', 'Delete')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Token,
    [object]$Body
  )

  $request = @{
    Method = $Method
    Uri = "$apiBase$Path"
    TimeoutSec = 20
  }
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $request.Headers = @{ Authorization = "Bearer $Token" }
  }
  if ($PSBoundParameters.ContainsKey('Body')) {
    $request.ContentType = 'application/json'
    $request.Body = $Body | ConvertTo-Json -Compress -Depth 8
  }
  $result = Invoke-RestMethod @request
  if ($result -is [Array]) {
    foreach ($entry in $result) { Write-Output $entry }
    return
  }
  return $result
}

function Assert-TestApiFailure {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [string]$Token,
    [object]$Body
  )

  $apiRequest = @{ Method = $Method; Path = $Path }
  if (-not [string]::IsNullOrWhiteSpace($Token)) { $apiRequest.Token = $Token }
  if ($PSBoundParameters.ContainsKey('Body')) { $apiRequest.Body = $Body }

  try {
    $null = Invoke-TestApi @apiRequest
  }
  catch {
    $response = $_.Exception.Response
    if (-not $response) {
      throw "The isolated API request to $Path failed without an HTTP response: $($_.Exception.Message)"
    }
    $actualStatus = [int]$response.StatusCode
    if ($actualStatus -ne $StatusCode) {
      throw "The isolated API request to $Path returned HTTP $actualStatus; expected HTTP $StatusCode."
    }
    return
  }
  throw "The isolated API request to $Path unexpectedly succeeded; expected HTTP $StatusCode."
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
  ) -FailureMessage 'Could not start the temporary isolated PostgreSQL cluster' -TimeoutSeconds 120 -AllowChildProcess)
  $postgresStarted = $true

  Write-Output 'Phase 1 test: creating the test-only role and database.'
  $env:PGPASSWORD = ''
  [void](Invoke-TestNative -Executable $psql -Arguments @(
    '-X', '-w', '-h', '127.0.0.1', '-p', "$dbPort", '-U', 'postgres', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-c', "CREATE ROLE $roleName WITH LOGIN PASSWORD '$databasePassword' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
  ) -FailureMessage 'Could not create the isolated application role')
  [void](Invoke-TestNative -Executable $psql -Arguments @(
    '-X', '-w', '-h', '127.0.0.1', '-p', "$dbPort", '-U', 'postgres', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-c', "GRANT pg_read_all_settings TO $roleName"
  ) -FailureMessage 'Could not grant isolated runtime-identity inspection to the test-only role')
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
  $ownerToken = $loginResponse.token

  Write-Output 'Phase 1 test: checking Owner and Cashier access, tables, menu and settings.'
  $cashierPassword = [guid]::NewGuid().ToString('N') + 'Cc3!'
  $cashierUsername = 'cashier' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $cashier = Invoke-TestApi -Method Post -Path '/api/users' -Token $ownerToken -Body @{
    name = 'Isolated Test Cashier'
    username = $cashierUsername
    password = $cashierPassword
    role = 'CASHIER'
  }
  if ($cashier.role -ne 'CASHIER' -or -not $cashier.active) {
    throw 'Owner cashier creation did not return an active Cashier.'
  }
  $cashierLogin = Invoke-TestApi -Method Post -Path '/api/auth/login' -Body @{
    username = $cashierUsername
    password = $cashierPassword
  }
  if ($cashierLogin.user.role -ne 'CASHIER' -or -not $cashierLogin.token) {
    throw 'The isolated Cashier could not sign in.'
  }
  $cashierToken = $cashierLogin.token

  $tables = @(Invoke-TestApi -Method Get -Path '/api/tables' -Token $cashierToken)
  $categories = @(Invoke-TestApi -Method Get -Path '/api/menu' -Token $cashierToken)
  $menuItems = @($categories | ForEach-Object { $_.items })
  if ($tables.Count -ne 70 -or $categories.Count -ne 13 -or $menuItems.Count -ne 120) {
    throw "The API returned unexpected master data: tables=$($tables.Count), categories=$($categories.Count), items=$($menuItems.Count)."
  }
  $menuItem = $menuItems | Where-Object { $_.pricingType -eq 'FULL_HALF' -and $null -ne $_.fullPrice -and $null -ne $_.halfPrice } | Select-Object -First 1
  if (-not $menuItem) { throw 'The seeded menu has no Full/Half item available for billing tests.' }
  $fullPrice = [decimal]::Parse([string]$menuItem.fullPrice, [Globalization.CultureInfo]::InvariantCulture)
  $halfPrice = [decimal]::Parse([string]$menuItem.halfPrice, [Globalization.CultureInfo]::InvariantCulture)

  Assert-TestApiFailure -Method Post -Path '/api/menu/categories' -Token $cashierToken -StatusCode 403 -Body @{
    name = 'Cashier must not create categories'
    sortOrder = 1000
  }
  Assert-TestApiFailure -Method Get -Path '/api/users' -Token $cashierToken -StatusCode 403
  $testCategory = Invoke-TestApi -Method Post -Path '/api/menu/categories' -Token $ownerToken -Body @{
    name = 'Isolated API Test Category'
    sortOrder = 1000
  }
  $testCategory = Invoke-TestApi -Method Patch -Path "/api/menu/categories/$($testCategory.id)" -Token $ownerToken -Body @{
    name = 'Isolated API Test Category Updated'
  }
  if ($testCategory.name -ne 'Isolated API Test Category Updated') {
    throw 'Owner category editing did not persist.'
  }
  $testMenuItem = Invoke-TestApi -Method Post -Path '/api/menu/items' -Token $ownerToken -Body @{
    categoryId = $testCategory.id
    name = 'Isolated API Test Item'
    pricingType = 'FULL_HALF'
    fullPrice = '150.00'
    halfPrice = '100.00'
    manualPriceNote = $null
  }
  $testMenuItem = Invoke-TestApi -Method Patch -Path "/api/menu/items/$($testMenuItem.id)" -Token $ownerToken -Body @{
    name = 'Isolated API Test Item Updated'
  }
  if ($testMenuItem.name -ne 'Isolated API Test Item Updated') {
    throw 'Owner menu item editing did not persist.'
  }
  $null = Invoke-TestApi -Method Patch -Path "/api/menu/items/$($testMenuItem.id)" -Token $ownerToken -Body @{ active = $false }

  $settings = Invoke-TestApi -Method Patch -Path '/api/settings' -Token $ownerToken -Body @{
    receiptWidthMm = 58
    upiId = 'isolated-test@upi'
    upiPayeeName = 'Isolated Test Dhaba'
  }
  if ($settings.receiptWidthMm -ne 58 -or $settings.upiId -ne 'isolated-test@upi') {
    throw 'Owner restaurant or receipt settings did not persist.'
  }

  Write-Output 'Phase 1 test: exercising open bills, Full/Half pricing, Other Item, quantity edits and removals.'
  $createdBill = Invoke-TestApi -Method Post -Path '/api/bills' -Token $cashierToken -Body @{ tableNumber = 1 }
  if (-not $createdBill.created -or -not $createdBill.bill.id) {
    throw 'Opening a new table bill did not create one open bill.'
  }
  $billId = [string]$createdBill.bill.id
  $existingBill = Invoke-TestApi -Method Post -Path '/api/bills' -Token $cashierToken -Body @{ tableNumber = 1 }
  if ($existingBill.created -or $existingBill.bill.id -ne $billId) {
    throw 'Opening an occupied table did not return its existing open bill.'
  }

  $fullBill = Invoke-TestApi -Method Post -Path "/api/bills/$billId/items" -Token $cashierToken -Body @{
    menuItemId = $menuItem.id
    size = 'FULL'
    quantity = 2
  }
  $fullLine = $fullBill.items | Where-Object { $_.itemName -eq $menuItem.name -and $_.size -eq 'FULL' } | Select-Object -First 1
  if (-not $fullLine -or [decimal]$fullLine.unitPrice -ne $fullPrice) {
    throw 'The Full menu price was not snapshotted onto the bill line.'
  }
  $otherBill = Invoke-TestApi -Method Post -Path "/api/bills/$billId/items" -Token $cashierToken -Body @{
    itemName = 'Other Item regression check'
    manualPrice = '12.34'
    quantity = 1
  }
  $otherLine = $otherBill.items | Where-Object { $_.itemName -eq 'Other Item regression check' } | Select-Object -First 1
  if (-not $otherLine -or [decimal]$otherLine.unitPrice -ne [decimal]12.34) {
    throw 'Other Item did not keep its manually entered price.'
  }
  $null = Invoke-TestApi -Method Patch -Path "/api/bills/$billId/items/$($otherLine.id)" -Token $cashierToken -Body @{ quantity = 2 }
  $halfBill = Invoke-TestApi -Method Post -Path "/api/bills/$billId/items" -Token $cashierToken -Body @{
    menuItemId = $menuItem.id
    size = 'HALF'
    quantity = 1
  }
  $halfLine = $halfBill.items | Where-Object { $_.itemName -eq $menuItem.name -and $_.size -eq 'HALF' } | Select-Object -First 1
  if (-not $halfLine -or [decimal]$halfLine.unitPrice -ne $halfPrice) {
    throw 'The Half menu price was not snapshotted onto the bill line.'
  }
  $null = Invoke-TestApi -Method Delete -Path "/api/bills/$billId/items/$($otherLine.id)" -Token $cashierToken
  $null = Invoke-TestApi -Method Delete -Path "/api/bills/$billId/items/$($halfLine.id)" -Token $cashierToken
  $null = Invoke-TestApi -Method Patch -Path "/api/bills/$billId/items/$($fullLine.id)" -Token $cashierToken -Body @{ quantity = 3 }
  $updatedFullBill = Invoke-TestApi -Method Patch -Path "/api/bills/$billId/items/$($fullLine.id)" -Token $cashierToken -Body @{ quantity = 2 }
  if ([decimal]$updatedFullBill.subtotal -ne ($fullPrice * 2)) {
    throw 'Bill quantity changes/removals did not recalculate its subtotal.'
  }
  $openBillSnapshot = Invoke-TestApi -Method Get -Path "/api/bills/$billId" -Token $cashierToken
  if ($openBillSnapshot.items.Count -ne 1 -or $openBillSnapshot.items[0].itemName -ne $menuItem.name) {
    throw 'The open bill did not retain only its expected historical item snapshot.'
  }
  $occupiedTable = @(Invoke-TestApi -Method Get -Path '/api/tables' -Token $cashierToken) | Where-Object { $_.number -eq 1 }
  if ($occupiedTable.status -ne 'OCCUPIED' -or $occupiedTable.currentBill.id -ne $billId) {
    throw 'Table status did not reflect its open bill.'
  }

  Write-Output 'Phase 1 test: settling Cash, UPI and Card, including confirmation and payment idempotency.'
  $upiKey = [guid]::NewGuid().ToString()
  $upiBody = @{ method = 'UPI'; idempotencyKey = $upiKey; upiConfirmed = $true }
  $upiUnconfirmed = @{ method = 'UPI'; idempotencyKey = $upiKey }
  Assert-TestApiFailure -Method Post -Path "/api/bills/$billId/payment" -Token $cashierToken -StatusCode 400 -Body $upiUnconfirmed
  $upiPayment = Invoke-TestApi -Method Post -Path "/api/bills/$billId/payment" -Token $cashierToken -Body $upiBody
  $upiReplay = Invoke-TestApi -Method Post -Path "/api/bills/$billId/payment" -Token $cashierToken -Body $upiBody
  if ($upiPayment.payment.method -ne 'UPI' -or $upiReplay.replayed -ne $true) {
    throw 'UPI payment confirmation or idempotent retry did not behave as expected.'
  }

  $cardBill = Invoke-TestApi -Method Post -Path '/api/bills' -Token $cashierToken -Body @{ tableNumber = 2 }
  $cardBillId = [string]$cardBill.bill.id
  $null = Invoke-TestApi -Method Post -Path "/api/bills/$cardBillId/items" -Token $cashierToken -Body @{ menuItemId = $menuItem.id; size = 'FULL'; quantity = 1 }
  $cardKey = [guid]::NewGuid().ToString()
  Assert-TestApiFailure -Method Post -Path "/api/bills/$cardBillId/payment" -Token $cashierToken -StatusCode 400 -Body @{ method = 'CARD'; idempotencyKey = $cardKey }
  $cardPayment = Invoke-TestApi -Method Post -Path "/api/bills/$cardBillId/payment" -Token $cashierToken -Body @{
    method = 'CARD'
    idempotencyKey = $cardKey
    cardConfirmed = $true
  }
  if ($cardPayment.payment.method -ne 'CARD') { throw 'Card payment confirmation did not complete.' }

  $cashBill = Invoke-TestApi -Method Post -Path '/api/bills' -Token $cashierToken -Body @{ tableNumber = 3 }
  $cashBillId = [string]$cashBill.bill.id
  $null = Invoke-TestApi -Method Post -Path "/api/bills/$cashBillId/items" -Token $cashierToken -Body @{ menuItemId = $menuItem.id; size = 'FULL'; quantity = 1 }
  $cashKey = [guid]::NewGuid().ToString()
  $cashPayment = Invoke-TestApi -Method Post -Path "/api/bills/$cashBillId/payment" -Token $cashierToken -Body @{
    method = 'CASH'
    idempotencyKey = $cashKey
    cashReceived = '500.00'
  }
  if ($cashPayment.payment.method -ne 'CASH' -or [decimal]$cashPayment.change -ne ([decimal]500 - $fullPrice)) {
    throw 'Cash payment or change calculation did not match the received amount.'
  }

  $cancelBill = Invoke-TestApi -Method Post -Path '/api/bills' -Token $cashierToken -Body @{ tableNumber = 4 }
  $cancelBillId = [string]$cancelBill.bill.id
  Assert-TestApiFailure -Method Post -Path "/api/bills/$cancelBillId/cancel" -Token $cashierToken -StatusCode 403 -Body @{ reason = 'Cashier owner permission check' }
  $cancelled = Invoke-TestApi -Method Post -Path "/api/bills/$cancelBillId/cancel" -Token $ownerToken -Body @{ reason = 'Isolated cancellation regression check' }
  if ($cancelled.status -ne 'CANCELLED') { throw 'Owner cancellation did not close the isolated open bill.' }

  Write-Output 'Phase 1 test: checking bill history, reprint data, daily reports and role enforcement.'
  $paidHistory = @(Invoke-TestApi -Method Get -Path '/api/bills?status=PAID' -Token $cashierToken)
  $cancelledHistory = @(Invoke-TestApi -Method Get -Path '/api/bills?status=CANCELLED' -Token $cashierToken)
  if ($paidHistory.Count -ne 3 -or $cancelledHistory.Count -ne 1) {
    throw "Bill history returned unexpected results: paid=$($paidHistory.Count), cancelled=$($cancelledHistory.Count)."
  }
  $receipt = Invoke-TestApi -Method Get -Path "/api/bills/$billId" -Token $cashierToken
  if ($receipt.status -ne 'PAID' -or $receipt.items[0].itemName -ne $menuItem.name -or [decimal]$receipt.items[0].unitPrice -ne $fullPrice) {
    throw 'The paid bill reprint response did not retain the item and price snapshots.'
  }
  $businessDate = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromMinutes(330)).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  $dailyReport = Invoke-TestApi -Method Get -Path "/api/reports/daily?date=$businessDate" -Token $ownerToken
  $reportedMethods = @($dailyReport.payments | ForEach-Object { $_.method } | Sort-Object)
  if ($dailyReport.paidBills.Count -ne 3 -or $dailyReport.cancelledBills.Count -ne 1 -or
      ($reportedMethods -join ',') -ne 'CARD,CASH,UPI' -or $dailyReport.tableSales.Count -ne 3) {
    throw 'Daily payment-method, table-wise, paid-bill, or cancellation reporting failed.'
  }
  $dashboard = Invoke-TestApi -Method Get -Path '/api/dashboard' -Token $ownerToken
  if ($dashboard.totalSales -ne ([double]($fullPrice * 4)) -or $dashboard.totalOrders -ne 3) {
    throw 'The Owner dashboard totals did not match confirmed payments.'
  }
  Assert-TestApiFailure -Method Get -Path '/api/users' -Token $cashierToken -StatusCode 403
  $ownerUsers = @(Invoke-TestApi -Method Get -Path '/api/users' -Token $ownerToken)
  if ($ownerUsers.Count -ne 2 -or @($ownerUsers | Where-Object { $_.role -eq 'OWNER' }).Count -ne 1) {
    throw 'Owner-only staff listing returned unexpected users.'
  }
  $null = Invoke-TestApi -Method Patch -Path "/api/users/$($cashier.id)" -Token $ownerToken -Body @{ active = $false }
  Assert-TestApiFailure -Method Get -Path '/api/me' -Token $cashierToken -StatusCode 401

  Write-Output 'Phase 1 test: checking one-time offline Owner recovery and API restart persistence.'
  $recoveredOwnerPassword = [guid]::NewGuid().ToString('N') + 'Oo4!'
  $recoveryResponse = Invoke-TestApi -Method Post -Path '/api/auth/offline-recovery/confirm' -Body @{
    username = $ownerUsername
    recoveryKey = $ownerResponse.recoveryKey
    password = $recoveredOwnerPassword
  }
  if (-not $recoveryResponse.message) { throw 'Offline Owner recovery did not confirm the password change.' }
  Assert-TestApiFailure -Method Post -Path '/api/auth/login' -StatusCode 401 -Body @{ username = $ownerUsername; password = $ownerPassword }
  $recoveredLogin = Invoke-TestApi -Method Post -Path '/api/auth/login' -Body @{ username = $ownerUsername; password = $recoveredOwnerPassword }
  if ($recoveredLogin.user.role -ne 'OWNER' -or -not $recoveredLogin.token) {
    throw 'The Owner could not sign in after offline recovery.'
  }

  Stop-Process -Id $apiProcess.Id -Force -ErrorAction Stop
  try { Wait-Process -Id $apiProcess.Id -Timeout 10 -ErrorAction SilentlyContinue } catch { }
  Start-Sleep -Milliseconds 500
  $apiProcess = Start-Process -FilePath $nodeExecutable -ArgumentList $apiArguments `
    -WorkingDirectory $workspaceRoot -PassThru -RedirectStandardOutput $apiOut -RedirectStandardError $apiErr -WindowStyle Hidden
  $healthReady = $false
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($apiProcess.HasExited) { throw 'The isolated API failed to restart against its existing temporary database.' }
    try {
      $health = Invoke-RestMethod -Uri "$apiBase/api/health" -TimeoutSec 2
      if ($health.status -eq 'ok' -and $health.database -eq 'connected') { $healthReady = $true; break }
    }
    catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $healthReady) { throw 'The isolated API did not reconnect to PostgreSQL after restart.' }
  $persistentPaidHistory = @(Invoke-TestApi -Method Get -Path '/api/bills?status=PAID' -Token $recoveredLogin.token)
  if ($persistentPaidHistory.Count -ne 3) { throw 'Paid bills did not persist across the isolated API restart.' }

  $finalCounts = Invoke-TestPsql -Database $databaseName -Sql 'SELECT (SELECT count(*) FROM "RestaurantTable"), (SELECT count(*) FROM "MenuCategory"), (SELECT count(*) FROM "MenuItem"), (SELECT count(*) FROM "User" WHERE "role" = ''OWNER''), (SELECT count(*) FROM "User" WHERE "role" = ''CASHIER''), (SELECT count(*) FROM "Bill" WHERE "status" = ''PAID''), (SELECT count(*) FROM "Bill" WHERE "status" = ''CANCELLED''), (SELECT count(*) FROM "Payment"), (SELECT count(*) FROM "Payment" WHERE "method" = ''CASH''), (SELECT count(*) FROM "Payment" WHERE "method" = ''UPI''), (SELECT count(*) FROM "Payment" WHERE "method" = ''CARD'')'
  if ($finalCounts -ne '70|14|121|1|1|3|1|3|1|1|1') {
    throw "The isolated POS workflow verification failed. Counts: $finalCounts"
  }

  $testPassed = $true
  Write-Output 'PASS: PostgreSQL 17 temporary cluster migrated and seeded 70 tables, 13 categories and 120 menu items.'
  Write-Output 'PASS: custom-format backup and isolated restore succeeded; both archive checksums matched.'
  Write-Output 'PASS: Owner/Cashier setup, authentication, permissions, offline recovery and Owner-managed settings/menu/cashiers.'
  Write-Output 'PASS: table status, open-bill reuse, Full/Half pricing, Other Item, quantity edits/removal and bill snapshots.'
  Write-Output 'PASS: Cash/UPI/Card settlement, UPI/Card confirmation, change, payment idempotency, history, reports and cancellation.'
  Write-Output 'PASS: API restart reconnected to PostgreSQL and all paid bills persisted.'
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
  $cashierPassword = $null
  $recoveredOwnerPassword = $null
  $ownerResponse = $null
  $loginResponse = $null
  $cashierLogin = $null
  $recoveredLogin = $null
  $cashierToken = $null
  $ownerToken = $null
  $testDatabaseUrl = $null
  $apiProcess = $null

  if ($serverStopped -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
    if ($testPassed) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    else {
      Write-Warning "Isolated regression failure artifacts were retained for diagnosis at: $tempRoot"
      if (Test-Path -LiteralPath $serverLog -PathType Leaf) {
        Write-Warning 'Temporary PostgreSQL server log follows:'
        Get-Content -LiteralPath $serverLog -Tail 80 | Write-Warning
      }
    }
  }
}

if (-not $testPassed) {
  throw 'Isolated Phase 1 database validation did not pass.'
}
