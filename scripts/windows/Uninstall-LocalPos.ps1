param(
  [Parameter(Mandatory = $true)]
  [string]$InstallDirectory
)

$ErrorActionPreference = "Stop"
$serviceName = "KoliWadaDhabaPostgreSQL"
$programDataRoot = Join-Path $env:ProgramData "Koli Wada Dhaba POS"
$dataDirectory = Join-Path $programDataRoot "Data"
$markerPath = Join-Path $programDataRoot "config\installation.json"
$pgCtl = Join-Path $InstallDirectory "resources\postgresql17\bin\pg_ctl.exe"
$backupScript = Join-Path $InstallDirectory "resources\installer\Backup-LocalPos.ps1"
$taskName = "Koli Wada Dhaba POS Daily Backup"
$taskPath = "\Koli Wada Dhaba POS\"

function ConvertTo-WindowsArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') { $slashes++; continue }
    if ($character -eq '"') {
      [void]$builder.Append(('\' * (($slashes * 2) + 1)))
      [void]$builder.Append('"')
    }
    else {
      if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
      [void]$builder.Append($character)
    }
    $slashes = 0
  }
  if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Invoke-PostgresControl {
  param([string[]]$Arguments)
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $pgCtl
  $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join " "
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "Could not start the bundled PostgreSQL control tool." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(90000)) {
      $process.Kill()
      $process.WaitForExit()
      throw "The dedicated PostgreSQL service did not stop in time."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      throw "The dedicated PostgreSQL service operation failed: $($stderr.Trim()) $($stdout.Trim())"
    }
  }
  finally {
    $process.Dispose()
  }
}

if (-not [Environment]::Is64BitOperatingSystem) {
  throw "This uninstaller helper requires 64-bit Windows."
}
$service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
if ($service) {
  $exeMatch = [regex]::Match($service.PathName, '^(?:"([^"]+)"|(\S+))')
  $serviceExe = if ($exeMatch.Groups[1].Success) { $exeMatch.Groups[1].Value } else { $exeMatch.Groups[2].Value }
  $dataMatch = [regex]::Match($service.PathName, '(?i)\s-D\s+(?:"([^"]+)"|(\S+))')
  $serviceData = if ($dataMatch.Groups[1].Success) { $dataMatch.Groups[1].Value } else { $dataMatch.Groups[2].Value }
  $expectedExe = [IO.Path]::GetFullPath($pgCtl)
  if (-not $dataMatch.Success -or
      -not [string]::Equals([IO.Path]::GetFullPath($serviceData).TrimEnd('\'),
        [IO.Path]::GetFullPath($dataDirectory).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals([IO.Path]::GetFullPath($serviceExe), $expectedExe, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "The named PostgreSQL service does not match this verified Koli Wada Dhaba installation. It was left running and unchanged."
  }
  if (-not (Test-Path -LiteralPath $dataDirectory -PathType Container) -or
      (Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json).DataDirectory -ne [IO.Path]::GetFullPath($dataDirectory)) {
    throw "The ProgramData cluster marker does not match. PostgreSQL service and data were left unchanged."
  }
  if (-not (Test-Path -LiteralPath $pgCtl -PathType Leaf)) {
    throw "The bundled PostgreSQL control tool is missing; service registration was retained to avoid damaging the existing cluster."
  }
  $currentService = Get-Service -Name $serviceName -ErrorAction Stop
  if ($currentService.Status -ne "Stopped") {
    Stop-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus(
      [ServiceProcess.ServiceControllerStatus]::Stopped,
      [TimeSpan]::FromSeconds(90)
    )
  }
  Invoke-PostgresControl -Arguments @("unregister", "-N", $serviceName)
}

$task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if ($task) {
  $taskAction = $task.Actions | Where-Object { $_.Arguments -like "*$backupScript*" } | Select-Object -First 1
  if (-not $taskAction) {
    throw "The scheduled task name is in use by a different action; it was left unchanged."
  }
  Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
}

Write-Output "The POS PostgreSQL Windows service and backup task were unregistered."
Write-Output "ProgramData database files, business records, Owner configuration, and backups were preserved."
