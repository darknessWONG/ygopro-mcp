# bridge/lan-test.ps1 - LAN P2P duel: stock client is the host (ygopro's own server code),
# our instrumented client joins as the guest so the control layer only drives a plain client.
param([string]$Deck = 'Speedroid-Windwitch', [int]$Minutes = 5, [int]$Port = 7911)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\lan-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }
function Click($hwnd, $x, $y) { if ($hwnd) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hwnd $x $y | Out-Null } }

W "=== LAN test $stamp deck=$Deck port=$Port ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item (Join-Path $game 'control.log') -ErrorAction SilentlyContinue

# host: the stock client hosts a LAN room (this is ygopro's real server code, no node involved)
cmd /c start "" /D $game "$stock" -c -h 127.0.0.1 -p $Port -n Host
Start-Sleep -Seconds 8
W ("host alive=" + ((Get-Process | Where-Object { $_.ProcessName -match 'ygopro' } | Measure-Object).Count))

# guest: our instrumented client joins
cmd /c start "" /D $game "$our" -j -h 127.0.0.1 -p $Port -n AiPlayer -d $Deck
Start-Sleep -Seconds 9
W ("pair alive=" + ((Get-Process | Where-Object { $_.ProcessName -match 'ygopro' } | Measure-Object).Count))

$h = J 'http://127.0.0.1:7788/health'
W ("control=" + ($h | ConvertTo-Json -Compress))
$null = J ("http://127.0.0.1:7788/deck?name=" + [uri]::EscapeDataString($Deck))
Start-Sleep -Seconds 2
$null = J 'http://127.0.0.1:7788/ready'
Start-Sleep -Seconds 2
$lb = J 'http://127.0.0.1:7788/lobby'
W ("lobby self={0} host={1} ready={2} bothReady={3}" -f $lb.self, $lb.isHost, ($lb.ready -join ','), $lb.bothReady)

# host side can only be driven by clicks: ready, then start
$all = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
$hHost = ($all | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
W "host hwnd=$hHost"
Click $hHost 744 452
Start-Sleep -Seconds 2
Click $hHost 830 551
Start-Sleep -Seconds 3

$st = J 'http://127.0.0.1:7788/state'
W ("started={0} turn={1} counts={2}" -f $st.started, $st.turn, ($st.counts | ConvertTo-Json -Compress))
if (-not $st.started) {
  W 'duel did not start'
  W '== control log tail =='
  Get-Content (Join-Path $game 'control.log') -Tail 12 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { W ('  ' + $_) }
  Get-Process ygopro,YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  return
}

$env:MAX_MINUTES = "$Minutes"
cmd /c start "" /min /D $root cmd /c "node bridge\policy-semantic.mjs > ranked\logs\sem-bot.log 2>&1"
$deadline = (Get-Date).AddMinutes($Minutes)
$spSeen = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  $s = J 'http://127.0.0.1:7788/state'
  if (-not $s) { W 'client gone'; break }
  $p = J 'http://127.0.0.1:7788/prompt'
  $sp = -1; if ($p) { $sp = $p.spsummonable }
  $mine = @($s.monsters[$s.myPlayer] | Where-Object { $_ -ne $null }).Count
  W ("turn={0} lp={1} myMon={2} sp={3} counts={4}" -f $s.turn, ($s.lp -join ','), $mine, $sp, ($s.counts | ConvertTo-Json -Compress))
  if ($sp -gt 0 -and -not $spSeen) { $spSeen = $true; W ("EXTRA-DECK OPTION: " + (($p.spsummonableCards | ForEach-Object { "$($_.code)/lv$($_.lv)" }) -join ',')) }
  if ($s.winPlayer -ge 0) { W ("game over win={0} reason={1}" -f $s.winPlayer, $s.winReason); break }
}
W '== control log (deck load) =='
Get-Content (Join-Path $game 'control.log') -Tail 10 -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern 'sections load|ready:|load ok' | ForEach-Object { W ('  ' + $_.Line) }
W "log: $log"
