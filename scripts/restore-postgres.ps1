param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath
)

$ErrorActionPreference = "Stop"
$workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = Join-Path $workspace ".env"
$directUrl = $env:DIRECT_URL

if (-not $directUrl -and (Test-Path $envPath)) {
    $directLine = Get-Content $envPath | Where-Object { $_ -match '^\s*DIRECT_URL\s*=' } | Select-Object -First 1
    if ($directLine -match '^\s*DIRECT_URL\s*=\s*(.*?)\s*$') {
        $directUrl = $matches[1]
        if ($directUrl.Length -ge 2 -and $directUrl[0] -eq '"' -and $directUrl[$directUrl.Length - 1] -eq '"') {
            $directUrl = $directUrl.Substring(1, $directUrl.Length - 2)
        } elseif ($directUrl.Length -ge 2 -and $directUrl[0] -eq "'" -and $directUrl[$directUrl.Length - 1] -eq "'") {
            $directUrl = $directUrl.Substring(1, $directUrl.Length - 2)
        }
    }
}

if (-not $directUrl) {
    throw "Set DIRECT_URL to the new Neon database's direct TLS connection string in the ignored workspace .env."
}

try {
    $connection = [uri]$directUrl
    if (
        $connection.Scheme -notin @("postgres", "postgresql") -or
        -not $connection.Host -or
        $connection.Host -in @("localhost", "127.0.0.1", "::1") -or
        $connection.Query -notmatch '(^|&)sslmode=(require|verify-ca|verify-full)(&|$)'
    ) {
        throw "The destination must be a remote PostgreSQL database using TLS."
    }
} catch {
    throw "DIRECT_URL must be a remote PostgreSQL URL using sslmode=require or stronger."
}

if (-not [System.IO.Path]::IsPathRooted($BackupPath)) {
    $BackupPath = Join-Path $workspace $BackupPath
}
if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
    throw "The specified backup file does not exist."
}

$pgRestore = Get-Command pg_restore.exe -ErrorAction SilentlyContinue
$psql = Get-Command psql.exe -ErrorAction SilentlyContinue
if (-not $pgRestore -or -not $psql) {
    throw "PostgreSQL pg_restore.exe and psql.exe are required. Install PostgreSQL client tools and add their bin folder to PATH."
}

$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $archiveListing = & $pgRestore.Source --list $BackupPath 2>&1
    $archiveExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($archiveExitCode -ne 0 -or -not $archiveListing) {
    throw "The selected backup is not a valid PostgreSQL custom-format archive."
}

$env:PGCONNECT_TIMEOUT = "10"
$emptyCheck = 'SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ''public'' AND c.relkind IN (''r'', ''p'', ''v'', ''m'', ''S'', ''f'');'
$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $tableCountOutput = & $psql.Source --no-password --set=ON_ERROR_STOP=1 --tuples-only --no-align --dbname=$directUrl --command=$emptyCheck 2>&1
    $checkExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}

if ($checkExitCode -ne 0 -or -not $tableCountOutput) {
    throw "Could not safely verify the destination database. No restore was attempted."
}
try {
    $tableCount = [int](($tableCountOutput | Select-Object -Last 1).ToString().Trim())
} catch {
    throw "Could not interpret the destination database check. No restore was attempted."
}
if ($tableCount -ne 0) {
    throw "The target database is not empty. No restore was attempted; use a newly created empty Neon database."
}

$confirmation = Read-Host "This will restore the backup into the verified empty remote database. Type RESTORE INTO EMPTY NEON DATABASE to continue"
if ($confirmation -cne "RESTORE INTO EMPTY NEON DATABASE") {
    throw "Restore cancelled; no database changes were made."
}

$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $restoreOutput = & $pgRestore.Source --exit-on-error --no-owner --no-acl --dbname=$directUrl $BackupPath 2>&1
    $restoreExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($restoreExitCode -ne 0) {
    throw "Restore failed and may have partially populated the destination. Keep the source database and backup unchanged; inspect the target before any retry."
}

Write-Output "Restore completed. Keep the source database and backup unchanged until database counts, API health, and billing workflows have been checked."
