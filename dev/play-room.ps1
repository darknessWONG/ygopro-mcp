param([Parameter(Mandatory=$true)][string]$Pass, [string]$Deck = 'Blackwing', [int]$MaxPlayMinutes = 15)
$ErrorActionPreference = 'Continue'
$root = 'D:\dsh_workspaces\MC_bot_dsh'
$game = Join-Path $root 'mycard-bot\game'
$exe  = Join-Path $root 'mycard-client\bin\release\x64\YGOPro.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $root "ranked\logs\play-$stamp.log"
function W([string]$m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line -Encoding UTF8; Write-Output $line }
function J([string]$url) { try { return ((Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json) } catch { return $null } }

W "=== play-room $stamp deck=$Deck ==="
Get-Process ygopro,YGOPro -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
cmd /c start "" /D $game "$exe" -h tiramisu.moenext.com -p 8911 -w $Pass -d $Deck -j -k
Start-Sleep -Seconds 6
W ('deck: ' + (J ("http://127.0.0.1:7788/deck?name=" + [uri]::EscapeDataString($Deck)) | ConvertTo-Json -Compress))

$started = $false; $readySent = 0; $startSent = 0
for ($i = 1; $i -le 30; $i++) {
  Start-Sleep -Seconds 2
  $lb = J 'http://127.0.0.1:7788/lobby'
  $st = J 'http://127.0.0.1:7788/state'
  if (-not $lb) { continue }
  $self = $lb.self
  $rMe = $lb.ready[$self] -eq 1
  $rOther = $lb.ready[1 - $self] -eq 1
  $act = 'wait'
  if (-not $rMe -and $readySent -lt 8) { $null = J 'http://127.0.0.1:7788/ready'; $readySent++; $act = "ready#$readySent" }
  elseif ($lb.isHost -and $lb.bothReady -and $startSent -lt 5) { $null = J 'http://127.0.0.1:7788/start'; $startSent++; $act = "start#$startSent" }
  W ("t+{0}s self={1} host={2} rMe={3} rOther={4} deck={5} started={6} act={7}" -f ($i*2), $self, $lb.isHost, $rMe, $rOther, $lb.deckMain, $st.started, $act)
  if ($st.started) { $started = $true; break }
}

if ($started) {
  W 'DUEL STARTED -> heuristic bot'
  $env:MAX_MINUTES = "$MaxPlayMinutes"
  & node (Join-Path $root 'bridge\dev\policy-heuristic.mjs') 2>&1 | ForEach-Object { W ("  bot: " + $_) }
  Start-Sleep -Seconds 3
  $fin = J 'http://127.0.0.1:7788/state'
  W ("RESULT: winPlayer={0} winReason={1} turn={2} lp={3}" -f $fin.winPlayer, $fin.winReason, $fin.turn, ($fin.lp -join ','))
} else { W 'duel did not start' }
W "log: $log"
