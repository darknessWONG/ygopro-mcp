param(
  [string]$Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss'),
  [int]$DurationSec = 1200,
  [int]$SampleInterval = 5,
  [int]$ShotInterval = 30,
  [int]$HostPort = 7788,
  [int]$GuestPort = 7789
)
$ErrorActionPreference = 'Continue'
$logDir = 'ranked\logs'
$dir = Join-Path $logDir ('refwin-' + $Stamp)
$log = Join-Path $logDir ('refbaseline-ui-' + $Stamp + '.log')
New-Item -ItemType Directory -Path $dir -Force | Out-Null
function Get-Json($url) { try { return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json } catch { return $null } }
function W($m) { Add-Content -Path $log -Value $m -Encoding UTF8 }
W ('diag-ui-baseline stamp=' + $Stamp + ' duration=' + $DurationSec + ' sample=' + $SampleInterval + ' shot=' + $ShotInterval + ' dir=' + $dir)
$t0 = Get-Date; $nextShot = 0; $shotN = 0; $samples = 0; $idleSamples = 0; $duelSamples = 0
$streak = @{}; $best = @{}; $games = 0; $wasStarted = $false
while (((Get-Date) - $t0).TotalSeconds -lt $DurationSec) {
  $el = [int]((Get-Date) - $t0).TotalSeconds
  $anyStarted = $false
  foreach ($port in @($HostPort, $GuestPort)) {
    $st = Get-Json ('http://127.0.0.1:' + $port + '/state')
    $ui = $null
    if ($st -and $st.started) { $anyStarted = $true; $ui = Get-Json ('http://127.0.0.1:' + $port + '/ui') }
    if ($null -eq $st) { W ('[' + $el + 's] p' + $port + ' DOWN'); continue }
    if (-not $st.started) { W ('[' + $el + 's] p' + $port + ' NOT_STARTED inDuel=' + $st.inDuel + ' turn=' + $st.turn); continue }
    if (-not $ui) { W ('[' + $el + 's] p' + $port + ' STARTED_UI_UNREADABLE'); continue }
    $samples++
    $vis = @()
    if ($ui.windows) { foreach ($w in @($ui.windows)) { if ($w.visible) { $vis += ($w.name + '|' + $w.rect.l + ',' + $w.rect.t + ',' + $w.rect.r + ',' + $w.rect.b + '|t=' + $w.textLen) } } }
    $visTxt = '[]'; if ($vis.Count -gt 0) { $visTxt = $vis -join ';' }
    W ('[' + $el + 's] p' + $port + ' turn=' + $st.turn + ' curMsg=' + $st.curMsg + ' awaiting=' + $st.awaiting + ' visible=' + $visTxt)
    $names = @()
    if ($vis.Count -gt 0) { foreach ($v in $vis) { $names += ($v -split '\|')[0] } }
    foreach ($key in @($streak.Keys)) {
      if ($key.StartsWith(([string]$port) + ':')) { $nm = $key.Substring(([string]$port).Length + 1); if ($names -notcontains $nm) { $streak[$key] = 0 } }
    }
    foreach ($n in $names) {
      $key = ([string]$port) + ':' + $n
      if (-not $streak.ContainsKey($key)) { $streak[$key] = 0 }
      $streak[$key] = $streak[$key] + 1
      if (-not $best.ContainsKey($key) -or $streak[$key] -gt $best[$key]) { $best[$key] = $streak[$key] }
    }
  }
  if ($anyStarted) { $duelSamples++; $wasStarted = $true } else { $idleSamples++; if ($wasStarted) { $games++; $wasStarted = $false } }
  if ($anyStarted -and $el -ge $nextShot) {
    $nextShot = $el + $ShotInterval
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'bridge\shot.ps1' -Tag ('ref' + $shotN) -OutDir $dir | Out-Null
    W ('  shot ref' + $shotN + ' at ' + $el + 's')
    $shotN++
  }
  Start-Sleep -Seconds $SampleInterval
}
if ($wasStarted) { $games++ }
W 'sampling done'
W ('SUMMARY samples=' + $samples + ' duelSamples=' + $duelSamples + ' idleSamples=' + $idleSamples + ' shots=' + $shotN + ' gamesSeen=' + $games)
foreach ($k in ($best.Keys | Sort-Object)) { W ('SUMMARY ' + $k + ' maxConsecutiveVisible=' + $best[$k]) }
Write-Output ('log=' + $log + ' dir=' + $dir)
foreach ($k in ($best.Keys | Sort-Object)) { Write-Output ('  ' + $k + ' = ' + $best[$k]) }