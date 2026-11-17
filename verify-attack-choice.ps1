# bridge/verify-attack-choice.ps1 - deterministic LAN check for ATTACK TARGET CHOICE (candidate list)
#
# Scenario: host attack-test (ATK 1600/1900) vs guest defense-two (ATK 1500/1900). Guest builds two
# monsters (1900 first, 1500 second) so the attack-target window has two candidates with different ATK.
#
# Modes:
#   before : current build - expect /actions to expose only ONE select action ("select first 1
#            card(s)"), which always picks candidate[0]; record that as bug evidence.
#   after  : fixed build - expect one action per candidate (`select_card`, label with atk/def/loc/seq)
#            plus `select_auto`; --Pick atk:1500 / atk:1900 / auto selects a specific one.
#
# ASCII only (PS 5.1). -DryRun first.
param(
  [ValidateSet('before','after')]
  [string]$Mode = 'before',
  [string]$HostDeck = 'attack-test',
  [string]$GuestDeck = 'defense-two',
  [string]$Pick = 'first',
  [int]$Attempts = 1,
  [string]$PickSeq = '',
  [switch]$Multi,
  [switch]$Direct,
  [switch]$GuestNoSummon,
  [int]$MaxMinutes = 4,
  [int]$Port = 7911,
  [string]$Exe = '',
  [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exeDefault = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
if ($Exe -ne '') {
  $exe = $Exe
  if (-not [System.IO.Path]::IsPathRooted($exe)) { $exe = Join-Path $root $exe }
  $exe = [System.IO.Path]::GetFullPath($exe)
} else { $exe = $exeDefault }
$game = Join-Path $root 'mycard-bot\game'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd  = Join-Path $root ("ranked\logs\attack-choice-$Mode-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$runlog = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $runlog -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

function Cleanup {
  Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'verify-attack-choice' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Launch([int]$ctl, [string]$name, [string]$deck) {
  $bat = Join-Path $env:TEMP ("launch-choice-$name-$ctl.cmd")
  $lines = @('@echo off',
             "set YGO_CONTROL_PORT=$ctl",
             'set YGO_CTRL_DEBUG=1',
             'set YGO_SUPPRESS_MODALS=1',
             'set YGO_NET_PROBE=0',
             'set YGO_TP=1',
             'set YGO_SIDE_AUTO=1',
             "cd /d `"$game`"",
             ("start `"`" `"$exe`" -d " + $deck + " -k"))
  Set-Content -Path $bat -Value $lines -Encoding ASCII
  Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $bat) -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if ((J "http://127.0.0.1:$ctl/health") -match 'true') { W "$name control up after $($i+1)s (port $ctl, deck=$deck)"; return $true }
  }
  W "$name control did NOT come up"
  return $false
}

if ($DryRun) {
  W "=== DRY RUN attack-choice mode=$Mode (no client started) ==="
  W ("exe exists=" + (Test-Path $exe) + " path=" + $exe)
  W ("host deck exists=" + (Test-Path (Join-Path $game ('deck\' + $HostDeck + '.ydk'))) + "  guest deck exists=" + (Test-Path (Join-Path $game ('deck\' + $GuestDeck + '.ydk'))))
  W ("driver exists=" + (Test-Path (Join-Path $root 'bridge\verify-attack-choice.mjs')))
  if (Test-Path $exe) { $f = Get-Item $exe; W ("exe fingerprint=" + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + $f.Length) }
  W ("running YGOPro=" + @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue).Count + " node=" + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count)
  $busy = @(); foreach ($p in @(7788, 7789, $Port)) { if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $busy += $p } }
  $busyTxt = 'none'; if ($busy.Count -gt 0) { $busyTxt = ($busy -join ',') }
  W ("listening ports among 7788/7789/" + $Port + " : " + $busyTxt)
  W "plan: host $HostDeck (ATT 1600/1900) vs guest $GuestDeck (DEF 1500+1900 two monsters) -> attack -> record /actions + selectable -> submit -> outcome"
  W "dry-run done"
  Write-Output "DRYRUN_OK"
  exit 0
}

try {
  W "=== verify attack-choice $stamp mode=$Mode host=$HostDeck guest=$GuestDeck pick=$Pick ==="
  W ("exe=" + (Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + (Get-Item $exe).Length)
  Cleanup
  if (-not (Launch 7788 'host' $HostDeck)) { throw 'host launch failed' }
  W ("host /host -> " + (J ("http://127.0.0.1:7788/host?match=1&port=" + $Port)))
  Start-Sleep -Seconds 3
  if (-not (Launch 7789 'guest' $GuestDeck)) { throw 'guest launch failed' }
  W ("guest /join -> " + (J ("http://127.0.0.1:7789/join?ip=127.0.0.1&port=" + $Port)))

  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    $lh = JS 'http://127.0.0.1:7788/lobby'
    if ($lh -and $lh.playerCount -ge 2) { W ("both in room players={0}" -f $lh.playerCount); break }
  }
  W ("deck host -> " + (J ("http://127.0.0.1:7788/deck?name=" + $HostDeck)))
  W ("deck guest -> " + (J ("http://127.0.0.1:7789/deck?name=" + $GuestDeck)))

  $started = $false
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    $null = J 'http://127.0.0.1:7788/ready'; $null = J 'http://127.0.0.1:7789/ready'; $null = J 'http://127.0.0.1:7788/start'
    $hs = JS 'http://127.0.0.1:7788/state'; $gs = JS 'http://127.0.0.1:7789/state'
    if ($hs -and $hs.started -and $gs -and $gs.started) { $started = $true; W "duel started at t+${i}s"; break }
  }
  if (-not $started) { throw 'duel did not start' }

  $drvArgs = @((Join-Path $root 'bridge\verify-attack-choice.mjs'), '--dir', $evd, '--max-min', $MaxMinutes, '--mode', $Mode, '--pick', $Pick, '--attempts', $Attempts)
  if ($PickSeq -ne '') { $drvArgs += @('--pick-seq', $PickSeq) }
  if ($Multi) { $drvArgs += '--multi' }
  if ($Direct) { $drvArgs += '--direct' }
  if ($GuestNoSummon) { $drvArgs += '--guest-no-summon' }
  W ("driver: node " + ($drvArgs -join ' '))
  $drvOut = & node @drvArgs 2>&1
  $drvOut | ForEach-Object { W ("driver: " + $_) }
}
catch { W ("ERROR: " + $_.Exception.Message) }
finally {
  try {
    $ctl = Get-ChildItem (Join-Path $game 'control-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2
    foreach ($f in $ctl) { Copy-Item $f.FullName (Join-Path $evd ("log-" + $f.Name)) -Force }
    W ("control logs copied: " + (($ctl | ForEach-Object { $_.Name }) -join ','))
  } catch { W ("copy control logs failed: " + $_.Exception.Message) }

  try {
    $an = @()
    foreach ($f in (Get-ChildItem $evd -Filter 'log-control-*.log' -ErrorAction SilentlyContinue)) {
      $txt = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
      $resp15 = @($txt | Select-String -Pattern 'response: prompt=15|SEND RESPONSE realMsg=15|SEND RESPONSE curMsg=15')
      $retry15 = @($txt | Select-String -Pattern 'RETRY after msg=15')
      $retryAll = @($txt | Select-String -Pattern 'RETRY after msg=')
      $battle110 = @($txt | Select-String -Pattern 'firstid=110')
      $eof = @($txt | Select-String -Pattern 'NET disconnected reason=eof')
      $an += [pscustomobject]@{
        file = $f.Name
        response15 = $resp15.Count
        retryFor15 = $retry15.Count
        retryAll = $retryAll.Count
        msgBattle110 = $battle110.Count
        eofLines = $eof.Count
        response15Samples = @($resp15 | Select-Object -Last 4 | ForEach-Object { $_.Line.Trim() })
        retry15Samples = @($retry15 | Select-Object -Last 4 | ForEach-Object { $_.Line.Trim() })
      }
    }
    $an | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evd 'choice-analysis.json') -Encoding UTF8
    W ("choice analysis: " + (($an | ForEach-Object { "{0} resp15={1} retry15={2} msg110={3} eof={4}" -f $_.file, $_.response15, $_.retryFor15, $_.msgBattle110, $_.eofLines }) -join ' | '))
  } catch { W ("choice analysis failed: " + $_.Exception.Message) }

  try {
    $sum = Get-Content (Join-Path $evd 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $acts = @($sum.actionsAtTarget)
    $selectKinds = @($acts | Where-Object { $_.kind -in 'select', 'select_card', 'card' })
    $perCandidate = @($acts | Where-Object { $_.kind -eq 'select_card' })
    $autoAct = @($acts | Where-Object { $_.kind -eq 'select_auto' })
    $r0 = @($sum.results)[0]
    $sel = @($sum.selectableAtTarget)
    $verdict = 'UNKNOWN'; $why = ''
    if (-not $r0) { $verdict = 'FAIL'; $why = 'no target result recorded' }
    elseif ($Mode -eq 'before') {
      if ($selectKinds.Count -eq 1 -and $sel.Count -ge 2) {
        $verdict = 'PASS(bug-reproduced)'
        $why = "only one select action ('$($selectKinds[0].label)') for $($sel.Count) candidates; picked candidate[0] atk=$($sel[0].atk); guestDestroyed=$($r0.guestMonsterDestroyed) hostDestroyed=$($r0.hostMonsterDestroyed)"
      } else {
        $verdict = 'FAIL'; $why = "expected exactly one select action with >=2 candidates, got selectKinds=$($selectKinds.Count) selectable=$($sel.Count)"
      }
    } else {
      $okCount = ($perCandidate.Count -ge 2)
      $picked = $r0.chosen.label
      if ($okCount -and $r0) { $verdict = 'PASS'; $why = "per-candidate actions=$($perCandidate.Count), picked=$picked, guestDestroyed=$($r0.guestMonsterDestroyed) hostDestroyed=$($r0.hostMonsterDestroyed)" }
      else { $verdict = 'FAIL'; $why = "per-candidate actions=$($perCandidate.Count) (want >=2), picked=$picked" }
    }
    W ("VERDICT mode=$Mode : $verdict ($why)")
    ([pscustomobject]@{ mode = $Mode; pick = $Pick; verdict = $verdict; why = $why }) | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $evd 'VERDICT.json') -Encoding UTF8
  } catch { W ("verdict error: " + $_.Exception.Message) }

  $null = J 'http://127.0.0.1:7788/surrender'; $null = J 'http://127.0.0.1:7789/surrender'
  Start-Sleep -Seconds 1
  Cleanup
  W "evidence: $evd"
  W '=== done ==='
  Write-Output "EVIDENCE_DIR=$evd"
}

