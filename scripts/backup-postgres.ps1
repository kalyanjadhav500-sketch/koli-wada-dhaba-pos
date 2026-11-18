param(
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = Join-Path $workspace ".env"
$databaseUrl = $env:DIRECT_URL
if (-not $databaseUrl) {
    $databaseUrl = $env:DATABASE_URL
}

if (-not $databaseUrl -and (Test-Path $envPath)) {
    foreach ($key in @("DIRECT_URL", "DATABASE_URL")) {
        $databaseLine = Get-Content $envPath | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
        if ($databaseLine -match "^\s*$key\s*=\s*(.*?)\s*$") {
            $databaseUrl = $matches[1]
            if ($databaseUrl.Length -ge 2 -and $databaseUrl[0] -eq '"' -and $databaseUrl[$databaseUrl.Length - 1] -eq '"') {
                $databaseUrl = $databaseUrl.Substring(1, $databaseUrl.Length - 2)
            } elseif ($databaseUrl.Length -ge 2 -and $databaseUrl[0] -eq "'" -and $databaseUrl[$databaseUrl.Length - 1] -eq "'") {
                $databaseUrl = $databaseUrl.Substring(1, $databaseUrl.Length - 2)
            }
            if ($databaseUrl) {
                break
            }
        }
    }
}

if (-not $databaseUrl) {
    throw "DATABASE_URL is not configured in the process environment or workspace .env."
}

try {
    $connection = [uri]$databaseUrl
    if ($connection.Scheme -notin @("postgres", "postgresql") -or -not $connection.Host) {
        throw "The configured DATABASE_URL is not a valid PostgreSQL URL."
    }
} catch {
    throw "DATABASE_URL is not a valid PostgreSQL connection URL."
}

$pgDump = Get-Command pg_dump.exe -ErrorAction SilentlyContinue
$pgRestore = Get-Command pg_restore.exe -ErrorAction SilentlyContinue
if (-not $pgDump -or -not $pgRestore) {
    throw "PostgreSQL pg_dump.exe and pg_restore.exe are required. Install PostgreSQL client tools and add their bin folder to PATH."
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $workspace "backups\postgres"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $workspace $OutputDirectory
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $OutputDirectory "koli-wada-dhaba-$timestamp.dump"
if (Test-Path $backupPath) {
    throw "A backup already exists at the target path; choose another output directory and do not overwrite it."
}

$env:PGCONNECT_TIMEOUT = "10"
$pgDatabaseUrl = [regex]::Replace($databaseUrl, '([?&])schema=[^&]*', '')
$pgDatabaseUrl = $pgDatabaseUrl -replace '\?&', '?'
$pgDatabaseUrl = $pgDatabaseUrl -replace '[?&]$', ''
$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $dumpOutput = & $pgDump.Source --no-password --format=custom --no-owner --no-acl --file=$backupPath --dbname=$pgDatabaseUrl 2>&1
    $dumpExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($dumpExitCode -ne 0) {
    if (Test-Path $backupPath) {
        Remove-Item -LiteralPath $backupPath
    }
    throw "pg_dump failed. Check database connectivity and credentials; the connection URL was not printed."
}

$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $listing = & $pgRestore.Source --list $backupPath 2>&1
    $restoreExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($restoreExitCode -ne 0 -or -not $listing) {
    throw "The backup was created, but pg_restore could not validate its archive. Keep the file and investigate before migration."
}

$file = Get-Item -LiteralPath $backupPath
Write-Output ("Backup and archive validation succeeded: {0} ({1:N1} MB)" -f $file.FullName, ($file.Length / 1MB))
Write-Output "Store this business-data backup on an encrypted, access-restricted drive. Do not email it or commit it."
