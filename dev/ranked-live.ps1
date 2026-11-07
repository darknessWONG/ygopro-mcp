# bridge/ranked-live.ps1 - one-shot real ranked run with diagnostics, log written to a file.
# Everything it learns is appended to ranked/logs/live-<stamp>.log so it can be inspected while running.
param(
  [int]$MaxPlayMinutes = 18,
  [string]$Deck = 'Blackwing'
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\live-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }

W "=== ranked live run $stamp deck=$Deck ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item (Join-Path $game 'control.log') -ErrorAction SilentlyContinue

$room = $null
for ($try = 1; $try -le 8; $try++) {
  W ("queueing match (attempt $try)...")
  $roomJson = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
  W ("room raw: " + ($roomJson -replace '"password":"[^"]+"', '"password":"***"'))
  $cand = $null
  try { $cand = $roomJson | ConvertFrom-Json } catch { $cand = $null }
  if (-not $cand -or -not $cand.password) { W 'no room returned, waiting 8s...'; Start-Sleep -Seconds 8; continue }
  if ($cand.stale) {
    W 'room is STALE (same password as previous dead room) -> waiting 25s and re-queueing'
    Start-Sleep -Seconds 25
    continue
  }
  $room = $cand
  break
}
if (-not $room -or -not $room.password) { W 'NO FRESH ROOM after retries'; return }
W ("room: {0}:{1} passlen={2}" -f $room.address, $room.port, $room.password.Length)

W 'launching client...'
cmd /c start "" /D $game "$our" -h $room.address -p $room.port -w $room.password -d $Deck -j -k
Start-Sleep -Seconds 3

$started = $false
for ($i = 1; $i -le 20; $i++) {
  Start-Sleep -Seconds 2
  $alive = (Get-Process | Where-Object { $_.ProcessName -eq 'YGOPro' -and $_.MainWindowHandle -ne 0 } | Measure-Object).Count
  $health = 'ERR'; $stoc = ''; $chat = ''; $state = ''
  try { $health = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/health' -TimeoutSec 3 -UseBasicParsing).Content } catch {}
  try { $stoc = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/stoc' -TimeoutSec 3 -UseBasicParsing).Content } catch {}
  try { $chat = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/chat' -TimeoutSec 3 -UseBasicParsing).Content } catch {}
  try { $state = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/state' -TimeoutSec 3 -UseBasicParsing).Content } catch {}
  $rd = 'skip'
  $deckOk = $false; $enters = 0; $deckNow = 0
  if ($state) { try { $sd = $state | ConvertFrom-Json; if ($sd.deckMain -gt 0) { $deckOk = $true }; $deckNow = $sd.deckMain } catch {} }
  if ($stoc) { $enters = ([regex]::Matches($stoc, '32')).Count }
  # only ready once the room has both players entered and our deck is loaded; repeat until started
  if ($alive -gt 0 -and $readySends -lt 4 -and $i -ge 9 -and ($i - $lastReady) -ge 3) {
    try { $rd = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/ready' -Method POST -TimeoutSec 3 -UseBasicParsing).Content; $readySends++; $lastReady = $i } catch { $rd = 'ERR' }
  }
  W ("t+{0}s alive={1} enters={2} deck={3} ready->{4}" -f ($i*2), $alive, $enters, $deckNow, $rd)
  if ($stoc -and $stoc -ne $script:lastStoc) { $script:lastStoc = $stoc; W ("  stoc: " + $stoc) }
  if ($chat -and $chat -ne $script:lastChat) { $script:lastChat = $chat; W ("  chat: " + $chat) }
  if ($state) {
    $s = $null; try { $s = $state | ConvertFrom-Json } catch {}
    if ($s) {
      W ("  state: started={0} turn={1} curMsg={2} deck={3} lp={4}" -f $s.started, $s.turn, $s.curMsg, $s.deckMain, ($s.lp -join ','))
      if ($s.started) { $started = $true; break }
    }
  }
  if ($alive -eq 0) { W 'client process gone'; break }
}

if ($started) {
  W 'duel started -> running ranked-bot (no --ready needed)'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  $env:NO_PROGRESS_MS = '60000'
  & node (Join-Path $root 'bridge\dev\ranked-bot.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  W 'bot returned'
} else {
  W 'duel did NOT start in 40s'
}
W '=== control.log tail ==='
if (Test-Path (Join-Path $game 'control.log')) {
  Get-Content (Join-Path $game 'control.log') -Encoding UTF8 | Select-Object -Last 20 | ForEach-Object { W ("  " + $_) }
}
W "log file: $log"
