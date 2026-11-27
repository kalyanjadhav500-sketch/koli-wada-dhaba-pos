[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# This script is installed under Program Files and launched only by the
# Koli Wada Dhaba POS SYSTEM scheduled task. The renderer can send only the
# fixed JSON operations below over the interactive-user-only named pipe.
$pipeName = 'KwdPosMaintenanceBroker'
$serviceName = 'KoliWadaDhabaPostgreSQL'
$databaseName = 'koli_wada_dhaba'
$port = 5433
$backupDirectory = Join-Path $env:ProgramData 'Koli Wada Dhaba POS\Backups'
$logDirectory = Join-Path $env:ProgramData 'Koli Wada Dhaba POS\Logs'
$statusPath = Join-Path $logDirectory 'backup-status.json'
$historyPath = Join-Path $logDirectory 'backup-history.json'
$restoreStatusPath = Join-Path $logDirectory 'restore-status.json'
$backupScript = Join-Path $PSScriptRoot 'Backup-LocalPos.ps1'
$restoreScript = Join-Path $PSScriptRoot 'Restore-LocalPos.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$postgresBin = Join-Path (Split-Path -Parent $PSScriptRoot) 'postgresql17\bin'
$pgRestore = Join-Path $postgresBin 'pg_restore.exe'
$pendingRestores = @{}
$maximumRequestBytes = 8192
$maximumHistoryEntries = 100

function Assert-TrustedPosFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw 'A required installed POS maintenance file is missing.'
  }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'A POS maintenance file is a reparse point and cannot be trusted.'
  }
}

function Get-RequestIdentity {
  param([Parameter(Mandatory = $true)][System.IO.Pipes.NamedPipeServerStream]$Pipe)

  try {
    $name = $Pipe.GetImpersonationUserName()
  }
  catch {
    throw 'Windows could not verify the local POS maintenance client.'
  }
  if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\r\n\0]') {
    throw 'Windows could not verify the local POS maintenance client.'
  }
  return $name
}

function Assert-ExactRequestFields {
  param(
    [Parameter(Mandatory = $true)]$Request,
    [Parameter(Mandatory = $true)][string[]]$AllowedFields
  )

  if ($null -eq $Request -or $Request -isnot [System.Collections.IDictionary]) {
    throw 'The local POS maintenance request is invalid.'
  }
  foreach ($key in $Request.Keys) {
    if ([string]$key -notin $AllowedFields) {
      throw 'The local POS maintenance request contains an unsupported field.'
    }
  }
}

function Assert-OwnerToken {
  param([Parameter(Mandatory = $true)]$Request)

  $token = [string]$Request.token
  if ($token.Length -gt 4096 -or $token -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
    throw 'Sign in with the Owner account to manage backups.'
  }

  try {
    $headers = @{ Authorization = "Bearer $token" }
    $user = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:4000/api/me' `
      -Headers $headers -TimeoutSec 5 -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
  }
  catch {
    throw 'Owner authorization could not be verified by the local POS service. Sign in again and retry.'
  }

  if ($user.role -cne 'OWNER' -or [string]::IsNullOrWhiteSpace([string]$user.id)) {
    throw 'Only the signed-in Owner can manage protected backups.'
  }
  return [string]$user.id
}

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

function Invoke-LocalTool {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [int]$TimeoutSeconds = 120
  )

  Assert-TrustedPosFile -Path $FilePath
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value $_ }) -join ' ')
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw 'The local POS maintenance operation could not start.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill()
      $process.WaitForExit()
      throw 'The local POS maintenance operation timed out.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      StdOut = $stdout
      StdErr = $stderr
    }
  }
  finally { $process.Dispose() }
}

function Get-BackupEntries {
  Assert-TrustedPosFile -Path (Join-Path (Join-Path $env:ProgramData 'Koli Wada Dhaba POS') 'config\installation.json')
  if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
    throw 'The protected POS backup folder is unavailable.'
  }
  $directory = Get-Item -LiteralPath $backupDirectory -Force -ErrorAction Stop
  if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'The protected POS backup folder is not a regular local folder.'
  }

  $known = @{}
  if (Test-Path -LiteralPath $historyPath -PathType Leaf) {
    try {
      $stored = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      foreach ($entry in @($stored.Backups)) {
        if ($entry.BackupId -match '^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$') {
          $known[[string]$entry.BackupId] = $entry
        }
      }
    }
    catch {
      # Existing archives remain visible from their protected directory. A
      # broken history index is never repaired or overwritten by the broker.
    }
  }

  $entries = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $backupDirectory -File -Filter '*.dump' -ErrorAction Stop)) {
    if ($file.Name -notmatch '^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$' -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    $record = $known[$file.Name]
    $created = $file.LastWriteTime.ToString('o')
    $purpose = 'Existing'
    $hash = $null
    $usbAvailable = $null
    $usbStatus = 'USB copy status is not recorded for this archive.'
    if ($record) {
      if ([long]$record.Length -ne [long]$file.Length) { continue }
      $created = [string]$record.CreatedLocal
      $purpose = [string]$record.Purpose
      if ([string]$record.SHA256 -match '^[0-9a-f]{64}$') { $hash = [string]$record.SHA256 }
      $usbAvailable = [bool]$record.UsbAvailable
      $usbStatus = [string]$record.UsbStatus
    }
    $entries += [pscustomobject]@{
      BackupId = $file.Name
      CreatedLocal = $created
      Purpose = $purpose
      Length = [long]$file.Length
      SHA256 = $hash
      UsbAvailable = $usbAvailable
      UsbStatus = $usbStatus
    }
  }
  return @($entries | Sort-Object CreatedLocal -Descending | Select-Object -First $maximumHistoryEntries)
}

function Get-BackupStatus {
  $stored = $null
  if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    try { $stored = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { $stored = $null }
  }

  $now = Get-Date
  $dueDates = @()
  $lastScheduled = [DateTime]::MinValue
  $hasLastScheduled = $stored -and [DateTime]::TryParse(
    [string]$stored.LastScheduledBackupLocal,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeLocal,
    [ref]$lastScheduled
  )
  if ($hasLastScheduled) {
    $date = $lastScheduled.Date.AddDays(1)
  }
  else {
    $date = $now.Date
  }
  $lastDueDate = if ($now.TimeOfDay -ge ([TimeSpan]::FromMinutes(90))) { $now.Date } else { $now.Date.AddDays(-1) }
  while ($date -le $lastDueDate -and $dueDates.Count -lt 366) {
    $dueDates += $date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $date = $date.AddDays(1)
  }
  if ($hasLastScheduled -and $lastScheduled.Date -gt $now.Date) { $dueDates = @() }
  $historicalMissed = @()
  if ($stored -and $stored.MissedScheduledDates) {
    $historicalMissed = @($stored.MissedScheduledDates | ForEach-Object { [string]$_ } |
      Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' })
  }
  $allMissed = @($historicalMissed + $dueDates | Select-Object -Unique | Sort-Object)
  $usbAvailability = Get-CurrentUsbAvailability

  return [pscustomobject]@{
    ScheduleLocalTime = '01:30'
    LastScheduledBackupLocal = if ($stored) { [string]$stored.LastScheduledBackupLocal } else { $null }
    LastAttemptLocal = if ($stored) { [string]$stored.LastAttemptLocal } else { $null }
    LastAttemptStatus = if ($stored) { [string]$stored.LastAttemptStatus } elseif ($stored.Status) { [string]$stored.Status } else { $null }
    LastAttemptPurpose = if ($stored) { [string]$stored.LastAttemptPurpose } else { $null }
    LastAttemptError = if ($stored) { [string]$stored.LastAttemptError } else { $null }
    MissedBackupDates = $allMissed
    MissedBackupCount = $allMissed.Count
    UsbAvailable = $usbAvailability.Available
    UsbStatus = $usbAvailability.Status
  }
}

function Get-CurrentUsbAvailability {
  try {
    $volume = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop |
      Where-Object { $_.VolumeName -eq 'KWD POS BACKUP' } | Select-Object -First 1)
    if ($volume.Count -eq 0) {
      return [pscustomobject]@{ Available = $false; Status = 'No removable drive with the approved volume label is connected.' }
    }
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
      return [pscustomobject]@{ Available = $false; Status = 'BitLocker status could not be checked for the connected USB drive.' }
    }
    $bitLocker = Get-BitLockerVolume -MountPoint $volume[0].DeviceID -ErrorAction Stop
    if ($bitLocker.VolumeStatus -eq 'FullyEncrypted' -and $bitLocker.ProtectionStatus -eq 'On') {
      return [pscustomobject]@{ Available = $true; Status = 'The approved removable drive is connected, fully encrypted and protected.' }
    }
    return [pscustomobject]@{ Available = $false; Status = 'The connected labeled drive is not fully encrypted and protected.' }
  }
  catch {
    return [pscustomobject]@{ Available = $false; Status = 'The connected USB drive encryption status could not be verified.' }
  }
}

function Get-RestoreStatus {
  if (-not (Test-Path -LiteralPath $restoreStatusPath -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $restoreStatusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
  catch { return [pscustomobject]@{ Status = 'Unavailable'; Message = 'Restore status could not be read.' } }
}

function Get-BackupById {
  param([Parameter(Mandatory = $true)][string]$BackupId)

  if ($BackupId -notmatch '^koli-wada-dhaba-\d{8}-\d{6}(?:-[0-9a-f]{32})?\.dump$') {
    throw 'The selected backup is not a recognized Koli Wada Dhaba POS archive.'
  }
  $entry = @(Get-BackupEntries | Where-Object { $_.BackupId -ceq $BackupId } | Select-Object -First 1)
  if ($entry.Count -ne 1) { throw 'The selected backup is missing from the protected POS backup folder.' }
  return $entry[0]
}

function Get-ValidatedArchiveHash {
  param([Parameter(Mandatory = $true)]$Entry)

  $path = Join-Path $backupDirectory $Entry.BackupId
  $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
  if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -le 0) {
    throw 'The selected backup archive is not a valid protected file.'
  }
  $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  if ($Entry.SHA256 -and $Entry.SHA256 -cne $actualHash) {
    throw 'The selected backup archive failed its recorded SHA256 integrity check.'
  }
  $listing = Invoke-LocalTool -FilePath $pgRestore -Arguments @('--list', $path) -TimeoutSeconds 180
  if ($listing.ExitCode -ne 0 -or $listing.StdOut -notmatch '(?m)^;\s+Format: CUSTOM\s*$' -or
      $listing.StdOut -notmatch '(?m)^;\s+dbname:\s*koli_wada_dhaba\s*$') {
    throw 'The selected archive failed PostgreSQL restore validation or belongs to another database.'
  }
  return $actualHash
}

function Invoke-BackupOperation {
  param([Parameter(Mandatory = $true)][string]$Purpose)

  Assert-TrustedPosFile -Path $backupScript
  $resultFile = Join-Path $logDirectory ("broker-backup-$([guid]::NewGuid().ToString('N')).json")
  try {
    $process = Invoke-LocalTool -FilePath $powershellExe -Arguments @(
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $backupScript,
      '-Purpose', $Purpose, '-ResultFile', $resultFile
    ) -TimeoutSeconds 7200
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
      throw 'The backup utility did not return a machine-readable result.'
    }
    $result = Get-Content -LiteralPath $resultFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($process.ExitCode -ne 0 -or $result.Status -cne 'Success') {
      $message = if ($result.Error) { [string]$result.Error } else { 'The verified backup operation failed.' }
      throw $message
    }
    $backupId = [IO.Path]::GetFileName([string]$result.BackupPath)
    if ([string]::IsNullOrWhiteSpace($backupId) -or $backupId -notmatch '^koli-wada-dhaba-\d{8}-\d{6}-[0-9a-f]{32}\.dump$') {
      throw 'The backup utility returned an unrecognized archive identity.'
    }
    $entry = Get-BackupById -BackupId $backupId
    if ($entry.SHA256 -and $entry.SHA256 -cne [string]$result.SHA256) {
      throw 'The backup utility result did not match protected backup history.'
    }
    return [pscustomobject]@{
      Status = 'Success'
      BackupId = $backupId
      CreatedLocal = [string]$result.CreatedLocal
      Length = [long]$result.Length
      SHA256 = [string]$result.SHA256
      UsbAvailable = [bool]$result.UsbAvailable
      UsbStatus = [string]$result.UsbStatus
    }
  }
  finally {
    if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
      Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    }
  }
}

function Handle-OwnerRequest {
  param(
    [Parameter(Mandatory = $true)]$Request,
    [Parameter(Mandatory = $true)][string]$ClientIdentity
  )

  $operation = [string]$Request.operation
  switch ($operation) {
    'ping' {
      Assert-ExactRequestFields -Request $Request -AllowedFields @('operation')
      return [pscustomobject]@{ Status = 'Ready' }
    }
    'status' {
      Assert-ExactRequestFields -Request $Request -AllowedFields @('operation', 'token')
      [void](Assert-OwnerToken -Request $Request)
      return [pscustomobject]@{ Status = Get-BackupStatus; Backups = @(Get-BackupEntries); Restore = Get-RestoreStatus }
    }
    'history' {
      Assert-ExactRequestFields -Request $Request -AllowedFields @('operation', 'token')
      [void](Assert-OwnerToken -Request $Request)
      return [pscustomobject]@{ Backups = @(Get-BackupEntries) }
    }
    'manualBackup' {
      Assert-ExactRequestFields -Request $Request -AllowedFields @('operation', 'token')
      [void](Assert-OwnerToken -Request $Request)
      return Invoke-BackupOperation -Purpose 'Manual'
    }
    'prepareRestore' {
      Assert-ExactRequestFields -Request $Request -AllowedFields @('operation', 'token', 'backupId', 'confirmRestore')
      if ([string]$Request.confirmRestore -cne 'RESTORE') {
        throw 'Explicit Owner restore confirmation is required.'
      }
      $ownerId = Assert-OwnerToken -Request $Request
      foreach ($oldTicket in @($pendingRestores.Keys)) {
        if ($pendingRestores[$oldTicket].ExpiresUtc -lt [DateTime]::UtcNow) { $pendingRestores.Remove($oldTicket) }
      }
      if ($pendingRestores.Count -ge 16) { throw 'Too many restore confirmations are pending. Wait a moment and try again.' }
      $entry = Get-BackupById -BackupId ([string]$Request.backupId)
      $hash = Get-ValidatedArchiveHash -Entry $entry
      $ticket = [guid]::NewGuid().ToString('N')
      $pendingRestores[$ticket] = [pscustomobject]@{
        OwnerId = $ownerId
        ClientIdentity = $ClientIdentity
        BackupId = $entry.BackupId
        SHA256 = $hash
        ExpiresUtc = [DateTime]::UtcNow.AddMinutes(5)
      }
      return [pscustomobject]@{
        Ticket = $ticket
        BackupId = $entry.BackupId
        CreatedLocal = $entry.CreatedLocal
        Length = $entry.Length
        SHA256 = $hash
      }
    }
    'executeRestore' {
      Assert-ExactRequestFields -Request $Request -AllowedFields @('operation', 'ticket')
      $ticket = [string]$Request.ticket
      if ($ticket -notmatch '^[0-9a-f]{32}$' -or -not $pendingRestores.ContainsKey($ticket)) {
        throw 'The restore confirmation expired. Select and validate the backup again.'
      }
      $prepared = $pendingRestores[$ticket]
      $pendingRestores.Remove($ticket)
      if ($prepared.ClientIdentity -cne $ClientIdentity -or $prepared.ExpiresUtc -lt [DateTime]::UtcNow) {
        throw 'The restore confirmation expired or came from a different Windows user. Select the backup again.'
      }

      Assert-TrustedPosFile -Path $restoreScript
      $resultFile = Join-Path $logDirectory ("broker-restore-$([guid]::NewGuid().ToString('N')).json")
      try {
        $process = Invoke-LocalTool -FilePath $powershellExe -Arguments @(
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $restoreScript,
          '-BackupId', $prepared.BackupId, '-ExpectedSHA256', $prepared.SHA256, '-ResultFile', $resultFile
        ) -TimeoutSeconds 7200
        if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
          throw 'The restore utility did not return a machine-readable result.'
        }
        $result = Get-Content -LiteralPath $resultFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($process.ExitCode -ne 0 -or $result.Status -cne 'Success') {
          $message = if ($result.Error) { [string]$result.Error } else { 'The restore operation failed. The verified pre-restore backup was retained.' }
          throw $message
        }
        return $result
      }
      finally {
        if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
          Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        }
      }
    }
    default { throw 'The requested local POS maintenance operation is not supported.' }
  }
}

function Read-PipeLine {
  param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

  $reader = [IO.StreamReader]::new($Stream, [Text.Encoding]::UTF8, $false, 1024, $true)
  $builder = [Text.StringBuilder]::new()
  while ($true) {
    $character = $reader.Read()
    if ($character -lt 0) { break }
    if ($character -eq 10) { break }
    if ($character -eq 13) { continue }
    [void]$builder.Append([char]$character)
    if ([Text.Encoding]::UTF8.GetByteCount($builder.ToString()) -gt $maximumRequestBytes) {
      throw 'The local POS maintenance request is too large.'
    }
  }
  if ($builder.Length -eq 0) { throw 'The local POS maintenance request is empty.' }
  return $builder.ToString()
}

function Write-PipeResponse {
  param(
    [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
    [Parameter(Mandatory = $true)]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 10 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json + "`n")
  if ($bytes.Length -gt 65536) { throw 'The local POS maintenance response is too large.' }
  $Stream.Write($bytes, 0, $bytes.Length)
  $Stream.Flush()
}

while ($true) {
  $pipe = $null
  try {
    $pipeSecurity = [System.IO.Pipes.PipeSecurity]::new()
    $pipeSecurity.SetAccessRuleProtection($true, $false)
    $interactiveSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-4')
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $pipeSecurity.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
      $interactiveSid,
      [System.IO.Pipes.PipeAccessRights]::ReadWrite,
      [Security.AccessControl.AccessControlType]::Allow
    ))
    $pipeSecurity.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
      $systemSid,
      [System.IO.Pipes.PipeAccessRights]::FullControl,
      [Security.AccessControl.AccessControlType]::Allow
    ))
    $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
      $pipeName,
      [System.IO.Pipes.PipeDirection]::InOut,
      8,
      [System.IO.Pipes.PipeTransmissionMode]::Byte,
      [System.IO.Pipes.PipeOptions]::Asynchronous,
      8192,
      8192,
      $pipeSecurity
    )
    $pipe.ReadTimeout = 10000
    $pipe.WriteTimeout = 10000
    $pipe.WaitForConnection()
    $clientIdentity = Get-RequestIdentity -Pipe $pipe
    $requestLine = Read-PipeLine -Stream $pipe
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = $maximumRequestBytes
    $request = $serializer.DeserializeObject($requestLine)
    $response = Handle-OwnerRequest -Request $request -ClientIdentity $clientIdentity
    Write-PipeResponse -Stream $pipe -Value ([ordered]@{ ok = $true; data = $response })
  }
  catch {
    $message = $_.Exception.Message
    if ($message -match '(?i)password|PGPASSWORD|DATABASE_URL|JWT_SECRET|secret') {
      $message = 'The protected POS maintenance operation failed. Review the Owner backup status and local POS logs.'
    }
    if ($pipe -and $pipe.IsConnected) {
      try { Write-PipeResponse -Stream $pipe -Value ([ordered]@{ ok = $false; error = $message }) }
      catch { }
    }
    Start-Sleep -Milliseconds 100
  }
  finally {
    if ($pipe) { $pipe.Dispose() }
  }
}
