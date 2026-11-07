# bridge/ranked-play.ps1 - one full real ranked attempt with our client + semantic policy.
# Account is PINNED via MC_ACCOUNT_ID (1173810 = the bot account) so ls-copy's other accounts can never be used.
# ASCII only (PS 5.1 parses this file as ANSI).
param(
  [int]$MaxPlayMinutes = 15,
  [string]$Deck = 'Blackwing',
  [int]$Id = 1173810,
  [switch]$Play
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log  = Join-Path $root "ranked\logs\ranked-play-$stamp.log"
$evd  = Join-Path $root "ranked\logs\ranked-play-$stamp"
New-Item -ItemType Directory -Path $evd -Force | Out-Null
function W([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -Path $log -Value $line -Encoding UTF8
  Write-Output $line
}
function JGet([string]$u) { try { return (Invoke-WebRequest -Uri $u -TimeoutSec 4 -UseBasicParsing).Content } catch { return $null } }
function JPost([string]$u) { try { return (Invoke-WebRequest -Uri $u -Method POST -TimeoutSec 6 -UseBasicParsing).Content } catch { return 'ERR' } }

W "=== ranked play $stamp account=$Id deck=$Deck play=$Play ==="
W "exe: $exe"
W "exe mtime: $((Get-Item $exe).LastWriteTime) size=$((Get-Item $exe).Length)"

# 0) preflight
$busy = Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' -or $_.Path -like '*mycard-bot\game*' }
if ($busy) { W "ABORT: client already running pid=$($busy.Id -join ',')"; return }
Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*node.exe' } | ForEach-Object { }
foreach ($p in 7788,7789) {
  $c = (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count
  if ($c -gt 0) { W "ABORT: port $p already listening"; return }
}

# 1) client first (control layer up before queueing, so the room password is not wasted on startup)
$env:YGO_CONTROL_PORT = '7788'
$env:YGO_SUPPRESS_MODALS = '1'
cmd /c start "" /D "$game" "$exe" -d $Deck -k
Start-Sleep -Seconds 9
$health = JGet 'http://127.0.0.1:7788/health'
W "client health: $health"
if ($health -notmatch 'true') { W 'ABORT: control layer not up'; return }
$net0 = JGet 'http://127.0.0.1:7788/net'; W "net0: $net0"

# 2) queue the ranked match (pinned account)
$room = $null
for ($q = 1; $q -le 6; $q++) {
  $env:MC_ACCOUNT_ID = "$Id"
  $raw = (& node (Join-Path $root 'bridge\get-room.mjs') 2>&1) | Where-Object { $_ -match '^\{' }
  $cand = $null; try { $cand = $raw | ConvertFrom-Json } catch {}
  if (-not $cand -or -not $cand.password) { W "queue attempt $q failed: $raw"; Start-Sleep -Seconds 6; continue }
  if ($cand.id -and [int]$cand.id -ne $Id) { W "ABORT: room queued under id=$($cand.id) != $Id"; return }
  if ($cand.stale) { W "stale room password; wait 20s"; Start-Sleep -Seconds 20; continue }
  $room = $cand; break
}
if (-not $room) { W 'ABORT: no fresh room'; return }
W ("room: {0}:{1} passlen={2} name={3} id={4}" -f $room.address, $room.port, $room.password.Length, $room.name, $room.id)
Set-Content -Path (Join-Path $evd 'room.json') -Value ($room | ConvertTo-Json -Compress) -Encoding UTF8

# 3) join through the control API
$joinUrl = "http://127.0.0.1:7788/join?ip={0}&port={1}&pass={2}" -f $room.address, $room.port, [uri]::EscapeDataString($room.password)
W "join -> $(JGet $joinUrl)"

# 3b) start the policy BEFORE ready/start: the first/ /second choice (kind:"tp") is asked during
#     the TP step, i.e. before /state.started becomes true, so the agent must already be polling.
$env:CONTROL_URL = 'http://127.0.0.1:7788'
$env:MAX_MINUTES = "$MaxPlayMinutes"
$env:NO_PROGRESS_MS = '60000'
$polLog = Join-Path $evd 'policy.log'
$polErr = Join-Path $evd 'policy.err.log'
$p = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput $polLog -RedirectStandardError $polErr -PassThru -WindowStyle Hidden
W "policy pid=$($p.Id) started before ready/start (answers TP)"
# 4) deck + ready (send early and repeatedly; the server starts once both players are ready)
$started = $false; $readySends = 0; $deckSent = $false
for ($i = 1; $i -le 45; $i++) {
  Start-Sleep -Seconds 2
  try {
  $stateRaw = JGet 'http://127.0.0.1:7788/state'
  $state = $null; try { $state = $stateRaw | ConvertFrom-Json } catch {}
  $netRaw = JGet 'http://127.0.0.1:7788/net'
  $net = $null; try { $net = $netRaw | ConvertFrom-Json } catch {}
  if ($i -ge 2 -and -not $deckSent) { W "deck -> $(JGet ('http://127.0.0.1:7788/deck?name=' + [uri]::EscapeDataString($Deck)))"; $deckSent = $true }
  $rd = 'skip'
  if ($i -ge 2 -and $readySends -lt 60) { $rd = JPost 'http://127.0.0.1:7788/ready'; $readySends++ }
  # ranked rooms: the first player is the host and must send HS_START once both are ready
  $st = JPost 'http://127.0.0.1:7788/start'
  $line = "t+{0}s ready#{1}={2} start={3} started={4} turn={5} curMsg={6} lp={7} net={8}/{9}" -f ($i*2), $readySends, $rd, $st, $state.started, $state.turn, $state.curMsg, ($state.lp -join '/'), $net.state, $net.alive
  W $line
  if ($state -and $state.started) { $started = $true; break }
  if ($net -and $net.state -eq 'disconnected' -and $state -and -not $state.started) {
    W 'client disconnected before duel start (probably kicked); stop this attempt'
    break
  }
  } catch { W ("loop error at i={0}: {1}" -f $i, $_.Exception.Message) }
}
if (-not $started) {
  W 'duel did NOT start; capturing diagnostics'
  Set-Content -Path (Join-Path $evd 'state-notstarted.json') -Value (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8
  powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag "ranked-$stamp" | ForEach-Object { W $_ }
  W '=== done (no start) ==='
  return
}
W 'DUEL STARTED'

# 5) play (policy already running since step 3b)
$deadline = (Get-Date).AddMinutes($MaxPlayMinutes + 2)
W "policy (already running) pid=$($p.Id) max=$MaxPlayMinutes min"
$shotEvery = 60; $nextShot = (Get-Date); $script:diagTick = 0
$winPlayer = -1; $winReason = -1
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  $stateRaw = JGet 'http://127.0.0.1:7788/state'
  $state = $null; try { $state = $stateRaw | ConvertFrom-Json } catch {}
  if ($state) {
    if ($state.winPlayer -ne $null -and [int]$state.winPlayer -ge 0) { $winPlayer = [int]$state.winPlayer; $winReason = [int]$state.winReason; }
  }
  if ($winPlayer -ge 0) { break }
  if ($p.HasExited) { W "policy exited code=$($p.ExitCode)"; break }
  # periodic diagnostics: capture the exact prompt/actions the policy is looking at
  $script:diagTick = 1 + ([int]$script:diagTick)
  if (($script:diagTick % 6) -eq 0) {
    Set-Content -Path (Join-Path $evd 'diag-state.json') -Value $stateRaw -Encoding UTF8
    Set-Content -Path (Join-Path $evd 'diag-prompt.json') -Value (JGet 'http://127.0.0.1:7788/prompt') -Encoding UTF8
    Set-Content -Path (Join-Path $evd 'diag-actions.json') -Value (JGet 'http://127.0.0.1:7788/actions') -Encoding UTF8
  }
  if ((Get-Date) -ge $nextShot) {
    $nextShot = (Get-Date).AddSeconds($shotEvery)
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag "ranked-$stamp" | ForEach-Object { W $_ }
    if ($state) { W ("hb turn={0} curMsg={1} lp={2} win={3}/{4}" -f $state.turn, $state.curMsg, ($state.lp -join '/'), $state.winPlayer, $state.winReason) }
  }
}
# 6) results
$finalRaw = JGet 'http://127.0.0.1:7788/state'
Set-Content -Path (Join-Path $evd 'state-final.json') -Value $finalRaw -Encoding UTF8
$final = $null; try { $final = $finalRaw | ConvertFrom-Json } catch {}
if ($final) {
  $isWin = $null
  if ($final.PSObject.Properties.Name -contains 'isWin' -and $null -ne $final.isWin) { $isWin = [bool]$final.isWin }
  elseif ($final.PSObject.Properties.Name -contains 'winPlayerLocal' -and $null -ne $final.winPlayerLocal) { $isWin = ([int]$final.winPlayerLocal -eq 0) }
  W ("FINAL raw={0} local={1} isWin={2} reason={3} turn={4} lp={5} lpOrder={6}" -f $final.winPlayer, $final.winPlayerLocal, $isWin, $final.winReasonName, $final.turn, ($final.lp -join '/'), $final.lpOrder)
}
Set-Content -Path (Join-Path $evd 'diag-final-state.json') -Value (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8
Set-Content -Path (Join-Path $evd 'diag-final-prompt.json') -Value (JGet 'http://127.0.0.1:7788/prompt') -Encoding UTF8
Set-Content -Path (Join-Path $evd 'diag-final-actions.json') -Value (JGet 'http://127.0.0.1:7788/actions') -Encoding UTF8
Set-Content -Path (Join-Path $evd 'diag-final-ui.json') -Value (JGet 'http://127.0.0.1:7788/ui') -Encoding UTF8
$cl = Get-ChildItem (Join-Path $root 'mycard-bot\game') -Filter 'control-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($cl) { Get-Content $cl.FullName -Tail 60 | Set-Content -Path (Join-Path $evd 'diag-client-log-tail.txt') -Encoding UTF8 }
if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
Set-Content -Path (Join-Path $evd 'net-final.json') -Value (JGet 'http://127.0.0.1:7788/net') -Encoding UTF8
$tail = @(); if (Test-Path $polLog) { $tail = Get-Content $polLog -Tail 25 }
W 'policy tail:'
$tail | ForEach-Object { W ("  " + $_) }
W "evidence dir: $evd"
W '=== done ==='
