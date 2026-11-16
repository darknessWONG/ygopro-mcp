# bridge/verify-probe-fails.ps1 - task-37 A: LAN verification that /tip probe timeouts no longer
# kill the client (probe-failed is degraded; passive silence guard keeps authority).
#
# Modes:
#   probe   : clients start with YGO_NET_PROBE=1 YGO_NET_PROBE_FAIL_MAX=1. The probe holds one side
#             silent on the opponent's turn for SilentSec (<60s passive guard). Expect:
#               NET probe timeout ... -> NET probe failed ... (defer to passive silence guard)
#               /net.alive=true, no "NET DEAD reason=probe-fails", no disconnect.
#   passive : clients start with YGO_NET_PROBE=0 and stay silent for SilentSec (>=70s). Expect the
#             passive path to still declare dead via "NET DEAD reason=stoc-timeout" (真断线兜底).
#
# ASCII only (PS 5.1). Use -DryRun first.
param(
  [ValidateSet('probe','passive')]
  [string]$Mode = 'probe',
  [string]$Deck = 'battle-test',
  [int]$SilentSec = 12,
  [int]$MaxMinutes = 2,
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
$evd  = Join-Path $root ("ranked\logs\probe-fails-$Mode-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$runlog = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $runlog -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

function Cleanup {
  Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'probe-fails-probe|verify-probe-fails' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Launch([int]$ctl, [string]$name) {
  $bat = Join-Path $env:TEMP ("launch-probefails-$name-$ctl.cmd")
  $lines = @('@echo off',
             "set YGO_CONTROL_PORT=$ctl",
             'set YGO_CTRL_DEBUG=1',
             'set YGO_SUPPRESS_MODALS=1',
             'set YGO_TP=1',
             'set YGO_SIDE_AUTO=1')
  if ($Mode -eq 'probe') { $lines += 'set YGO_NET_PROBE=1'; $lines += 'set YGO_NET_PROBE_FAIL_MAX=1' }
  else { $lines += 'set YGO_NET_PROBE=0' }
  $lines += "cd /d `"$game`""
  $lines += ("start `"`" `"$exe`" -d " + $Deck + " -k")
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
  W "=== DRY RUN mode=$Mode (no client started) ==="
  W ("exe exists=" + (Test-Path $exe) + " path=" + $exe)
  W ("probe driver exists=" + (Test-Path (Join-Path $root 'bridge\probe-fails-probe.mjs')))
  if (Test-Path $exe) { $f = Get-Item $exe; W ("exe fingerprint=" + $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + $f.Length) }
  W ("running YGOPro=" + @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue).Count + " node=" + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count)
  $busy = @(); foreach ($p in @(7788, 7789, $Port)) { if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $busy += $p } }
  $busyTxt = 'none'; if ($busy.Count -gt 0) { $busyTxt = ($busy -join ',') }
  W ("listening ports among 7788/7789/" + $Port + " : " + $busyTxt)
  if ($Mode -eq 'probe') { W "client env: YGO_NET_PROBE=1 YGO_NET_PROBE_FAIL_MAX=1 (silent ${SilentSec}s on opponent turn)" }
  else { W "client env: YGO_NET_PROBE=0 (silent ${SilentSec}s, expect passive NET DEAD)" }
  W "dry-run done"
  Write-Output "DRYRUN_OK"
  exit 0
}

try {
  W "=== verify probe-fails $stamp mode=$Mode deck=$Deck silentSec=$SilentSec maxMin=$MaxMinutes ==="
  W ("exe=" + (Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + (Get-Item $exe).Length)
  Cleanup
  if (-not (Launch 7788 'host')) { throw 'host launch failed' }
  W ("host /host -> " + (J ("http://127.0.0.1:7788/host?match=1&port=" + $Port)))
  Start-Sleep -Seconds 3
  if (-not (Launch 7789 'guest')) { throw 'guest launch failed' }
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
    $null = J 'http://127.0.0.1:7788/ready'; $null = J 'http://127.0.0.1:7789/ready'; $null = J 'http://127.0.0.1:7788/start'
    $hs = JS 'http://127.0.0.1:7788/state'; $gs = JS 'http://127.0.0.1:7789/state'
    if ($hs -and $hs.started -and $gs -and $gs.started) { $started = $true; W "duel started at t+${i}s"; break }
  }
  if (-not $started) { throw 'duel did not start' }

  $drvArgs = @((Join-Path $root 'bridge\probe-fails-probe.mjs'), '--dir', $evd, '--max-min', $MaxMinutes, '--silent-sec', $SilentSec, '--side', 'host')
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
      $to = @($txt | Select-String -Pattern 'NET probe timeout')
      $failed = @($txt | Select-String -Pattern 'NET probe failed|NET probe deferred')
      $probeDead = @($txt | Select-String -Pattern 'NET DEAD reason=probe-fails')
      $netDead = @($txt | Select-String -Pattern 'NET DEAD reason=')
      $disconnected = @($txt | Select-String -Pattern 'NET disconnected')
      $reply = @($txt | Select-String -Pattern 'NET probe reply')
      $an += [pscustomobject]@{
        file = $f.Name
        probeTimeouts = $to.Count
        probeFailedDeferred = $failed.Count
        probeDeadLines = $probeDead.Count
        netDeadLines = $netDead.Count
        disconnectLines = $disconnected.Count
        probeReplyLines = $reply.Count
        timeoutSamples = @($to | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() })
        failedSamples = @($failed | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() })
        netDeadSamples = @($netDead | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() })
      }
    }
    $an | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evd 'probe-analysis.json') -Encoding UTF8
    W ("probe analysis: " + (($an | ForEach-Object { "{0} probeTimeout={1} failed={2} probeDead={3} netDead={4} disconnect={5}" -f $_.file, $_.probeTimeouts, $_.probeFailedDeferred, $_.probeDeadLines, $_.netDeadLines, $_.disconnectLines }) -join ' | '))
  } catch { W ("probe analysis failed: " + $_.Exception.Message) }

  try {
    $ga = Get-Content (Join-Path $evd 'probe-analysis.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $to = (@($ga) | Measure-Object -Property probeTimeouts -Sum).Sum
    $failed = (@($ga) | Measure-Object -Property probeFailedDeferred -Sum).Sum
    $probeDead = (@($ga) | Measure-Object -Property probeDeadLines -Sum).Sum
    $netDead = (@($ga) | Measure-Object -Property netDeadLines -Sum).Sum
    $disc = (@($ga) | Measure-Object -Property disconnectLines -Sum).Sum
    $ps = Get-Content (Join-Path $evd 'probe-summary.json') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($Mode -eq 'probe') {
      if ($to -ge 1 -and $failed -ge 1 -and $probeDead -eq 0 -and $disc -eq 0) { $verdict = 'PASS'; $why = "timeouts=$to failedDeferred=$failed probeDead=0 disconnect=0" }
      else { $verdict = 'FAIL'; $why = "timeouts=$to failedDeferred=$failed probeDead=$probeDead netDead=$netDead disconnect=$disc" }
    } else {
      if ($netDead -ge 1 -and $probeDead -eq 0) { $verdict = 'PASS'; $why = "passive NET DEAD observed ($netDead), no probe-fails reason" }
      elseif ($disc -ge 1 -and $probeDead -eq 0) { $verdict = 'PASS'; $why = "passive path disconnected ($disc), no probe-fails reason" }
      else { $verdict = 'FAIL'; $why = "passive: netDead=$netDead probeDead=$probeDead disconnect=$disc" }
    }
  } catch { $verdict = 'FAIL'; $why = 'verdict error: ' + $_.Exception.Message }
  W ("VERDICT mode=$Mode : $verdict ($why)")
  ([pscustomobject]@{ mode = $Mode; verdict = $verdict; why = $why }) | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $evd 'VERDICT.json') -Encoding UTF8

  $null = J 'http://127.0.0.1:7788/surrender'; $null = J 'http://127.0.0.1:7789/surrender'
  Start-Sleep -Seconds 1
  Cleanup
  W "evidence: $evd"
  W '=== done ==='
  Write-Output "EVIDENCE_DIR=$evd"
}
