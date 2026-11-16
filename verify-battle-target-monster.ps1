# bridge/verify-battle-target-monster.ps1 - deterministic LAN check: attack the opponent's MONSTER
# (task-37 B). Host = attacker (battle-test: ATK 2000), guest = defender (battle-test-low: ATK 1500).
# The driver builds both boards, has the host attack the guest's monster and answer the
# MSG_SELECT_CARD(15) target prompt with raw bytes; this wrapper collects the control-log evidence.
#
# ASCII only (PS 5.1 reads this as ANSI). Use -DryRun first.
param(
  [string]$HostDeck = 'battle-test',
  [string]$GuestDeck = 'battle-test-low',
  [int]$MaxMinutes = 5,
  [int]$Port = 7911,
  [int]$StopAfterHits = 1,
  [switch]$Multi,
  # optional client exe (default: formal build); a copy build can be used like verify-eof-guard
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
$evd  = Join-Path $root ("ranked\logs\battle-target-monster-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$runlog = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $runlog -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

function Cleanup {
  Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'verify-battle-target-monster|policy-semantic' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Launch([int]$ctl, [string]$name, [string]$deck) {
  $bat = Join-Path $env:TEMP ("launch-btm-$name-$ctl.cmd")
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
  W "=== DRY RUN battle-target-monster (no client started) ==="
  W ("exe exists=" + (Test-Path $exe) + " path=" + $exe)
  W ("host deck exists=" + (Test-Path (Join-Path $game ('deck\' + $HostDeck + '.ydk'))) + "  guest deck exists=" + (Test-Path (Join-Path $game ('deck\' + $GuestDeck + '.ydk'))))
  W ("driver exists=" + (Test-Path (Join-Path $root 'bridge\verify-battle-target-monster.mjs')))
  if (Test-Path $exe) { $f = Get-Item $exe; W ("exe fingerprint=" + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + $f.Length) }
  W ("running YGOPro=" + @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue).Count + " node=" + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count)
  $busy = @(); foreach ($p in @(7788, 7789, $Port)) { if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $busy += $p } }
  $busyTxt = 'none'; if ($busy.Count -gt 0) { $busyTxt = ($busy -join ',') }
  W ("listening ports among 7788/7789/" + $Port + " : " + $busyTxt)
  W "plan: host deck=$HostDeck (ATK 2000) / guest deck=$GuestDeck (ATK 1500) -> build both boards -> host attacks guest monster -> answer 15 with raw [1,seqNo] -> expect guest monster destroyed + LP -500 + firstid=110 + no RETRY15 + no eof"
  W "dry-run done"
  Write-Output "DRYRUN_OK"
  exit 0
}

try {
  W "=== verify battle-target-monster $stamp host=$HostDeck guest=$GuestDeck maxMin=$MaxMinutes ==="
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

  $drvArgs = @((Join-Path $root 'bridge\verify-battle-target-monster.mjs'), '--dir', $evd, '--max-min', $MaxMinutes, '--stop-after-hits', $StopAfterHits)
  if ($Multi) { $drvArgs += '--multi' }
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
      $resp15 = @($txt | Select-String -Pattern 'SEND RESPONSE realMsg=15|SEND RESPONSE curMsg=15|response: prompt=15')
      $retry15 = @($txt | Select-String -Pattern 'RETRY after msg=15')
      $retryAll = @($txt | Select-String -Pattern 'RETRY after msg=')
      $battle110 = @($txt | Select-String -Pattern 'firstid=110')
      $prompt15 = @($txt | Select-String -Pattern 'PROMPT publish seq=\d+ msg=15')
      $eof = @($txt | Select-String -Pattern 'NET disconnected reason=eof')
      $an += [pscustomobject]@{
        file = $f.Name
        response15 = $resp15.Count
        retryFor15 = $retry15.Count
        retryAll = $retryAll.Count
        msgBattle110 = $battle110.Count
        promptMsg15 = $prompt15.Count
        eofLines = $eof.Count
        response15Samples = @($resp15 | Select-Object -Last 5 | ForEach-Object { $_.Line.Trim() })
        retry15Samples = @($retry15 | Select-Object -Last 5 | ForEach-Object { $_.Line.Trim() })
        battleSamples = @($battle110 | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() })
      }
    }
    $an | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evd 'target-analysis.json') -Encoding UTF8
    W ("target analysis: " + (($an | ForEach-Object { "{0} resp15={1} retry15={2} msg110={3} eof={4}" -f $_.file, $_.response15, $_.retryFor15, $_.msgBattle110, $_.eofLines }) -join ' | '))
  } catch { W ("target analysis failed: " + $_.Exception.Message) }

  # verdict: driver hit + log evidence (response15>0, no retry15, msgBattle110>0, no eof)
  $verdict = 'UNKNOWN'; $why = ''
  try {
    $ps = Get-Content (Join-Path $evd 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ga = Get-Content (Join-Path $evd 'target-analysis.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $resp15 = (@($ga) | Measure-Object -Property response15 -Sum).Sum
    $retry15 = (@($ga) | Measure-Object -Property retryFor15 -Sum).Sum
    $msg110 = (@($ga) | Measure-Object -Property msgBattle110 -Sum).Sum
    $eof = (@($ga) | Measure-Object -Property eofLines -Sum).Sum
    $hits = $ps.verdict.hits; $fails = $ps.verdict.fails
    if ($hits -ge $StopAfterHits -and $resp15 -gt 0 -and $retry15 -eq 0 -and $msg110 -gt 0 -and $eof -eq 0) {
      $verdict = 'PASS'; $why = "hits=$hits resp15=$resp15 retry15=0 msg110=$msg110 eof=0"
    } else {
      $verdict = 'FAIL'; $why = "hits=$hits fails=$fails resp15=$resp15 retry15=$retry15 msg110=$msg110 eof=$eof"
    }
  } catch { $why = 'verdict error: ' + $_.Exception.Message }
  W ("VERDICT: $verdict ($why)")
  ([pscustomobject]@{ verdict = $verdict; why = $why; hostDeck = $HostDeck; guestDeck = $GuestDeck }) | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $evd 'VERDICT.json') -Encoding UTF8

  $null = J 'http://127.0.0.1:7788/surrender'; $null = J 'http://127.0.0.1:7789/surrender'
  Start-Sleep -Seconds 1
  Cleanup
  W "evidence: $evd"
  W '=== done ==='
  Write-Output "EVIDENCE_DIR=$evd"
}


