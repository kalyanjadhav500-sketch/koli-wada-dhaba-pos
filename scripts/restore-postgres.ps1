param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    [string]$DirectUrl = "",
    [string]$ConfirmationText = "",
    [string]$PreRestoreBackupDirectory = ""
)

$ErrorActionPreference = "Stop"
$workspace = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envPath = Join-Path $workspace ".env"
$directUrl = $DirectUrl
if (-not $directUrl) {
    $directUrl = $env:DIRECT_URL
}

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
    throw "Set DIRECT_URL to the local loopback application database URL."
}

try {
    $connection = [uri]$directUrl
    if (
        $connection.Scheme -notin @("postgres", "postgresql") -or
        -not $connection.Host -or
        $connection.Host -notin @("localhost", "127.0.0.1", "::1")
    ) {
        throw "The destination must be the local loopback PostgreSQL database."
    }
} catch {
    throw "DIRECT_URL must be a loopback PostgreSQL URL."
}

if (-not [System.IO.Path]::IsPathRooted($BackupPath)) {
    $BackupPath = Join-Path $workspace $BackupPath
}
if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
    throw "The specified backup file does not exist."
}

$pgRestore = Get-Command pg_restore.exe -ErrorAction SilentlyContinue
$pgDump = Get-Command pg_dump.exe -ErrorAction SilentlyContinue
$psql = Get-Command psql.exe -ErrorAction SilentlyContinue
if (-not $pgRestore -or -not $pgDump -or -not $psql) {
    throw "PostgreSQL pg_dump.exe, pg_restore.exe, and psql.exe are required. Install PostgreSQL client tools and add their bin folder to PATH."
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
if ($tableCount -eq 0) {
    throw "The target database is empty. The restore workflow requires a preexisting application database."
}

$confirmation = $ConfirmationText
if (-not $confirmation) {
    $confirmation = Read-Host "This will replace the current local POS database after creating a pre-restore backup. Type RESTORE LOCAL POS DATABASE to continue"
}
if ($confirmation -cne "RESTORE LOCAL POS DATABASE") {
    throw "Restore cancelled; no database changes were made."
}

if (-not $PreRestoreBackupDirectory) {
    $PreRestoreBackupDirectory = Join-Path $env:ProgramData "Koli Wada Dhaba POS\Backups\PreRestore"
    $securePreRestoreDirectory = $true
}
if (-not [System.IO.Path]::IsPathRooted($PreRestoreBackupDirectory)) {
    $PreRestoreBackupDirectory = Join-Path $workspace $PreRestoreBackupDirectory
}
New-Item -ItemType Directory -Path $PreRestoreBackupDirectory -Force | Out-Null
if ($securePreRestoreDirectory) {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $aclResult = & icacls.exe $PreRestoreBackupDirectory /inheritance:r /grant:r `
        "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*${currentSid}:(OI)(CI)M" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restrict pre-restore backup permissions. No restore was attempted."
    }
}
$preRestorePath = Join-Path $PreRestoreBackupDirectory (
    "koli-wada-dhaba-pre-restore-{0}-{1}.dump" -f (Get-Date -Format "yyyyMMdd-HHmmss"), [guid]::NewGuid().ToString("N")
)
$pgDatabaseUrl = [regex]::Replace($directUrl, '([?&])schema=[^&]*', '')
$pgDatabaseUrl = $pgDatabaseUrl -replace '\?&', '?'
$pgDatabaseUrl = $pgDatabaseUrl -replace '[?&]$', ''
$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $preBackupOutput = & $pgDump.Source --no-password --format=custom --no-owner --no-acl `
        "--file=$preRestorePath" "--dbname=$pgDatabaseUrl" 2>&1
    $preBackupExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($preBackupExitCode -ne 0) {
    if (Test-Path -LiteralPath $preRestorePath) {
        Remove-Item -LiteralPath $preRestorePath -Force
    }
    throw "Could not create the required pre-restore backup. No restore was attempted."
}
$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $preBackupListing = & $pgRestore.Source --list $preRestorePath 2>&1
    $preBackupValidationCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($preBackupValidationCode -ne 0 -or -not $preBackupListing) {
    throw "The pre-restore backup did not validate. It was retained for investigation; no restore was attempted."
}

$previousErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $restoreOutput = & $pgRestore.Source --exit-on-error --clean --if-exists --no-owner --no-acl --dbname=$pgDatabaseUrl $BackupPath 2>&1
    $restoreExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorPreference
}
if ($restoreExitCode -ne 0) {
    throw "Restore failed and may have partially populated the destination. A validated pre-restore backup was retained at '$preRestorePath'; inspect the target before any retry."
}

Write-Output "Validated pre-restore backup retained at: $preRestorePath"
Write-Output "Restore completed. Keep the source database and backup unchanged until database counts, API health, and billing workflows have been checked."
