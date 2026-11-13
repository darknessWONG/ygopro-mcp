# verify-match-state.ps1 - one-off LAN check for /state.match (game results, series, over)
# Launches host+guest locally, starts a Bo3, then has the guest surrender game1 and game2
# so that /state.match must show: games[0] (win/reason SURRENDER, over=false), then
# game=2 + both entries, then over=true after STOC_DUEL_END.
param(
  [int]$Port = 7911,
  [string]$Deck = 'BlackwingHT2S'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$game = Join-Path $root 'mycard-bot\game'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd = Join-Path $root ("ranked\logs\match-state-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$logFile = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $logFile -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }
function Launch([int]$ctl, [string]$name, [string[]]$extra) {
  $bat = Join-Path $env:TEMP ("launch-$name-$ctl.cmd")
  $lines = @('@echo off', "set YGO_CONTROL_PORT=$ctl", 'set YGO_CTRL_DEBUG=1', 'set YGO_SUPPRESS_MODALS=1', 'set YGO_NET_PROBE=0', 'set YGO_TP=1',
             "cd /d `"$game`"", ("start `"`" `"$exe`" " + ($extra -join ' ')))
  Set-Content -Path $bat -Value $lines -Encoding ASCII
  Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $bat) -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if ((J "http://127.0.0.1:$ctl/health") -match 'true') { W "$name control up ($ctl)"; return $true } }
  W "$name control did NOT come up"; return $false
}
function ShowMatch([string]$tag, [int]$ctl) {
  $s = JS "http://127.0.0.1:$ctl/state"
  if (-not $s) { W "$tag state unreadable"; return $null }
  $m = $s.match
  if (-not $m) { W "$tag NO match object"; return $null }
  $g = @()
  if ($m.games) { foreach ($x in $m.games) { $g += ("g{0}:win={1},seat={2},{3}" -f $x.game, $x.win, $x.winnerSeat, $x.reasonName) } }
  W ("{0} match: game={1} over={2} won={3}/{4} lastWin={5} lastReason={6} games=[{7}]" -f `
      $tag, $m.game, $m.over, $m.gamesWonLocal, $m.gamesWonOpp, $m.lastWinnerLocal, $m.lastReasonName, ($g -join ' | '))
  return $m
}

try {
  Get-Process YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3

  if (-not (Launch 7788 'host' @('-d', $Deck, '-k'))) { throw 'host launch failed' }
  W ("host /host -> " + (J ("http://127.0.0.1:7788/host?match=1&port=" + $Port)))
  Start-Sleep -Seconds 3
  if (-not (Launch 7789 'guest' @('-d', $Deck, '-k'))) { throw 'guest launch failed' }
  Start-Sleep -Seconds 2
  # the -j auto-join path is unreliable in this build; drive the LAN join window through the control layer
  W ("guest /join -> " + (J ("http://127.0.0.1:7789/join?ip=127.0.0.1&port=" + $Port)))
  Start-Sleep -Seconds 2

  # wait for both in room
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $lh = JS 'http://127.0.0.1:7788/lobby'
    if ($lh -and $lh.playerCount -ge 2) { W ("both in room (players={0})" -f $lh.playerCount); break }
  }
  W ("host /deck -> " + (J ("http://127.0.0.1:7788/deck?name=" + $Deck)))
  W ("guest /deck -> " + (J ("http://127.0.0.1:7789/deck?name=" + $Deck)))
  Start-Sleep -Seconds 1
  W ("host /ready -> " + (J 'http://127.0.0.1:7788/ready'))
  # wait until the lobby really shows both sides ready before clicking START once
  $bothReady = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    $lh = JS 'http://127.0.0.1:7788/lobby'
    if ($lh -and $lh.bothReady) { $bothReady = $true; W ("bothReady after {0}s (ready={1})" -f $i, ($lh.ready -join '/')); break }
  }
  W ("guest /ready -> " + (J 'http://127.0.0.1:7789/ready'))
  Start-Sleep -Seconds 2
  W ("host /start -> " + (J 'http://127.0.0.1:7788/start'))

  # wait duel start
  # After HS_START the duel enters the TP (first/second) prompt; /state.started only flips
  # once MSG_START arrives, so answer any tp prompt on both sides while waiting.
  $started = $false
  for ($i = 0; $i -lt 200; $i++) {
    Start-Sleep -Seconds 1
    if ($i -gt 0 -and ($i % 10) -eq 0) { $null = J 'http://127.0.0.1:7788/start' }
    foreach ($p in 7788, 7789) {
      $a = JS "http://127.0.0.1:$p/actions"
      if ($a -and $a.actions) {
        foreach ($act in $a.actions) {
          if ($act.kind -eq 'tp') { W ("answer tp ({0}) -> act_id={1}" -f $p, $act.id); $null = J ("http://127.0.0.1:$p/act_id?id=" + $act.id) }
        }
      }
    }
    $hs = JS 'http://127.0.0.1:7788/state'
    if ($hs -and $hs.started) { $started = $true; W ("duel started (turn={0}, waited {1}s)" -f $hs.turn, $i); break }
    if (($i % 20) -eq 19) { $lh = JS 'http://127.0.0.1:7788/lobby'; $n = JS 'http://127.0.0.1:7788/net'; W ("waiting start {0}s: lobby players={1} ready={2} lastStoc={3}" -f ($i+1), $lh.playerCount, ($lh.ready -join '/'), $n.lastStocName) }
  }
  if (-not $started) { ShowMatch 'pre-start' 7788; throw 'duel did not start' }
  ShowMatch 'G1-start' 7788

  # guest surrenders game 1
  W ("guest /surrender -> " + (J 'http://127.0.0.1:7789/surrender'))
  Start-Sleep -Seconds 5
  ShowMatch 'after-G1' 7788

  # side phase: both sides must confirm (side_ok); the prompt can take a few seconds to appear
  $sideDone = @{ 7788 = $false; 7789 = $false }
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    foreach ($ctl in 7788, 7789) {
      if ($sideDone[$ctl]) { continue }
      $a = JS "http://127.0.0.1:$ctl/actions"
      if ($a -and $a.actions) {
        foreach ($act in $a.actions) {
          if ($act.kind -eq 'side_ok') {
            W ("side_ok ({0}) -> {1}" -f $ctl, (J ("http://127.0.0.1:$ctl/act_id?id=" + $act.id)))
            $sideDone[$ctl] = $true
          }
        }
      }
    }
    if ($sideDone[7788] -and $sideDone[7789]) { W ("side_ok answered on both sides (waited {0}s)" -f $i); break }
  }
  if (-not ($sideDone[7788] -and $sideDone[7789])) { W 'WARN: side_ok not answered on both sides' }
  # wait game 2
  $g2 = $false
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    $hs = JS 'http://127.0.0.1:7788/state'
    if ($hs -and $hs.started -and $hs.match -and $hs.match.game -ge 2) { $g2 = $true; W ("game 2 started (turn={0})" -f $hs.turn); break }
  }
  if (-not $g2) { ShowMatch 'no-game2' 7788; throw 'game 2 did not start' }
  ShowMatch 'G2-start' 7788

  W ("guest /surrender -> " + (J 'http://127.0.0.1:7789/surrender'))
  for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; $m = ShowMatch 'after-G2' 7788; if ($m -and $m.over) { break } }
  $final = ShowMatch 'after-G2' 7788
  W ("HOST match json: " + (J 'http://127.0.0.1:7788/state').Substring(0,0) )
  $raw = J 'http://127.0.0.1:7788/state'
  if ($raw -match '"match":\{.*?\}') { W ("match object: " + $Matches[0]) }
  W ("=== VERDICT: over={0} won={1} games={2} ===" -f $final.over, $final.gamesWonLocal, ($final.games | Measure-Object).Count)
}
catch {
  W ("ERROR: " + $_.Exception.Message)
}
finally {
  Start-Sleep -Seconds 2
  Get-Process YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  W 'cleanup done'
}
