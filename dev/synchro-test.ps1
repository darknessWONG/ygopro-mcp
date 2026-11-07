# bridge/synchro-test.ps1 - play N local games and report whether extra-deck (Synchro/Xyz/Link) summons were attempted.
param([int]$Games = 3, [string]$Deck = 'Blackwing', [int]$GameMinutes = 6)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$our  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stock = Join-Path $game 'ygopro.exe'
$gui  = Join-Path $root 'mycard-bot\tools\gui.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\syn-$stamp.log"
$botLog = Join-Path $root 'ranked\logs\syn-bot.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }
function Click-If($hwnd, $x, $y) { if ($hwnd) { & powershell -NoProfile -ExecutionPolicy Bypass -File $gui click $hwnd $x $y | Out-Null } }

W "=== synchro test $stamp games=$Games deck=$Deck ==="
for ($g = 1; $g -le $Games; $g++) {
  W "--- game $g ---"
  Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Remove-Item $botLog -ErrorAction SilentlyContinue
  cmd /c start "" /min /D $root cmd /c "node local-server\server.mjs --port 7911 --auto p2 --pace 2 > local-server\logs\syn-$g.log 2>&1"
  Start-Sleep -Seconds 3
  cmd /c start "" /D $game "$our" -h 127.0.0.1 -p 7911 -n AiPlayer -c -k
  Start-Sleep -Seconds 8
  cmd /c start "" /D $game "$stock" -h 127.0.0.1 -p 7911 -n Guest -j -k
  Start-Sleep -Seconds 8
  $all = Get-Process | Where-Object { $_.ProcessName -match 'ygopro' -and $_.MainWindowHandle -ne 0 }
  $hHost = ($all | Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -First 1).MainWindowHandle
  $hGuest = ($all | Where-Object { $_.Path -like '*mycard-bot\game*' } | Select-Object -First 1).MainWindowHandle
  Click-If $hGuest 744 452
  Start-Sleep -Seconds 1
  Click-If $hHost 744 452
  Start-Sleep -Seconds 2
  Click-If $hHost 830 551
  Start-Sleep -Seconds 3
  $st = J 'http://127.0.0.1:7788/state'
  W ("started={0} turn={1}" -f $st.started, $st.turn)
  if (-not $st.started) { W 'game did not start'; continue }
  $env:MAX_MINUTES = "$GameMinutes"
  # run bot in background so we can kill it when the game ends
  cmd /c start "" /min /D $root cmd /c "node bridge\dev\policy-heuristic.mjs > ranked\logs\syn-bot.log 2>&1"
  $deadline = (Get-Date).AddMinutes($GameMinutes)
  $synSeen = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $live = J 'http://127.0.0.1:7788/state'
    if (-not $live) { break }
    if (Test-Path $botLog) {
      $hit = Select-String -Path $botLog -Pattern 'prefer extra-deck' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit -and -not $synSeen) { $synSeen = $true; W ('EXTRA-DECK SUMmon seen: ' + $hit.Line.Trim()) }
    }
    if ($live.winPlayer -ge 0) { W ("game over winPlayer={0} reason={1} turn={2}" -f $live.winPlayer, $live.winReason, $live.turn); break }
  }
  if (Test-Path $botLog) { W ('bot tail: ' + ((Get-Content $botLog -Tail 3 -Encoding UTF8) -join ' | ')) }
}
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
W "log: $log"
