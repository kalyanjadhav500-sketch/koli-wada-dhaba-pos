[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,

    [switch]$IsolatedTestMode,

    [string]$DataDirectory = "",

    [int]$Port = 0,

    [string]$DatabaseUrl = "",

    [string]$PostgresBinDirectory = "",

    [string]$ConfirmationText = "",

    [string]$PreRestoreBackupDirectory = ""
)

$ErrorActionPreference = "Stop"
$previousPgConnectTimeout = [Environment]::GetEnvironmentVariable("PGCONNECT_TIMEOUT", "Process")

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
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

function Assert-PathWithinDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $normalizedChild = Get-NormalizedPath $ChildPath
    $normalizedParent = Get-NormalizedPath $ParentPath
    $prefix = $normalizedParent + [IO.Path]::DirectorySeparatorChar

    if (-not $normalizedChild.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must remain inside the disposable isolated test directory."
    }
}

if (-not $IsolatedTestMode.IsPresent) {
    throw @"
This legacy restore script is disabled for normal development and production use.
Production POS restores must be performed through the Owner-authorized local restore
workflow, which verifies the KoliWadaDhabaPostgreSQL service, installation identity,
pre-restore backup, and restored business data. No database connection was attempted.
For disposable automated tests, explicitly pass -IsolatedTestMode and every required
isolated-cluster argument. No production or developer database URL is accepted.
"@
}

if ([string]::IsNullOrWhiteSpace($DataDirectory) -or
    [string]::IsNullOrWhiteSpace($DatabaseUrl) -or
    [string]::IsNullOrWhiteSpace($PostgresBinDirectory)) {
    throw "Isolated restore requires an explicit data directory, database URL, and PostgreSQL binary directory."
}

if ($Port -lt 1024 -or $Port -gt 65535 -or $Port -in @(5432, 5433)) {
    throw "Isolated restore requires a dynamically allocated port other than 5432 or 5433."
}

$tempRoot = Get-NormalizedPath ([IO.Path]::GetTempPath())
$resolvedDataDirectory = Get-NormalizedPath $DataDirectory
$resolvedPostgresBin = Get-NormalizedPath $PostgresBinDirectory
$isolatedRoot = Split-Path -Parent $resolvedDataDirectory
$isolatedName = Split-Path -Leaf $isolatedRoot
$dataLeaf = Split-Path -Leaf $resolvedDataDirectory

Assert-PathWithinDirectory -ChildPath $resolvedDataDirectory -ParentPath $tempRoot -Description "The isolated PostgreSQL data directory"

if ($isolatedName -notmatch '^KWD-Phase1-Isolated-[a-f0-9]{32}$' -or $dataLeaf -ne 'data') {
    throw "The supplied data directory is not a recognized disposable KWD Phase 1 test cluster. No connection was attempted."
}

$developerDataDirectory = 'C:\Program Files\PostgreSQL\17\data'
if ([string]::Equals(
    $resolvedDataDirectory,
    (Get-NormalizedPath $developerDataDirectory),
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "The developer PostgreSQL data directory is prohibited. No connection was attempted."
}

try {
    $connection = [uri]$DatabaseUrl
    if ($connection.Scheme -notin @('postgres', 'postgresql') -or
        $connection.Host -ne '127.0.0.1' -or
        $connection.Port -ne $Port -or
        [string]::IsNullOrWhiteSpace($connection.AbsolutePath) -or
        $connection.AbsolutePath -eq '/') {
        throw 'The URL must target the specified disposable database on 127.0.0.1 and the explicit test port.'
    }
}
catch {
    throw 'The supplied isolated test database URL is invalid or does not match the isolated port.'
}

if (-not (Test-Path -LiteralPath $resolvedDataDirectory -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $resolvedDataDirectory 'PG_VERSION') -PathType Leaf)) {
    throw 'The disposable PostgreSQL data directory or PG_VERSION marker is missing.'
}

if ((Get-Content -LiteralPath (Join-Path $resolvedDataDirectory 'PG_VERSION') -Raw).Trim() -ne '17') {
    throw 'The isolated test cluster is not PostgreSQL 17.'
}

$postgres = Join-Path $resolvedPostgresBin 'postgres.exe'
$pgCtl = Join-Path $resolvedPostgresBin 'pg_ctl.exe'
$pgDump = Join-Path $resolvedPostgresBin 'pg_dump.exe'
$pgRestore = Join-Path $resolvedPostgresBin 'pg_restore.exe'
$psql = Join-Path $resolvedPostgresBin 'psql.exe'

foreach ($requiredFile in @($postgres, $pgCtl, $pgDump, $pgRestore, $psql)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "A required isolated PostgreSQL 17 tool is missing: $requiredFile"
    }
}

$versionOutput = Invoke-NativeTool -Executable $postgres -Arguments @('--version') -FailureMessage 'Could not verify the isolated PostgreSQL executable'
if ($versionOutput -notmatch '\b17\.') {
    throw 'The supplied isolated PostgreSQL binaries are not version 17.'
}

$pgCtlStatus = Invoke-NativeTool -Executable $pgCtl -Arguments @('-D', $resolvedDataDirectory, 'status') -FailureMessage 'The disposable PostgreSQL cluster is not running' -TimeoutSeconds 30
if ($pgCtlStatus -notmatch '(?i)server is running') {
    throw 'pg_ctl did not confirm that the supplied disposable test cluster is running.'
}

$resolvedBackupPath = if ([IO.Path]::IsPathRooted($BackupPath)) {
    Get-NormalizedPath $BackupPath
}
else {
    Get-NormalizedPath (Join-Path (Get-Location).Path $BackupPath)
}
$expectedBackupDirectory = Join-Path $isolatedRoot 'backups'
Assert-PathWithinDirectory -ChildPath $resolvedBackupPath -ParentPath $expectedBackupDirectory -Description 'The selected backup archive'

if (-not (Test-Path -LiteralPath $resolvedBackupPath -PathType Leaf) -or
    [IO.Path]::GetExtension($resolvedBackupPath) -ne '.dump') {
    throw 'The selected backup archive does not exist or is not a .dump file.'
}

$selectedBackupInfo = Get-Item -LiteralPath $resolvedBackupPath
if ($selectedBackupInfo.Length -le 0) {
    throw 'The selected backup archive is empty.'
}

$selectedArchiveListing = Invoke-NativeTool -Executable $pgRestore -Arguments @('--list', $resolvedBackupPath) -FailureMessage 'The selected backup archive failed pg_restore validation' -TimeoutSeconds 120
if ([string]::IsNullOrWhiteSpace($selectedArchiveListing) -or
    $selectedArchiveListing -notmatch '(?im)^; Archive created at') {
    throw 'pg_restore did not return a valid custom-format archive listing. No restore was attempted.'
}

$env:PGCONNECT_TIMEOUT = '5'
$pgDatabaseUrl = [regex]::Replace($DatabaseUrl, '([?&])schema=[^&]*', '')
$pgDatabaseUrl = $pgDatabaseUrl -replace '\?&', '?'
$pgDatabaseUrl = $pgDatabaseUrl -replace '[?&]$', ''

if ([string]::IsNullOrWhiteSpace($pgDatabaseUrl)) {
    throw 'The normalized isolated PostgreSQL connection URL is empty.'
}

$verificationSql = "SELECT current_setting('data_directory'), current_setting('listen_addresses'), current_setting('port')"
$runtimeOutput = Invoke-NativeTool -Executable $psql -Arguments @(
    '--no-password', '--set=ON_ERROR_STOP=1', '--tuples-only', '--no-align',
    "--dbname=$pgDatabaseUrl", "--command=$verificationSql"
) -FailureMessage 'Could not verify the connected isolated PostgreSQL runtime' -TimeoutSeconds 30
$runtimeParts = $runtimeOutput.Trim() -split '\|'

if ($runtimeParts.Count -ne 3 -or
    -not [string]::Equals((Get-NormalizedPath $runtimeParts[0]), $resolvedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
    $runtimeParts[1] -ne '127.0.0.1' -or
    $runtimeParts[2] -ne "$Port") {
    throw 'The connected PostgreSQL server did not prove it is the exact disposable loopback cluster. No restore was started.'
}

$confirmation = $ConfirmationText
if ([string]::IsNullOrWhiteSpace($confirmation)) {
    $confirmation = Read-Host 'This will replace objects only inside the disposable isolated test database. Type RESTORE ISOLATED KWD TEST DATABASE to continue'
}

if ($confirmation -cne 'RESTORE ISOLATED KWD TEST DATABASE') {
    throw 'Isolated restore cancelled; no database changes were made.'
}

if ([string]::IsNullOrWhiteSpace($PreRestoreBackupDirectory)) {
    $PreRestoreBackupDirectory = Join-Path $isolatedRoot 'pre-restore'
}
elseif (-not [IO.Path]::IsPathRooted($PreRestoreBackupDirectory)) {
    $PreRestoreBackupDirectory = Join-Path $isolatedRoot $PreRestoreBackupDirectory
}

$resolvedPreRestoreDirectory = Get-NormalizedPath $PreRestoreBackupDirectory
Assert-PathWithinDirectory -ChildPath $resolvedPreRestoreDirectory -ParentPath $isolatedRoot -Description 'The pre-restore backup directory'
New-Item -ItemType Directory -Path $resolvedPreRestoreDirectory -Force | Out-Null

$preRestoreName = 'koli-wada-dhaba-isolated-pre-restore-{0}-{1}.dump' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), [guid]::NewGuid().ToString('N')
$preRestorePath = Join-Path $resolvedPreRestoreDirectory $preRestoreName
$partialPath = $preRestorePath + '.partial'

if (Test-Path -LiteralPath $preRestorePath) {
    throw 'A pre-restore backup with the generated name already exists. No file was overwritten.'
}

try {
    [void](Invoke-NativeTool -Executable $pgDump -Arguments @(
        '--no-password', '--format=custom', '--no-owner', '--no-acl',
        "--file=$partialPath", "--dbname=$pgDatabaseUrl"
    ) -FailureMessage 'Could not create the required isolated pre-restore backup' -TimeoutSeconds 1800)

    if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
        throw 'pg_dump did not create the expected isolated pre-restore archive.'
    }

    $partialInfo = Get-Item -LiteralPath $partialPath
    if ($partialInfo.Length -le 0) {
        throw 'The isolated pre-restore archive is empty.'
    }

    $preRestoreListing = Invoke-NativeTool -Executable $pgRestore -Arguments @('--list', $partialPath) -FailureMessage 'The isolated pre-restore archive failed pg_restore validation' -TimeoutSeconds 120
    if ([string]::IsNullOrWhiteSpace($preRestoreListing) -or
        $preRestoreListing -notmatch '(?im)^; Archive created at') {
        throw 'The pre-restore archive did not pass custom-format validation. No restore was attempted.'
    }

    Move-Item -LiteralPath $partialPath -Destination $preRestorePath
    $preRestoreInfo = Get-Item -LiteralPath $preRestorePath
    $preRestoreHash = (Get-FileHash -LiteralPath $preRestorePath -Algorithm SHA256).Hash

    [void](Invoke-NativeTool -Executable $pgRestore -Arguments @(
        '--exit-on-error', '--clean', '--if-exists', '--no-owner', '--no-acl',
        "--dbname=$pgDatabaseUrl", $resolvedBackupPath
    ) -FailureMessage 'The isolated PostgreSQL restore failed; the validated pre-restore archive has been retained' -TimeoutSeconds 1800)

    $postRestoreSql = "SELECT current_database(), current_setting('data_directory'), current_setting('port'), (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE')"
    $postRestoreOutput = Invoke-NativeTool -Executable $psql -Arguments @(
        '--no-password', '--set=ON_ERROR_STOP=1', '--tuples-only', '--no-align',
        "--dbname=$pgDatabaseUrl", "--command=$postRestoreSql"
    ) -FailureMessage 'The isolated database could not be verified after restore' -TimeoutSeconds 60
    $postRestoreParts = $postRestoreOutput.Trim() -split '\|'

    if ($postRestoreParts.Count -ne 4 -or
        $postRestoreParts[0] -ne $connection.AbsolutePath.TrimStart('/') -or
        -not [string]::Equals((Get-NormalizedPath $postRestoreParts[1]), $resolvedDataDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        $postRestoreParts[2] -ne "$Port" -or
        [int]$postRestoreParts[3] -le 0) {
        throw "The restored isolated database failed post-restore identity or schema validation. The pre-restore backup was retained at: $preRestorePath"
    }

    [pscustomobject]@{
        status = 'restored-and-verified'
        purpose = 'isolated-test'
        restoredArchive = $resolvedBackupPath
        preRestoreArchive = $preRestoreInfo.FullName
        preRestoreSizeBytes = $preRestoreInfo.Length
        preRestoreSha256 = $preRestoreHash
        database = $postRestoreParts[0]
        dataDirectory = $postRestoreParts[1]
        port = $Port
        publicTableCount = [int]$postRestoreParts[3]
        completedLocal = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Write-Output
}
catch {
    if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
        Write-Warning "An incomplete pre-restore archive was retained inside the isolated test directory: $partialPath"
    }
    throw
}
finally {
    [Environment]::SetEnvironmentVariable('PGCONNECT_TIMEOUT', $previousPgConnectTimeout, 'Process')
}
