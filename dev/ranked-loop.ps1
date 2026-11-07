# bridge/ranked-loop.ps1 - bounded ranked attempts: up to $MaxAttempts matches, stop as soon as one starts.
# Each attempt: fresh room (skip stale) -> launch our client -> gate ready on both players entered -> run bot.
# All output goes to ranked/logs/loop-<stamp>.log so it can be watched while running.
param(
  [int]$MaxAttempts = 3,
  [int]$MaxPlayMinutes = 12,
  [string]$Deck = 'Blackwing'
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\loop-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }

W "=== ranked loop $stamp attempts=$MaxAttempts deck=$Deck ==="

function Queue-FreshRoom {
  for ($i = 1; $i -le 8; $i++) {
    W "queue attempt $i..."
    $raw = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
    $cand = $null; try { $cand = $raw | ConvertFrom-Json } catch {}
    if (-not $cand -or -not $cand.password) { W 'no room; wait 8s'; Start-Sleep -Seconds 8; continue }
    if ($cand.stale) { W 'stale room; wait 25s'; Start-Sleep -Seconds 25; continue }
    W ("fresh room passlen={0}" -f $cand.password.Length)
    return $cand
  }
  return $null
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  W "--- attempt $attempt/$MaxAttempts ---"
  Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $room = Queue-FreshRoom
  if (-not $room) { W 'no fresh room; aborting'; break }

  cmd /c start "" /D $game "$exe" -h $room.address -p $room.port -w $room.password -d $Deck -j -k
  Start-Sleep -Seconds 3
  $started = $false
  $readySends = 0
  for ($i = 1; $i -le 25; $i++) {
    Start-Sleep -Seconds 2
    $alive = (Get-Process -Name YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object).Count
    if ($alive -eq 0) { W 'client gone'; break }
    $enters = 0; $state = $null; $stoc = ''
    try { $stoc = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/stoc' -TimeoutSec 3 -UseBasicParsing).Content; $enters = ([regex]::Matches($stoc, '32')).Count } catch {}
    try { $state = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/state' -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json } catch {}
    $rd = 'skip'
    if ($enters -ge 2 -and $readySends -lt 5 -and $i -ge 4) {
      try { $rd = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/ready' -Method POST -TimeoutSec 4 -UseBasicParsing).Content; $readySends++ } catch { $rd = 'ERR' }
    }
    W ("t+{0}s alive={1} enters={2} ready->{3} state:started={4} msg={5} deck={6}" -f ($i*2), $alive, $enters, $rd, $state.started, $state.curMsg, $state.deckMain)
    if ($state -and $state.started) { $started = $true; break }
  }

  if ($started) {
    W 'duel started -> bot'
    $env:MAX_MINUTES = "$MaxPlayMinutes"; $env:NO_PROGRESS_MS = '60000'
    & node (Join-Path $root 'bridge\dev\ranked-bot.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
    W 'bot finished; stopping loop'
    break
  }
  W "attempt $attempt did not start; cooldown 20s"
  Start-Sleep -Seconds 20
}
W '=== loop done ==='
W "log: $log"
