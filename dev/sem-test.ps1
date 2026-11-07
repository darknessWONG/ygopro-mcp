# bridge/sem-test.ps1 - local duel driven by the semantic action API; logs /actions labels & resulting state.
param([int]$Minutes = 6, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\semtest-$stamp.log"
$botLog = Join-Path $root 'ranked\logs\sem-bot.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== sem-test $stamp ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-Item $botLog -ErrorAction SilentlyContinue
cmd /c start "" /min /D $root cmd /c "node local-server\server.mjs --port 7911 --auto p2 --pace 2 > local-server\logs\sem3.log 2>&1"
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
Start-Sleep -Seconds 9
$all = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
$hHost = ($all | Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -First 1).MainWindowHandle
$hGuest = ($all | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
if ($hGuest) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hGuest 744 452 | Out-Null }
Start-Sleep -Seconds 1
if ($hHost) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hHost 744 452 | Out-Null }
Start-Sleep -Seconds 2
if ($hHost) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hHost 830 551 | Out-Null }
Start-Sleep -Seconds 3
$st = J 'http://127.0.0.1:7788/state'
$tries = 0
while ((!$st -or -not $st.started) -and $tries -lt 8) {
  $tries++
  $all2 = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
  $hH = ($all2 | Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -First 1).MainWindowHandle
  $hG = ($all2 | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
  if ($hG) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hG 744 452 | Out-Null }
  Start-Sleep -Seconds 1
  if ($hH) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hH 744 452 | Out-Null }
  Start-Sleep -Seconds 2
  if ($hH) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hH 830 551 | Out-Null }
  Start-Sleep -Seconds 3
  $st = J 'http://127.0.0.1:7788/state'
  W ("retry {0}: started={1} turn={2}" -f $tries, $st.started, $st.turn)
}
W ("started={0} turn={1} myPlayer={2}" -f $st.started, $st.turn, $st.myPlayer)
if (-not $st.started) { W 'game did not start'; return }
$env:MAX_MINUTES = "$Minutes"
cmd /c start "" /min /D $root cmd /c "node bridge\policy-semantic.mjs > ranked\logs\sem-bot.log 2>&1"
$deadline = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 6
  $s = J 'http://127.0.0.1:7788/state'
  if (-not $s) { W 'client gone'; break }
  $mine = @($s.monsters[$s.myPlayer] | Where-Object { $_ -ne $null }).Count
  $theirs = @($s.monsters[1 - $s.myPlayer] | Where-Object { $_ -ne $null }).Count
  W ("turn={0} lp={1} myMon={2} oppMon={3} myZoneSeq={4}" -f $s.turn, ($s.lp -join ','), $mine, $theirs, (($s.monsters[$s.myPlayer] | ForEach-Object { $_.seq }) -join '/'))
  if ($s.winPlayer -ge 0) { W ("game over win={0} reason={1}" -f $s.winPlayer, $s.winReason); break }
}
W '== bot actions =='
if (Test-Path $botLog) { Get-Content $botLog -Tail 20 -Encoding UTF8 | ForEach-Object { W ('  ' + $_) } }
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
W "log: $log"
