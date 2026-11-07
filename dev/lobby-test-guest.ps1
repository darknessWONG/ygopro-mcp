# bridge/lobby-test-guest.ps1 - validate the guest seat (self=1) path on a LOCAL server:
# stock client hosts, our client is guest: our /ready must make bothReady true, then the HOST must start.
param([int]$MaxPlayMinutes = 8, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\lobbyg-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== lobby test (guest seat) $stamp ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
cmd /c start "" /min /D $root cmd /c "node local-server\server.mjs --port 7911 --auto none --pace 2 > local-server\logs\lobby-guest.log 2>&1"
Start-Sleep -Seconds 3
# stock = host
cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7911 -n StockHost -c -k
Start-Sleep -Seconds 8
# our client = guest (control port default 7788)
cmd /c start "" /D $game "$our" -h 127.0.0.1 -p 7911 -n AiGuest -j -k
Start-Sleep -Seconds 9

$lobby0 = J 'http://127.0.0.1:7788/lobby'
W ('lobby: ' + ($lobby0 | ConvertTo-Json -Compress))
W ('deck: ' + (J 'http://127.0.0.1:7788/deck?name=Blackwing' | ConvertTo-Json -Compress))
Start-Sleep -Seconds 2
W ('our ready: ' + (J 'http://127.0.0.1:7788/ready' | ConvertTo-Json -Compress))
Start-Sleep -Seconds 3
$lobby1 = J 'http://127.0.0.1:7788/lobby'
W ('lobby after our ready: ' + ($lobby1 | ConvertTo-Json -Compress))

# stock host: click ready then start
$hStock = (Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.Path -like '*mycard-bot\game*' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
if ($hStock) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hStock 744 452 | Out-Null; W 'stock ready clicked'
  Start-Sleep -Seconds 2
  & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hStock 830 551 | Out-Null; W 'stock start clicked'
} else { W 'stock window not found' }
Start-Sleep -Seconds 4
$state = J 'http://127.0.0.1:7788/state'
W ("state: started={0} turn={1} msg={2}" -f $state.started, $state.turn, $state.curMsg)
if ($state.started) {
  W 'duel started -> heuristic bot (guest side)'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  W 'bot returned'
} else { W 'duel did not start' }
W "log: $log"
