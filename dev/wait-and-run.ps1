# bridge/wait-and-run.ps1 - wait for the match API to stop returning 409 (pending match), then run one clean
# lobby-aware attempt: preload deck -> ready -> (start if we are host) -> watch -> bot.
param([int]$MaxWaitMinutes = 20, [int]$MaxPlayMinutes = 15, [string]$Deck = 'Blackwing')
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\wait-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== wait-and-run $stamp ==="
Get-Process ygopro,YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$room = $null
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
while ((Get-Date) -lt $deadline -and -not $room) {
  $out = & node (Join-Path $root 'bridge\get-room.mjs') 2>&1
  $line = $out | Where-Object { $_ -match '^\{' } | Select-Object -First 1
  if ($line) {
    $c = $null; try { $c = $line | ConvertFrom-Json } catch {}
    if ($c -and $c.password) {
      if ($c.stale) { W 'stale room; wait 20s'; Start-Sleep -Seconds 20; continue }
      $room = $c
      break
    }
  }
  W 'match API busy (409/pending); wait 45s'
  Start-Sleep -Seconds 45
}
if (-not $room) { W 'gave up waiting for a fresh room'; return }
W ("fresh room passlen={0} -> launch" -f $room.password.Length)

cmd /c start "" /D $game "$exe" -h $room.address -p $room.port -w $room.password -d $Deck -j -k
Start-Sleep -Seconds 6
W ('deck preload: ' + (J ("http://127.0.0.1:7788/deck?name=" + [uri]::EscapeDataString($Deck)) | ConvertTo-Json -Compress))

$started = $false; $readySent = 0; $startSent = 0
for ($i = 1; $i -le 26; $i++) {
  Start-Sleep -Seconds 2
  $lobby = J 'http://127.0.0.1:7788/lobby'
  $state = J 'http://127.0.0.1:7788/state'
  if (-not $lobby) { W "t+$($i*2)s control ERR"; continue }
  $self = $lobby.self
  $readyMe = $lobby.ready[$self] -eq 1
  $readyOther = $lobby.ready[1 - $self] -eq 1
  $act = 'wait'
  if (-not $readyMe -and $readySent -lt 8) { $null = J 'http://127.0.0.1:7788/ready'; $readySent++; $act = "ready#$readySent" }
  elseif ($lobby.isHost -and $lobby.bothReady -and $startSent -lt 4) { $null = J 'http://127.0.0.1:7788/start'; $startSent++; $act = "start#$startSent" }
  W ("t+{0}s self={1} host={2} readyMe={3} readyOther={4} deck={5} started={6} act={7}" -f ($i*2), $self, $lobby.isHost, $readyMe, $readyOther, $lobby.deckMain, $state.started, $act)
  if ($state.started) { $started = $true; break }
}

if ($started) {
  W 'DUEL STARTED -> heuristic bot'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  W 'bot returned'
} else { W 'no duel start this attempt' }
W "log: $log"
