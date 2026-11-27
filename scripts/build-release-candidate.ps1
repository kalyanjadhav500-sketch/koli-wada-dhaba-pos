[CmdletBinding()]
param(
  [string]$Version = '0.1.5'
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$expectedBranch = 'feature/windows-installer-hardening'
$actualBranch = (& git -C $workspace branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $actualBranch -cne $expectedBranch) {
  throw "Build only from the preserved $expectedBranch branch. Current branch: $actualBranch"
}

$desktopPackagePath = Join-Path $workspace 'apps\desktop\package.json'
$desktopPackage = Get-Content -LiteralPath $desktopPackagePath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([string]$desktopPackage.version -cne $Version) {
  throw "Requested candidate $Version does not match apps/desktop/package.json."
}
$releaseRoot = Join-Path $workspace "release\windows-$Version"
if (Test-Path -LiteralPath $releaseRoot) {
  throw "The output folder already exists and will not be overwritten: $releaseRoot"
}

# The staging and renderer build scripts replace generated directories. Move
# each existing user/workspace copy aside first, then restore it in finally.
$relativeTargets = @(
  'build-runtime\api',
  'build-runtime\installer-tools',
  'build-runtime\installer',
  'build-runtime\shared',
  'apps\api\dist',
  'apps\web\dist',
  'apps\desktop\renderer'
)
$workspacePrefix = [IO.Path]::GetFullPath($workspace).TrimEnd('\') + '\'
$snapshotRoot = Join-Path ([IO.Path]::GetTempPath()) ("KWD-ReleaseStage-$([guid]::NewGuid().ToString('N'))")
$snapshotItems = @()
$previousOffline = [Environment]::GetEnvironmentVariable('npm_config_offline', 'Process')
$hadPreviousOffline = $null -ne $previousOffline
$restoreFailures = @()

try {
  if ([IO.Path]::GetPathRoot($snapshotRoot) -ine [IO.Path]::GetPathRoot($workspace)) {
    throw 'Staging preservation must use the same volume as the workspace.'
  }
  New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
  foreach ($relative in $relativeTargets) {
    $sourcePath = Join-Path $workspace $relative
    $fullSource = [IO.Path]::GetFullPath($sourcePath)
    if (-not $fullSource.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to snapshot a generated path outside the workspace: $sourcePath"
    }
    $pathExists = Test-Path -LiteralPath $fullSource
    if ($pathExists -and -not (Test-Path -LiteralPath $fullSource -PathType Container)) {
      throw "An unexpected file occupies a generated directory path: $fullSource"
    }
    $existed = $pathExists
    $snapshotPath = Join-Path $snapshotRoot $relative
    $snapshotItem = [pscustomobject]@{ Relative = $relative; FullSource = $fullSource; SnapshotPath = $snapshotPath; Existed = $existed; Moved = $false }
    $snapshotItems += $snapshotItem
    if ($existed) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $snapshotPath) -Force | Out-Null
      Move-Item -LiteralPath $fullSource -Destination $snapshotPath -ErrorAction Stop
      $snapshotItem.Moved = $true
    }
  }

  # Reuse the already resolved package trees for an offline candidate build.
  # They came from the snapshot above and are restored from it after packaging.
  foreach ($relative in @('build-runtime\api', 'build-runtime\installer-tools')) {
    $savedDirectory = Join-Path $snapshotRoot $relative
    $activeDirectory = Join-Path $workspace $relative
    if (-not (Test-Path -LiteralPath $savedDirectory -PathType Container)) { continue }
    $savedModules = Join-Path $savedDirectory 'node_modules'
    if (Test-Path -LiteralPath $savedModules -PathType Container) {
      New-Item -ItemType Directory -Path $activeDirectory -Force | Out-Null
      Copy-Item -LiteralPath $savedModules -Destination (Join-Path $activeDirectory 'node_modules') -Recurse -Force
    }
    $savedLock = Join-Path $savedDirectory 'package-lock.json'
    if (Test-Path -LiteralPath $savedLock -PathType Leaf) {
      New-Item -ItemType Directory -Path $activeDirectory -Force | Out-Null
      Copy-Item -LiteralPath $savedLock -Destination (Join-Path $activeDirectory 'package-lock.json') -Force
    }
  }

  $env:npm_config_offline = 'true'
  Push-Location $workspace
  try {
    & npm.cmd run desktop:installer
    if ($LASTEXITCODE -ne 0) { throw "Windows installer build failed with exit code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  $setupPath = Join-Path $releaseRoot "Koli Wada Dhaba POS Setup $Version.exe"
  if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw "The packaged Setup.exe was not created at the expected path: $setupPath"
  }
  $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setupPath)
  if ([string]$versionInfo.ProductVersion -notmatch ('^' + [regex]::Escape($Version) + '(?:\.|$)')) {
    throw "The installer file metadata does not match version $Version. Found: $($versionInfo.ProductVersion)"
  }

  $sourceZipScript = Join-Path $workspace 'scripts\package-source-zip.ps1'
  & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $sourceZipScript -Version $Version
  if ($LASTEXITCODE -ne 0) { throw "Complete source ZIP packaging failed with exit code $LASTEXITCODE." }
  $sourceZipPath = Join-Path $releaseRoot "Koli Wada Dhaba POS Project $Version.zip"

  foreach ($artifact in @($setupPath, $sourceZipPath)) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "A required release artifact is missing: $artifact" }
    $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToUpperInvariant()
    $sidecar = $artifact + '.sha256'
    [IO.File]::WriteAllText($sidecar, "$hash *$([IO.Path]::GetFileName($artifact))`r`n", [Text.UTF8Encoding]::new($false))
  }

  Write-Output "Setup: $setupPath"
  Write-Output "Source ZIP: $sourceZipPath"
  Write-Output "Setup version: $($versionInfo.ProductVersion)"
  Write-Output "Setup bytes: $((Get-Item -LiteralPath $setupPath).Length)"
  Write-Output "Source ZIP bytes: $((Get-Item -LiteralPath $sourceZipPath).Length)"
  Write-Output 'SHA256 sidecars were generated for both final artifacts.'
}
finally {
  for ($index = $snapshotItems.Count - 1; $index -ge 0; $index--) {
    $item = $snapshotItems[$index]
    try {
      if (($item.Moved -or -not $item.Existed) -and (Test-Path -LiteralPath $item.FullSource)) {
        $resolvedSource = [IO.Path]::GetFullPath($item.FullSource)
        if (-not $resolvedSource.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
          throw "Refusing to remove a generated directory outside the workspace: $resolvedSource"
        }
        Remove-Item -LiteralPath $resolvedSource -Recurse -Force -ErrorAction Stop
      }
      if ($item.Existed -and $item.Moved) {
        if (-not (Test-Path -LiteralPath $item.SnapshotPath -PathType Container)) {
          throw "The saved workspace directory could not be found: $($item.SnapshotPath)"
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.FullSource) -Force | Out-Null
        Move-Item -LiteralPath $item.SnapshotPath -Destination $item.FullSource -ErrorAction Stop
      }
    }
    catch { $restoreFailures += $_.Exception.Message }
  }

  if ($hadPreviousOffline) { [Environment]::SetEnvironmentVariable('npm_config_offline', $previousOffline, 'Process') }
  else { [Environment]::SetEnvironmentVariable('npm_config_offline', $null, 'Process') }

  if ($restoreFailures.Count -eq 0 -and (Test-Path -LiteralPath $snapshotRoot -PathType Container)) {
    $resolvedSnapshot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $snapshotRoot).Path)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedSnapshot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedSnapshot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  elseif ($restoreFailures.Count -gt 0) {
    Write-Warning "One or more staged workspace directories need manual restoration. Original copies remain under: $snapshotRoot"
    $restoreFailures | ForEach-Object { Write-Warning $_ }
  }
}
