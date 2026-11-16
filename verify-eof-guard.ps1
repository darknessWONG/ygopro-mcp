# bridge/verify-eof-guard.ps1 - LAN verification for the prompt-idle EOF guard (task from lead 2026-11-16)
#
# Scenario being verified: a prompt is published but the caller (LLM/agent) never answers -> after
# ~90s the server EOF-kicks us. poc adds YGO_PROMPT_AUTO_DEFAULT_MS (default 60000, 0=off),
# a 45s `PROMPT idle warning` log and `/prompt.awaitingSinceMs`.
#
# Modes:
#   positive : default guard on. Hold a prompt for IdleSec (default 70s) without answering ->
#              expect `PROMPT idle warning` (~45s) -> `PROMPT auto-default ...` (~60s) -> prompt
#              advances and the duel continues, NO eof.
#   negative : same hold but clients started with YGO_PROMPT_AUTO_DEFAULT_MS=0 -> expect NO
#              auto-default; server should still EOF after ~90s (confirms the guard is what saves us).
#   fast     : answer prompts quickly for MaxMinutes -> expect NO auto-default and
#              `awaitingSinceMs` visible in /prompt (normal path not affected).
#
# ASCII only (PS 5.1 reads this as ANSI). Use -DryRun first.
param(
  [ValidateSet('positive','negative','fast')]
  [string]$Mode = 'positive',
  [string]$Deck = 'battle-test',
  [int]$IdleSec = 70,
  [int]$MaxMinutes = 3,
  [int]$Port = 7911,
  # optional client env overrides for faster testing (empty = client default)
  [string]$AutoDefaultMs = '',
  [string]$WarnMs = '',
  # exe to launch (default: the formal build). Use a copy build (e.g. mycard-client-build\...)
  # so verification never locks / touches the formal YGOPro.exe. cwd stays mycard-bot\game.
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
$exeIsDefault = ($exe -eq [System.IO.Path]::GetFullPath($exeDefault))
$game = Join-Path $root 'mycard-bot\game'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evd  = Join-Path $root ("ranked\logs\eof-guard-$Mode-$stamp")
New-Item -ItemType Directory -Force -Path $evd | Out-Null
$runlog = Join-Path $evd 'run.log'
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $runlog -Value $line -Encoding UTF8; Write-Host $line }
function J([string]$u) { try { return (& curl.exe -s --max-time 5 $u) } catch { return $null } }
function JS([string]$u) { $r = J $u; if (-not $r) { return $null }; try { return $r | ConvertFrom-Json } catch { return $null } }

function Cleanup {
  # Only kill clients launched from *this* exe path, so a formal-build client that someone else
  # is using (pid 21528 case) is never touched; node helpers of this harness are killed by cmdline.
  Get-Process YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'eof-guard-probe|verify-eof-guard|policy-semantic' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

function Launch([int]$ctl, [string]$name, [string[]]$extra) {
  $bat = Join-Path $env:TEMP ("launch-eofguard-$name-$ctl.cmd")
  $lines = @('@echo off',
             "set YGO_CONTROL_PORT=$ctl",
             'set YGO_CTRL_DEBUG=1',
             'set YGO_SUPPRESS_MODALS=1',
             'set YGO_NET_PROBE=0',
             'set YGO_TP=1',
             'set YGO_SIDE_AUTO=1')
  if ($Mode -eq 'negative') { $lines += 'set YGO_PROMPT_AUTO_DEFAULT_MS=0' }
  elseif ($AutoDefaultMs -ne '') { $lines += ("set YGO_PROMPT_AUTO_DEFAULT_MS=" + $AutoDefaultMs) }
  if ($WarnMs -ne '') { $lines += ("set YGO_PROMPT_IDLE_WARN_MS=" + $WarnMs) }
  $lines += "cd /d `"$game`""
  $lines += ("start `"`" `"$exe`" " + ($extra -join ' '))
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
  W ("exe source=" + $(if ($exeIsDefault) { 'FORMAL build (lock risk while poc compiles)' } else { 'COPY build (formal exe untouched)' }))
  W ("client cwd=" + $game + " exists=" + (Test-Path $game))
  W ("probe exists=" + (Test-Path (Join-Path $root 'bridge\eof-guard-probe.mjs')))
  if (Test-Path $exe) {
    $b = [System.IO.File]::ReadAllBytes($exe); $s = [System.Text.Encoding]::ASCII.GetString($b)
    W ("exe has 'PROMPT auto-default'=" + $s.Contains('PROMPT auto-default') + " 'awaitingSinceMs'=" + $s.Contains('awaitingSinceMs') + " 'YGO_PROMPT_AUTO_DEFAULT_MS'=" + $s.Contains('YGO_PROMPT_AUTO_DEFAULT_MS'))
    W ("exe fingerprint=" + (Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + (Get-Item $exe).Length)
  } else { W "WARNING: exe path does not exist" }
  W ("running YGOPro=" + @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue).Count + " node=" + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count)
  $busy = @()
  foreach ($p in @(7788, 7789, $Port)) {
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $busy += $p }
  }
  $busyTxt = 'none'; if ($busy.Count -gt 0) { $busyTxt = ($busy -join ',') }
  W ("listening ports among 7788/7789/" + $Port + " : " + $busyTxt)
  W "cleanup policy: only clients whose Path == the -Exe above are stopped (formal pid 21528 untouched when -Exe is a copy)"
  if ($Mode -eq 'negative') { W "client env: YGO_PROMPT_AUTO_DEFAULT_MS=0 (guard off)" }
  elseif ($AutoDefaultMs -ne '') { W ("client env: YGO_PROMPT_AUTO_DEFAULT_MS=" + $AutoDefaultMs + " YGO_PROMPT_IDLE_WARN_MS=" + $WarnMs) }
  else { W "client env: YGO_PROMPT_AUTO_DEFAULT_MS default (60000) / warn 45000" }
  W "plan: launch host/guest -> /host?match=1 -> /join -> deck/ready/start -> probe mode=$Mode idleSec=$IdleSec"
  W "dry-run done"
  Write-Output "DRYRUN_OK"
  exit 0
}

try {
  W "=== verify eof-guard $stamp mode=$Mode deck=$Deck idleSec=$IdleSec port=$Port ==="
  W ("exe=" + (Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " / " + (Get-Item $exe).Length)
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
    $hs = JS 'http://127.0.0.1:7788/state'; $gs = JS 'http://127.0.0.1:7789/state'
    if ($hs -and $hs.started -and $gs -and $gs.started) { $started = $true; W "duel started at t+${i}s"; break }
  }
  if (-not $started) { throw 'duel did not start' }

  $probeArgs = @((Join-Path $root 'bridge\eof-guard-probe.mjs'), '--dir', $evd)
  if ($Mode -eq 'fast') {
    $probeArgs += @('--mode', 'fast', '--max-min', $MaxMinutes)
  } else {
    $probeArgs += @('--mode', 'idle', '--idle-sec', $IdleSec, '--side', 'host', '--max-min', $MaxMinutes)
  }
  W ("probe: node " + ($probeArgs -join ' '))
  $probeOut = & node @probeArgs 2>&1
  $probeOut | ForEach-Object { W ("probe: " + $_) }
}
catch { W ("ERROR: " + $_.Exception.Message) }
finally {
  # save control logs for the two clients of this run
  try {
    $ctl = Get-ChildItem (Join-Path $game 'control-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2
    foreach ($f in $ctl) { Copy-Item $f.FullName (Join-Path $evd ("log-" + $f.Name)) -Force }
    W ("control logs copied: " + (($ctl | ForEach-Object { $_.Name }) -join ','))
  } catch { W ("copy control logs failed: " + $_.Exception.Message) }

  # analyze guard-related log lines
  try {
    $an = @()
    foreach ($f in (Get-ChildItem $evd -Filter 'log-control-*.log' -ErrorAction SilentlyContinue)) {
      $txt = Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
      $warn = @($txt | Select-String -Pattern 'PROMPT idle warning')
      $auto = @($txt | Select-String -Pattern 'PROMPT auto-default')
      $eof  = @($txt | Select-String -Pattern 'NET disconnected reason=eof')
      $since = @($txt | Select-String -Pattern 'awaitingSinceMs')
      $an += [pscustomobject]@{
        file = $f.Name
        idleWarnings = $warn.Count
        autoDefaults = $auto.Count
        eofLines = $eof.Count
        awaitingSinceMsLines = $since.Count
        warningSamples = @($warn | Select-Object -Last 4 | ForEach-Object { $_.Line.Trim() })
        autoDefaultSamples = @($auto | Select-Object -Last 4 | ForEach-Object { $_.Line.Trim() })
        eofSamples = @($eof | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() })
        sinceSamples = @($since | Select-Object -Last 3 | ForEach-Object { $_.Line.Trim() })
      }
    }
    $an | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evd 'guard-analysis.json') -Encoding UTF8
    W ("guard analysis: " + (($an | ForEach-Object { "{0} warn={1} auto={2} eof={3}" -f $_.file, $_.idleWarnings, $_.autoDefaults, $_.eofLines }) -join ' | '))
  } catch { W ("guard analysis failed: " + $_.Exception.Message) }

  # verdict from probe summary + log analysis
  $verdict = 'UNKNOWN'; $verdictWhy = ''
  try {
    $ps = Get-Content (Join-Path $evd 'probe-summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ga = Get-Content (Join-Path $evd 'guard-analysis.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $autoTotal = (@($ga) | Measure-Object -Property autoDefaults -Sum).Sum
    $warnTotal = (@($ga) | Measure-Object -Property idleWarnings -Sum).Sum
    $eofTotal = (@($ga) | Measure-Object -Property eofLines -Sum).Sum
    if ($Mode -eq 'positive') {
      if ($ps.sawPromptAdvance -and -not $ps.sawEof -and $autoTotal -gt 0 -and $warnTotal -gt 0) { $verdict = 'PASS'; $verdictWhy = "prompt advanced after auto-default (t=$($ps.promptAdvancedAt)s), warning=$warnTotal auto=$autoTotal, no eof" }
      elseif ($ps.sawEof) { $verdict = 'FAIL'; $verdictWhy = "got eof at $($ps.eofAtSec)s instead of auto-default (auto=$autoTotal warn=$warnTotal)" }
      else { $verdict = 'FAIL'; $verdictWhy = "no eof, but auto-default/warning/advance missing (warn=$warnTotal auto=$autoTotal advanced=$($ps.sawPromptAdvance))" }
    } elseif ($Mode -eq 'negative') {
      if ($ps.sawEof -and $autoTotal -eq 0) { $verdict = 'PASS'; $verdictWhy = "guard off: eof at $($ps.eofAtSec)s as before, auto-default=$autoTotal" }
      elseif (-not $ps.sawEof -and $autoTotal -eq 0) { $verdict = 'PASS*'; $verdictWhy = "guard off: no auto-default; eof not observed within window (server may kick later)" }
      else { $verdict = 'FAIL'; $verdictWhy = "guard off but auto-default fired (auto=$autoTotal)" }
    } else {
      if ($autoTotal -eq 0 -and $ps.awaitingSinceMsPresent) { $verdict = 'PASS'; $verdictWhy = "fast path unaffected: auto-default=0, awaitingSinceMs present, answered=$($ps.answered)" }
      else { $verdict = 'FAIL'; $verdictWhy = "fast path: auto-default=$autoTotal awaitingSinceMs=$($ps.awaitingSinceMsPresent) answered=$($ps.answered)" }
    }
  } catch { $verdictWhy = "verdict error: " + $_.Exception.Message }
  W ("VERDICT mode=$Mode : $verdict ($verdictWhy)")
  $verdictObj = [pscustomobject]@{ mode = $Mode; verdict = $verdict; why = $verdictWhy }
  $verdictObj | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $evd 'VERDICT.json') -Encoding UTF8

  $null = J 'http://127.0.0.1:7788/surrender'; $null = J 'http://127.0.0.1:7789/surrender'
  Start-Sleep -Seconds 1
  Cleanup
  W "evidence: $evd"
  W '=== done ==='
  Write-Output "EVIDENCE_DIR=$evd"
}
