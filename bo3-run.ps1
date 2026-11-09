# bridge/bo3-run.ps1 - run a full local best-of-3 match and let two policies play it.
# ASCII only (PS 5.1 parses this file as ANSI).
param(
  [string]$HostDeck = 'BlackwingHT2',
  [string]$GuestDeck = 'BlackwingHT2',
  [int]$MaxMinutes = 18,
  [int]$Port = 7911
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd  = Join-Path $root "ranked\logs\bo3-run-$stamp"
New-Item -ItemType Directory -Path $evd -Force | Out-Null
$log = Join-Path $evd 'run.log'
function W([string]$m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 }
function JGet([string]$u) { try { return (Invoke-WebRequest -Uri $u -TimeoutSec 4 -UseBasicParsing).Content } catch { return $null } }
function JPost([string]$u) { try { return (Invoke-WebRequest -Uri $u -Method POST -TimeoutSec 8 -UseBasicParsing).Content } catch { return $null } }
function St([string]$u) { $r = JGet $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }
function AnswerPending([int]$ctlPort, $state, [string]$tag) {
  # ask /actions directly: side_ok / tp are synthetic pre-duel prompts, /state may not carry them
  $a = JGet "http://127.0.0.1:$ctlPort/actions"
  if (-not $a) { return }
  $o = $null; try { $o = $a | ConvertFrom-Json } catch { return }
  if (-not $o -or -not $o.actions) { return }
  foreach ($act in $o.actions) {
    if ($act.kind -eq 'side_ok' -or $act.kind -eq 'tp') {
      $r = JGet ("http://127.0.0.1:$ctlPort/act_id?id=" + $act.id)
      W ("$tag answered {0} id={1} -> {2}" -f $act.kind, $act.id, $r)
      return
    }
  }
}
function HasPending([int]$ctlPort) {
  $a = JGet "http://127.0.0.1:$ctlPort/actions"
  if (-not $a) { return $false }
  $o = $null; try { $o = $a | ConvertFrom-Json } catch { return $false }
  if (-not $o -or -not $o.actions) { return $false }
  foreach ($act in $o.actions) { if ($act.kind -eq 'side_ok' -or $act.kind -eq 'tp') { return $true } }
  return $false
}
function Launch([int]$ctlPort, [string]$name, [string[]]$extra) {
  $c = Join-Path $evd ("start-$name.cmd")
  $lines = @('@echo off', "set YGO_CONTROL_PORT=$ctlPort", 'set YGO_CTRL_DEBUG=1', 'set YGO_SUPPRESS_MODALS=1',
             "cd /d `"$game`"", ("start `"`" `"$exe`" " + ($extra -join ' ')))
  Set-Content -Path $c -Value $lines -Encoding ASCII
  Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $c) -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if ((JGet "http://127.0.0.1:$ctlPort/health") -match 'true') { W "$name control up after $($i+1)s (port $ctlPort)"; return $true } }
  W "$name control did not come up"; return $false
}

W "=== bo3 run $stamp hostDeck=$HostDeck guestDeck=$GuestDeck port=$Port ==="
Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# host: start as normal host on our port, then leave that room and create a MATCH room through the control layer
if (-not (Launch 7788 'host' @('-c', '-p', "$Port", '-d', $HostDeck, '-k'))) { W 'ABORT host'; return }
Start-Sleep -Seconds 2
W "leave -> $(JGet 'http://127.0.0.1:7788/leave')"
Start-Sleep -Seconds 2
W "host(match) -> $(JPost ("http://127.0.0.1:7788/host?match=1&port=$Port"))"
Start-Sleep -Seconds 3
W ("host lobby: " + (JGet 'http://127.0.0.1:7788/lobby'))

# guest: auto-join the LAN room on the same port
if (-not (Launch 7789 'guest' @('-j', '-h', '127.0.0.1', '-p', "$Port", '-d', $GuestDeck, '-k'))) { W 'ABORT guest'; return }

# policies must be running before /start: the first/second (TP) choice is asked before started=true
$env:CONTROL_URL = 'http://127.0.0.1:7788'
$env:MAX_MINUTES = "$MaxMinutes"
$env:NO_PROGRESS_MS = '120000'
$ph = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evd 'policy-host.log') -RedirectStandardError (Join-Path $evd 'policy-host.err.log') -PassThru -WindowStyle Hidden
$env:CONTROL_URL = 'http://127.0.0.1:7789'
$pg = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evd 'policy-guest.log') -RedirectStandardError (Join-Path $evd 'policy-guest.err.log') -PassThru -WindowStyle Hidden
W "policies started before ready/start: host=$($ph.Id) guest=$($pg.Id)"

# decks + ready + start
$started = $false
for ($i = 1; $i -le 40; $i++) {
  Start-Sleep -Seconds 2
  $hs = St 'http://127.0.0.1:7788/state'
  $gs = St 'http://127.0.0.1:7789/state'
  if ($i -eq 2) {
    W "deck host -> $(JGet ('http://127.0.0.1:7788/deck?name=' + $HostDeck))"
    W "deck guest -> $(JGet ('http://127.0.0.1:7789/deck?name=' + $GuestDeck))"
  }
  if ($i -ge 2) {
    $null = JPost 'http://127.0.0.1:7788/ready'
    $null = JPost 'http://127.0.0.1:7789/ready'
    $null = JPost 'http://127.0.0.1:7788/start'
  }
  $hl = St 'http://127.0.0.1:7788/lobby'
  $gl = St 'http://127.0.0.1:7789/lobby'
  W ("t+{0}s host started={1} turn={2} | guest started={3} turn={4} | lobby={5}/{6}" -f ($i*2), $hs.started, $hs.turn, $gs.started, $gs.turn, ($hl.ready -join ','), ($gl.ready -join ','))
  if ($hs -and $hs.started -and $gs -and $gs.started) { $started = $true; break }
}
if (-not $started) { W 'duel did not start'; Write-Output "evidence: $evd"; return }
W 'GAME 1 STARTED'

# policies already playing since before ready/start
W "policies running: host= guest="

$deadline = (Get-Date).AddMinutes($MaxMinutes)
$lastShot = Get-Date
$g = 1
$lastTurn = -1
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  $hs = St 'http://127.0.0.1:7788/state'
  $gs = St 'http://127.0.0.1:7789/state'
  if ($hs) {
    if ($hs.turn -ne $lastTurn) { $lastTurn = $hs.turn; W ("host turn={0} lp={1} win={2}/{3} side={4} tp={5}" -f $hs.turn, ($hs.lp -join '/'), $hs.winPlayer, $hs.winReason, $hs.sidePending, $hs.tpPending) }
    if ($hs.winPlayer -ge 0 -or $hs.turn -eq 0) { W ("host result raw={0} isWin={1} reason={2}" -f $hs.winPlayer, $hs.isWin, $hs.winReasonName) }
  }
  if ((Get-Date) -ge $lastShot.AddSeconds(60)) {
    $lastShot = Get-Date
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag "bo3-$stamp" | Out-Null
    W ("hb host(turn={0} lp={1}) guest(turn={2} lp={3})" -f $hs.turn, ($hs.lp -join '/'), $gs.turn, ($gs.lp -join '/'))
  }
  # a policy exits when a game finishes; the match continues into side-decking + next game,
  # so relaunch it so somebody answers side_ok / tp.
  AnswerPending 7788 $hs 'host'
  AnswerPending 7789 $gs 'guest'
  $waitSideH = ($hs -and ($hs.PSObject.Properties.Name -contains 'sidePending') -and $hs.sidePending)
  $waitSideG = ($gs -and ($gs.PSObject.Properties.Name -contains 'sidePending') -and $gs.sidePending)
  $waitTpH = ($hs -and ($hs.PSObject.Properties.Name -contains 'tpPending') -and $hs.tpPending)
  $waitTpG = ($gs -and ($gs.PSObject.Properties.Name -contains 'tpPending') -and $gs.tpPending)
  if ($ph.HasExited -and -not (HasPending 7788)) {
    W ("host policy exited (code={0}) -> relaunch for side/next game" -f $ph.ExitCode)
    Start-Sleep -Seconds 2
    $env:CONTROL_URL = 'http://127.0.0.1:7788'
    $env:MAX_MINUTES = "$MaxMinutes"; $env:NO_PROGRESS_MS = '120000'
    $ph = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evd 'policy-host.log') -RedirectStandardError (Join-Path $evd 'policy-host.err.log') -PassThru -WindowStyle Hidden
    W "host policy relaunched pid=$($ph.Id)"
  }
  if ($pg.HasExited -and -not (HasPending 7789)) {
    W ("guest policy exited (code={0}) -> relaunch for side/next game" -f $pg.ExitCode)
    Start-Sleep -Seconds 2
    $env:CONTROL_URL = 'http://127.0.0.1:7789'
    $env:MAX_MINUTES = "$MaxMinutes"; $env:NO_PROGRESS_MS = '120000'
    $pg = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evd 'policy-guest.log') -RedirectStandardError (Join-Path $evd 'policy-guest.err.log') -PassThru -WindowStyle Hidden
    W "guest policy relaunched pid=$($pg.Id)"
  }
  $netH = St 'http://127.0.0.1:7788/net'
  if ($netH -and $netH.state -eq 'disconnected' -and (-not $hs -or -not $gs)) { W 'clients gone; stop'; break }
}
$null = JPost 'http://127.0.0.1:7788/surrender'
$null = JPost 'http://127.0.0.1:7789/surrender'
foreach ($p in @($ph, $pg)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
W "evidence: $evd"
W '=== done ==='
Write-Output "evidence: $evd"
