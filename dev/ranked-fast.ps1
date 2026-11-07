# bridge/ranked-fast.ps1 - ranked attempts where the client is ALREADY running before we queue,
# so the 30s room window is not eaten by client startup. Join is done through the control API.
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
$log = Join-Path $root "ranked\logs\fast-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }

W "=== ranked fast loop $stamp attempts=$MaxAttempts deck=$Deck ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 1) client first (idle in main menu, control layer up)
cmd /c start "" /D $game "$exe" -d $Deck -k
Start-Sleep -Seconds 9
try { $health = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/health' -TimeoutSec 4 -UseBasicParsing).Content } catch { $health = 'ERR' }
W "client health: $health"
if ($health -notmatch 'true') { W 'control layer not up; abort'; return }

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  W "--- attempt $attempt/$MaxAttempts ---"
  # 2) queue the match (as fast as possible)
  $t0 = Get-Date
  $room = $null
  for ($q = 1; $q -le 8; $q++) {
    $raw = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
    $cand = $null; try { $cand = $raw | ConvertFrom-Json } catch {}
    if (-not $cand -or -not $cand.password) { W 'no room; wait 6s'; Start-Sleep -Seconds 6; continue }
    if ($cand.stale) { W 'stale room; wait 20s'; Start-Sleep -Seconds 20; continue }
    $room = $cand; break
  }
  if (-not $room) { W 'no fresh room; abort'; break }
  W ("fresh room in {0:N1}s passlen={1}" -f ((Get-Date) - $t0).TotalSeconds, $room.password.Length)

  # 3) join immediately through the control API
  try {
    $j = (Invoke-WebRequest -Uri ("http://127.0.0.1:7788/join?ip={0}&port={1}&pass={2}" -f $room.address, $room.port, [uri]::EscapeDataString($room.password)) -Method POST -TimeoutSec 6 -UseBasicParsing).Content
  } catch { $j = 'ERR' }
  W "join -> $j"

  # 4) wait for both players, then ready (max 5 sends), watch for duel start
  $started = $false; $readySends = 0
  for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 2
    $enters = 0; $state = $null
    try { $stoc = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/stoc' -TimeoutSec 3 -UseBasicParsing).Content; $enters = ([regex]::Matches($stoc, '32')).Count } catch {}
    try { $state = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/state' -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json } catch {}
    $rd = 'skip'
    if ($enters -ge 2 -and $readySends -lt 5) {
      try { $rd = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/ready' -Method POST -TimeoutSec 4 -UseBasicParsing).Content; $readySends++ } catch { $rd = 'ERR' }
    }
    $hs = ""; try { $hs = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/hs' -TimeoutSec 3 -UseBasicParsing).Content } catch {}`r`n    W ("t+{0}s enters={1} ready->{2} started={3} msg={4} deck={5} hs={6}" -f ($i*2), $enters, $rd, $state.started, $state.curMsg, $state.deckMain, $hs)
    if ($state -and $state.started) { $started = $true; break }
  }

  if ($started) {
    W 'duel started -> bot'
    $env:MAX_MINUTES = "$MaxPlayMinutes"; $env:NO_PROGRESS_MS = '60000'
    & node (Join-Path $root 'bridge\dev\ranked-bot.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
    W 'bot finished'
    break
  }
  W "attempt $attempt did not start; cooldown 15s"
  Start-Sleep -Seconds 15
}
W '=== done ==='
W "log: $log"
