[CmdletBinding()]
param(
    [switch]$IsolatedTestMode,
    [string]$DataDirectory = "",
    [int]$Port = 0,
    [string]$DatabaseUrl = "",
    [string]$PostgresBinDirectory = "",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$previousPgConnectTimeout = [Environment]::GetEnvironmentVariable("PGCONNECT_TIMEOUT", "Process")

function Get-FullPathWithoutTrailingSeparator {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
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

function Invoke-NativeTool {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage,
        [int]$TimeoutSeconds = 300
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
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
            if ($detail.Length -gt 1200) {
                $detail = $detail.Substring(0, 1200)
            }
            throw "$FailureMessage (exit code $($process.ExitCode)). $detail"
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

# Prisma appends schema=public to its connection URLs. libpq tools such as
# psql and pg_dump do not accept Prisma's schema parameter, so remove only
# that parameter before passing the URL to PostgreSQL client utilities.
$pgDatabaseUrl = [regex]::Replace($DatabaseUrl, '([?&])schema=[^&]*', '')
$pgDatabaseUrl = $pgDatabaseUrl -replace '\?&', '?'
$pgDatabaseUrl = $pgDatabaseUrl -replace '[?&]$', ''

if ([string]::IsNullOrWhiteSpace($pgDatabaseUrl)) {
    throw "The normalized isolated PostgreSQL connection URL is empty."
}

if (-not $IsolatedTestMode) {
    throw @"
This legacy backup script is disabled for normal development and production use.
Production POS backups must use the installed scripts/windows/Backup-LocalPos.ps1 utility,
which validates the dedicated KoliWadaDhabaPostgreSQL service and its protected configuration.
For disposable automated tests, explicitly pass -IsolatedTestMode and every required
isolated-cluster argument. No database connection was attempted.
"@
}

if (-not $IsolatedTestMode.IsPresent) {
    throw "Isolated test mode must be explicitly enabled."
}

if ($Port -lt 1024 -or $Port -gt 65535) {
    throw "Isolated mode requires an explicit TCP port between 1024 and 65535."
}

if ([string]::IsNullOrWhiteSpace($DataDirectory) -or
    [string]::IsNullOrWhiteSpace($DatabaseUrl) -or
    [string]::IsNullOrWhiteSpace($PostgresBinDirectory)) {
    throw "Isolated mode requires an explicit data directory, database URL, and PostgreSQL binary directory."
}

$tempRoot = Get-FullPathWithoutTrailingSeparator ([IO.Path]::GetTempPath())
$resolvedDataDirectory = Get-FullPathWithoutTrailingSeparator $DataDirectory
$resolvedPostgresBin = Get-FullPathWithoutTrailingSeparator $PostgresBinDirectory
$isolatedRoot = Split-Path -Parent $resolvedDataDirectory
$isolatedName = Split-Path -Leaf $isolatedRoot

if (-not $resolvedDataDirectory.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $isolatedName -notmatch '^KWD-Phase1-Isolated-[a-f0-9]{32}$' -or
    (Split-Path -Leaf $resolvedDataDirectory) -ne "data") {
    throw "The supplied PostgreSQL data directory is not a recognized disposable KWD Phase 1 test cluster. No connection was attempted."
}

$developerDataDirectory = "C:\Program Files\PostgreSQL\17\data"
if ([string]::Equals($resolvedDataDirectory, (Get-FullPathWithoutTrailingSeparator $developerDataDirectory), [StringComparison]::OrdinalIgnoreCase)) {
    throw "The developer PostgreSQL data directory is prohibited. No connection was attempted."
}

if ($Port -in @(5432, 5433)) {
    throw "Ports 5432 and 5433 are prohibited for this isolated test backup. Use a dynamically allocated disposable-cluster port."
}

try {
    $connection = [uri]$DatabaseUrl
    if ($connection.Scheme -notin @("postgres", "postgresql") -or
        $connection.Host -ne "127.0.0.1" -or
        $connection.Port -ne $Port -or
        [string]::IsNullOrWhiteSpace($connection.AbsolutePath) -or
        $connection.AbsolutePath -eq "/") {
        throw "The URL must target the specified disposable database on 127.0.0.1 and the explicit test port."
    }
}
catch {
    throw "The supplied isolated test database URL is invalid or does not match the isolated port."
}

if (-not (Test-Path -LiteralPath $resolvedDataDirectory -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $resolvedDataDirectory "PG_VERSION") -PathType Leaf)) {
    throw "The disposable PostgreSQL data directory or PG_VERSION marker is missing."
}
if ((Get-Content -LiteralPath (Join-Path $resolvedDataDirectory "PG_VERSION") -Raw).Trim() -ne "17") {
    throw "The isolated test cluster is not PostgreSQL 17."
}

$postgres = Join-Path $resolvedPostgresBin "postgres.exe"
$pgCtl = Join-Path $resolvedPostgresBin "pg_ctl.exe"
$pgDump = Join-Path $resolvedPostgresBin "pg_dump.exe"
$pgRestore = Join-Path $resolvedPostgresBin "pg_restore.exe"
$psql = Join-Path $resolvedPostgresBin "psql.exe"
foreach ($requiredFile in @($postgres, $pgCtl, $pgDump, $pgRestore, $psql)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "A required isolated PostgreSQL 17 tool is missing: $requiredFile"
    }
}

$versionOutput = Invoke-NativeTool -Executable $postgres -Arguments @("--version") -FailureMessage "Could not verify the isolated PostgreSQL executable"
if ($versionOutput -notmatch '\b17\.') {
    throw "The supplied isolated PostgreSQL binaries are not version 17."
}

$pgCtlStatus = Invoke-NativeTool -Executable $pgCtl -Arguments @("-D", $resolvedDataDirectory, "status") -FailureMessage "The disposable PostgreSQL cluster is not running" -TimeoutSeconds 30
if ($pgCtlStatus -notmatch '(?i)server is running') {
    throw "pg_ctl did not confirm that the supplied disposable test cluster is running."
}

$env:PGCONNECT_TIMEOUT = "5"
$verificationSql = "SELECT current_setting('data_directory'), current_setting('listen_addresses'), current_setting('port')"
$runtimeOutput = Invoke-NativeTool -Executable $psql -Arguments @(
    "--no-password", "--set=ON_ERROR_STOP=1", "--tuples-only", "--no-align",
    "--dbname=$pgDatabaseUrl", "--command=$verificationSql"
) -FailureMessage "Could not verify the connected isolated PostgreSQL runtime" -TimeoutSeconds 30
$runtimeParts = ($runtimeOutput.Trim() -split '\|')
if ($runtimeParts.Count -ne 3 -or
    -not [string]::Equals((Get-FullPathWithoutTrailingSeparator $runtimeParts[0]), $resolvedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
    $runtimeParts[1] -ne "127.0.0.1" -or
    $runtimeParts[2] -ne "$Port") {
    throw "The connected PostgreSQL server did not prove it is the exact disposable loopback cluster. No dump was started."
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $isolatedRoot "backups"
}
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path (Get-Location).Path $OutputDirectory
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$resolvedOutputDirectory = Get-FullPathWithoutTrailingSeparator $OutputDirectory
if (-not $resolvedOutputDirectory.StartsWith($isolatedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Isolated test backup output must remain inside the disposable KWD test directory."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$backupName = "koli-wada-dhaba-isolated-$timestamp-$([guid]::NewGuid().ToString('N')).dump"
$partialPath = Join-Path $resolvedOutputDirectory ($backupName + ".partial")
$backupPath = Join-Path $resolvedOutputDirectory $backupName
if (Test-Path -LiteralPath $backupPath) {
    throw "A backup archive with the generated name already exists. No file was overwritten."
}

try {
    [void](Invoke-NativeTool -Executable $pgDump -Arguments @(
        "--no-password", "--format=custom", "--no-owner", "--no-acl",
        "--file=$partialPath", "--dbname=$pgDatabaseUrl"
    ) -FailureMessage "The isolated PostgreSQL custom-format backup failed" -TimeoutSeconds 1800)

    if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
        throw "pg_dump did not create the expected isolated backup archive."
    }
    $partialInfo = Get-Item -LiteralPath $partialPath
    if ($partialInfo.Length -le 0) {
        throw "The isolated backup archive is empty."
    }

    $archiveListing = Invoke-NativeTool -Executable $pgRestore -Arguments @("--list", $partialPath) -FailureMessage "The isolated backup archive failed pg_restore validation" -TimeoutSeconds 120
    if ([string]::IsNullOrWhiteSpace($archiveListing) -or $archiveListing -notmatch '(?im)^; Archive created at') {
        throw "pg_restore did not return a valid custom-format archive listing. The partial archive was retained for diagnosis."
    }

    Move-Item -LiteralPath $partialPath -Destination $backupPath
    $backupInfo = Get-Item -LiteralPath $backupPath
    $hash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash

    [pscustomobject]@{
        status = "verified"
        purpose = "isolated-test"
        archivePath = $backupInfo.FullName
        sizeBytes = $backupInfo.Length
        sha256 = $hash
        createdLocal = (Get-Date).ToString("o")
        port = $Port
    } | ConvertTo-Json -Compress | Write-Output
}
catch {
    if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
        # Keep an invalid partial archive inside the disposable cluster for diagnosis.
        Write-Warning "An unverified partial archive was retained at: $partialPath"
    }
    throw
}
finally {
    [Environment]::SetEnvironmentVariable("PGCONNECT_TIMEOUT", $previousPgConnectTimeout, "Process")
}
