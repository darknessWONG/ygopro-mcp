# bridge/verify-battle-policy.ps1 - LAN battle target verification with two policy bots (task-36 #1)
#
# Unlike verify-battle-target.ps1 (which drives both sides with fixed scripted actions and can get
# stuck in synchro/effect card-selection prompts), this harness lets bridge/policy-semantic.mjs
# play both sides while bridge/observe-battle.mjs records the battle -> target-selection evidence
# read-only. Use this one when we need real attack-target windows.
#
# ASCII only (PS 5.1 reads this as ANSI).
param(
  [string]$Deck = 'Blackwing',
  [int]$MaxMinutes = 4,
  [int]$Port = 7911,
  [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$game = Join-Path $root 'mycard-bot\game'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd  = Join-Path $root ("ranked\logs\verify-battle-policy-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$runlog = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $runlog -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

function Cleanup {
  Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' -or $_.Path -like '*mycard-bot\game*' } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'policy-semantic|observe-battle|verify-battle' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Launch([int]$ctl, [string]$name, [string[]]$extra) {
  $bat = Join-Path $env:TEMP ("launch-vbp-$name-$ctl.cmd")
  $lines = @('@echo off',
             "set YGO_CONTROL_PORT=$ctl",
             'set YGO_CTRL_DEBUG=1',
             'set YGO_SUPPRESS_MODALS=1',
             'set YGO_NET_PROBE=0',
             'set YGO_TP=1',
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

if ($DryRun) {
  W "=== DRY RUN (policy mode, no client started) ==="
  W ("exe exists=" + (Test-Path $exe))
  W ("policy exists=" + (Test-Path (Join-Path $root 'bridge\policy-semantic.mjs')))
  W ("observer exists=" + (Test-Path (Join-Path $root 'bridge\observe-battle.mjs')))
  $yg = @(Get-Process YGOPro -ErrorAction SilentlyContinue); $nd = @(Get-Process node -ErrorAction SilentlyContinue)
  W ("running YGOPro=" + $yg.Count + " node=" + $nd.Count)
  W "plan: launch host/guest -> /host?match=1 -> /join -> deck/ready/start -> 2x policy-semantic -> observe-battle (read-only) -> report"
  W "dry-run done"
  Write-Output "DRYRUN_OK"
  exit 0
}

$ph = $null; $pg = $null
try {
  W "=== verify battle policy $stamp deck=$Deck maxMin=$MaxMinutes port=$Port ==="
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

  # policies must run before start (they answer TP if any, and start playing immediately)
  $env:CONTROL_URL = 'http://127.0.0.1:7788'; $env:MAX_MINUTES = "$($MaxMinutes + 2)"; $env:NO_PROGRESS_MS = '90000'
  $ph = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evd 'policy-host.log') -RedirectStandardError (Join-Path $evd 'policy-host.err.log') -PassThru -WindowStyle Hidden
  $env:CONTROL_URL = 'http://127.0.0.1:7789'
  $pg = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $root 'bridge\policy-semantic.mjs')) -RedirectStandardOutput (Join-Path $evd 'policy-guest.log') -RedirectStandardError (Join-Path $evd 'policy-guest.err.log') -PassThru -WindowStyle Hidden
  W "policies started host=$($ph.Id) guest=$($pg.Id)"

  $started = $false
  for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 1
    $null = J 'http://127.0.0.1:7788/ready'
    $null = J 'http://127.0.0.1:7789/ready'
    $null = J 'http://127.0.0.1:7788/start'
    $hs = JS 'http://127.0.0.1:7788/state'; $gs = JS 'http://127.0.0.1:7789/state'
    if ($hs -and $hs.started -and $gs -and $gs.started) { $started = $true; W "duel started at t+${i}s"; break }
  }
  if (-not $started) { throw 'duel did not start' }

  W 'starting read-only observer'
  $obsArgs = @((Join-Path $root 'bridge\observe-battle.mjs'), '--dir', $evd, '--max-min', $MaxMinutes, '--stop-after-targets', '2')
  $obsOut = & node @obsArgs 2>&1
  $obsOut | ForEach-Object { W ("observer: " + $_) }
}
catch { W ("ERROR: " + $_.Exception.Message) }
finally {
  foreach ($p in @($ph, $pg)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
  try {
    $ctl = Get-ChildItem (Join-Path $game 'control-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2
    foreach ($f in $ctl) { Copy-Item $f.FullName (Join-Path $evd ("log-" + $f.Name)) -Force }
    W ("control logs copied: " + (($ctl | ForEach-Object { $_.Name }) -join ','))
    $an = @()
    foreach ($f in (Get-ChildItem $evd -Filter 'log-control-*.log' -ErrorAction SilentlyContinue)) {
      $txt = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
      $send15 = @($txt | Select-String -Pattern 'SEND RESPONSE.*snapCurMsg=15')
      $retry15 = @($txt | Select-String -Pattern 'RETRY after msg=15')
      $retry = @($txt | Select-String -Pattern 'RETRY after msg=')
      $resp15 = @($txt | Select-String -Pattern 'response: prompt=15')
      $an += [pscustomobject]@{ file = $f.Name; sendSnap15 = $send15.Count; retryFor15 = $retry15.Count; retryAll = $retry.Count; resp15 = $resp15.Count
        send15Samples = @($send15 | Select-Object -Last 8 | ForEach-Object { $_.Line.Trim() })
        retry15Samples = @($retry15 | Select-Object -Last 5 | ForEach-Object { $_.Line.Trim() })
        resp15Samples = @($resp15 | Select-Object -Last 8 | ForEach-Object { $_.Line.Trim() }) }
    }
    $an | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evd 'battle-analysis.json') -Encoding UTF8
    W ("battle analysis: " + (($an | ForEach-Object { "{0} send15={1} retry15={2} resp15={3}" -f $_.file, $_.sendSnap15, $_.retryFor15, $_.resp15 }) -join ' | '))
  } catch { W ("analysis failed: " + $_.Exception.Message) }
  $null = J 'http://127.0.0.1:7788/surrender'; $null = J 'http://127.0.0.1:7789/surrender'
  Start-Sleep -Seconds 1
  Cleanup
  W "evidence: $evd"
  W '=== done ==='
  Write-Output "EVIDENCE_DIR=$evd"
}
