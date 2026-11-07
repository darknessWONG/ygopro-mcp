# bridge/reconnect-lab-run.ps1
# One-click reconnect-lab experiment: host (7911) + guest through netfault (7912), sample /net with
# bridge/net-probe.mjs, inject a link fault (freeze|drop), hold, optionally thaw, then summarise.
#
# Everything is started and stopped by this script (no other agent or terminal is required). It only
# touches processes it started itself; it refuses to run if YGOPro / the ports are already in use.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File bridge\reconnect-lab-run.ps1 -Mode freeze -HoldSeconds 20
#   powershell ... -File bridge\reconnect-lab-run.ps1 -Mode drop   -HoldSeconds 20
#   powershell ... -File bridge\reconnect-lab-run.ps1 -Mode freeze -HoldSeconds 20 -Thaw -DryRun
#   powershell ... -File bridge\reconnect-lab-run.ps1 -SelfTest          # plumbing test, no YGOPro
#
# Output: ranked\logs\reconnect-lab-<stamp>.log / .json, netprobe-<stamp>.csv, reconnect-*.png
# NOTE: this file is ASCII-only on purpose (Windows PowerShell 5.1 parses .ps1 as ANSI).
#
# CLIENT LAUNCH (important): the GUI exe is NOT started with `Start-Process -FilePath ...` directly.
# That pattern was observed to take ~14s and then block forever (guest never appeared). Instead each
# client is launched through a generated .cmd wrapper (`cd /d <game dir>` + `start "" "<exe>" <args>`),
# exactly like bridge\lan-host.cmd / lan-guest.cmd, and the pid is resolved by diffing
# `Get-Process YGOPro` with a hard timeout (-LaunchTimeoutSec) + loud diagnostics on failure.
#
# GUEST JOIN (important): the guest must NOT be started with `-j` for the proxy experiment.
# `-j` makes the client auto-join using system.conf's lasthost/lastport (usually 7911) and IGNORES
# the `-p` argument, so no traffic would go through netfault (observed: totalConnections=0 and a
# freeze/drop that changes nothing). Instead: start the guest WITHOUT `-j`, then drive
#   GET /join?ip=127.0.0.1&port=7912&pass=   ->  /ready
# and assert netfault `/status.totalConnections >= 1` before injecting the fault.
param(
    [ValidateSet('freeze', 'drop')]
    [string]$Mode = 'freeze',
    [int]$HoldSeconds = 20,
    [string]$Deck = 'Blackwing',
    [int]$Port = 7789,
    [switch]$Thaw,
    [int]$ThawWaitSeconds = 10,
    [int]$TurnTarget = 2,
    [int]$StartupTimeoutSec = 150,
    [int]$ServerPort = 7911,
    [int]$ProxyListen = 7912,
    [int]$ProxyCtrl = 7913,
    [int]$HostPort = 7788,
    [string]$HostNick = 'HostA',
    [string]$GuestNick = 'GuestB',
    [string]$ClientExe = 'mycard-client\bin\release\x64\YGOPro.exe',
    [string]$GameDir = 'mycard-bot\game',
    [string]$OutDir = 'ranked\logs',
    [int]$ProbeIntervalMs = 500,
    [int]$LaunchTimeoutSec = 25,
    [switch]$SkipShot,
    [switch]$ClientDebug,
    [switch]$KeepClients,
    [switch]$SkipProxyAssert,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:Started = @()      # PSCustomObject { Name; Process }   (node helpers: netfault/probe)
$script:Pids = @{}         # name -> { Pid; Wrapper }           (YGOPro clients, launched via cmd)
$script:LogFile = $null
$script:StartTime = Get-Date
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Run([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg)
    Write-Host $line
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { } }
}
function Write-Step([int]$n, [int]$total, [string]$msg) { Write-Run ('[{0}/{1}] {2}' -f $n, $total, $msg) }

function Get-Root() { return (Split-Path -Parent $PSScriptRoot) }

function Http-GetRaw([string]$url, [int]$timeoutSec = 4) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec
        return $r.Content
    } catch { return $null }
}
function Http-GetJson([string]$url, [int]$timeoutSec = 4) {
    $raw = Http-GetRaw $url $timeoutSec
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function Http-Post([string]$url, [int]$timeoutSec = 4) {
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -TimeoutSec $timeoutSec
        return $r.Content
    } catch { return $null }
}

function Test-PortBusy([int]$p) {
    try {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($null -ne $c) { return $true }
    } catch { }
    $h = Http-GetRaw ('http://127.0.0.1:{0}/health' -f $p) 1
    if ($null -ne $h -and $h.Length -gt 0) { return $true }
    return $false
}

function Wait-Health([int]$p, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = Http-GetJson ('http://127.0.0.1:{0}/health' -f $p) 2
        if ($null -ne $h -and $h.ok) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Call-Api([string]$url, [string]$what, [int]$tries = 4) {
    for ($i = 1; $i -le $tries; $i++) {
        $raw = Http-GetRaw $url 4
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $ok = $true
            try {
                $j = $raw | ConvertFrom-Json
                if ($j.PSObject.Properties.Name -contains 'ok') { $ok = [bool]$j.ok }
            } catch { }
            if ($ok) { Write-Run ('  {0} -> ok ({1}/{2})' -f $what, $i, $tries); return $raw }
        }
        Write-Run ('  {0} -> retry ({1}/{2})' -f $what, $i, $tries)
        Start-Sleep -Milliseconds 1000
    }
    Write-Run ('  {0} -> FAILED' -f $what)
    return $null
}

function Start-Tracked([string]$name, [string]$file, [string[]]$argList, [string]$workDir, [string]$stdoutPath, [string]$stderrPath) {
    $common = @{ FilePath = $file; ArgumentList = $argList; PassThru = $true; WindowStyle = 'Hidden' }
    if ($workDir) { $common['WorkingDirectory'] = $workDir }
    if ($stdoutPath) { $common['RedirectStandardOutput'] = $stdoutPath }
    if ($stderrPath) { $common['RedirectStandardError'] = $stderrPath }
    $p = Start-Process @common
    $script:Started += [pscustomobject]@{ Name = $name; Process = $p }
    Write-Run ('  started {0} pid={1}' -f $name, $p.Id)
    return $p
}

function Stop-Tracked([string]$name) {
    foreach ($s in @($script:Started)) {
        if ($s.Name -ne $name) { continue }
        try {
            $p = Get-Process -Id $s.Process.Id -ErrorAction SilentlyContinue
            if ($null -ne $p) {
                Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue
                Write-Run ('  stopped {0} pid={1}' -f $name, $s.Process.Id)
            }
        } catch { }
    }
    $script:Started = @($script:Started | Where-Object { $_.Name -ne $name })
}

function Stop-All() {
    foreach ($s in @($script:Started)) {
        try {
            $p = Get-Process -Id $s.Process.Id -ErrorAction SilentlyContinue
            if ($null -ne $p) {
                Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue
                Write-Run ('  cleanup {0} pid={1}' -f $s.Name, $s.Process.Id)
            }
        } catch { }
    }
    $script:Started = @()
}

# -------------------------------------------------------------------------------------
# YGOPro launch helpers.
#
# DO NOT launch the GUI exe with `Start-Process -FilePath <YGOPro.exe> -PassThru`:
# on this machine it can take ~14s (observed) or block forever (guest never appeared), because
# PS waits on a GUI process start. The reliable pattern is the one lan-host.cmd / lan-guest.cmd
# already use: a tiny .cmd that does `cd /d <game dir>` + `start "" "<exe>" <args>`, invoked as
# `cmd /c <wrapper>`. The wrapper returns immediately; the real pid is resolved by diffing
# `Get-Process <exe name>` before/after (with a hard timeout and loud diagnostics).
# -------------------------------------------------------------------------------------
function Get-ClientPids([string]$procName) {
    return @(Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

function New-ClientWrapper([string]$name, [int]$controlPort, [string[]]$clientArgs) {
    $wrapper = Join-Path $outPath ('client-{0}-{1}.cmd' -f $name, $script:Stamp)
    $lines = @()
    $lines += '@echo off'
    $lines += ('set YGO_CONTROL_PORT=' + $controlPort)
    if ($ClientDebug) { $lines += 'set YGO_CTRL_DEBUG=1' }
    $lines += ('cd /d "' + $gameDirPath + '"')
    $lines += ('start "" "' + $exePath + '" ' + ($clientArgs -join ' '))
    [System.IO.File]::WriteAllText($wrapper, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
    return $wrapper
}

function Write-LaunchDiagnostics([string]$phase) {
    Write-Run ('  --- diagnostics for ' + $phase + ' ---')
    try {
        $procs = @(Get-Process YGOPro -ErrorAction SilentlyContinue)
        Write-Run ('  YGOPro processes: {0}' -f $procs.Count)
        foreach ($p in $procs) {
            $pathText = ''
            try { $pathText = $p.Path } catch { $pathText = '(path unreadable)' }
            Write-Run ('    pid={0} start={1} path={2}' -f $p.Id, $p.StartTime, $pathText)
        }
    } catch { }
    try {
        $st = Http-GetJson ('http://127.0.0.1:{0}/status' -f $ProxyCtrl) 1
        if ($null -ne $st) { Write-Run ('  netfault: mode={0} connections={1} totalConnections={2} bytes={3}/{4}' -f $st.mode, $st.connections, $st.totalConnections, $st.bytesUp, $st.bytesDown) }
        else { Write-Run '  netfault: /status unreachable' }
    } catch { }
    try {
        $logs = @(Get-ChildItem $gameDirPath -Filter 'control-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
        if ($logs.Count -eq 0) { Write-Run '  ctl logs: none in game dir' }
        foreach ($l in $logs) { Write-Run ('  ctl log: {0} (mtime {1})' -f $l.Name, $l.LastWriteTime.ToString('HH:mm:ss')) }
    } catch { }
}

function Launch-Client([string]$name, [int]$controlPort, [string[]]$clientArgs, [int]$waitSec) {
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
    $before = Get-ClientPids $procName
    $wrapper = New-ClientWrapper $name $controlPort $clientArgs
    Write-Run ('  wrapper: {0}' -f $wrapper)
    # `cmd /c <wrapper>` returns immediately; the wrapper itself does `start "" <exe> ...`
    $null = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', ('"' + $wrapper + '"')) -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds($waitSec)
    $newPid = $null
    while ((Get-Date) -lt $deadline) {
        $now = Get-ClientPids $procName
        $newIds = @($now | Where-Object { $before -notcontains $_ })
        if ($newIds.Count -gt 0) { $newPid = [int]$newIds[0]; break }
        Start-Sleep -Milliseconds 300
    }
    if ($null -eq $newPid) {
        Write-Run ('  ERROR: no {0} process appeared within {1}s' -f $procName, $waitSec)
        Write-LaunchDiagnostics $name
        throw ('client {0} did not start (wrapper: {1})' -f $name, $wrapper)
    }
    $script:Pids[$name] = [pscustomobject]@{ Pid = $newPid; Wrapper = $wrapper }
    Write-Run ('  launched {0} pid={1} via cmd wrapper' -f $name, $newPid)
    return $newPid
}

function Stop-OurClients() {
    foreach ($k in @($script:Pids.Keys)) {
        $procId = $script:Pids[$k].Pid
        try {
            if ($null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                Write-Run ('  stopped {0} pid={1}' -f $k, $procId)
            }
        } catch { }
        $script:Pids.Remove($k)
    }
    # fallback: only our exe AND started after this script began (never touch foreign clients)
    try {
        $procName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
        $left = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $script:StartTime })
        foreach ($p in $left) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Write-Run ('  stopped leftover {0} pid={1}' -f $procName, $p.Id)
            } catch { }
        }
    } catch { }
}

# =====================================================================================
# preflight
# =====================================================================================
$root = Get-Root
$exePath = Join-Path $root $ClientExe
$gameDirPath = Join-Path $root $GameDir
$outPath = Join-Path $root $OutDir
$probePath = Join-Path $root 'bridge\net-probe.mjs'
$netfaultPath = Join-Path $root 'bridge\netfault.mjs'
$shotPath = Join-Path $root 'bridge\shot.ps1'
$logFile = Join-Path $outPath ('reconnect-lab-{0}.log' -f $script:Stamp)
$summaryFile = Join-Path $outPath ('reconnect-lab-{0}.json' -f $script:Stamp)
$csvFile = Join-Path $outPath ('netprobe-{0}.csv' -f $script:Stamp)
$probeOut = Join-Path $outPath ('netprobe-{0}.stdout.txt' -f $script:Stamp)
$probeErr = Join-Path $outPath ('netprobe-{0}.stderr.txt' -f $script:Stamp)
$nfOut = Join-Path $outPath ('netfault-{0}.stdout.txt' -f $script:Stamp)
$nfErr = Join-Path $outPath ('netfault-{0}.stderr.txt' -f $script:Stamp)
$probeDurationMs = ($HoldSeconds + $ThawWaitSeconds + 45) * 1000

try {
    if (-not (Test-Path $outPath)) { New-Item -ItemType Directory -Path $outPath -Force | Out-Null }
    $script:LogFile = $logFile
} catch { }

Write-Run '================ reconnect-lab-run ================'
Write-Run ('mode={0} holdSeconds={1} thaw={2} deck={3} guestPort={4} dryRun={5}' -f $Mode, $HoldSeconds, [bool]$Thaw, $Deck, $Port, [bool]$DryRun)
Write-Run ('root={0}' -f $root)

$fail = $null
if ($null -eq (Get-Command node -ErrorAction SilentlyContinue)) { $fail = 'node not found in PATH' }
elseif (-not (Test-Path $exePath)) { $fail = ('client exe not found: ' + $exePath) }
elseif (-not (Test-Path $gameDirPath)) { $fail = ('game dir not found: ' + $gameDirPath) }
elseif (-not (Test-Path $probePath)) { $fail = ('missing ' + $probePath) }
elseif (-not (Test-Path $netfaultPath)) { $fail = ('missing ' + $netfaultPath) }
if ($fail) { Write-Run ('ABORT: ' + $fail); exit 2 }

Write-Step 1 9 'preflight: ports must be free and no YGOPro running'
$busy = @()
foreach ($p in @($ServerPort, $ProxyListen, $ProxyCtrl, $HostPort, $Port)) {
    if (Test-PortBusy $p) { $busy += $p }
}
$existing = @(Get-Process YGOPro -ErrorAction SilentlyContinue)
if ($DryRun) {
    # rehearsal: nothing is started, so conflicts are warnings, not blockers
    if ($busy.Count -gt 0) { Write-Run ('  WARN (dry run): ports in use: ' + ($busy -join ',')) }
    if ($existing.Count -gt 0) { Write-Run ('  WARN (dry run): {0} YGOPro already running' -f $existing.Count) }
    Write-Run '  ports/YGOPro conflicts would ABORT a real run'
} else {
    if ($busy.Count -gt 0) { Write-Run ('ABORT: ports already in use: ' + ($busy -join ',')); exit 2 }
    if ($existing.Count -gt 0) {
        Write-Run ('ABORT: {0} YGOPro process(es) already running (this script never kills foreign clients): {1}' -f $existing.Count, (($existing | ForEach-Object { $_.Id }) -join ','))
        exit 2
    }
    Write-Run '  ports free, no existing YGOPro'
}

if ($SelfTest) {
    # plumbing self-test: proves the cmd-wrapper launch path works, without starting YGOPro
    Write-Step 1 1 'self-test: cmd wrapper launch plumbing (no YGOPro)'
    $tmp = Join-Path $outPath ('selftest-{0}' -f $script:Stamp)
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $marker = Join-Path $tmp 'marker.txt'
    $wrapper = Join-Path $tmp 'selftest.cmd'
    $content = (@('@echo off', ('echo self-test ok > "' + $marker + '"')) -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($wrapper, $content, (New-Object System.Text.ASCIIEncoding))
    $null = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', ('"' + $wrapper + '"')) -WindowStyle Hidden -PassThru
    $ok = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $marker) { $ok = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if ($ok) {
        Write-Run ('  PASS: wrapper executed, marker=' + $marker)
        Write-Run '  (this verifies cmd /c + start plumbing; the real exe is launched the same way)'
        exit 0
    }
    Write-Run '  FAIL: cmd wrapper did not produce the marker within 10s'
    exit 1
}

if ($DryRun) {
    Write-Step 2 9 'DRY RUN: would start netfault'
    Write-Run ('  node "{0}" --listen {1} --upstream 127.0.0.1:{2} --ctrl {3}' -f $netfaultPath, $ProxyListen, $ServerPort, $ProxyCtrl)
    Write-Step 3 9 'DRY RUN: would start host client (cmd wrapper -> start "" exe)'
    Write-Run ('  set YGO_CONTROL_PORT={0}; cd /d "{1}"; start "" "{2}" -c -h 127.0.0.1 -p {3} -n {4} -d {5} -k' -f $HostPort, $gameDirPath, $exePath, $ServerPort, $HostNick, $Deck)
    Write-Step 4 9 'DRY RUN: would start guest client (NO -j; join via HTTP through proxy)'
    Write-Run ('  set YGO_CONTROL_PORT={0}; cd /d "{1}"; start "" "{2}" -h 127.0.0.1 -p {3} -n {4} -d {5} -k' -f $Port, $gameDirPath, $exePath, $ProxyListen, $GuestNick, $Deck)
    Write-Run ('  then GET http://127.0.0.1:{0}/join?ip=127.0.0.1&port={1}&pass=   (-j would ignore -p) and assert netfault totalConnections >= 1' -f $Port, $ProxyListen)
    Write-Step 5 9 'DRY RUN: would /deck -> guest /join(7912) -> assert proxy traffic -> /ready -> /start, then wait turn >= target'
    Write-Step 6 9 'DRY RUN: would start net-probe'
    Write-Run ('  node "{0}" --port {1} --interval {2} --duration {3} --csv "{4}"' -f $probePath, $Port, $ProbeIntervalMs, $probeDurationMs, $csvFile)
    Write-Step 7 9 ('DRY RUN: would inject POST http://127.0.0.1:{0}/mode?m={1} and hold {2}s' -f $ProxyCtrl, $Mode, $HoldSeconds)
    Write-Step 8 9 'DRY RUN: would sample /health /state /net and take a screenshot during hold'
    Write-Step 9 9 'DRY RUN: would stop probe, summarise CSV, clean up'
    Write-Run 'DRY RUN complete (nothing was started)'
    exit 0
}

# =====================================================================================
# experiment
# =====================================================================================
$injectUtc = $null
$detectMs = $null
$thawedUtc = $null
$recoverMs = $null
$healthDuring = $null
$stateDuring = $null
$netDuring = $null
$netAfterThaw = $null
$shotPathOut = $null
$probeDeadEvent = $null
$probeSummary = $null
$guestPid = $null
$probeCsvRows = 0
$proxyAtInject = $null
$result = @{}

try {
    Write-Step 2 9 'start netfault proxy'
    $nfArgs = @(('"' + $netfaultPath + '"'), '--listen', "$ProxyListen", '--upstream', ("127.0.0.1:" + $ServerPort), '--ctrl', "$ProxyCtrl")
    $null = Start-Tracked 'netfault' 'node' $nfArgs $root $nfOut $nfErr
    $nfReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        $st = Http-GetJson ('http://127.0.0.1:{0}/status' -f $ProxyCtrl) 1
        if ($null -ne $st) { $nfReady = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $nfReady) { throw 'netfault control port did not come up' }
    Write-Run ('  netfault ready: {0} -> {1}' -f $st.listen, $st.upstream)

    Write-Step 3 9 'start host client'
    $hostArgs = @('-c', '-h', '127.0.0.1', '-p', "$ServerPort", '-n', $HostNick, '-d', $Deck, '-k')
    $null = Launch-Client 'host' $HostPort $hostArgs $LaunchTimeoutSec
    $ok = Wait-Health $HostPort 45
    if (-not $ok) {
        Write-LaunchDiagnostics 'host-after-launch'
        throw ('host control API not up on ' + $HostPort)
    }
    Write-Run ('  host up (/{0}/health ok)' -f $HostPort)

    Write-Step 4 9 'start guest client (NO -j; will join via HTTP through proxy)'
    # no -j: `-j` auto-join uses system.conf lasthost/lastport and ignores -p -> traffic would bypass
    # the proxy. We start at the menu and drive /join?port=7912 ourselves in step 5.
    $guestArgs = @('-h', '127.0.0.1', '-p', "$ProxyListen", '-n', $GuestNick, '-d', $Deck, '-k')
    $guestPid = Launch-Client 'guest' $Port $guestArgs $LaunchTimeoutSec
    $ok = Wait-Health $Port 45
    if (-not $ok) {
        Write-LaunchDiagnostics 'guest-after-launch'
        throw ('guest control API not up on ' + $Port)
    }
    Write-Run ('  guest up pid={0} (/{1}/health ok)' -f $guestPid, $Port)

    Write-Step 5 9 ('deck -> guest join(7912) -> assert proxy -> ready -> start; wait turn >= ' + $TurnTarget)
    $enc = [uri]::EscapeDataString($Deck)
    $null = Call-Api ('http://127.0.0.1:{0}/deck?name={1}' -f $HostPort, $enc) 'host /deck'
    $null = Call-Api ('http://127.0.0.1:{0}/deck?name={1}' -f $Port, $enc) 'guest /deck'
    $joinUrl = ('http://127.0.0.1:{0}/join?ip=127.0.0.1&port={1}&pass=' -f $Port, $ProxyListen)
    $null = Call-Api $joinUrl ('guest /join(port ' + $ProxyListen + ')') 6
    # CRITICAL assertion: without traffic through the proxy a freeze/drop proves nothing
    $proxyOk = $false
    $proxyWaitDeadline = (Get-Date).AddSeconds(20)
    $proxyStatus = $null
    while ((Get-Date) -lt $proxyWaitDeadline) {
        $proxyStatus = Http-GetJson ('http://127.0.0.1:{0}/status' -f $ProxyCtrl) 2
        if ($null -ne $proxyStatus -and [int]$proxyStatus.totalConnections -ge 1) { $proxyOk = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if ($proxyOk) {
        Write-Run ('  proxy traffic OK: totalConnections={0} bytesUp={1} bytesDown={2}' -f $proxyStatus.totalConnections, $proxyStatus.bytesUp, $proxyStatus.bytesDown)
    } elseif ($SkipProxyAssert) {
        Write-Run '  WARN (-SkipProxyAssert): guest never connected to the proxy; fault injection would be meaningless'
    } else {
        Write-LaunchDiagnostics 'guest-proxy-assert'
        Write-Run ('  ERROR: netfault totalConnections={0} after /join(port {1}) -> guest traffic is NOT going through the proxy' -f $proxyStatus.totalConnections, $ProxyListen)
        throw 'guest traffic did not reach netfault; refusing to inject a meaningless fault (see diagnostics; use -SkipProxyAssert to override)'
    }
    $null = Call-Api ('http://127.0.0.1:{0}/ready' -f $HostPort) 'host /ready'
    $null = Call-Api ('http://127.0.0.1:{0}/ready' -f $Port) 'guest /ready'
    $null = Call-Api ('http://127.0.0.1:{0}/start' -f $HostPort) 'host /start'
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $pre = $null
    while ((Get-Date) -lt $deadline) {
        $st = Http-GetJson ('http://127.0.0.1:{0}/state' -f $Port) 2
        if ($null -ne $st -and $st.started -and $st.inDuel -and [int]$st.turn -ge $TurnTarget) { $pre = $st; break }
        Start-Sleep -Milliseconds 700
    }
    if ($null -eq $pre) { throw ('duel did not reach turn >= ' + $TurnTarget + ' within ' + $StartupTimeoutSec + 's') }
    $preFile = Join-Path $outPath ('reconnect-pre-{0}.json' -f $script:Stamp)
    try { [System.IO.File]::WriteAllText($preFile, (($pre | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false))) } catch { }
    Write-Run ('  duel running: turn={0} lp={1} inDuel={2}' -f $pre.turn, ($pre.lp -join '/'), $pre.inDuel)
    Write-Run ('  snapshot: {0}' -f $preFile)

    Write-Step 6 9 'start net-probe sampling /net'
    $probeArgs = @(('"' + $probePath + '"'), '--port', "$Port", '--interval', "$ProbeIntervalMs", '--duration', "$probeDurationMs", '--csv', ('"' + $csvFile + '"'))
    $null = Start-Tracked 'probe' 'node' $probeArgs $root $probeOut $probeErr
    Start-Sleep -Seconds 2
    Write-Run ('  probe running, csv={0}' -f $csvFile)

    Write-Step 7 9 ('inject fault: mode=' + $Mode)
    $injectUtc = (Get-Date).ToUniversalTime()
    $body = Http-Post ('http://127.0.0.1:{0}/mode?m={1}' -f $ProxyCtrl, $Mode) 4
    $st = Http-GetJson ('http://127.0.0.1:{0}/status' -f $ProxyCtrl) 2
    $proxyAtInject = $st
    Write-Run ('  injected at {0} -> proxy mode={1} connections={2} bytesUp={3} body={4}' -f $injectUtc.ToString('HH:mm:ss.fff'), $st.mode, $st.connections, $st.bytesUp, $body)
    Write-Run ('  holding {0}s ...' -f $HoldSeconds)

    Start-Sleep -Seconds $HoldSeconds

    Write-Step 8 9 'sample during hold + screenshot'
    $healthDuring = Http-GetJson ('http://127.0.0.1:{0}/health' -f $Port) 2
    $stateDuring = Http-GetJson ('http://127.0.0.1:{0}/state' -f $Port) 2
    $netDuring = Http-GetJson ('http://127.0.0.1:{0}/net' -f $Port) 2
    $netText = Http-GetRaw ('http://127.0.0.1:{0}/net' -f $Port) 2
    Write-Run ('  guest /health ok={0}  /state turn={1} started={2}  /net={3}' -f `
        ($null -ne $healthDuring -and $healthDuring.ok), ($stateDuring.turn), ($stateDuring.started), $netText)
    if (-not $SkipShot) {
        if (Test-Path $shotPath) {
            $tag = 'reconnect-' + $Mode
            try {
                & $shotPath -Tag $tag -OutDir $outPath
                $shotPathOut = Join-Path $outPath ($tag + '*.png')
                Write-Run ('  screenshot requested: {0}' -f $shotPathOut)
            } catch { Write-Run ('  screenshot failed: ' + $_.Exception.Message) }
        } else { Write-Run '  shot.ps1 not found, skipping screenshot' }
    }

    if ($Thaw -and $Mode -eq 'freeze') {
        Write-Run ('  thaw: POST /thaw, then wait {0}s' -f $ThawWaitSeconds)
        $thawedUtc = (Get-Date).ToUniversalTime()
        $null = Http-Post ('http://127.0.0.1:{0}/thaw' -f $ProxyCtrl) 4
        Start-Sleep -Seconds $ThawWaitSeconds
        $netAfterThaw = Http-GetJson ('http://127.0.0.1:{0}/net' -f $Port) 2
        Write-Run ('  after thaw /net: ' + (Http-GetRaw ('http://127.0.0.1:{0}/net' -f $Port) 2))
    }

    Write-Step 9 9 'stop probe, read CSV, summarise'
    Stop-Tracked 'probe'
    Start-Sleep -Milliseconds 800

    if (Test-Path $csvFile) {
        try {
            $rows = @(Import-Csv -Path $csvFile)
            $probeCsvRows = $rows.Count
            foreach ($r in $rows) {
                if ($r.alive -eq 'false' -or $r.probeState -eq 'confirmed_dead') {
                    try {
                        $ts = ([datetime]$r.ts).ToUniversalTime()
                        $detectMs = [int](($ts - $injectUtc).TotalMilliseconds)
                    } catch { }
                    break
                }
            }
            if ($null -ne $detectMs -and $detectMs -lt 0) { $detectMs = $null }
        } catch { Write-Run ('  CSV parse failed: ' + $_.Exception.Message) }
    } else { Write-Run ('  CSV not found: ' + $csvFile) }

    if (Test-Path $probeOut) {
        $ev = @(Select-String -Path $probeOut -Pattern '^EVENT (DEAD|ALIVE)' -ErrorAction SilentlyContinue)
        $deadLines = @($ev | Where-Object { $_.Line -like 'EVENT DEAD*' })
        $aliveLines = @($ev | Where-Object { $_.Line -like 'EVENT ALIVE*' })
        if ($deadLines.Count -gt 0) { $probeDeadEvent = $deadLines[0].Line; Write-Run ('  probe: ' + $probeDeadEvent) }
        foreach ($al in $aliveLines) { Write-Run ('  probe: ' + $al.Line) }
        $sm = @(Select-String -Path $probeOut -Pattern '^SUMMARY ' -ErrorAction SilentlyContinue)
        if ($sm.Count -gt 0) {
            $probeSummary = $sm[$sm.Count - 1].Line.Substring(8)
            Write-Run ('  probe summary: ' + $probeSummary)
        }
        if ($null -eq $detectMs -and $null -ne $deadLines.Count -and $deadLines.Count -gt 0) {
            $m = [regex]::Match($deadLines[0].Line, 't=(\d+)ms')
            if ($m.Success) { $detectMs = [int]$m.Groups[1].Value + 2000 }
        }
    }

    $aliveAfter = $null
    if ($null -ne $netDuring) { $aliveAfter = $netDuring.alive }
    $guestAliveNow = $null -ne (Get-Process -Id $guestPid -ErrorAction SilentlyContinue)
    $recovered = $null
    if ($null -ne $netAfterThaw) { $recovered = [bool]$netAfterThaw.alive }
    if ($null -ne $thawedUtc -and $null -ne $detectMs) { $recoverMs = $null }

    $result = [ordered]@{
        stamp = $script:Stamp
        mode = $Mode
        holdSeconds = $HoldSeconds
        thaw = [bool]$Thaw
        deck = $Deck
        guestPort = $Port
        proxyListen = $ProxyListen
        proxyCtrl = $ProxyCtrl
        trafficThroughProxy = $(if ($null -ne $proxyAtInject) { ([int]$proxyAtInject.totalConnections -ge 1) } else { $false })
        proxyTotalConnections = $(if ($null -ne $proxyAtInject) { [int]$proxyAtInject.totalConnections } else { $null })
        proxyBytesUp = $(if ($null -ne $proxyAtInject) { [int]$proxyAtInject.bytesUp } else { $null })
        proxyBytesDown = $(if ($null -ne $proxyAtInject) { [int]$proxyAtInject.bytesDown } else { $null })
        serverPort = $ServerPort
        injectUtc = $(if ($null -ne $injectUtc) { $injectUtc.ToString('o') } else { $null })
        detectMs = $detectMs
        detectWithin10s = $(if ($null -ne $detectMs) { $detectMs -le 10000 } else { $false })
        probeCsvRows = $probeCsvRows
        probeDeadEvent = $probeDeadEvent
        probeSummary = $probeSummary
        controlApiAliveDuringFault = $($null -ne $healthDuring -and $healthDuring.ok)
        netDuring = $netDuring
        guestProcessAliveAtEnd = $guestAliveNow
        guestPid = $guestPid
        disconnectedSeen = $($null -ne $netDuring -and ($netDuring.state -eq 'confirmed_dead' -or $netDuring.connected -eq $false -or $netDuring.alive -eq $false))
        thawedUtc = $(if ($null -ne $thawedUtc) { $thawedUtc.ToString('o') } else { $null })
        recoveredAfterThaw = $recovered
        screenshotGlob = $shotPathOut
        preStateFile = $preFile
        csv = $csvFile
        probeStdout = $probeOut
        probeStderr = $probeErr
        clientLogsHint = ('control-<pid>.log in ' + $gameDirPath)
        log = $logFile
    }
    try {
        [System.IO.File]::WriteAllText($summaryFile, (($result | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

} catch {
    Write-Run ('ERROR: ' + $_.Exception.Message)
    $result = [ordered]@{ stamp = $script:Stamp; mode = $Mode; error = $_.Exception.Message; log = $logFile }
} finally {
    Write-Run 'cleanup'
    Stop-Tracked 'probe'
    if ($KeepClients) {
        Write-Run '  -KeepClients: host/guest left running (stop them manually)'
        $script:Pids = @{}
    } else {
        Stop-OurClients
    }
    Stop-Tracked 'netfault'
    Stop-All
    $env:YGO_CONTROL_PORT = $null
}

# =====================================================================================
# summary
# =====================================================================================
Write-Run '================ SUMMARY ================'
if ($result.Contains('error')) {
    Write-Run ('result: ERROR ' + $result.error)
} else {
    $d = 'not detected'
    if ($null -ne $result.detectMs) { $d = ('{0} ms' -f $result.detectMs) }
    Write-Run ('fault injected      : mode={0} at {1}' -f $result.mode, $result.injectUtc)
    Write-Run ('traffic via proxy   : {0}   (connections={1} bytesUp={2} bytesDown={3})' -f $result.trafficThroughProxy, $result.proxyTotalConnections, $result.proxyBytesUp, $result.proxyBytesDown)
    Write-Run ('dead detected after : {0}   (target <= 10000 ms)' -f $d)
    Write-Run ('control API alive   : {0}   (client process itself must stay responsive)' -f $result.controlApiAliveDuringFault)
    Write-Run ('disconnected seen   : {0}' -f $result.disconnectedSeen)
    Write-Run ('guest process alive : {0}   (pid {1})' -f $result.guestProcessAliveAtEnd, $result.guestPid)
    if ($result.thaw) { Write-Run ('recovered after thaw: {0}' -f $result.recoveredAfterThaw) }
    Write-Run ('probe csv rows      : {0}' -f $result.probeCsvRows)
    Write-Run ('screenshot          : {0}' -f $result.screenshotGlob)
    Write-Run ('csv                 : {0}' -f $result.csv)
    Write-Run ('summary json        : {0}' -f $summaryFile)
    Write-Run ('log                 : {0}' -f $logFile)
    $verdict = 'FAIL'
    if (-not $result.trafficThroughProxy) {
        $verdict = 'INVALID (traffic did not pass the proxy; freeze/drop proved nothing)'
    } elseif ($null -ne $result.detectMs -and $result.controlApiAliveDuringFault) {
        $verdict = 'PASS'
    } elseif ($null -ne $result.detectMs) {
        $verdict = 'PASS(detected)'
    }
    Write-Run ('verdict             : {0}' -f $verdict)
}
Write-Run 'done'
exit 0
