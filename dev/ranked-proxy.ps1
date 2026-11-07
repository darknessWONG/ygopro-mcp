# bridge/ranked-proxy.ps1 - ranked auto-play via STOCK client + protocol proxy (auto-answer).
# The stock client provides the genuine login/room/ready handshake; mycard-bot/proxy.mjs answers
# every duel prompt at the protocol level, so the client is never idle (no AFK warning).
param(
  [int]$MaxMinutes = 12,
  [string]$Deck = 'Blackwing',
  [string]$Policy = 'heuristic'
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\proxy-live-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }

W "=== ranked via stock client + proxy ($stamp) deck=$Deck policy=$Policy ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$room = $null
for ($try = 1; $try -le 8; $try++) {
  W "queueing match (attempt $try)..."
  $raw = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
  $cand = $null; try { $cand = $raw | ConvertFrom-Json } catch {}
  if (-not $cand -or -not $cand.password) { W 'no room, wait 8s'; Start-Sleep -Seconds 8; continue }
  W ("room: passlen={0} stale={1}" -f $cand.password.Length, $cand.stale)
  $room = $cand; break   # try even a pending/stale room; a dead room simply fails to join
}
if (-not $room) { W 'NO FRESH ROOM'; return }

$proxyLog = Join-Path $root "ranked\logs\proxy-$stamp.log"
cmd /c start "" /min /D $root cmd /c "node mycard-bot\proxy.mjs --listen 7912 --upstream $($room.address):$($room.port) --mode auto --policy $Policy --stamp > `"$proxyLog`" 2>&1"
Start-Sleep -Seconds 4
W "proxy: $proxyLog"

cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7912 -w $room.password -d $Deck -j -k
W 'stock client launched, waiting for room screen...'
Start-Sleep -Seconds 13

$h = (Get-Process -Name ygopro | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
W "stock hwnd=$h"
if ($h) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $h 744 452 | Out-Null; W 'clicked ready (744,452)' }
Start-Sleep -Seconds 3
if ($h) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $h 830 551 | Out-Null; W 'clicked start (830,551) - no-op when we are the guest' }
Start-Sleep -Seconds 2
if ($h) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $h 744 452 | Out-Null }

$deadline = (Get-Date).AddMinutes($MaxMinutes)
$lastTail = 0
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  $alive = (Get-Process -Name ygopro -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object).Count
  $proxyOk = (Get-Process -Name node -ErrorAction SilentlyContinue | Measure-Object).Count
  $tail = ''
  if (Test-Path $proxyLog) { $tail = (Get-Content $proxyLog -Tail 4 -Encoding UTF8) -join ' | ' }
  W ("alive=$alive node=$proxyOk tail: " + $tail)
  if ($alive -eq 0) { W 'client exited'; break }
  if ((Test-Path $proxyLog) -and ((Get-Content $proxyLog -Encoding UTF8) -match 'MSG_WIN|GAME OVER|LP_ZERO|winReason')) { W 'duel finished'; break }
}
W '=== proxy log tail ==='
if (Test-Path $proxyLog) { Get-Content $proxyLog -Tail 40 -Encoding UTF8 | ForEach-Object { W ("  " + $_) } }
W "log: $log"
