# bridge/final-run.ps1 - ranked attempt loop with lobby-aware control (works whether we are host or guest).
param([int]$MaxRooms = 4, [int]$MaxPlayMinutes = 15, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\final-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== final run $stamp rooms=$MaxRooms deck=$Deck ==="
for ($roomTry = 1; $roomTry -le $MaxRooms; $roomTry++) {
  Get-Process ygopro,YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $room = $null
  for ($i = 1; $i -le 6; $i++) {
    $raw = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
    $c = $null; try { $c = $raw | ConvertFrom-Json } catch {}
    if ($c -and $c.password -and -not $c.stale) { $room = $c; break }
    W 'stale/no room; wait 20s'; Start-Sleep -Seconds 20
  }
  if (-not $room) { W 'NO FRESH ROOM'; break }
  W ("room $roomTry passlen={0} -> launch -j" -f $room.password.Length)
  cmd /c start "" /D $game "$exe" -h $room.address -p $room.port -w $room.password -d $Deck -j -k
  Start-Sleep -Seconds 5
  W ('preload deck: ' + (J ("http://127.0.0.1:7788/deck?name=" + [uri]::EscapeDataString($Deck)) | ConvertTo-Json -Compress))

  $started = $false; $readySent = 0; $startSent = 0; $joined = $false
  for ($i = 1; $i -le 24; $i++) {
    Start-Sleep -Seconds 2
    $lobby = J 'http://127.0.0.1:7788/lobby'
    $state = J 'http://127.0.0.1:7788/state'
    if ($lobby -and $lobby.statuses.Count -gt 0) { $joined = $true }
    $self = $lobby.self
    $readyMe = $lobby.ready[$self] -eq 1
    $readyOther = $lobby.ready[1 - $self] -eq 1
    $action = 'wait'
    if (-not $readyMe -and $readySent -lt 8) { $null = J 'http://127.0.0.1:7788/ready'; $readySent++; $action = "ready#$readySent" }
    elseif ($lobby.isHost -and $lobby.bothReady -and $startSent -lt 4) { $null = J 'http://127.0.0.1:7788/start'; $startSent++; $action = "start#$startSent" }
    W ("t+{0}s self={1} isHost={2} readyMe={3} readyOther={4} deck={5} started={6} act={7}" -f ($i*2), $self, $lobby.isHost, $readyMe, $readyOther, $lobby.deckMain, $state.started, $action)
    if ($state.started) { $started = $true; break }
    if ($i -eq 8 -and -not $joined) { W 'client did not join; retry with a new room'; break }
  }
  if ($started) {
    W 'DUEL STARTED -> heuristic bot'
    $env:MAX_MINUTES = "$MaxPlayMinutes"
    & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
    W 'bot returned'
    break
  }
}
W "log: $log"
