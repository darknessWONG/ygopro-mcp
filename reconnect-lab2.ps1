# reconnect-lab2.ps1 - phase 2 of task-26:
#   1) fresh duel -> kill guest -> rejoin same nick (expect: TCP up but no STOC)
#   2) control group: rejoin with a DIFFERENT nickname (GuestX)
#   3) clean new game: restart host, then both deck/ready/start -> can clients rejoin a NEW duel?
param(
  [int]$TurnTarget = 2,
  [int]$MaxWaitSec = 100,
  [string]$Deck = 'Blackwing',
  [string]$AltNick = 'GuestX'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$gameDir = Join-Path $root 'mycard-bot\game'
$exe = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$hostCmd = Join-Path $PSScriptRoot 'lan-host.cmd'
$guestCmd = Join-Path $PSScriptRoot 'lan-guest.cmd'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $root ("ranked\logs\reconnect4-$stamp")
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$progress = Join-Path $dir 'progress.log'
function P([string]$m) { $l = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m; Add-Content -Path $progress -Value $l -Encoding UTF8; Write-Host $l }
function J([string]$u) { try { return (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 3).Content } catch { return $null } }
function Kill-YgoProcs { @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' -or $_.Path -like '*mycard-bot\game*' }) | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} } }
function Kill-NodeBots { @(Get-Process -Name node -ErrorAction SilentlyContinue) | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} } }
function Get-Pids { @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*mycard-client*' } | Select-Object -ExpandProperty Id) }
function Launch-Client([string]$cmdFile, [string]$hooks) { Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ' + $cmdFile + ' ' + $hooks + ' ' + $Deck) -WindowStyle Hidden | Out-Null }
function Launch-GuestAs([string]$nick) {
  $oldui = $env:YGO_CONTROL_PORT; $olddbg = $env:YGO_CTRL_DEBUG; $oldhk = $env:YGO_HOOKS
  $env:YGO_CONTROL_PORT = '7789'; $env:YGO_CTRL_DEBUG = '1'; $env:YGO_HOOKS = 'all'
  Start-Process -FilePath $exe -ArgumentList @('-j','-h','127.0.0.1','-p','7911','-n',$nick,'-d',$Deck,'-k') -WorkingDirectory $gameDir -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 1
  if ($null -eq $oldui) { Remove-Item Env:YGO_CONTROL_PORT -ErrorAction SilentlyContinue } else { $env:YGO_CONTROL_PORT = $oldui }
  if ($null -eq $olddbg) { Remove-Item Env:YGO_CTRL_DEBUG -ErrorAction SilentlyContinue } else { $env:YGO_CTRL_DEBUG = $olddbg }
  if ($null -eq $oldhk) { Remove-Item Env:YGO_HOOKS -ErrorAction SilentlyContinue } else { $env:YGO_HOOKS = $oldhk }
}
function Start-Bot([int]$port, [string]$tag) {
  $ou = $env:CONTROL_URL; $om = $env:MAX_MINUTES
  $env:CONTROL_URL = "http://127.0.0.1:$port"; $env:MAX_MINUTES = '6'
  $p = Start-Process -FilePath 'node' -ArgumentList 'bridge/policy-semantic.mjs' -WorkingDirectory $root `
       -RedirectStandardOutput (Join-Path $dir ("bot-$tag.out.log")) -RedirectStandardError (Join-Path $dir ("bot-$tag.err.log")) -PassThru -WindowStyle Hidden
  if ($null -eq $ou) { Remove-Item Env:CONTROL_URL -ErrorAction SilentlyContinue } else { $env:CONTROL_URL = $ou }
  if ($null -eq $om) { Remove-Item Env:MAX_MINUTES -ErrorAction SilentlyContinue } else { $env:MAX_MINUTES = $om }
  return $p
}
function Snap([string]$tag, [int]$port) { $s = J ("http://127.0.0.1:$port/state"); if ($s) { Set-Content -Path (Join-Path $dir ("$tag-state-p$port.json")) -Value $s -Encoding UTF8 }; return $s }
function Sum([string]$json) {
  if (-not $json) { return 'DOWN' }
  try { $j = $json | ConvertFrom-Json
    return ('started=' + $j.started + ' inDuel=' + $j.inDuel + ' turn=' + $j.turn + ' lp=' + ($j.lp -join '/') + ' win=' + $j.winPlayer + '/' + $j.winReason + ' seat=' + $j.mySeat + ' msgs=' + $j.pipeline.msgCount + ' stoc=' + $j.pipeline.lastStocName)
  } catch { return 'PARSE-FAIL' }
}
function Wait-Health([int]$port, [int]$sec) { for ($i = 0; $i -lt $sec; $i++) { Start-Sleep -Seconds 1; if (J ("http://127.0.0.1:$port/health")) { return $true } }; return $false }
function Find-Ctl([int]$procId) { $p = Join-Path $gameDir ("control-$pid.log"); if (Test-Path $p) { return $p } else { return $null } }
function Do-Ready([int]$port, [string]$deck) {
  $enc = [uri]::EscapeDataString($deck)
  try { $null = Invoke-WebRequest ("http://127.0.0.1:$port/deck?name=" + $enc) -UseBasicParsing -TimeoutSec 5 } catch { P ('deck err p' + $port) }
  Start-Sleep -Milliseconds 800
  try { $null = Invoke-WebRequest ("http://127.0.0.1:$port/ready") -UseBasicParsing -TimeoutSec 5 } catch { P ('ready err p' + $port) }
}

P ("=== reconnect-lab2 start dir=$dir ===")
Kill-NodeBots; Kill-YgoProcs; Start-Sleep -Seconds 2
Launch-Client $hostCmd 'msganalyze'; Start-Sleep -Seconds 9
$hostPid = @(Get-Pids); P ('host=' + ($hostPid -join ',') + ' health7788=' + (J 'http://127.0.0.1:7788/health'))
Launch-Client $guestCmd 'all'; Start-Sleep -Seconds 11
$all = @(Get-Pids); $guestPid = @($all | Where-Object { $hostPid -notcontains $_ })
P ('guest=' + ($guestPid -join ',') + ' health7789=' + (J 'http://127.0.0.1:7789/health'))
Do-Ready 7788 $Deck; Do-Ready 7789 $Deck; Start-Sleep -Seconds 2
P ('lobby=' + (J 'http://127.0.0.1:7788/lobby'))
try { $null = Invoke-WebRequest 'http://127.0.0.1:7788/start' -UseBasicParsing -TimeoutSec 5 } catch { P 'start err' }
$botH = Start-Bot 7788 'h'; $botG = Start-Bot 7789 'g'
P ('bots h=' + $botH.Id + ' g=' + $botG.Id)
$reached = $false; $dl = (Get-Date).AddSeconds($MaxWaitSec)
while ((Get-Date) -lt $dl) {
  Start-Sleep -Seconds 2
  $g = J 'http://127.0.0.1:7789/state'
  if (-not $g) { continue }
  try { $gj = $g | ConvertFrom-Json } catch { continue }
  if ($gj.started -and $gj.turn -ge $TurnTarget) { $reached = $true; P ('PRE guest: ' + (Sum $g)); P ('PRE host: ' + (Sum (J 'http://127.0.0.1:7788/state'))); Snap 'pre' 7789; Snap 'pre' 7788; break }
}
P ('reached=' + $reached)
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot.ps1') -Tag 'r4-pre' -OutDir $dir | Out-Null

# ---- 1) kill guest, rejoin same nick ----
$gp = [int]$guestPid[0]
P ('KILL guest pid=' + $gp)
Stop-Process -Id $gp -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
P ('after kill host: ' + (Sum (Snap 'kill' 7788)))
Launch-Client $guestCmd 'all'
$up = Wait-Health 7789 30
$newAll = @(Get-Pids); $g1 = @($newAll | Where-Object { $hostPid -notcontains $_ })
P ('rejoin#1 same-nick up=' + $up + ' pid=' + ($g1 -join ','))
$g1log = if ($g1.Count -gt 0) { Find-Ctl ([int]$g1[0]) } else { $null }
if ($up) {
  try { $null = Invoke-WebRequest 'http://127.0.0.1:7789/join?ip=127.0.0.1&port=7911&pass=' -UseBasicParsing -TimeoutSec 5; P 'rejoin#1 /join ok' } catch { P ('rejoin#1 /join err') }
  Start-Sleep -Seconds 2
  try { $null = Invoke-WebRequest 'http://127.0.0.1:7789/ready' -UseBasicParsing -TimeoutSec 5; P 'rejoin#1 /ready ok' } catch { P 'rejoin#1 /ready err' }
  for ($i = 1; $i -le 5; $i++) { Start-Sleep -Seconds 2; P ('rejoin#1 +' + ($i*2) + 's guest: ' + (Sum (J 'http://127.0.0.1:7789/state'))) }
  P ('rejoin#1 host lobby=' + (J 'http://127.0.0.1:7788/lobby'))
  P ('rejoin#1 guest lobby=' + (J 'http://127.0.0.1:7789/lobby'))
  Snap 'rejoin1' 7789
}

# ---- 2) control group: different nickname ----
P ('=== CONTROL: rejoin with nickname ' + $AltNick + ' ===')
foreach ($x in @(Get-Pids)) { if ($hostPid -notcontains $x) { Stop-Process -Id $x -Force -ErrorAction SilentlyContinue; P ('killed guest ' + $x) } }
Start-Sleep -Seconds 3
Launch-GuestAs $AltNick
$up2 = Wait-Health 7789 30
$g2 = @(@(Get-Pids) | Where-Object { $hostPid -notcontains $_ })
P ('control up=' + $up2 + ' pid=' + ($g2 -join ','))
$g2log = if ($g2.Count -gt 0) { Find-Ctl ([int]$g2[0]) } else { $null }
if ($up2) {
  try { $null = Invoke-WebRequest 'http://127.0.0.1:7789/join?ip=127.0.0.1&port=7911&pass=' -UseBasicParsing -TimeoutSec 5; P 'control /join ok' } catch { P 'control /join err' }
  Start-Sleep -Seconds 2
  try { $null = Invoke-WebRequest 'http://127.0.0.1:7789/ready' -UseBasicParsing -TimeoutSec 5; P 'control /ready ok' } catch { P 'control /ready err' }
  for ($i = 1; $i -le 4; $i++) { Start-Sleep -Seconds 2; P ('control +' + ($i*2) + 's guest: ' + (Sum (J 'http://127.0.0.1:7789/state'))) }
  P ('control host lobby=' + (J 'http://127.0.0.1:7788/lobby'))
  P ('control guest lobby=' + (J 'http://127.0.0.1:7789/lobby'))
  Snap 'control' 7789
}

# ---- 3) clean new game: fresh host + existing guest ----
P '=== CLEAN NEW GAME: restart host, deck/ready/start with current guest ==='
foreach ($x in @(Get-Pids)) { if ($hostPid -contains $x) { Stop-Process -Id $x -Force -ErrorAction SilentlyContinue; P ('killed old host ' + $x) } }
Start-Sleep -Seconds 3
Launch-Client $hostCmd 'msganalyze'
$upNewHost = Wait-Health 7788 30
$hostPid2 = @(Get-Pids)
P ('new host up=' + $upNewHost + ' pids=' + ($hostPid2 -join ',') + ' health7789=' + (J 'http://127.0.0.1:7789/health'))
Do-Ready 7788 $Deck; Do-Ready 7789 $Deck; Start-Sleep -Seconds 2
P ('new lobby=' + (J 'http://127.0.0.1:7788/lobby'))
try { $null = Invoke-WebRequest 'http://127.0.0.1:7788/start' -UseBasicParsing -TimeoutSec 5; P 'new /start ok' } catch { P 'new /start err' }
$newStarted = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 2
  $gs = J 'http://127.0.0.1:7789/state'; $hs = J 'http://127.0.0.1:7788/state'
  try { $gj = $gs | ConvertFrom-Json; $hj = $hs | ConvertFrom-Json } catch { continue }
  if ($gj.started -and $hj.started) { $newStarted = $true; P ('NEW GAME started! guest turn=' + $gj.turn + ' mySeat=' + $gj.mySeat + ' | host turn=' + $hj.turn); break }
}
P ('new game started=' + $newStarted)
Snap 'newgame' 7789; Snap 'newgame' 7788
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot.ps1') -Tag 'r4-newgame' -OutDir $dir | Out-Null
P ('=== done ===')
Start-Sleep -Seconds 2
Kill-NodeBots; Kill-YgoProcs
P 'cleanup done'
