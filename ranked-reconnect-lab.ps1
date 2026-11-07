# bridge/ranked-reconnect-lab.ps1 - real ranked reconnect experiment (single owning process, so children survive).
# Flow: netfault proxy in front of the ranked server -> client joins via proxy -> duel starts -> hard drop ->
# relaunch client -> rejoin SAME room+password -> ready/start -> check if the duel resumed (turn/LP).
# Account is pinned (1173810) so no other ls-copy account can be used. ASCII only (PS 5.1 ANSI parse).
param(
  [int]$HoldSeconds = 8,
  [int]$MaxPlayMinutes = 12,
  [string]$Deck = 'Blackwing',
  [int]$Id = 1173810,
  [string]$Server = 'tiramisu.moenext.com',
  [int]$ServerPort = 8911
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd  = Join-Path $root "ranked\logs\ranked-rc-$stamp"
New-Item -ItemType Directory -Path $evd -Force | Out-Null
$log = Join-Path $evd 'run.log'
function W([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -Path $log -Value $line -Encoding UTF8
}
function JGet([string]$u) { try { return (Invoke-WebRequest -Uri $u -TimeoutSec 4 -UseBasicParsing).Content } catch { return $null } }
function JPost([string]$u) { try { return (Invoke-WebRequest -Uri $u -Method POST -TimeoutSec 6 -UseBasicParsing).Content } catch { return 'ERR' } }
function St([string]$u) { $r = JGet $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

W "=== ranked reconnect lab $stamp server=$Server`:$ServerPort account=$Id deck=$Deck hold=$HoldSeconds ==="
W "exe mtime=$((Get-Item $exe).LastWriteTime)"

# preflight
Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*node.exe*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$ip = ([System.Net.Dns]::GetHostAddresses($Server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
W "server ip=$ip"

$env:YGO_CONTROL_PORT = '7788'; $env:YGO_CTRL_DEBUG = '1'; $env:YGO_SUPPRESS_MODALS = '1'; $env:MC_ACCOUNT_ID = "$Id"
$nf = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\netfault.mjs'), '--listen', '7912', '--upstream', "$ip`:$ServerPort", '--ctrl', '7913') -WindowStyle Hidden -PassThru
W "netfault pid=$($nf.Id)"
Start-Sleep -Seconds 2
W "netfault status: $(JGet 'http://127.0.0.1:7913/status')"

function StartClient() {
  # launch through a generated .cmd + Start-Process: piping "cmd /c start" from a captured-stdio job keeps the
  # pipe open (the GUI child inherits it) and blocks the caller, which stalled an earlier attempt.
  $c = Join-Path $evd 'start-client.cmd'
  $lines = @(
    '@echo off',
    "set YGO_CONTROL_PORT=7788",
    "set YGO_CTRL_DEBUG=1",
    "set YGO_SUPPRESS_MODALS=1",
    "set MC_ACCOUNT_ID=$Id",
    "cd /d `"$game`"",
    "start `"`" `"$exe`" -d $Deck -k"
  )
  Set-Content -Path $c -Value $lines -Encoding ASCII
  Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $c) -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1; if ((JGet 'http://127.0.0.1:7788/health') -match 'true') { W "client up after $($i+1)s"; return $true } }
  W 'client did not come up'; return $false
}
function GetRoom() {
  for ($q = 1; $q -le 6; $q++) {
    $raw = (& node (Join-Path $root 'bridge\get-room.mjs') 2>&1) | Where-Object { $_ -match '^\{' }
    $c = $null; try { $c = $raw | ConvertFrom-Json } catch {}
    if (-not $c -or -not $c.password) { W "queue failed: $raw"; Start-Sleep -Seconds 6; continue }
    if ($c.id -and [int]$c.id -ne $Id) { W "ABORT room id=$($c.id)"; return $null }
    if ($c.stale) { W 'stale room; wait 20s'; Start-Sleep -Seconds 20; continue }
    return $c
  }
  return $null
}
function TryStartDuel([int]$maxSec) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  $deckSent = $false
  while ((Get-Date) -lt $deadline) {
    $s = St 'http://127.0.0.1:7788/state'
    if ($s -and $s.started) { return $s }
    if (-not $deckSent) { $null = JGet 'http://127.0.0.1:7788/deck'; $deckSent = $true }
    $null = JPost 'http://127.0.0.1:7788/ready'
    $null = JPost 'http://127.0.0.1:7788/start'
    Start-Sleep -Seconds 2
  }
  return (St 'http://127.0.0.1:7788/state')
}

# ---- phase 1: join via proxy
if (-not (StartClient)) { W 'phase1 abort'; return }
$room = GetRoom
if (-not $room) { W 'phase1 abort: no room'; return }
$roomJson = $room | ConvertTo-Json -Compress
Set-Content -Path (Join-Path $evd 'room.json') -Value $roomJson -Encoding UTF8
W "room=$($room.address):$($room.port) passlen=$($room.password.Length) id=$($room.id)"
$null = JGet ("http://127.0.0.1:7788/join?ip=127.0.0.1&port=7912&pass=" + [uri]::EscapeDataString($room.password))
$s = TryStartDuel 45
W "phase1 started=$($s.started) turn=$($s.turn) lp=$($s.lp -join '/')"
if (-not $s.started) { W 'phase1 abort: duel did not start'; Set-Content (Join-Path $evd 'phase1-state.json') (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8; return }
$nfStatus = JGet 'http://127.0.0.1:7913/status' | ConvertFrom-Json
W "proxy connections=$($nfStatus.totalConnections) bytesDown=$($nfStatus.bytesDown)"
if ([int]$nfStatus.totalConnections -lt 1) { W 'INVALID: traffic did not pass proxy'; return }

# ---- phase 2: play until turn >= 2 (or 45s), snapshot, then drop
$pre = $null
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
  $s = St 'http://127.0.0.1:7788/state'
  if ($s -and [int]$s.turn -ge 2) { $pre = $s; break }
  Start-Sleep -Seconds 2
}
if (-not $pre) { $pre = St 'http://127.0.0.1:7788/state' }
W "pre-drop turn=$($pre.turn) lp=$($pre.lp -join '/') seat=$($pre.mySeat)"
Set-Content (Join-Path $evd 'pre-drop-state.json') ($pre | ConvertTo-Json -Depth 4) -Encoding UTF8
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag "rc-pre-$stamp" | Out-Null
$d = JPost 'http://127.0.0.1:7913/mode?m=drop'
W "drop -> $d"
$t0 = Get-Date
$netAfter = $null
while (((Get-Date) - $t0).TotalSeconds -lt $HoldSeconds) {
  Start-Sleep -Seconds 1
  $netAfter = St 'http://127.0.0.1:7788/net'
}
W "post-drop net: state=$($netAfter.state) alive=$($netAfter.alive) closeReason=$($netAfter.closeReason) since=$($netAfter.sinceLastStoc)"
Set-Content (Join-Path $evd 'post-drop-net.json') ($netAfter | ConvertTo-Json -Depth 4) -Encoding UTF8
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag "rc-drop-$stamp" | Out-Null

# ---- phase 3: relaunch client and rejoin the SAME room+password
Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
W "relaunch + rejoin same room"
if (-not (StartClient)) { W 'phase3 abort'; return }
$null = JGet ("http://127.0.0.1:7788/join?ip=127.0.0.1&port=7912&pass=" + [uri]::EscapeDataString($room.password))
$rejoinNet = $null; $resumed = $false
$deadline = (Get-Date).AddSeconds(75)
$deckSent = $false
while ((Get-Date) -lt $deadline) {
  $s = St 'http://127.0.0.1:7788/state'
  $n = St 'http://127.0.0.1:7788/net'
  if (-not $deckSent -and $n -and $n.connected) { $null = JGet 'http://127.0.0.1:7788/deck'; $deckSent = $true }
  if ($n -and $n.connected) { $null = JPost 'http://127.0.0.1:7788/ready'; $null = JPost 'http://127.0.0.1:7788/start' }
  if ($s -and $s.started -and $s.inDuel -and [int]$s.turn -ge [int]$pre.turn) { $resumed = $true; break }
  Start-Sleep -Seconds 2
}
$finalState = St 'http://127.0.0.1:7788/state'
$finalNet = St 'http://127.0.0.1:7788/net'
W "RESUMED=$resumed final: started=$($finalState.started) inDuel=$($finalState.inDuel) turn=$($finalState.turn) lp=$($finalState.lp -join '/') net=$($finalNet.state)/$($finalNet.closeReason)"
Set-Content (Join-Path $evd 'final-state.json') ($finalState | ConvertTo-Json -Depth 4) -Encoding UTF8
Set-Content (Join-Path $evd 'final-net.json') ($finalNet | ConvertTo-Json -Depth 4) -Encoding UTF8
Set-Content (Join-Path $evd 'final-chat.json') (JGet 'http://127.0.0.1:7788/chat') -Encoding UTF8
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag "rc-final-$stamp" | Out-Null

# ---- phase 4: if resumed, let the semantic policy finish the game
if ($resumed) {
  W 'resumed -> starting semantic policy'
  $env:CONTROL_URL = 'http://127.0.0.1:7788'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  $env:NO_PROGRESS_MS = '60000'
  $polLog = Join-Path $evd 'policy.log'
  $p = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput $polLog -RedirectStandardError (Join-Path $evd 'policy.err.log') -PassThru -WindowStyle Hidden
  W "policy pid=$($p.Id)"
  $deadline = (Get-Date).AddMinutes($MaxPlayMinutes + 1)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $s = St 'http://127.0.0.1:7788/state'
    if ($s -and [int]$s.winPlayer -ge 0) { W "WIN player=$($s.winPlayer) reason=$($s.winReason) turn=$($s.turn)"; break }
    if ($p.HasExited) { W "policy exited code=$($p.ExitCode)"; break }
  }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Set-Content (Join-Path $evd 'after-play-state.json') (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8
}
# cleanup
Stop-Process -Id $nf.Id -Force -ErrorAction SilentlyContinue
Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' } | Stop-Process -Force -ErrorAction SilentlyContinue
W "evidence: $evd"
W '=== done ==='
