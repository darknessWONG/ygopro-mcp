# reconnect-lab.ps1 - local LAN disconnect/rejoin experiment (task-26)
# Runs the WHOLE scenario in one process so the two client processes stay alive.
# Outputs go to ranked\logs\reconnect3-<stamp>\ (progress.log + json snapshots + logs).
param(
  [int]$TurnTarget = 3,
  [int]$MaxWaitSec = 120,
  [string]$Deck = 'Blackwing'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$gameDir = Join-Path $root 'mycard-bot\game'
$exe = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$hostCmd = Join-Path $PSScriptRoot 'lan-host.cmd'
$guestCmd = Join-Path $PSScriptRoot 'lan-guest.cmd'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $root ("ranked\logs\reconnect3-$stamp")
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$progress = Join-Path $dir 'progress.log'
function P([string]$m) {
  $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m
  Add-Content -Path $progress -Value $line -Encoding UTF8
  Write-Host $line
}
function J([string]$u) {
  try { return (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 3).Content } catch { return $null }
}
function Kill-YgoProcs {
  @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue |
     Where-Object { $_.Path -like '*mycard-client*' -or $_.Path -like '*mycard-bot\game*' }) |
    ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; P ("killed ygopro pid=" + $_.Id) } catch {} }
}
function Kill-NodeBots {
  @(Get-Process -Name node -ErrorAction SilentlyContinue) | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
}
function Launch-Client([string]$cmdFile, [string]$hooks) {
  $args = '/c ' + $cmdFile + ' ' + $hooks + ' ' + $Deck
  Start-Process -FilePath $env:ComSpec -ArgumentList $args -WindowStyle Hidden | Out-Null
}
function Launch-GuestAs([string]$nick) {
  # custom nickname (control group): same launcher flags as lan-guest.cmd
  $env:YGO_CONTROL_PORT = '7789'
  $env:YGO_CTRL_DEBUG = '1'
  $env:YGO_HOOKS = 'all'
  $a = @('-j', '-h', '127.0.0.1', '-p', '7911', '-n', $nick, '-d', $Deck, '-k')
  Start-Process -FilePath $exe -ArgumentList $a -WorkingDirectory $gameDir -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 1
  Remove-Item Env:YGO_CONTROL_PORT,Env:YGO_CTRL_HOOKS,Env:YGO_HOOKS -ErrorAction SilentlyContinue
}
function Get-Pids {
  @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue |
     Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -ExpandProperty Id)
}
function Start-Bot([int]$port, [string]$tag) {
  $env:CONTROL_URL = "http://127.0.0.1:$port"
  $env:MAX_MINUTES = '6'
  $p = Start-Process -FilePath 'node' -ArgumentList 'bridge/policy-semantic.mjs' `
      -WorkingDirectory $root `
      -RedirectStandardOutput (Join-Path $dir ("bot-$tag.out.log")) `
      -RedirectStandardError (Join-Path $dir ("bot-$tag.err.log")) `
      -PassThru -WindowStyle Hidden
  Remove-Item Env:CONTROL_URL,Env:MAX_MINUTES -ErrorAction SilentlyContinue
  return $p
}
function Snap([string]$tag, [int]$port = 7788) {
  $s = J ("http://127.0.0.1:$port/state")
  if ($s) { Set-Content -Path (Join-Path $dir ("$tag-state-p$port.json")) -Value $s -Encoding UTF8 }
  return $s
}
function Summarize([string]$json) {
  if (-not $json) { return 'DOWN' }
  try {
    $j = $json | ConvertFrom-Json
    return ('started=' + $j.started + ' inDuel=' + $j.inDuel + ' turn=' + $j.turn + ' phase=' + $j.phaseName +
            ' lp=' + ($j.lp -join '/') + ' win=' + $j.winPlayer + '/' + $j.winReason +
            ' mySeat=' + $j.mySeat + ' chain=' + $j.chainDepth + ' curMsg=' + $j.curMsg +
            ' msgs=' + $j.pipeline.msgCount + ' stoc=' + $j.pipeline.lastStocName)
  } catch { return 'PARSE-FAIL' }
}
function Find-CtlLog([int]$procId) {
  $p = Join-Path $gameDir ("control-$pid.log")
  if (Test-Path $p) { return $p }
  return $null
}

P ("=== reconnect-lab start stamp=$stamp dir=$dir ===")
Kill-NodeBots
Kill-YgoProcs
Start-Sleep -Seconds 2
P ("precheck: ygopro=" + @(Get-Pids).Count + " node=" + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count)

# ---- 1) launch host + guest ----
Launch-Client $hostCmd 'msganalyze'
Start-Sleep -Seconds 9
$hostPid = @(Get-Pids)
P ("host pids=" + ($hostPid -join ',') + " health7788=" + (J 'http://127.0.0.1:7788/health'))
Launch-Client $guestCmd 'all'
Start-Sleep -Seconds 11
$all = @(Get-Pids)
$guestPid = @($all | Where-Object { $hostPid -notcontains $_ })
P ("guest pids=" + ($guestPid -join ',') + " health7789=" + (J 'http://127.0.0.1:7789/health'))
if ($hostPid.Count -eq 0 -or $guestPid.Count -eq 0) { P 'FATAL: clients did not start'; Kill-NodeBots; Kill-YgoProcs; exit 1 }
$hostLogPath = Find-CtlLog ([int]$hostPid[0])
$guestLogPath = Find-CtlLog ([int]$guestPid[0])
P ("ctl logs: host=" + (Split-Path -Leaf $hostLogPath) + " guest=" + (Split-Path -Leaf $guestLogPath))

# ---- 2) deck/ready/start ----
$enc = [uri]::EscapeDataString($Deck)
$null = Invoke-WebRequest ("http://127.0.0.1:7788/deck?name=" + $enc) -UseBasicParsing -TimeoutSec 5
$null = Invoke-WebRequest ("http://127.0.0.1:7789/deck?name=" + $enc) -UseBasicParsing -TimeoutSec 5
$null = Invoke-WebRequest 'http://127.0.0.1:7788/ready' -UseBasicParsing -TimeoutSec 5
$null = Invoke-WebRequest 'http://127.0.0.1:7789/ready' -UseBasicParsing -TimeoutSec 5
Start-Sleep -Seconds 2
P ("lobby=" + (J 'http://127.0.0.1:7788/lobby'))
$null = Invoke-WebRequest 'http://127.0.0.1:7788/start' -UseBasicParsing -TimeoutSec 5

# ---- 3) bots + wait for turn >= TurnTarget ----
$botH = Start-Bot 7788 'h'
$botG = Start-Bot 7789 'g'
P ("bots: h=" + $botH.Id + " g=" + $botG.Id + " node=" + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count)
$reached = $false
$deadline = (Get-Date).AddSeconds($MaxWaitSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $g = J 'http://127.0.0.1:7789/state'; $h = J 'http://127.0.0.1:7788/state'
  if (-not $g -or -not $h) { continue }
  try { $gj = $g | ConvertFrom-Json } catch { continue }
  if ($gj.started -and $gj.turn -ge $TurnTarget) {
    $reached = $true
    P ("PRE guest: " + (Summarize $g))
    P ("PRE host : " + (Summarize $h))
    Snap 'pre' 7789; Snap 'pre' 7788
    $pg = J 'http://127.0.0.1:7789/prompt'; if ($pg) { Set-Content -Path (Join-Path $dir 'pre-prompt-p7789.json') -Value $pg -Encoding UTF8 }
    $ph = J 'http://127.0.0.1:7788/prompt'; if ($ph) { Set-Content -Path (Join-Path $dir 'pre-prompt-p7788.json') -Value $ph -Encoding UTF8 }
    break
  }
}
P ("turn>= $TurnTarget reached=" + $reached)
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot.ps1') -Tag 'r3-pre' -OutDir $dir | Out-Null
P ('screenshot r3-pre done')

# ---- 4) hard kill guest ----
$gp = [int]$guestPid[0]
P ("=== KILL guest pid=$gp (host $($hostPid[0]) stays) ===")
$hostLogBefore = if ($hostLogPath) { (Get-Item $hostLogPath).Length } else { 0 }
try { Stop-Process -Id $gp -Force -ErrorAction Stop; P 'guest killed' } catch { P ('kill failed: ' + $_.Exception.Message) }
Start-Sleep -Milliseconds 800
$h1 = Snap 'kill1' 7788
P ("t+0.8s host health=" + (J 'http://127.0.0.1:7788/health') + " | " + (Summarize $h1))
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot.ps1') -Tag 'r3-kill' -OutDir $dir | Out-Null
Start-Sleep -Seconds 2
$h2 = Snap 'kill3' 7788
P ("t+3s   host: " + (Summarize $h2))
Start-Sleep -Seconds 2
$h3 = Snap 'kill5' 7788
P ("t+5s   host: " + (Summarize $h3))
# host log lines around the disconnect
if ($hostLogPath) {
  $newLines = @()
  try { $newLines = Get-Content $hostLogPath | Where-Object { $_ -match 'MSG_WIN|STOC_HS_PLAYER_CHANGE|disconnect|PLAYER|STOC_ERROR|end' } | Select-Object -Last 12 } catch {}
  Set-Content -Path (Join-Path $dir 'host-log-kill-window.txt') -Value ($newLines -join "`r`n") -Encoding UTF8
  P ('host log kill window saved (' + $newLines.Count + ' lines)')
}

# ---- 5) rejoin with SAME nickname ----
P '=== REJOIN #1: same nickname (GuestB) ==='
Launch-Client $guestCmd 'all'
$up = $false
for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; if (J 'http://127.0.0.1:7789/health') { $up = $true; break } }
P ("same-nick client control up=" + $up + " after ~" + ($i + 1) + "s")
$newAll = @(Get-Pids)
$newGuest = @($newAll | Where-Object { $hostPid -notcontains $_ })
P ("after rejoin pids: all=" + ($newAll -join ',') + " newGuest=" + ($newGuest -join ','))
$newGuestLog = if ($newGuest.Count -gt 0) { Find-CtlLog ([int]$newGuest[0]) } else { $null }
if ($up) {
  try { $j1 = Invoke-WebRequest 'http://127.0.0.1:7789/join?ip=127.0.0.1&port=7911&pass=' -UseBasicParsing -TimeoutSec 5; P ('/join -> ' + $j1.StatusCode) } catch { P ('/join error: ' + $_.Exception.Message) }
  Start-Sleep -Seconds 2
  try { $r1 = Invoke-WebRequest 'http://127.0.0.1:7789/ready' -UseBasicParsing -TimeoutSec 5; P ('/ready -> ' + $r1.StatusCode) } catch { P ('/ready error: ' + $_.Exception.Message) }
  for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 2
    $gs = Snap ("rejoin" + $i) 7789
    P ("rejoin+" + ($i * 2) + "s guest: " + (Summarize $gs) + " | host: " + (Summarize (J 'http://127.0.0.1:7788/state')))
  }
  Set-Content -Path (Join-Path $dir 'rejoin-pids.txt') -Value ('host=' + ($hostPid -join ',') + ' newGuest=' + ($newGuest -join ',')) -Encoding ASCII
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot.ps1') -Tag 'r3-rejoin' -OutDir $dir | Out-Null
}
P ('== done ==')
# keep processes alive for a moment then clean up
Start-Sleep -Seconds 2
Kill-NodeBots
Kill-YgoProcs
P ('cleanup done')
