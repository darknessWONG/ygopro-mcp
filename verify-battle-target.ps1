# bridge/verify-battle-target.ps1 - LAN repro harness for the "attack target rejected" bug (task-36 #1)
#
# Launches host (:7788) + guest (:7789) on a local LAN room, starts a duel, then lets
# verify-battle-target.mjs drive both sides to the battle phase and record what happens when
# an attack target (MSG_SELECT_CARD=15) is answered.
#
# IMPORTANT: same time only one pair of clients may run (and while poc compiles the exe no
# client may run at all - it locks the binary). Use -DryRun first; only run for real when
# lead says the exe is ready.
#
# ASCII only (PS 5.1 reads this as ANSI).
param(
  [string]$Deck = 'Blackwing',
  [int]$MaxMinutes = 6,
  [int]$Port = 7911,
  [switch]$DryRun,
  # item 3: keep one side idle for N seconds while it is its turn (e.g. 25)
  [string]$IdleProbeSide = '',
  [int]$IdleProbeSec = 0,
  # stop after N battle-target selections (0 = full run)
  [int]$StopAfterTargets = 0,
  # item 2: do NOT set YGO_TP, so the client answers TP on its own after ~2s and logs it
  [switch]$TpAuto
)
$script:TpAutoMode = [bool]$TpAuto
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$game = Join-Path $root 'mycard-bot\game'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd  = Join-Path $root ("ranked\logs\verify-battle-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$runlog = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $runlog -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

function Cleanup {
  Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' -or $_.Path -like '*mycard-bot\game*' } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'policy-semantic|verify-battle-target' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Launch([int]$ctl, [string]$name, [string[]]$extra) {
  $bat = Join-Path $env:TEMP ("launch-repro-$name-$ctl.cmd")
  $lines = @('@echo off',
             "set YGO_CONTROL_PORT=$ctl",
             'set YGO_CTRL_DEBUG=1',
             'set YGO_SUPPRESS_MODALS=1',
             'set YGO_NET_PROBE=0',
             $(if ($script:TpAutoMode) { 'rem YGO_TP not set (TpAuto mode)' } else { 'set YGO_TP=1' }),
             'set YGO_SIDE_AUTO=1',
             "cd /d `"$game`"",
             ("start `"`" `"$exe`" " + ($extra -join ' ')))
  Set-Content -Path $bat -Value $lines -Encoding ASCII
  Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $bat) -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if ((J "http://127.0.0.1:$ctl/health") -match 'true') { W "$name control up after $($i+1)s (port $ctl)"; return $true }
  }
  W "$name control did NOT come up"
  return $false
}

$script:TpAutoMode = [bool]$TpAuto
if ($DryRun) {
  W "=== DRY RUN (no client will be started) ==="
  W ("exe exists=" + (Test-Path $exe) + " path=" + $exe)
  W ("game dir exists=" + (Test-Path $game))
  W ("deck file exists=" + (Test-Path (Join-Path $game ('deck\' + $Deck + '.ydk'))))
  W ("driver exists=" + (Test-Path (Join-Path $root 'bridge\verify-battle-target.mjs')))
  $yg = @(Get-Process YGOPro -ErrorAction SilentlyContinue)
  $nd = @(Get-Process node -ErrorAction SilentlyContinue)
  W ("running YGOPro=" + $yg.Count + " node=" + $nd.Count + " (must be 0/0 while poc compiles)")
  $busy = @()
  foreach ($p in @(7788, 7789, $Port)) {
    $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($c) { $busy += $p }
  }
  $busyTxt = 'none'; if ($busy.Count -gt 0) { $busyTxt = ($busy -join ',') }
  W ("listening ports among 7788/7789/" + $Port + " : " + $busyTxt)
  W ("plan: launch host (:7788) -d " + $Deck + " -k -> /host?match=1&port=" + $Port + " -> launch guest (:7789) -d " + $Deck + " -k -> /join -> /deck x2 -> /ready x2 -> /start -> driver --max-min " + $MaxMinutes)
  W "env of clients: YGO_CONTROL_PORT, YGO_CTRL_DEBUG=1, YGO_SUPPRESS_MODALS=1, YGO_NET_PROBE=0, YGO_TP=1, YGO_SIDE_AUTO=1"
  W "dry-run done"
  Write-Output "DRYRUN_OK"
  exit 0
}

try {
  W "=== verify battle-target $stamp deck=$Deck maxMin=$MaxMinutes port=$Port ==="
  W "exe=$exe"
  Cleanup
  if (-not (Launch 7788 'host' @('-d', $Deck, '-k'))) { throw 'host launch failed' }
  W ("host /host -> " + (J ("http://127.0.0.1:7788/host?match=1&port=" + $Port)))
  Start-Sleep -Seconds 3
  if (-not (Launch 7789 'guest' @('-d', $Deck, '-k'))) { throw 'guest launch failed' }
  W ("guest /join -> " + (J ("http://127.0.0.1:7789/join?ip=127.0.0.1&port=" + $Port)))

  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    $lh = JS 'http://127.0.0.1:7788/lobby'
    if ($lh -and $lh.playerCount -ge 2) { W ("both in room players={0}" -f $lh.playerCount); break }
  }
  W ("deck host -> " + (J ("http://127.0.0.1:7788/deck?name=" + $Deck)))
  W ("deck guest -> " + (J ("http://127.0.0.1:7789/deck?name=" + $Deck)))

  $started = $false
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    $null = J 'http://127.0.0.1:7788/ready'
    $null = J 'http://127.0.0.1:7789/ready'
    $null = J 'http://127.0.0.1:7788/start'
    $hs = JS 'http://127.0.0.1:7788/state'
    $gs = JS 'http://127.0.0.1:7789/state'
    if ($hs -and $hs.started -and $gs -and $gs.started) { $started = $true; W "duel started at t+${i}s"; break }
    if ($i % 5 -eq 0) {
      $lh = JS 'http://127.0.0.1:7788/lobby'
      W ("waiting start t+{0}s hostStarted={1} guestStarted={2} lobbyReady={3}" -f $i, $hs.started, $gs.started, ($lh.ready -join ','))
    }
  }
  if (-not $started) { throw 'duel did not start' }

  $env:REPRO_DIR = $evd
  W 'starting driver (both sides driven by verify-battle-target.mjs)'
  if ($IdleProbeSec -gt 0 -and $IdleProbeSide) { $env:IDLE_PROBE = '{0}:{1}' -f $IdleProbeSide, $IdleProbeSec }
  $driverArgs = @((Join-Path $root 'bridge\verify-battle-target.mjs'), '--dir', $evd, '--max-min', $MaxMinutes)
  if ($StopAfterTargets -gt 0) { $driverArgs += @('--stop-after-targets', $StopAfterTargets) }
  if ($env:IDLE_PROBE) { $driverArgs += @('--idle-probe', $env:IDLE_PROBE) }
  $driverOut = & node @driverArgs 2>&1
  $driverOut | ForEach-Object { W ("driver: " + $_) }
}
catch {
  W ("ERROR: " + $_.Exception.Message)
}
finally {
  # save control logs for the two clients of this run
  try {
    $ctl = Get-ChildItem (Join-Path $game 'control-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2
    foreach ($f in $ctl) { Copy-Item $f.FullName (Join-Path $evd ("log-" + $f.Name)) -Force }
    W ("control logs copied: " + (($ctl | ForEach-Object { $_.Name }) -join ','))
  } catch { W ("copy control logs failed: " + $_.Exception.Message) }

  # retry analysis from the saved control logs
  try {
    $an = @()
    foreach ($f in (Get-ChildItem $evd -Filter 'log-control-*.log' -ErrorAction SilentlyContinue)) {
      $txt = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
      $retry   = @($txt | Select-String -Pattern 'RETRY after msg=')
      $retry15 = @($txt | Select-String -Pattern 'RETRY after msg=15')
      $resp    = @($txt | Select-String -Pattern 'response: prompt=')
      $sel     = @($txt | Select-String -Pattern 'response: prompt=15')
      $send    = @($txt | Select-String -Pattern 'SEND RESPONSE')
      $snap    = @($txt | Select-String -Pattern 'snapCurMsg|dInfoCurMsg|selectMin=')
      $send15  = @($txt | Select-String -Pattern 'SEND RESPONSE.*snapCurMsg=15')
      $skipSel = @($txt | Select-String -Pattern 'UI skip select|direct bytes')
      $stale   = @($txt | Select-String -Pattern 'stale action id|stale snapshot')
      $tpAuto  = @($txt | Select-String -Pattern 'TP auto-answered|external choice window')
      $netAlive= @($txt | Select-String -Pattern 'NET ALIVE reason=our-turn-idle')
      $netDead = @($txt | Select-String -Pattern 'NET DEAD reason=')
      $an += [pscustomobject]@{
        file = $f.Name
        retryLines = $retry.Count
        retryForPrompt15 = $retry15.Count
        responseLines = $resp.Count
        responsesForPrompt15 = $sel.Count
        sendResponseLines = $send.Count
        sendResponseForSnapshot15 = $send15.Count
        snapshotLines = $snap.Count
        uiSkipSelectLines = $skipSel.Count
        staleLines = $stale.Count
        tpAutoLines = $tpAuto.Count
        netAliveOurTurnLines = $netAlive.Count
        netDeadLines = $netDead.Count
        retrySamples = @($retry | Select-Object -Last 8 | ForEach-Object { $_.Line.Trim() })
        prompt15Samples = @($sel | Select-Object -Last 8 | ForEach-Object { $_.Line.Trim() })
        sendResponseSamples = @($send | Select-Object -Last 6 | ForEach-Object { $_.Line.Trim() })
        snapshotSamples = @($snap | Select-Object -Last 5 | ForEach-Object { $_.Line.Trim() })
        send15Samples = @($send15 | Select-Object -Last 6 | ForEach-Object { $_.Line.Trim() })
        tipSamples = @(($tpAuto + $stale + $skipSel + $netAlive + $netDead) | Select-Object -Last 8 | ForEach-Object { $_.Line.Trim() })
      }
    }
    $an | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evd 'retry-analysis.json') -Encoding UTF8
    W ("retry analysis: " + (($an | ForEach-Object { "{0} retry={1} retry15={2} resp={3} p15={4} send15={5}" -f $_.file, $_.retryLines, $_.retryForPrompt15, $_.responseLines, $_.responsesForPrompt15, $_.sendResponseForSnapshot15 }) -join ' | '))
  } catch { W ("retry analysis failed: " + $_.Exception.Message) }

  $null = J 'http://127.0.0.1:7788/surrender'
  $null = J 'http://127.0.0.1:7789/surrender'
  Start-Sleep -Seconds 1
  Cleanup
  W "evidence: $evd"
  W '=== done ==='
  Write-Output "EVIDENCE_DIR=$evd"
}




