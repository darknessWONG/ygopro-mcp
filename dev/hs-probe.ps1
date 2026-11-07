# bridge/hs-probe.ps1 - one attempt with detailed HS/ready diagnostics (client pre-launched, join via API).
param([int]$MaxPlayMinutes = 10, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\hsprobe-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function Get-Json([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== hs probe $stamp ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
cmd /c start "" /D $game "$exe" -d $Deck -k
Start-Sleep -Seconds 9
W ("health: " + (Get-Json 'http://127.0.0.1:7788/health' | ConvertTo-Json -Compress))

$room = $null
for ($i = 1; $i -le 6; $i++) {
  $raw = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
  $c = $null; try { $c = $raw | ConvertFrom-Json } catch {}
  if ($c -and $c.password -and -not $c.stale) { $room = $c; break }
  W 'stale/no room, wait 20s'; Start-Sleep -Seconds 20
}
if (-not $room) { W 'NO ROOM'; return }
W ("room passlen={0}" -f $room.password.Length)
$joinUrl = "http://127.0.0.1:7788/join?ip={0}&port={1}&pass={2}" -f $room.address, $room.port, [uri]::EscapeDataString($room.password)
W ("join -> " + (Get-Json $joinUrl))

$started = $false; $readySends = 0
for ($i = 1; $i -le 20; $i++) {
  Start-Sleep -Seconds 2
  $hs = Get-Json 'http://127.0.0.1:7788/hs'
  $stoc = Get-Json 'http://127.0.0.1:7788/stoc'
  $state = Get-Json 'http://127.0.0.1:7788/state'
  $hsText = if ($hs) { ($hs.statuses -join ',') } else { '?' }
  $stocText = if ($stoc) { ($stoc.packets -join ',') } else { '?' }
  $rd = 'skip'
  if ($readySends -lt 6 -and $i -ge 2) {
    $r = Get-Json 'http://127.0.0.1:7788/ready'
    $readySends++
    $rd = if ($r) { ($r | ConvertTo-Json -Compress) } else { 'ERR' }
  }
  W ("t+{0}s ready#{1}->{2} started={3} msg={4} deck={5} hs=[{6}] stoc=[{7}]" -f ($i*2), $readySends, $rd, $state.started, $state.curMsg, $state.deckMain, $hsText, $stocText)
  if ($state.started) { $started = $true; break }
}

if ($started) {
  W 'duel started -> heuristic bot'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  W 'bot returned'
} else { W 'no duel start' }
W "log: $log"
