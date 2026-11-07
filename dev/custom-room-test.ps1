# bridge/custom-room-test.ps1
# Zero-rating comparison on MyCard's own server (custom room, port 7911):
# stock client = host (-c), instrumented client = guest (-j), both through recording proxies.
# Prints both proxy frame logs so we can diff what each client sends around "ready".
param(
  [string]$Upstream = 'tiramisu.moenext.com:7911',
  [int]$WaitConnect = 11,
  [int]$WaitDuel = 36
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$pass = 'aiprobe' + (Get-Random -Minimum 100 -Maximum 999)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logA = Join-Path $root "ranked\logs\proxy-$stamp-7912.log"
$logB = Join-Path $root "ranked\logs\proxy-$stamp-7913.log"

Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Write-Output "upstream=$Upstream pass=$pass"

cmd /c start "" /min /D $root cmd /c "node mycard-bot\proxy.mjs --listen 7912 --upstream $Upstream --mode record --stamp > `"$logA`" 2>&1"
cmd /c start "" /min /D $root cmd /c "node mycard-bot\proxy.mjs --listen 7913 --upstream $Upstream --mode record --stamp > `"$logB`" 2>&1"
Start-Sleep -Seconds 3

cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7912 -w $pass -c -d Blackwing -k
Start-Sleep -Seconds $WaitConnect
cmd /c start "" /D $game "$our" -h 127.0.0.1 -p 7913 -w $pass -j -d Blackwing -k
Start-Sleep -Seconds $WaitConnect

$all = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
$hStock = ($all | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
$hOur   = ($all | Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -First 1).MainWindowHandle
Write-Output "hwnd stock=$hStock our=$hOur"

if ($hStock) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hStock 744 452 | Out-Null }
Start-Sleep -Seconds 2
try { $r = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/ready' -Method POST -TimeoutSec 6 -UseBasicParsing).Content } catch { $r = "ERR $($_.Exception.Message)" }
Write-Output "our /ready -> $r"

for ($i = 1; $i -le 12; $i++) {
  Start-Sleep -Seconds 3
  try {
    $s = (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/state' -TimeoutSec 6 -UseBasicParsing).Content | ConvertFrom-Json
    Write-Output ("t+{0}s started={1} turn={2} curMsg={3} lp={4},{5} deckMain={6}" -f ($i*3), $s.started, $s.turn, $s.curMsg, $s.lp[0], $s.lp[1], $s.deckMain)
    if ($s.started) { break }
  } catch { Write-Output ("t+{0}s control ERR" -f ($i*3)) }
}
try { Write-Output ("chat: " + (Invoke-WebRequest -Uri 'http://127.0.0.1:7788/chat' -TimeoutSec 6 -UseBasicParsing).Content) } catch {}

Write-Output '===== stock (host) frames ====='
if (Test-Path $logA) { Get-Content $logA -Tail 30 } else { Write-Output "(no log $logA)" }
Write-Output '===== our (guest) frames ====='
if (Test-Path $logB) { Get-Content $logB -Tail 30 } else { Write-Output "(no log $logB)" }
