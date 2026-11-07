# bridge/sem-test2.ps1 - fully API-driven local duel (no pixel clicks on our side).
param([int]$Minutes = 6, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\sem2-$stamp.log"
$botLog = Join-Path $root 'ranked\logs\sem-bot.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== sem-test2 $stamp deck=$Deck ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item $botLog -ErrorAction SilentlyContinue
cmd /c start "" /min /D $root cmd /c "set PASSIVE_AUTO=1&& node local-server\server.mjs --port 7911 --auto p2 --pace 2 > local-server\logs\sem5.log 2>&1"
Start-Sleep -Seconds 3
cmd /c start "" /D $game "$our" -h 127.0.0.1 -p 7911 -n AiPlayer -c -k
Start-Sleep -Seconds 10
$null = J ("http://127.0.0.1:7788/deck?name=" + [uri]::EscapeDataString($Deck))
Start-Sleep -Seconds 2
$null = J 'http://127.0.0.1:7788/ready'
Start-Sleep -Seconds 2
$s0 = J 'http://127.0.0.1:7788/state'
W ("deck loaded main={0} extra={1}" -f $s0.deckMain, $s0.deckExtra)
cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7911 -n Guest -j -k
Start-Sleep -Seconds 10
$all = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
$hGuest = ($all | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
if ($hGuest) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hGuest 744 452 | Out-Null; W 'guest ready clicked' }
Start-Sleep -Seconds 3
$lb = J 'http://127.0.0.1:7788/lobby'
W ("lobby self={0} host={1} ready={2}" -f $lb.self, $lb.isHost, ($lb.ready -join ','))
if ($lb -and $lb.isHost -and $lb.bothReady) { $null = J 'http://127.0.0.1:7788/start'; W '/start sent via API' }
Start-Sleep -Seconds 4
$st = J 'http://127.0.0.1:7788/state'
W ("started={0} turn={1}" -f $st.started, $st.turn)
if (-not $st.started) { W 'game did not start'; Get-Process ygopro,YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; return }
$env:MAX_MINUTES = "$Minutes"
$env:PASSIVE_AUTO = "1"
cmd /c start "" /min /D $root cmd /c "node bridge\policy-semantic.mjs > ranked\logs\sem-bot.log 2>&1"
$deadline = (Get-Date).AddMinutes($Minutes)
$sawSp = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  $s = J 'http://127.0.0.1:7788/state'
  if (-not $s) { W 'client gone'; break }
  $mine = @($s.monsters[$s.myPlayer] | Where-Object { $_ -ne $null }).Count
  $p = J 'http://127.0.0.1:7788/prompt'
  if ($p -and $p.spsummonable -gt 0 -and -not $sawSp) {
    $sawSp = $true
    W ("EXTRA-DECK OPTION AVAILABLE: " + (($p.spsummonableCards | ForEach-Object { "$($_.code)/lv$($_.lv)/ty$($_.ty)" }) -join ','))
  }
  $spN = -1; if ($p) { $spN = $p.spsummonable }
  W ("turn={0} lp={1} myMon={2} curMsg={3} sp={4}" -f $s.turn, ($s.lp -join ','), $mine, $s.curMsg, $spN)
  if ($s.winPlayer -ge 0) { W ("game over win={0} reason={1}" -f $s.winPlayer, $s.winReason); break }
}
W ('sawSp=' + $sawSp)
W '== bot actions =='
if (Test-Path $botLog) { Get-Content $botLog -Tail 25 -Encoding UTF8 | ForEach-Object { W ('  ' + $_) } }
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
W "log: $log"
