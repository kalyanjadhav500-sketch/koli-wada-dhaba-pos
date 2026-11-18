$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$apiDirectory = Join-Path $workspaceRoot "apps\api"
$node = "C:\Program Files\nodejs\node.exe"

if (-not (Test-Path $node)) {
  throw "Node.js was not found at its installed path."
}

$listeners = Get-NetTCPConnection -State Listen -LocalPort 4000 -ErrorAction SilentlyContinue
foreach ($ownerId in ($listeners | Select-Object -ExpandProperty OwningProcess -Unique)) {
  $existing = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId"
  if (
    -not $existing -or
    $existing.ExecutablePath -notmatch "node\.exe$" -or
    $existing.CommandLine -notmatch "dist[\\/]server\.js"
  ) {
    throw "Port 4000 is used by a process that is not the POS API; it was left unchanged."
  }
  Stop-Process -Id $ownerId -Force
}

$env:NODE_ENV = "production"
$env:API_HOST = "127.0.0.1"
$env:API_PORT = "4000"
$process = Start-Process -FilePath $node -ArgumentList "dist\server.js" -WorkingDirectory $apiDirectory -PassThru

$healthy = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
  Start-Sleep -Milliseconds 500
  if ($process.HasExited) {
    throw "The POS API exited while restarting. Check the API window for its error."
  }
  try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:4000/api/health" -TimeoutSec 2 -UseBasicParsing
    if ($response.StatusCode -eq 200) {
      $health = $response.Content | ConvertFrom-Json
      if ($health.status -eq "ok" -and $health.database -eq "connected") {
        $healthy = $true
        break
      }
    }
  }
  catch {
    if ($attempt -eq 19) {
      throw "POS API did not become healthy. Check the API window for details."
    }
  }
}

if (-not $healthy) {
  throw "POS API did not report a healthy database connection."
}

Write-Output "POS API restarted successfully. The Cloudflare Tunnel can reconnect to it."
