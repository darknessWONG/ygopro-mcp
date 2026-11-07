# bridge/lobby-test.ps1 - validate the prep-screen interfaces on a LOCAL server (no account risk).
# Scenario A: our client is host (self=0) -> /ready then /start.
param([int]$MaxPlayMinutes = 10, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\lobby-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== lobby test $stamp (local server) ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
cmd /c start "" /min /D $root cmd /c "node local-server\server.mjs --port 7911 --auto none --pace 2 > local-server\logs\lobby-test.log 2>&1"
Start-Sleep -Seconds 3
cmd /c start "" /D $game "$our" -h 127.0.0.1 -p 7911 -n AiHost -c -k
Start-Sleep -Seconds 8
cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7911 -n Guest -j -k
Start-Sleep -Seconds 8

Write-Output ('lobby before: ' + (J 'http://127.0.0.1:7788/lobby' | ConvertTo-Json -Compress))
W ('deck preload: ' + (J 'http://127.0.0.1:7788/deck?name=Blackwing' | ConvertTo-Json -Compress))
Start-Sleep -Seconds 2
W ('ready our: ' + (J 'http://127.0.0.1:7788/ready' | ConvertTo-Json -Compress))
$hGuest = (Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.Path -like '*mycard-bot\game*' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
if ($hGuest) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hGuest 744 452 | Out-Null; W 'guest ready clicked' }
Start-Sleep -Seconds 3
$lobby = J 'http://127.0.0.1:7788/lobby'
W ('lobby after ready: ' + ($lobby | ConvertTo-Json -Compress))
if ($lobby -and $lobby.isHost -and $lobby.bothReady) { W ('start: ' + (J 'http://127.0.0.1:7788/start' | ConvertTo-Json -Compress)) }
else { W 'bothReady not reached; waiting a bit'; Start-Sleep -Seconds 3; $lobby = J 'http://127.0.0.1:7788/lobby'; W ('lobby retry: ' + ($lobby | ConvertTo-Json -Compress)); if ($lobby.bothReady) { W ('start: ' + (J 'http://127.0.0.1:7788/start' | ConvertTo-Json -Compress)) } }

Start-Sleep -Seconds 4
$state = J 'http://127.0.0.1:7788/state'
W ("state: started={0} turn={1} msg={2}" -f $state.started, $state.turn, $state.curMsg)
if ($state.started) {
  W 'duel started -> heuristic bot'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  W 'bot returned'
} else { W 'duel did not start' }
W "log: $log"
