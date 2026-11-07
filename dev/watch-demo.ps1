# bridge/watch-demo.ps1 - launch a visible AI duel (local server + our client + stock client) and keep it alive
# so the user can watch the window (and the OBS overlay) while this job runs.
param([int]$KeepAliveMinutes = 25, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\watch-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }

W "=== watch demo $stamp deck=$Deck ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

cmd /c start "" /min /D $root cmd /c "node bridge\dev\overlay.mjs > ranked\logs\overlay.log 2>&1"
cmd /c start "" /min /D $root cmd /c "node local-server\server.mjs --port 7911 --auto p2 --pace 2 > local-server\logs\demo-watch.log 2>&1"
Start-Sleep -Seconds 3
W 'local server + overlay started (overlay http://127.0.0.1:7790/)'

cmd /c start "" /D $game "$our" -h 127.0.0.1 -p 7911 -n AiPlayer -c -k
Start-Sleep -Seconds 9
cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7911 -n GuestB -j -k
Start-Sleep -Seconds 9

$all = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
$hHost = ($all | Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -First 1).MainWindowHandle
$hGuest = ($all | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
W "hwnd host=$hHost guest=$hGuest"
if ($hGuest) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hGuest 744 452 | Out-Null; W 'guest ready clicked' }
Start-Sleep -Seconds 1
if ($hHost) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hHost 744 452 | Out-Null; W 'host ready clicked' }
Start-Sleep -Seconds 2
if ($hHost) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hHost 830 551 | Out-Null; W 'host start clicked' }
Start-Sleep -Seconds 3

try { $s = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/state' -TimeoutSec 5 -UseBasicParsing).Content | ConvertFrom-Json; W ("started={0} turn={1} lp={2}" -f $s.started, $s.turn, ($s.lp -join ',')) } catch { W 'state ERR' }

W 'starting heuristic bot'
cmd /c start "" /min /D $root cmd /c "node bridge\dev\policy-heuristic.mjs > ranked\logs\demo-bot.log 2>&1"

# keep the job (and thus the clients) alive so the user can watch
$deadline = (Get-Date).AddMinutes($KeepAliveMinutes)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 15
  $alive = (Get-Process | Where-Object { $_.ProcessName -match 'ygopro' } | Measure-Object).Count
  $tail = ''
  if (Test-Path (Join-Path $root 'ranked\logs\demo-bot.log')) { $tail = (Get-Content (Join-Path $root 'ranked\logs\demo-bot.log') -Tail 2 -Encoding UTF8) -join ' | ' }
  W ("alive=$alive bot: " + $tail)
  if ($alive -eq 0) { W 'clients gone'; break }
}
W 'watch demo done'
