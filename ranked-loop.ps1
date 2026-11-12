# bridge/ranked-loop.ps1 - play N consecutive ranked matches unattended.
# Queues, joins, plays with the semantic policy, waits through the Bo3 side phase,
# screenshots every 10s, and records stalls/prompts it has never seen.
# ASCII only (PS 5.1 parses this file as ANSI).
param(
  [int]$Runs = 3,
  [int]$MaxMinutesPerMatch = 18,
  [string]$Deck = 'BlackwingHT2S',
  [int]$Id = 1173810,
  [int]$ShotEverySec = 10,
  [int]$StallSec = 75,
  [int]$MaxTotalMinutes = 90,
  [int]$SilentAbortSec = 150,
  [int]$EmptyRoomSec = 35
)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:lastDump = (Get-Date).AddMinutes(-10)
$evd = Join-Path $root "ranked\logs\loop-$stamp"
New-Item -ItemType Directory -Path $evd -Force | Out-Null
$log = Join-Path $evd 'run.log'
$summaryPath = Join-Path $evd 'summary.json'
trap {
  W ("FATAL: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
  Get-Process YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  exit 1
}
function W([string]$m) { Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 }
function JGet([string]$u) { try { return (Invoke-WebRequest -Uri $u -TimeoutSec 4 -UseBasicParsing).Content } catch { return $null } }
function JPost([string]$u) { try { return (Invoke-WebRequest -Uri $u -Method POST -TimeoutSec 8 -UseBasicParsing).Content } catch { return $null } }
function St([string]$p) { $r = JGet "http://127.0.0.1:$p/state"; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }
function AnswerPending([int]$ctlPort, [string]$tag) {
  $a = JGet "http://127.0.0.1:$ctlPort/actions"
  if (-not $a) { return }
  $o = $null; try { $o = $a | ConvertFrom-Json } catch { return }
  if (-not $o -or -not $o.actions) { return }
  foreach ($act in $o.actions) {
    if ($act.kind -eq 'side_ok' -or $act.kind -eq 'tp') {
      $r = JGet ("http://127.0.0.1:$ctlPort/act_id?id=" + $act.id)
      W ("{0} answered {1} id={2} -> {3}" -f $tag, $act.kind, $act.id, $r)
      return
    }
  }
}
function Shot([string]$tag) { $t = (Get-Date -Format 'HHmmss'); powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bridge\shot.ps1') -Tag ("{0}-{1}" -f $tag, $t) -OutDir ("ranked\logs\loop-$stamp\shots") | Out-Null }

# 0) preflight
$busy = Get-Process YGOPro -ErrorAction SilentlyContinue
if ($busy) { W ("killing leftover clients pid=" + ($busy.Id -join ',')); $busy | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
$stray = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.StartTime -lt (Get-Date).AddSeconds(-30) }
if ($stray) { W ("killing stray runners pid=" + ($stray.Id -join ',')); $stray | Stop-Process -Id { $_.Id } -Force -ErrorAction SilentlyContinue }
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($p in 7788,7789) {
  if (((Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count) -gt 0) { W "ABORT: port $p listening"; return }
}

$results = @()
$matchNo = 0; $successCount = 0; $totalDeadline = (Get-Date).AddMinutes($MaxTotalMinutes)
$globalStalls = 0
while ($successCount -lt $Runs -and (Get-Date) -lt $totalDeadline) {
  $matchNo++; $clientFault = $false
  $mStart = Get-Date
  $evm = Join-Path $evd ("match-{0}" -f $matchNo)
  New-Item -ItemType Directory -Path $evm -Force | Out-Null
  W ("=== MATCH {0}/{1} deck={2} exe={3} {4} ===" -f $matchNo, $Runs, $Deck, (Get-Item $exe).LastWriteTime, (Get-Item $exe).Length)

  # 1) client
  $env:YGO_CONTROL_PORT = '7788'; $env:YGO_SUPPRESS_MODALS = '1'; $env:YGO_NET_PROBE = '0'; $env:YGO_RESUME_JOURNAL = '0'
  # the client auto-connects to system.conf lasthost at startup; a leftover LAN host/port
  # (127.0.0.1:7911 with nobody listening) makes it fail/quit before we can join a room.
  $conf = Join-Path $game 'system.conf'
  if (Test-Path $conf) {
    $txt = [IO.File]::ReadAllText($conf, [Text.Encoding]::UTF8)
    $txt = [regex]::Replace($txt, '(?m)^\s*lasthost\s*=.*$', 'lasthost = tiramisu.moonext.com')
    $txt = [regex]::Replace($txt, '(?m)^\s*lastport\s*=.*$', 'lastport = 8911')
    [IO.File]::WriteAllText($conf, $txt, (New-Object System.Text.UTF8Encoding($false)))
    W 'system.conf lasthost/lastport -> ranked server'
  }
  cmd /c start "" /D "$game" "$exe" -d $Deck -k
  $up = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    $h = (cmd /c "curl.exe -s --max-time 2 http://127.0.0.1:7788/health") | Out-String
    $h = $h.Trim()
    $nproc = (Get-Process YGOPro -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($h -like '*"ok":true*') { $up = $true; W ("client up after {0}s (procs={1}) health={2}" -f ($i+1), $nproc, $h); break }
    if ($nproc -eq 0) { W ("client process gone after {0}s" -f ($i+1)); break }
    if (($i % 5) -eq 4) { W ("waiting for control layer.. {0}s health={1} procs={2}" -f ($i+1), ($h -replace '\s+',' '), $nproc) }
  }
  if (-not $up) { W 'ABORT: client control layer not up'; Shot "m$matchNo-noctl"; break }

  # 2) queue
  $room = $null
  for ($q = 1; $q -le 60; $q++) {
    $env:MC_ACCOUNT_ID = "$Id"
    $rawFile = Join-Path $evm 'room-raw.txt'
    cmd /c "node `"$root\bridge\get-room.mjs`" > `"$rawFile`" 2>&1"
    $raw = Get-Content $rawFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $cand = $null
    if ($raw -match '\{"address".*?\}') { try { $cand = $Matches[0] | ConvertFrom-Json } catch {} }
    if (-not $cand -or -not $cand.password) { W ("queue attempt {0} failed raw=[{1}]" -f $q, ($raw -replace "\s+"," ")); Start-Sleep -Seconds 30; continue }
    if ($cand.id -and [int]$cand.id -ne $Id) { W "ABORT: room id=$($cand.id) != $Id"; break }
    if ($cand.stale) { W 'stale room; wait 20s'; Start-Sleep -Seconds 20; continue }
    $room = $cand; break
  }
  if (-not $room) { W 'ABORT: no fresh room'; break }
  W ("room {0}:{1}" -f $room.address, $room.port)
  Set-Content -Path (Join-Path $evm 'room.json') -Value ($room | ConvertTo-Json -Compress) -Encoding UTF8

  # 3) join
  $joinUrl = "http://127.0.0.1:7788/join?ip={0}&port={1}&pass={2}" -f $room.address, $room.port, [uri]::EscapeDataString($room.password)
  $joined = $false
  for ($jt = 1; $jt -le 4; $jt++) {
    $jr = JGet $joinUrl
    W ("join attempt {0} -> {1}" -f $jt, $jr)
    for ($k = 0; $k -lt 10; $k++) {
      Start-Sleep -Seconds 2
      $n = $null; try { $n = (JGet 'http://127.0.0.1:7788/net') | ConvertFrom-Json } catch {}
      $u = JGet 'http://127.0.0.1:7788/ui'
      if ($n -and $n.connected -and $n.joined) { $joined = $true; break }
      if ($u -and ($u -match '"wLanWindow"') -and ($u -notmatch '"windowsVisible":\[[^\]]*wLanWindow')) { $joined = $true; break }
    }
    if ($joined) { W 'join confirmed (connected+joined)'; break }
    W 'join not confirmed yet -> retry'
  }
  if (-not $joined) { W 'WARN: join could not be confirmed' }

  # 4) policy before ready/start (answers TP and side_ok; plays the duels)
  $env:CONTROL_URL = 'http://127.0.0.1:7788'
  $env:MAX_MINUTES = "$MaxMinutesPerMatch"
  $env:NO_PROGRESS_MS = '90000'
  $pol = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evm 'policy.log') -RedirectStandardError (Join-Path $evm 'policy.err.log') -PassThru -WindowStyle Hidden
  W "policy pid=$($pol.Id)"

  # 5) deck + ready + start, screenshots every N sec, wait for the duel to start
  $started = $false; $emptyTicks = 0; $noOpponent = $false; $startSends = 0
  $nextShot = Get-Date
  $deckSent = $false
  $readySends = 0
  for ($i = 1; $i -le 45; $i++) {
    Start-Sleep -Seconds 2
    $s = St '7788'
    $net = JGet 'http://127.0.0.1:7788/net'
    if ($i -eq 2 -and -not $deckSent) { W "deck -> $(JGet ('http://127.0.0.1:7788/deck?name=' + [uri]::EscapeDataString($Deck)))"; $deckSent = $true }
    # keep pressing ready until the lobby reports us as ready, then keep asking to start
    $lb = $null; try { $lb = (JGet 'http://127.0.0.1:7788/lobby') | ConvertFrom-Json } catch {}
    $selfReady = $false
    if ($lb -and $lb.ready -and ($lb.ready.Count -ge 2)) { $selfReady = ([int]$lb.ready[[int]$lb.self] -eq 1) }
    $playerCount = 0
    if ($lb -and $lb.statuses) { $playerCount = $lb.statuses.Count }
    # joined but nobody else showed up within EmptyRoomSec -> leave and re-queue
    if ($playerCount -lt 2) {
      if (-not $emptySince) { $emptySince = Get-Date; W ("room is empty, waiting up to {0}s for an opponent" -f $EmptyRoomSec) }
      elseif (((Get-Date) - $emptySince).TotalSeconds -ge $EmptyRoomSec) {
        W ("nobody joined within {0}s -> leave and re-queue" -f $EmptyRoomSec)
        try { $null = JPost 'http://127.0.0.1:7788/leave' } catch {}
        Start-Sleep -Seconds 2
        $noOpponent = $true; break
      }
    } else { $emptySince = $null }
    if (-not $selfReady -and $readySends -lt 30) { $null = JPost 'http://127.0.0.1:7788/ready'; $readySends++ }
    # both sides ready does NOT auto-start: keep sending HS_START until /state.started.
    # (lobby.statuses can lag / miss the opponent, so also trigger on bothReady or our own ready.)
    $bothReady = ($lb -and $lb.bothReady)
    if (-not $started -and $readySends -gt 0 -and $startSends -lt 20 -and ($i % 2) -eq 0 -and ($bothReady -or $playerCount -ge 2)) {
      $null = JPost 'http://127.0.0.1:7788/start'; $startSends++
      W ("start: HS_START #{0} (bothReady={1} players={2})" -f $startSends, $bothReady, $playerCount)
    }
    if (($i % 5) -eq 0 -and $lb) { W ("lobby ready={0} self={1} bothReady={2}" -f ($lb.ready -join ','), $lb.self, $lb.bothReady); Set-Content -Path (Join-Path $evm ("lobby-{0}.json" -f $i)) -Value ($lb | ConvertTo-Json -Compress) -Encoding UTF8 }
    if ((Get-Date) -ge $nextShot) { $nextShot = (Get-Date).AddSeconds($ShotEverySec); Shot "m$matchNo-start" }
    if ($s -and $s.started) { $started = $true; break }
    if ($net -and $net.state -eq 'disconnected' -and -not ($s -and $s.started)) { W 'disconnected before duel start'; break }
  }
  if (-not $started) { if (-not $noOpponent) { $clientFault = $true }; W 'duel did NOT start'; Shot "m$matchNo-nostart"; Set-Content -Path (Join-Path $evm 'state-notstarted.json') -Value (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8 }
  else { W 'duel started' }

  # 6) monitor to the end of the match (Bo3: game2/game3 after side phase)
  $deadline = $mStart.AddMinutes($MaxMinutesPerMatch)
  if ($noOpponent) { W "skip monitor (empty room)"; $deadline = (Get-Date).AddSeconds(-1) }
  $nextShot = Get-Date
  $lastSeq = -1; $lastProgress = Get-Date; $stallCount = 0; $script:prevWin = -1; $script:lastSig = ""
  $games = @(); $gameNo = 0; $matchOver = $false; $duelEnded = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $s = St '7788'
    if (-not $s) { W 'client gone (control layer down)'; $matchOver = $true; break }
    if ((Get-Date) -ge $nextShot) { $nextShot = (Get-Date).AddSeconds($ShotEverySec); Shot "m$matchNo-live" }
    # server goes silent on an opponent that left: timeLeft stops ticking and no STOC arrives.
    # leave the room and take a new match instead of burning the whole budget.
    if (([int]$s.winPlayer -lt 0) -and -not $awaiting -and -not $s.sidePending -and -not $s.tpPending -and ((Get-Date) - $lastProgress).TotalSeconds -gt $SilentAbortSec) {
      W ("silent duel for {0}s (turn={1} curMsg={2} timeLeft={3}) -> leave and re-queue" -f [int]((Get-Date) - $lastProgress).TotalSeconds, $s.turn, $s.curMsg, $s.timeLeft)
      Shot "m$matchNo-silent"
      Set-Content -Path (Join-Path $evm 'silent-state.json') -Value (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8
      Set-Content -Path (Join-Path $evm 'silent-net.json') -Value (JGet 'http://127.0.0.1:7788/net') -Encoding UTF8
      try { $null = JPost 'http://127.0.0.1:7788/leave' } catch {}
      Start-Sleep -Seconds 3
      $matchOver = $true; break
    }
    if ($s.inDuel -and ([int]$s.winPlayer -lt 0) -and -not $awaiting -and -not $s.sidePending -and -not $s.tpPending -and ((Get-Date) - $lastProgress).TotalSeconds -gt 300 -and ([int]$s.timeLeft -le 5)) {
      W ("opponent idle for {0}s (turn={1} curMsg={2}) -> surrender this match and re-queue" -f [int]((Get-Date) - $lastProgress).TotalSeconds, $s.turn, $s.curMsg)
      Shot "m$matchNo-opponentidle"
      $null = JPost 'http://127.0.0.1:7788/surrender'
      Start-Sleep -Seconds 5
      $matchOver = $true; break
    }
    AnswerPending 7788 'self'
    $net = $null; try { $net = (JGet 'http://127.0.0.1:7788/net') | ConvertFrom-Json } catch {}
    # progress tracking
    $seq = [int]$s.seq
    $sig = "{0}|{1}|{2}|{3}" -f $s.turn, $s.phase, ($s.lp -join '/'), $s.curMsg
    if ($seq -ne $lastSeq -or $sig -ne $script:lastSig) { $lastSeq = $seq; $script:lastSig = $sig; $lastProgress = Get-Date }
    $winNow = -1
    if ($s.winPlayer -ne $null) { $winNow = [int]$s.winPlayer }
    if ($winNow -ge 0 -and $script:prevWin -lt 0) {
      $gameNo++
      $entry = "{0}:{1}" -f $winNow, ($s.winReasonName)
      $games += $entry
      W ("GAME {0} result raw={1} isWin={2} reason={3} turn={4} lp={5}" -f $gameNo, $winNow, $s.isWin, $s.winReasonName, $s.turn, ($s.lp -join '/'))
    }
    if ($winNow -lt 0) { $script:prevWin = -1 } else { $script:prevWin = $winNow }
    # stall detection: awaiting but the prompt sequence has not moved for a while
    $awaiting = ($s.PSObject.Properties.Name -contains 'awaiting') -and $s.awaiting
    if (-not $awaiting -and -not $s.sidePending -and -not $s.tpPending -and ([int]$s.winPlayer -lt 0) -and ((Get-Date) - $lastProgress).TotalSeconds -gt ($StallSec * 1.5) -and (((Get-Date) - $script:lastDump).TotalSeconds -gt 60)) { $script:lastDump = Get-Date
      $stag = "m$matchNo-noprompt"
      Shot $stag
      Set-Content -Path (Join-Path $evm "$stag-state.json") -Value (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8
      Set-Content -Path (Join-Path $evm "$stag-net.json") -Value (JGet 'http://127.0.0.1:7788/net') -Encoding UTF8
      Set-Content -Path (Join-Path $evm "$stag-ui.json") -Value (JGet 'http://127.0.0.1:7788/ui') -Encoding UTF8
      W ("NOPROMPT {0}s without progress (curMsg={1} turn={2}) dumped {3}" -f [int]((Get-Date) - $lastProgress).TotalSeconds, $s.curMsg, $s.turn, $stag)
      # keep lastProgress as is: the idle watchdog uses it to give up on a stalled opponent
    }
    if ($awaiting -and ((Get-Date) - $lastProgress).TotalSeconds -gt $StallSec) {
      $stallCount++; $globalStalls++; if ($awaiting) { $clientFault = $true }
      $stag = "m$matchNo-stall$stallCount"
      Shot $stag
      Set-Content -Path (Join-Path $evm "$stag-state.json") -Value (JGet 'http://127.0.0.1:7788/state') -Encoding UTF8
      Set-Content -Path (Join-Path $evm "$stag-prompt.json") -Value (JGet 'http://127.0.0.1:7788/prompt') -Encoding UTF8
      Set-Content -Path (Join-Path $evm "$stag-actions.json") -Value (JGet 'http://127.0.0.1:7788/actions') -Encoding UTF8
      Set-Content -Path (Join-Path $evm "$stag-ui.json") -Value (JGet 'http://127.0.0.1:7788/ui') -Encoding UTF8
      W ("STALL #{0} awaiting=1 seq={1} curMsg={2} turn={3} side={4} tp={5} (dumped {6})" -f $stallCount, $s.seq, $s.curMsg, $s.turn, $s.sidePending, $s.tpPending, $stag)
      # best effort: nudge with the first action, policy should normally do this first
      $a = JGet 'http://127.0.0.1:7788/actions'
      $o = $null; try { $o = $a | ConvertFrom-Json } catch {}
      if ($o -and $o.actions -and $o.actions.Count -gt 0) { W ("nudge -> act_id={0} kind={1}" -f $o.actions[0].id, $o.actions[0].kind); $null = JGet ("http://127.0.0.1:7788/act_id?id=" + $o.actions[0].id) }
      $lastProgress = Get-Date
    }
    if ($net -and $net.state -eq 'disconnected') {
      W ("connection lost mid-duel (alive={0} closeReason={1} sinceStoc={2}ms) -> abort match and re-queue" -f $net.alive, $net.closeReason, $net.sinceLastStoc)
      Shot "m$matchNo-disconnect"
      Set-Content -Path (Join-Path $evm 'net-disconnected.json') -Value (JGet 'http://127.0.0.1:7788/net') -Encoding UTF8
      $matchOver = $true; break
    }
    # MC ranked is a single duel: after the win screen the server sends STOC_DUEL_END and closes the room
    $lastStoc = $s.lastStocName
    if (-not $lastStoc -and $net) { $lastStoc = $net.lastStocName }
    if ($lastStoc -eq 'STOC_DUEL_END') { W 'STOC_DUEL_END -> match over'; Start-Sleep -Seconds 3; $matchOver = $true; $duelEnded = $true; break }
    if ($net -and $net.lastStocName -eq 'STOC_DUEL_END') { W 'STOC_DUEL_END (net) -> match over'; Start-Sleep -Seconds 3; $matchOver = $true; $duelEnded = $true; break }
    # match over: results recorded and nothing left to play (no side phase, no TP pending, not started)

    $duelLive = ($s -and $s.started -and [int]$s.winPlayer -lt 0)
    if ($pol -and $pol.HasExited -and $duelLive) {
      W ("policy exited (code={0}) -> relaunch for side/next duel" -f $pol.ExitCode)
      Start-Sleep -Seconds 2
      $env:CONTROL_URL = 'http://127.0.0.1:7788'
      $env:MAX_MINUTES = "$MaxMinutesPerMatch"; $env:NO_PROGRESS_MS = '90000'
      $pol = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evm ("policy-{0}.log" -f $gameNo)) -RedirectStandardError (Join-Path $evm ("policy-{0}.err.log" -f $gameNo)) -PassThru -WindowStyle Hidden
      W "policy relaunched pid=$($pol.Id)"
    }
  }
  if ($duelEnded -and $gameNo -ge 2) {
    $successCount++; W ("MATCH {0} COMPLETE ({1}/{2} consecutive bo3 done, games={3})" -f $matchNo, $successCount, $Runs, $gameNo)
  } elseif ($duelEnded) {
    W ("MATCH {0} ended after {1} game(s) (opponent left) -> external, streak kept at {2}" -f $matchNo, $gameNo, $successCount)
  } elseif ($clientFault) {
    W ("MATCH {0} aborted on OUR side -> streak reset (was {1})" -f $matchNo, $successCount)
    $successCount = 0
  } else {
    W ("MATCH {0} aborted (external: silent opponent / empty room / network) -> streak kept at {1}" -f $matchNo, $successCount)
  }
  $mEnd = Get-Date
  $dur = [int]($mEnd - $mStart).TotalSeconds
  $final = St '7788'
  $res = [pscustomobject]@{
    match = $matchNo; started = $started; games = $games; stalls = $stallCount; seconds = $dur
    finalWinRaw = if ($final) { $final.winPlayer } else { $null }
    finalIsWin = if ($final) { $final.isWin } else { $null }
    finalTurn = if ($final) { $final.turn } else { $null }
  }
  $results += $res
  W ("MATCH {0} done: games={1} stalls={2} dur={3}s result={4}" -f $matchNo, ($games -join ','), $stallCount, $dur, ($res | ConvertTo-Json -Compress))
  Set-Content -Path (Join-Path $evm 'match.json') -Value ($res | ConvertTo-Json -Compress) -Encoding UTF8

  # 7) cleanup this match
  if ($pol -and -not $pol.HasExited) { Stop-Process -Id $pol.Id -Force -ErrorAction SilentlyContinue }
  try { $null = JPost 'http://127.0.0.1:7788/leave' } catch {}
  Start-Sleep -Seconds 12
  Get-Process YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 6
}

$ok = ($results | Where-Object { $_.started -and $_.games.Count -ge 1 }).Count
$sum = [pscustomobject]@{
  stamp = $stamp; matchesRequested = $Runs; matchesWithGames = $ok
  totalStalls = $globalStalls; results = $results
}
Set-Content -Path $summaryPath -Value ($sum | ConvertTo-Json -Depth 5) -Encoding UTF8
W ("=== DONE: {0}/{1} matches had duels, total stalls={2} evidence={3} ===" -f $ok, $Runs, $globalStalls, $evd)
Write-Output ("evidence: {0}" -f $evd)
