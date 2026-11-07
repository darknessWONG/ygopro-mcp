# bridge/room-join-run.ps1 - join whatever room the match API hands us (including a "pending" one),
# then run the lobby-aware prep flow and let the bot play.
param([int]$MaxTries = 8, [int]$MaxPlayMinutes = 18, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\join-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }
function Get-Room {
  $out = & node (Join-Path $root 'bridge\get-room.mjs') 2>&1
  $line = $out | Where-Object { $_ -match '^\{' } | Select-Object -First 1
  if (-not $line) { return $null }
  try { return ($line | ConvertFrom-Json) } catch { return $null }
}

W "=== room-join-run $stamp tries=$MaxTries deck=$Deck ==="
for ($try = 1; $try -le $MaxTries; $try++) {
  Get-Process ygopro,YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $room = Get-Room
  if (-not $room -or -not $room.password) { W "no room from API (try $try); wait 25s"; Start-Sleep -Seconds 25; continue }
  W ("try {0}: room passlen={1} stale={2}" -f $try, $room.password.Length, $room.stale)
  cmd /c start "" /D $game "$exe" -h $room.address -p $room.port -w $room.password -d $Deck -j -k
  Start-Sleep -Seconds 7
  $lobby = J 'http://127.0.0.1:7788/lobby'
  $joined = ($lobby -and $lobby.statuses.Count -gt 0)
  W ("joined={0} lobby={1}" -f $joined, ($lobby | ConvertTo-Json -Compress))
  if (-not $joined) { W 'join failed (dead room?); next'; Start-Sleep -Seconds 8; continue }

  $null = J ("http://127.0.0.1:7788/deck?name=" + [uri]::EscapeDataString($Deck))
  $started = $false; $readySent = 0; $startSent = 0
  for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    $lb = J 'http://127.0.0.1:7788/lobby'
    $st = J 'http://127.0.0.1:7788/state'
    if (-not $lb) { continue }
    $self = $lb.self
    $readyMe = $lb.ready[$self] -eq 1
    $other = $lb.ready[1 - $self] -eq 1
    $act = 'wait'
    if (-not $readyMe -and $readySent -lt 8) { $null = J 'http://127.0.0.1:7788/ready'; $readySent++; $act = "ready#$readySent" }
    elseif ($lb.isHost -and $lb.bothReady -and $startSent -lt 5) { $null = J 'http://127.0.0.1:7788/start'; $startSent++; $act = "start#$startSent" }
    W ("t+{0}s self={1} host={2} rMe={3} rOther={4} deck={5} started={6} act={7}" -f ($i*2), $self, $lb.isHost, $readyMe, $other, $lb.deckMain, $st.started, $act)
    if ($st.started) { $started = $true; break }
  }
  if ($started) {
    W 'DUEL STARTED -> heuristic bot'
    $env:MAX_MINUTES = "$MaxPlayMinutes"
    & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
    W 'bot returned'
    break
  }
  W 'did not start; next room'
  Start-Sleep -Seconds 10
}
W "log: $log"
