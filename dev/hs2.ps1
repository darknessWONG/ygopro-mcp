# bridge/hs2.ps1 - one ranked attempt using the proven -j launch, logging HS ready statuses.
param([int]$MaxPlayMinutes = 10, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\hs2-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== hs2 $stamp ==="
Get-Process ygopro,YGOPro,node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$room = $null
for ($i = 1; $i -le 6; $i++) {
  $raw = (& node (Join-Path $root 'bridge\get-room.mjs')) | Where-Object { $_ -match '^\{' }
  $c = $null; try { $c = $raw | ConvertFrom-Json } catch {}
  if ($c -and $c.password -and -not $c.stale) { $room = $c; break }
  W 'stale/no room; wait 20s'; Start-Sleep -Seconds 20
}
if (-not $room) { W 'NO ROOM'; return }
W ("room passlen={0} -> launching client" -f $room.password.Length)
cmd /c start "" /D $game "$exe" -h $room.address -p $room.port -w $room.password -d $Deck -j -k

$started = $false; $readySends = 0; $lastHs = ''
for ($i = 1; $i -le 22; $i++) {
  Start-Sleep -Seconds 2
  $hs = J 'http://127.0.0.1:7788/hs'
  $stoc = J 'http://127.0.0.1:7788/stoc'
  $state = J 'http://127.0.0.1:7788/state'
  $hsText = if ($hs) { ($hs.statuses -join ',') } else { '?' }
  $stocText = if ($stoc) { ($stoc.packets -join ',') } else { '?' }
  $enters = 0; if ($stoc) { $enters = ($stoc.packets | Where-Object { $_ -eq 32 } | Measure-Object).Count }
  $rd = 'skip'
  if ($readySends -lt 6 -and $i -ge 3) {
    $before = $hsText
    $r = J 'http://127.0.0.1:7788/ready'
    $readySends++
    Start-Sleep -Milliseconds 400
    $after = J 'http://127.0.0.1:7788/hs'
    $afterText = if ($after) { ($after.statuses -join ',') } else { '?' }
    $rd = "sent(before=[$before] after=[$afterText])"
  }
  W ("t+{0}s ready={1} started={2} msg={3} deck={4} self={5} ourREADY={6} ourNOTREADY={7} hs=[{8}]" -f ($i*2), $rd, $state.started, $state.curMsg, $state.deckMain, $state.selftype, $rd34, $rd35, $hsText)
  if ($state.started) { $started = $true; break }
}
if ($started) {
  W 'duel started -> heuristic bot'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  W 'bot returned'
} else { W 'no duel start' }
W "log: $log"
