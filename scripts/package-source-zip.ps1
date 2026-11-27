[CmdletBinding()]
param(
  [string]$Version = '0.1.5',
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$desktopPackagePath = Join-Path $workspace 'apps\desktop\package.json'
$desktopPackage = Get-Content -LiteralPath $desktopPackagePath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([string]$desktopPackage.version -cne $Version) {
  throw "Requested source ZIP version $Version does not match desktop package version $($desktopPackage.version)."
}

$versionOutputRoot = Join-Path $workspace "release\windows-$Version"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $versionOutputRoot "Koli Wada Dhaba POS Project $Version.zip"
}
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$allowedOutputRoot = [IO.Path]::GetFullPath($versionOutputRoot).TrimEnd('\') + '\'
if (-not $outputFullPath.StartsWith($allowedOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The source ZIP must be created inside its versioned release folder.'
}
if (Test-Path -LiteralPath $outputFullPath) {
  throw 'The source ZIP already exists and will not be overwritten.'
}

$includeRoots = @('apps', 'scripts', 'docs', 'build-runtime', 'reference-videos')
$rootFiles = @(
  '.gitignore',
  '.env.example',
  'compose.yaml',
  'package.json',
  'package-lock.json',
  'README.md',
  'Reset-Owner-Password.cmd',
  'Restart-POS-API.cmd'
)
$requiredEntries = @(
  'apps/api/src/server.ts',
  'apps/desktop/main.cjs',
  'apps/desktop/preload.cjs',
  'apps/desktop/maintenance-contract.cjs',
  'apps/desktop/print-contract.cjs',
  'apps/desktop/print-contract.test.cjs',
  'apps/web/src/App.tsx',
  'apps/shared/menu.json',
  'scripts/windows/Install-LocalPos.ps1',
  'scripts/windows/Backup-LocalPos.ps1',
  'scripts/windows/Restore-LocalPos.ps1',
  'scripts/windows/Pos-Maintenance-Broker.ps1',
  'scripts/windows/Uninstall-LocalPos.ps1',
  'scripts/package-source-zip.ps1',
  'scripts/build-release-candidate.ps1',
  'docs/windows-installation-0.1.5.md',
  'docs/windows-upgrade-0.1.5.md',
  'docs/windows-backup-restore-0.1.5.md',
  'docs/windows-uninstall-data-preservation-0.1.5.md',
  'docs/windows-acceptance-checklist-0.1.5.md',
  'docs/menu-reference-review.md',
  'build-runtime/api/dist/server.js',
  'build-runtime/api/prisma.config.ts',
  'build-runtime/postgresql17/bin/initdb.exe',
  'build-runtime/postgresql17/bin/pg_ctl.exe',
  'build-runtime/postgresql17/bin/pg_restore.exe',
  'build-runtime/postgresql17/server_license.txt',
  'build-runtime/postgresql17/commandlinetools_3rd_party_licenses.txt'
)

function Test-IncludedFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $normalized = $RelativePath.Replace('\', '/')
  $segments = @($normalized.Split('/'))
  $fileName = $segments[-1]
  if ($segments -contains '.git' -or $segments -contains 'release') { return $false }
  if ($normalized -ceq 'apps/web/capacitor.config.ts') { return $false }
  if ($segments -contains 'node_modules' -and $segments[0] -ne 'build-runtime') { return $false }
  if ($segments -contains 'android' -or $segments -contains 'coverage') { return $false }
  if ($normalized -match '^apps/desktop/renderer(/|$)' -or $normalized -match '^apps/(api|web)/dist(/|$)') { return $false }
  if ($segments -contains 'Backups' -or $segments -contains 'Logs' -or $segments -contains 'temp' -or
      $segments -contains 'tmp' -or $segments -contains 'test-results' -or $segments -contains 'pre-restore') { return $false }
  if ($normalized -match '^build-runtime/postgresql17/data(/|$)' -or $normalized -match '(^|/)KWD-Phase1-Isolated-[^/]+/') { return $false }
  if ($fileName -match '^\.env($|\.)' -and $fileName -cne '.env.example') { return $false }
  if ($fileName -ceq '.pgadmin-password' -or $fileName -match '(?i)\.dpapi$|\.pgpass$|\.dump$|\.sqlite3?$|\.bak$|\.backup$') { return $false }
  if ($fileName -match '(?i)^(postgresql\.conf|pg_hba\.conf|postmaster\.pid|postmaster\.opts|PG_VERSION)$' -and $normalized -match '(^|/)(Data|data)(/|$)') { return $false }
  if ($fileName -match '(?i)\.(tmp|temp|log)$') { return $false }
  return $true
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputFullPath)) | Out-Null
$temporaryPath = $outputFullPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
$sourceFiles = [System.Collections.Generic.List[object]]::new()
$workspacePrefix = [IO.Path]::GetFullPath($workspace).TrimEnd('\') + '\'

foreach ($rootFile in $rootFiles) {
  $sourcePath = Join-Path $workspace $rootFile
  if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
    $rootItem = Get-Item -LiteralPath $sourcePath
    $sourceFiles.Add([pscustomobject]@{ FullName = $sourcePath; RelativePath = $rootFile; LastWriteTime = $rootItem.LastWriteTime })
  }
}
foreach ($root in $includeRoots) {
  $rootPath = Join-Path $workspace $root
  if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
  $rootItem = Get-Item -LiteralPath $rootPath -Force
  if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to package a source root that is a reparse point: $rootPath"
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force -ErrorAction Stop)) {
    $fileFullPath = [IO.Path]::GetFullPath($file.FullName)
    if (-not $fileFullPath.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "A source file resolved outside the workspace: $($file.FullName)"
    }
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to package a source file that is a reparse point: $($file.FullName)"
    }
    $relative = $fileFullPath.Substring($workspacePrefix.Length).Replace('\', '/')
    if (Test-IncludedFile -RelativePath $relative) {
      $sourceFiles.Add([pscustomobject]@{ FullName = $file.FullName; RelativePath = $relative; LastWriteTime = $file.LastWriteTime })
    }
  }
}

$entryNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$outputStream = $null
$archive = $null
try {
  $outputStream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $archive = [IO.Compression.ZipArchive]::new($outputStream, [IO.Compression.ZipArchiveMode]::Create, $false)
  foreach ($source in $sourceFiles) {
    if (-not $entryNames.Add($source.RelativePath)) {
      throw "Duplicate source ZIP entry: $($source.RelativePath)"
    }
    $entry = $archive.CreateEntry($source.RelativePath, [IO.Compression.CompressionLevel]::Optimal)
    $writeTime = $source.LastWriteTime
    if ($writeTime.Year -lt 1980) { $writeTime = [DateTime]::new(1980, 1, 1) }
    $entry.LastWriteTime = [DateTimeOffset]::new($writeTime)
    $inputStream = [IO.File]::OpenRead($source.FullName)
    $entryStream = $entry.Open()
    try { $inputStream.CopyTo($entryStream) }
    finally { $entryStream.Dispose(); $inputStream.Dispose() }
  }
  $archive.Dispose()
  $archive = $null
  $outputStream.Dispose()
  $outputStream = $null
  [IO.File]::Move($temporaryPath, $outputFullPath)
}
catch {
  if ($archive) { $archive.Dispose() }
  if ($outputStream) { $outputStream.Dispose() }
  if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
  throw
}

$verify = [IO.Compression.ZipFile]::OpenRead($outputFullPath)
try {
  $verifiedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $verify.Entries) {
    if (-not $verifiedNames.Add($entry.FullName)) { throw "Duplicate ZIP entry found: $($entry.FullName)" }
    if (-not (Test-IncludedFile -RelativePath $entry.FullName)) { throw "A prohibited file is present in the source ZIP: $($entry.FullName)" }
    $readStream = $entry.Open()
    try {
      $buffer = [byte[]]::new(65536)
      while ($readStream.Read($buffer, 0, $buffer.Length) -gt 0) { }
    }
    finally { $readStream.Dispose() }
  }
  foreach ($required in $requiredEntries) {
    if (-not $verifiedNames.Contains($required)) { throw "A required project/runtime file is absent from the ZIP: $required" }
  }
}
finally { $verify.Dispose() }

$file = Get-Item -LiteralPath $outputFullPath
$hash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash
Write-Output "Source ZIP: $outputFullPath"
Write-Output "Bytes: $($file.Length)"
Write-Output "SHA256: $hash"
Write-Output "Entries: $($entryNames.Count)"
