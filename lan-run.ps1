<#
.SYNOPSIS
  bridge/lan-run.ps1 - 一键 LAN 跑局器（起 host/guest -> 备牌 -> 准备 -> 开局 -> 双 bot -> 看门狗 -> 收集证据）

.DESCRIPTION
  本机自编客户端（mycard-client）的 LAN 对局全流程封装。同一时间只允许存在一对客户端，
  因此本脚本是**唯一**负责启动/停止 YGOPro 进程的入口。

  已验证配方（不要改）：
    - host:  bridge\lan-host.cmd  <hooks> <deck>   （YGOPro.exe -c -k，控制口 7788）
    - guest: bridge\lan-guest.cmd <hooks> <deck>   （YGOPro.exe -j -k，控制口 7789）
    - host 的 hooks 必须是 msganalyze（用 all 时 stoc 钩子会在开局搞死进程）；guest 用 all
    - mycard-bot\game\system.conf 里 lasthost=127.0.0.1 / lastport=7911 必须保持（否则客机连去排位服）
    - 起 host 等 9s，起 guest 等 10s
    - 对 7788/7789 依次 /deck?name=<Deck> -> /ready -> 7788 /start

.EXAMPLE
  # 跑 1 局（默认 Blackwing，最多 8 分钟）
  powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1

.EXAMPLE
  # 连续跑 3 局，换卡组
  powershell -NoProfile -ExecutionPolicy Bypass -File bridge\lan-run.ps1 -Games 3 -Deck "Blue Eyes"

.NOTES
  退出码：0 = 所有对局至少完成到结算或按预期收尾；1 = 至少一局启动失败。
#>
[CmdletBinding()]
param(
    [int]$Games = 1,                      # 连续跑几局
    [int]$MaxMinutes = 8,                 # 单局上限（分钟）
    [string]$Deck = 'Blackwing',          # 双方使用的卡组名（game\deck 下的 .ydk 名）
    [string]$Hooks = 'msganalyze',        # host 的 YGO_HOOKS（不要用 all）
    [string]$GuestHooks = 'all',          # guest 的 YGO_HOOKS
    [int]$StallSeconds = 120,             # 局面无进展超过 N 秒判定卡死（缩短等待，便于连跑）
    [ValidateSet('', 'local', 'server')]
    [string]$PlaceCoords = '',            # 可选：给两端设 YGO_PLACE_COORDS=local|server（默认不传，用客户端默认）
    [switch]$KeepClients                  # 结束后不杀客户端（默认杀）
)

$ErrorActionPreference = 'Continue'

$root     = Split-Path -Parent $PSScriptRoot          # ...\MC_bot_dsh
$logDir   = Join-Path $root 'ranked\logs'
$gameDir  = Join-Path $root 'mycard-bot\game'
$hostCmd  = Join-Path $PSScriptRoot 'lan-host.cmd'
$guestCmd = Join-Path $PSScriptRoot 'lan-guest.cmd'
$policy   = 'bridge\policy-semantic.mjs'

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLog = Join-Path $logDir "lan-run-$stamp.log"
# 本局 bot 的 PID 落盘：CIM/WMI 在本机可能被策略拒绝，用 PID 文件来保证下一局能清掉上一局的 bot
$botPidFile = Join-Path $logDir 'lan-bots.pids'
# 本局客户端（YGOPro）的 PID 落盘：Process.Path 读不到时（半死/权限）用它兜底判活与杀进程
$clientPidFile = Join-Path $logDir 'lan-clients.pids'

# ----------------------------------------------------------------------------- helpers
function Write-Run([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $runLog -Value $line -Encoding UTF8
}

function Http-GetJson([string]$url, [int]$timeoutSec = 4) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec
        if ([string]::IsNullOrWhiteSpace($r.Content)) { return $null }
        return ($r.Content | ConvertFrom-Json)
    } catch { return $null }
}

# 调一个控制 API，最多重试 3 次（窗口没准备好时很常见）
function Call-Api([string]$url, [string]$what, [int]$tries = 3) {
    for ($i = 1; $i -le $tries; $i++) {
        $j = Http-GetJson $url
        if ($null -ne $j) {
            $ok = $true
            if ($j.PSObject.Properties.Name -contains 'ok') { $ok = [bool]$j.ok }
            if ($ok) { Write-Run ("  {0} -> ok ({1}/{2})" -f $what, $i, $tries); return $true }
        }
        Write-Run ("  {0} -> fail ({1}/{2})" -f $what, $i, $tries)
        Start-Sleep -Milliseconds 1200
    }
    return $false
}

function Get-State([int]$port) { return (Http-GetJson ("http://127.0.0.1:{0}/state" -f $port) 3) }
function Get-Health([int]$port) { return (Http-GetJson ("http://127.0.0.1:{0}/health" -f $port) 2) }

function Get-PidFileIds([string]$path) {
    $ids = @()
    if (Test-Path $path) {
        foreach ($ln in (Get-Content $path -ErrorAction SilentlyContinue)) {
            $t = $ln.Trim()
            if ($t -match '^\d+$') { $ids += [int]$t }
        }
    }
    return $ids
}

# 客户端进程 = 按路径命中的 + PID 文件里登记的（后者保证 Path 读不到时也能判活/杀进程）
function Get-YgoProcs {
    $out = @()
    $seen = @{}
    $pids = Get-PidFileIds $clientPidFile
    foreach ($p in @(Get-Process -Name YGOPro -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        $byPath = $false
        if ($path -and ($path -like '*mycard-client*' -or $path -like '*mycard-bot\game*')) { $byPath = $true }
        if ($byPath -or ($pids -contains $p.Id)) {
            $out += $p
            $seen[$p.Id] = 1
        }
    }
    # PID 文件里有、但按名字没枚举到的（防御；ProcessName 必须是 YGOPro 才认）
    foreach ($id in $pids) {
        if ($seen.ContainsKey($id)) { continue }
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            if ($p.ProcessName -eq 'YGOPro') { $out += $p; $seen[$id] = 1 }
        } catch { }
    }
    return $out
}

function Stop-YgoProcs([string]$why) {
    for ($pass = 1; $pass -le 2; $pass++) {
        $procs = @(Get-YgoProcs)
        if ($procs.Count -eq 0) { break }
        Write-Run ("  [kill] {0}: ygopro pids={1}" -f $why, (($procs | ForEach-Object { $_.Id }) -join ','))
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 900
    }
    $left = @(Get-YgoProcs)
    if ($left.Count -gt 0) {
        Write-Run ("  [kill] {0}: forced leftover pids={1}" -f $why, (($left | ForEach-Object { $_.Id }) -join ','))
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
    }
    Remove-Item $clientPidFile -Force -ErrorAction SilentlyContinue
}

# 只杀 policy-semantic 相关的 node，别的 node 进程（local-server 等）不动
function Stop-BotProcs {
    $bots = @()
    try {
        $bots = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop |
                  Where-Object { $_.CommandLine -like '*policy-semantic*' })
    } catch {
        try {
            $bots = @(Get-WmiObject Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop |
                      Where-Object { $_.CommandLine -like '*policy-semantic*' })
        } catch { $bots = @() }
    }
    foreach ($b in $bots) {
        Write-Run ("  [kill] bot node pid=" + $b.ProcessId)
        Stop-Process -Id $b.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# 兜底：按上一/本局写下的 PID 文件杀 bot（不依赖 CIM/WMI，跨局、跨脚本崩溃都能清）
function Stop-BotsFromPidFile {
    if (-not (Test-Path $botPidFile)) { return }
    $pids = @()
    foreach ($ln in (Get-Content $botPidFile -ErrorAction SilentlyContinue)) {
        $t = $ln.Trim()
        if ($t -match '^\d+$') { $pids += [int]$t }
    }
    foreach ($pid_ in $pids) {
        try {
            $p = Get-Process -Id $pid_ -ErrorAction Stop
            if ($p.ProcessName -eq 'node') {
                Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
                Write-Run ("  [kill] bot(pidfile) pid=" + $pid_)
            }
        } catch { }
    }
    Remove-Item $botPidFile -Force -ErrorAction SilentlyContinue
}

# 用 cmd /c 跑 lan-*.cmd；cmd 内部用 start 拉起客户端后立刻返回
function Start-Client([string]$cmdFile, [string]$hooks, [string]$deckName) {
    if (-not (Test-Path $cmdFile)) { throw "missing launcher: $cmdFile" }
    $cmdLine = '/c ' + $cmdFile + ' ' + $hooks + ' "' + $deckName + '"'
    # 可选：YGO_PLACE_COORDS=local|server（控制层 place 坐标解释开关，默认不传）
    $oldPc = $env:YGO_PLACE_COORDS
    if (-not [string]::IsNullOrEmpty($PlaceCoords)) { $env:YGO_PLACE_COORDS = $PlaceCoords }
    try {
        Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -WindowStyle Hidden | Out-Null
    } finally {
        if ($null -eq $oldPc) { Remove-Item Env:YGO_PLACE_COORDS -ErrorAction SilentlyContinue } else { $env:YGO_PLACE_COORDS = $oldPc }
    }
}

function Start-Bot([int]$port, [string]$outLog, [string]$errLog) {
    $oldUrl = $env:CONTROL_URL
    $oldMax = $env:MAX_MINUTES
    $env:CONTROL_URL = "http://127.0.0.1:$port"
    $env:MAX_MINUTES = "$MaxMinutes"
    $p = Start-Process -FilePath 'node' -ArgumentList $policy `
         -WorkingDirectory $root -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
         -PassThru -WindowStyle Hidden
    if ($null -eq $oldUrl) { Remove-Item Env:CONTROL_URL -ErrorAction SilentlyContinue } else { $env:CONTROL_URL = $oldUrl }
    if ($null -eq $oldMax) { Remove-Item Env:MAX_MINUTES -ErrorAction SilentlyContinue } else { $env:MAX_MINUTES = $oldMax }
    return $p
}

# win_reason -> 人话（数据源：mycard-bot\game\strings.conf 的 !victory 段）
function Get-VictoryStrings {
    $map = @{}
    $p = Join-Path $gameDir 'strings.conf'
    if (Test-Path $p) {
        foreach ($ln in (Get-Content $p -Encoding UTF8)) {
            if ($ln -match '^\s*!victory\s+0x([0-9a-fA-F]+)\s+(.+?)\s*$') {
                $code = [Convert]::ToInt32($matches[1], 16)
                $map[$code] = $matches[2]
            }
        }
    }
    return $map
}

# MSG_RETRY 计数：新版客户端有顶层 retryCount，旧版只有 pipeline.retryCount —— 两处都读
function Get-StateRetry($s) {
    if ($null -eq $s) { return 0 }
    $names = @($s.PSObject.Properties.Name)
    if ($names -contains 'retryCount' -and $null -ne $s.retryCount) { return [int]$s.retryCount }
    if ($names -contains 'pipeline') {
        $pn = @($s.pipeline.PSObject.Properties.Name)
        if ($pn -contains 'retryCount' -and $null -ne $s.pipeline.retryCount) { return [int]$s.pipeline.retryCount }
    }
    return 0
}

# 连续同一提示被拒次数（新版：顶层 retryStreak / pipeline.retryStreak）。
# 这才是"重放循环"的判据；retryCount 是累计值，正常对局里也会缓慢增长（每次可能是不同提示）。
function Get-StateRetryStreak($s) {
    if ($null -eq $s) { return 0 }
    $names = @($s.PSObject.Properties.Name)
    if ($names -contains 'retryStreak' -and $null -ne $s.retryStreak) { return [int]$s.retryStreak }
    if ($names -contains 'pipeline') {
        $pn = @($s.pipeline.PSObject.Properties.Name)
        if ($pn -contains 'retryStreak' -and $null -ne $s.pipeline.retryStreak) { return [int]$s.pipeline.retryStreak }
    }
    return 0
}

function Get-StateAnalyze($s) {
    if ($null -eq $s) { return -1 }
    if (@($s.PSObject.Properties.Name) -contains 'pipeline') {
        $pn = @($s.pipeline.PSObject.Properties.Name)
        if ($pn -contains 'analyzeCount') { return [int]$s.pipeline.analyzeCount }
    }
    return -1
}

# 单行摘要：turn/phase/curMsg/seq/awaiting/retryCount/win/winReason/lp/张数/管线分析计数
function Fmt-State($s) {
    if ($null -eq $s) { return 'none' }
    $names = @($s.PSObject.Properties.Name)
    $lp = '-'; if ($names -contains 'lp') { $lp = ($s.lp -join '/') }
    $cnt = '-'
    if ($names -contains 'counts') { $cnt = 'h' + ($s.counts.hand -join '/') + ' g' + ($s.counts.grave -join '/') }
    $phName = ''
    if ($names -contains 'phaseName') { $phName = '(' + $s.phaseName + ')' }
    $wrName = ''
    if ($names -contains 'winReasonName') { $wrName = '/' + $s.winReasonName }
    return ('turn={0} ph={1}{2} msg={3} seq={4} aw={5} retry={6} an={7} win={8}/{9}{10} lp={11} {12}' -f `
        $s.turn, $s.phase, $phName, $s.curMsg, $s.seq, $s.awaiting, (Get-StateRetry $s), (Get-StateAnalyze $s), $s.winPlayer, $s.winReason, $wrName, $lp, $cnt)
}

# 决策数：只数 bot 的动作行 `[sem] #<n> ...`（心跳 hb / STALL / http-err 行不算）
function Count-Decisions([string]$path) {
    if (-not (Test-Path $path)) { return 0 }
    $n = 0
    foreach ($ln in (Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($ln -match '^\[sem\] #\d+ ') { $n++ }
    }
    return $n
}

# escalate 次数：优先取心跳行里的 esc=N（新版 bot），再数 `[sem] escalate` 行，取较大者
function Get-Escalations([string]$path) {
    if (-not (Test-Path $path)) { return 0 }
    $maxEsc = 0
    $lines = 0
    foreach ($ln in (Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($ln -match '\besc=(\d+)') { $v = [int]$matches[1]; if ($v -gt $maxEsc) { $maxEsc = $v } }
        if ($ln -match '\[sem\]\s+escalat') { $lines++ }
    }
    return [Math]::Max($maxEsc, $lines)
}

# 重试数：宿主客户端 control-<pid>.log 里 `RETRY after msg=` 的行数（task-12 的客户端才写这种行）。
# 老版本客户端没有该行 -> 退化为数 `OnMessageBegin len=1 id=1`（MSG_RETRY 的调试行），并标记 estimated。
function Count-Retries([string]$path) {
    $res = [pscustomobject]@{ Count = 0; Estimated = $false; Source = 'none' }
    if ([string]::IsNullOrEmpty($path) -or -not (Test-Path $path)) { return $res }
    $lines = @(Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    $n = 0
    foreach ($ln in $lines) { if ($ln -match 'RETRY after msg=') { $n++ } }
    if ($n -gt 0) { $res.Count = $n; $res.Estimated = $false; $res.Source = 'RETRY after msg='; return $res }
    $n2 = 0
    foreach ($ln in $lines) { if ($ln -match 'OnMessageBegin len=1 id=1$') { $n2++ } }
    if ($n2 -gt 0) { $res.Count = $n2; $res.Estimated = $true; $res.Source = 'id=1(MSG_RETRY)'; return $res }
    return $res
}

# 找到本局宿主客户端的 control-<pid>.log（客户端 cwd = mycard-bot\game）
function Find-HostControlLog($hostPids, $sinceTime) {
    if ($null -ne $hostPids -and $hostPids.Count -gt 0) {
        foreach ($pid_ in $hostPids) {
            $p = Join-Path $gameDir ("control-{0}.log" -f $pid_)
            if (Test-Path $p) { return $p }
        }
    }
    $cand = @(Get-ChildItem $gameDir -Filter 'control-*.log' -File -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -ge $sinceTime } | Sort-Object LastWriteTime -Descending)
    if ($cand.Count -gt 0) { return $cand[0].FullName }
    return $null
}

function Get-LastLogLine([string]$path) {
    if (-not (Test-Path $path)) { return '(no bot log)' }
    $l = @(Get-Content $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($l.Count -eq 0) { return '(empty bot log)' }
    return $l[$l.Count - 1]
}

$victoryMap = Get-VictoryStrings

# ----------------------------------------------------------------------------- main
Write-Run "================================================================"
Write-Run ("LAN run start: games={0} deck='{1}' maxMin={2} hostHooks={3} guestHooks={4} stall={5}s placeCoords='{6}'" -f $Games, $Deck, $MaxMinutes, $Hooks, $GuestHooks, $StallSeconds, $PlaceCoords)
Write-Run "root=$root"
Write-Run ("victory strings loaded: {0}" -f $victoryMap.Count)

$results = @()
$exitCode = 0

try {
for ($g = 1; $g -le $Games; $g++) {
    Write-Run ""
    Write-Run "=== Game $g/$Games ==="
    $gameStart = Get-Date
    $ghLog = Join-Path $logDir ("lan-bot-host-{0}-g{1}.log" -f $stamp, $g)
    $ghErr = $ghLog + '.err'
    $ggLog = Join-Path $logDir ("lan-bot-guest-{0}-g{1}.log" -f $stamp, $g)
    $ggErr = $ggLog + '.err'
    $stateOut = Join-Path $logDir ("lan-state-{0}-g{1}.json" -f $stamp, $g)

    $winPlayer = -1
    $winReason = -1
    $turns = 0
    $endCause = ''
    $hostPid = @()
    $guestPid = @()

    # 1) 清场
    Write-Run "[1/8] cleanup"
    Stop-BotsFromPidFile
    Stop-BotProcs
    Stop-YgoProcs 'pre-game'
    Start-Sleep -Seconds 2
    if (-not (Test-Path $gameDir)) {
        Write-Run "  FATAL: game dir missing: $gameDir"
        $exitCode = 1
        break
    }

    # 2) 起 host
    Write-Run "[2/8] start host ($Hooks)"
    $before = @(Get-YgoProcs | ForEach-Object { $_.Id })
    try { Start-Client $hostCmd $Hooks $Deck } catch { Write-Run ("  FATAL: " + $_); $endCause = 'start-failed' }
    Start-Sleep -Seconds 9
    $hostPid = @(Get-YgoProcs | Where-Object { $before -notcontains $_.Id } | ForEach-Object { $_.Id })
    $hostHealth = $null
    for ($k = 0; $k -lt 3; $k++) {
        $hostHealth = Get-Health 7788
        if ($null -ne $hostHealth) { break }
        Start-Sleep -Seconds 2
    }
    Write-Run ("  host pid={0} control7788={1} procs={2}" -f ($hostPid -join ','), ($null -ne $hostHealth), @(Get-YgoProcs).Count)
    if ($hostPid.Count -gt 0) { Set-Content -Path $clientPidFile -Value $hostPid -Encoding ASCII }
    if ($null -eq $hostHealth) { $endCause = 'start-failed' }

    # 3) 起 guest
    if ($endCause -ne 'start-failed') {
        Write-Run "[3/8] start guest ($GuestHooks)"
        $before2 = @(Get-YgoProcs | ForEach-Object { $_.Id })
        try { Start-Client $guestCmd $GuestHooks $Deck } catch { Write-Run ("  FATAL: " + $_); $endCause = 'start-failed' }
        Start-Sleep -Seconds 10
        $guestPid = @(Get-YgoProcs | Where-Object { $before2 -notcontains $_.Id } | ForEach-Object { $_.Id })
        $guestHealth = $null
        for ($k = 0; $k -lt 3; $k++) {
            $guestHealth = Get-Health 7789
            if ($null -ne $guestHealth) { break }
            Start-Sleep -Seconds 2
        }
        Write-Run ("  guest pid={0} control7789={1} procs={2}" -f ($guestPid -join ','), ($null -ne $guestHealth), @(Get-YgoProcs).Count)
        if ($guestPid.Count -gt 0) { Add-Content -Path $clientPidFile -Value $guestPid -Encoding ASCII }
        if ($null -eq $guestHealth) { $endCause = 'start-failed' }
        if ($guestPid.Count -eq 0) { Write-Run '  warn: guest pid 未识别，将用最新 control 日志兜底' }
    }

    # 4) 备牌 + 准备 + 开局（整体最多 3 轮）
    if ($endCause -ne 'start-failed') {
        Write-Run "[4/8] deck/ready/start"
        $started = $false
        for ($attempt = 1; $attempt -le 3 -and -not $started; $attempt++) {
            Write-Run ("  attempt {0}/3" -f $attempt)
            $enc = [uri]::EscapeDataString($Deck)
            $null = Call-Api ("http://127.0.0.1:7788/deck?name=" + $enc) '7788 /deck'
            $null = Call-Api ("http://127.0.0.1:7789/deck?name=" + $enc) '7789 /deck'
            Start-Sleep -Seconds 2
            $null = Call-Api 'http://127.0.0.1:7788/ready' '7788 /ready'
            $null = Call-Api 'http://127.0.0.1:7789/ready' '7789 /ready'
            Start-Sleep -Seconds 2
            $lb = Http-GetJson 'http://127.0.0.1:7788/lobby'
            if ($null -ne $lb) { Write-Run ("  lobby={0}" -f ($lb | ConvertTo-Json -Compress)) }
            $null = Call-Api 'http://127.0.0.1:7788/start' '7788 /start'
            # 等开局（2026-11-08: SELECT_TP 现在由控制层决定 → 必须先答 TP，否则客户端不会 started）
            $deadlineStart = (Get-Date).AddSeconds(25)
            $tpPicked = $false
            while ((Get-Date) -lt $deadlineStart) {
                if (-not $tpPicked) {
                    foreach ($tpPort in 7788, 7789) {
                        $tpPrompt = Http-GetJson ("http://127.0.0.1:{0}/prompt" -f $tpPort) 3
                        if ($tpPrompt -and [bool]$tpPrompt.tpPending) {
                            $tpSeq = [int]$tpPrompt.seq
                            $tpUrl = "http://127.0.0.1:{0}/act_id?seq={1}&id=0" -f $tpPort, $tpSeq
                            $tpResp = Call-Api $tpUrl ("{0} /act_id(TP)" -f $tpPort)
                            Write-Run ("  TP pending on {0} -> answered first (seq={1}) resp={2}" -f $tpPort, $tpSeq, [string]$tpResp)
                            $tpPicked = $true
                            break
                        }
                    }
                }
                Start-Sleep -Seconds 2
                $hs = Get-State 7788
                $gs = Get-State 7789
                $hsOk = ($null -ne $hs) -and [bool]$hs.started
                $gsOk = ($null -ne $gs) -and [bool]$gs.started
                if ($hsOk -and $gsOk) { $started = $true; break }
            }
            if (-not $started) { Write-Run '  not started yet, retry' }
        }
        if (-not $started) { $endCause = 'no-start' }
    }

    # 5) 起双 bot
    $botH = $null; $botG = $null
    if ($endCause -eq '') {
        Write-Run "[5/8] start bots (MAX_MINUTES=$MaxMinutes)"
        $botH = Start-Bot 7788 $ghLog $ghErr
        $botG = Start-Bot 7789 $ggLog $ggErr
        Write-Run ("  bot host pid={0} log={1}" -f $botH.Id, (Split-Path -Leaf $ghLog))
        Write-Run ("  bot guest pid={0} log={1}" -f $botG.Id, (Split-Path -Leaf $ggLog))
        Set-Content -Path $botPidFile -Value @($botH.Id, $botG.Id) -Encoding ASCII
        Start-Sleep -Seconds 3
        $hs0 = Get-State 7788; $gs0 = Get-State 7789
        Write-Run ("  host  : " + (Fmt-State $hs0))
        Write-Run ("  guest : " + (Fmt-State $gs0))
    }

    # 6) 看门狗：每 2s 记录两端状态，胜/进程消失/卡死/超时/retry 风暴结束
    if ($endCause -eq '') {
        Write-Run "[6/8] watchdog"
        $wdStart = Get-Date
        $lastProgress = Get-Date
        $lastSig = ''
        $lastTurnSeen = -1
        $lastTurnChange = Get-Date
        while ($true) {
            $el = [int]((Get-Date) - $wdStart).TotalSeconds
            if ($el -ge ($MaxMinutes * 60)) { $endCause = 'deadline'; break }

            $hs = Get-State 7788
            $gs = Get-State 7789
            $procs = @(Get-YgoProcs)
            $nAlive = $procs.Count
            Write-Run ("  {0,4}s alive={1} | H {2} | G {3}" -f $el, $nAlive, (Fmt-State $hs), (Fmt-State $gs))

            if ($nAlive -lt 2) { $endCause = 'client-exit'; break }

            $wp = -1; $wr = -1
            if ($null -ne $hs -and $hs.winPlayer -ge 0) { $wp = $hs.winPlayer; $wr = $hs.winReason }
            if ($null -ne $gs -and $gs.winPlayer -ge 0) { $wp = $gs.winPlayer; $wr = $gs.winReason }
            if ($wp -ge 0) { $winPlayer = $wp; $winReason = $wr; $endCause = 'win'; break }

            # retry 风暴检测：
            #   主判据 = 连续被拒次数 retryStreak（同一提示反复被拒才是真死循环）；
            #   次判据 = 累计 retryCount 很高（>=30）也说明一直在被拒。
            # 两者都必须叠加"回合数长时间不动"，避免误杀正常推进的对局（正常局里偶发 1~2 次 RETRY 是允许的）。
            $retryNow = [Math]::Max((Get-StateRetry $hs), (Get-StateRetry $gs))
            $streakNow = [Math]::Max((Get-StateRetryStreak $hs), (Get-StateRetryStreak $gs))
            $turnNow = -1
            if ($null -ne $hs) { $turnNow = [int]$hs.turn }
            if ($null -ne $gs -and [int]$gs.turn -gt $turnNow) { $turnNow = [int]$gs.turn }
            if ($turnNow -ne $lastTurnSeen) { $lastTurnSeen = $turnNow; $lastTurnChange = Get-Date }
            $turnStuckSec = ((Get-Date) - $lastTurnChange).TotalSeconds
            if (($streakNow -ge 6 -or $retryNow -ge 30) -and $turnStuckSec -ge 30) {
                $endCause = 'retry-loop'
                Write-Run ("  retry loop detected: streak={0} retryCount={1}, turn stuck at {2} for {3:N0}s" -f $streakNow, $retryNow, $turnNow, $turnStuckSec)
                break
            }

            $sig = ''
            if ($null -ne $hs) { $sig += "H$($hs.turn)/$($hs.seq)/$($hs.phase)" }
            if ($null -ne $gs) { $sig += "G$($gs.turn)/$($gs.seq)/$($gs.phase)" }
            if ($sig -ne $lastSig) { $lastSig = $sig; $lastProgress = Get-Date }
            elseif (((Get-Date) - $lastProgress).TotalSeconds -ge $StallSeconds) {
                $endCause = 'stalled'; break
            }
            Start-Sleep -Seconds 2
        }
        Write-Run ("  end cause: {0}" -f $endCause)
    }

    # 7) 收尾 + 证据
    Write-Run "[7/8] collect evidence"
    $hsF = Get-State 7788
    $gsF = Get-State 7789
    if ($winPlayer -lt 0) {
        if ($null -ne $hsF -and $hsF.winPlayer -ge 0) { $winPlayer = $hsF.winPlayer; $winReason = $hsF.winReason }
        if ($null -ne $gsF -and $gsF.winPlayer -ge 0) { $winPlayer = $gsF.winPlayer; $winReason = $gsF.winReason }
    }
    $turns = 0
    if ($null -ne $hsF -and $hsF.turn -gt $turns) { $turns = $hsF.turn }
    if ($null -ne $gsF -and $gsF.turn -gt $turns) { $turns = $gsF.turn }

    try {
        $ev = [pscustomobject]@{
            stamp = $stamp; game = $g; deck = $Deck
            hostState = $hsF; guestState = $gsF
            endCause = $endCause
        }
        $ev | ConvertTo-Json -Depth 6 | Set-Content -Path $stateOut -Encoding UTF8
        Write-Run ("  final states -> {0}" -f (Split-Path -Leaf $stateOut))
    } catch { Write-Run ("  warn: cannot write state json: " + $_) }

    Start-Sleep -Seconds 2
    # 先按句柄杀本局 bot（CIM/WMI 在本机可能被策略拒绝，句柄是最可靠的）
    foreach ($bp in @($botH, $botG)) {
        if ($null -ne $bp) {
            try { if (-not $bp.HasExited) { Stop-Process -Id $bp.Id -Force -ErrorAction Stop; Write-Run ("  [kill] bot pid=" + $bp.Id) } } catch { }
        }
    }
    Stop-BotProcs
    Stop-BotsFromPidFile
    if (-not $KeepClients) { Stop-YgoProcs 'post-game' } else { Write-Run '  keep clients (KeepClients)' }

    $hostDec = Count-Decisions $ghLog
    $guestDec = Count-Decisions $ggLog
    $hostLast = Get-LastLogLine $ghLog
    $guestLast = Get-LastLogLine $ggLog

    # 重试指标：两端 control-<pid>.log 的 `RETRY after msg=` 行数（谁收到 RETRY 就是谁的响应非法）
    $hostCtl = Find-HostControlLog $hostPid $gameStart
    $guestCtl = Find-HostControlLog $guestPid $gameStart
    if ($guestCtl -eq $hostCtl) {
        # pid 识别失败时兜底：取本局时间内、与 host 不同的最新 control-*.log
        $cand = @(Get-ChildItem $gameDir -Filter 'control-*.log' -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -ne $hostCtl -and $_.LastWriteTime -ge $gameStart } |
                  Sort-Object LastWriteTime -Descending)
        if ($cand.Count -gt 0) { $guestCtl = $cand[0].FullName }
    }
    $retryH = Count-Retries $hostCtl
    $retryG = Count-Retries $guestCtl
    $retries = $retryH.Count + $retryG.Count
    $retrySource = $retryH.Source
    $retryEst = ($retryH.Estimated -or $retryG.Estimated)
    # /state 里的 retryCount 作为交叉验证（新版有顶层 retryCount，旧版只有 pipeline.retryCount）
    $retryStateH = Get-StateRetry $hsF
    $retryStateG = Get-StateRetry $gsF
    $retryState = [Math]::Max($retryStateH, $retryStateG)
    if ($retries -eq 0 -and $retryState -gt 0) { $retries = $retryState; $retryEst = $true; $retrySource = 'state.retryCount' }

    # bot 的 escalate 次数（新版 bot 心跳行里有 esc=N；也数 `[sem] escalate` 行）
    $escH = Get-Escalations $ghLog
    $escG = Get-Escalations $ggLog
    $escalations = [Math]::Max($escH, $escG)

    # 从两端 control 日志抽关键行（RESPONSE / RETRY / MSG_WIN / PIPE / stall），存证
    $excerpt = Join-Path $logDir ("lan-ctl-{0}-g{1}.txt" -f $stamp, $g)
    try {
        $keyLines = @()
        foreach ($pair in @(@('HOST', $hostCtl), @('GUEST', $guestCtl))) {
            $tag = $pair[0]; $path = $pair[1]
            if ([string]::IsNullOrEmpty($path) -or -not (Test-Path $path)) { continue }
            $hits = @(Select-String -Path $path -Pattern 'RETRY after msg=|RETRY loop detected|response: prompt=|PLACE resp|MSG_WIN player=|PIPE |retry: auto-dismissed|stall' -ErrorAction SilentlyContinue)
            $keep = $hits
            if ($hits.Count -gt 60) { $keep = $hits[($hits.Count - 60)..($hits.Count - 1)] }
            $keyLines += ('===== ' + $tag + ' ' + (Split-Path -Leaf $path) + ' (key lines: ' + $hits.Count + ') =====')
            foreach ($h in $keep) { $keyLines += ($h.Line) }
        }
        if ($keyLines.Count -gt 0) { $keyLines | Set-Content -Path $excerpt -Encoding UTF8 }
    } catch { Write-Run ("  warn: excerpt failed: " + $_) }

    # 单独抽 place(18) 的响应字节：retry 风暴 + 有 escalate 时，一次定位编码问题
    $placeFile = Join-Path $logDir ("lan-place-{0}-g{1}.txt" -f $stamp, $g)
    try {
        if ($retries -ge 8 -and $escalations -gt 0) {
            $pl = @()
            $pl += ('# place(MSG_SELECT_PLACE=18) 响应字节 / stamp=' + $stamp + ' game=' + $g + ' retries=' + $retries + ' esc=' + $escalations)
            foreach ($pair in @(@('HOST', $hostCtl), @('GUEST', $guestCtl))) {
                $tag = $pair[0]; $path = $pair[1]
                if ([string]::IsNullOrEmpty($path) -or -not (Test-Path $path)) { continue }
                $r = @(Select-String -Path $path -Pattern 'response: prompt=18|RETRY after msg=18|PLACE resp' -ErrorAction SilentlyContinue)
                $pl += ('===== ' + $tag + ' ' + (Split-Path -Leaf $path) + ' (lines: ' + $r.Count + ') =====')
                foreach ($h in $r) { $pl += $h.Line }
            }
            if ($pl.Count -gt 1) { $pl | Set-Content -Path $placeFile -Encoding UTF8 }
        }
    } catch { Write-Run ("  warn: place excerpt failed: " + $_) }

    $vicName = '未判定'
    if ($winReason -ge 0) {
        $stateName = $null
        foreach ($s in @($hsF, $gsF)) {
            if ($null -ne $s -and @($s.PSObject.Properties.Name) -contains 'winReasonName' -and [int]$s.winReason -ge 0) { $stateName = [string]$s.winReasonName }
        }
        if (-not [string]::IsNullOrEmpty($stateName) -and $stateName -ne 'UNKNOWN') { $vicName = $stateName }
        elseif ($victoryMap.ContainsKey($winReason)) { $vicName = $victoryMap[$winReason] }
        else { $vicName = ('unknown(0x{0:x})' -f $winReason) }
    }

    # 自然胜负（lead 口径）：winPlayer>=0 且 retries<5 且对局是正常打完（win 收尾、非投降/超时/断线）
    $natural = $false
    if ($winPlayer -ge 0 -and $retries -lt 5 -and $endCause -eq 'win' -and $winReason -ne 0 -and $winReason -ne 3 -and $winReason -ne 4) { $natural = $true }
    $dur = [int]((Get-Date) - $gameStart).TotalSeconds

    Write-Run ("  host decisions : {0}  last: {1}" -f $hostDec, $hostLast)
    Write-Run ("  guest decisions: {0}  last: {1}" -f $guestDec, $guestLast)
    Write-Run ("  retries: host={0} guest={1} total={2} (source={3}, estimated={4}) stateRetry host={5} guest={6}" -f `
        $retryH.Count, $retryG.Count, $retries, $retrySource, $retryEst, $retryStateH, $retryStateG)
    Write-Run ("  escalations: host={0} guest={1}" -f $escH, $escG)
    Write-Run ("  ctl logs: host={0} guest={1}  excerpt={2}  place={3}" -f (Split-Path -Leaf $hostCtl), (Split-Path -Leaf $guestCtl), (Split-Path -Leaf $excerpt), (Split-Path -Leaf $placeFile))
    Write-Run ("  turns={0} winPlayer={1} winReason={2} ({3}) natural={4} duration={5}s" -f $turns, $winPlayer, $winReason, $vicName, $natural, $dur)

    $results += [pscustomobject]@{
        Game          = $g
        HostDec       = $hostDec
        GuestDec      = $guestDec
        RetriesH      = $retryH.Count
        RetriesG      = $retryG.Count
        Retries       = $retries
        RetryEst      = $retryEst
        Escalations   = $escalations
        Turns         = $turns
        WinPlayer     = $winPlayer
        WinReason     = $winReason
        WinReasonName = $vicName
        Natural       = $natural
        DurationSec   = $dur
        EndCause      = $endCause
    }
    if ($endCause -eq 'start-failed' -or $endCause -eq 'no-start') { $exitCode = 1 }

    if ($g -lt $Games) {
        Write-Run "[8/8] gap 5s before next game"
        Start-Sleep -Seconds 5
    }
}
} finally {
    # 无论正常结束、异常、还是提前退出，都保证按路径清掉客户端与 bot（避免留孤儿）
    Write-Run '[finally] guaranteed cleanup: bots + clients'
    Stop-BotsFromPidFile
    Stop-BotProcs
    Stop-YgoProcs 'finally'
    Write-Run '[finally] done'
}

# ----------------------------------------------------------------------------- summary
Write-Run ""
Write-Run "================================================================"
Write-Run "SUMMARY"
$lines = @()
$lines += ('run log   : ' + $runLog)
$lines += ('games     : ' + $Games + '  deck=' + $Deck)
foreach ($r in $results) {
    $est = ''
    if ($r.RetryEst) { $est = '~' }
    $lines += ('  G{0}  hostDec={1,3}  guestDec={2,3}  retries(H/G)={3}{4}/{5}  esc={6}  turns={7,3}  win={8}  reason={9} ({10})  natural={11}  {12}s  {13}' -f `
        $r.Game, $r.HostDec, $r.GuestDec, $r.RetriesH, $est, $r.RetriesG, $r.Escalations, $r.Turns, $r.WinPlayer, $r.WinReason, $r.WinReasonName, $r.Natural, $r.DurationSec, $r.EndCause)
}
$completed = @($results | Where-Object { $_.EndCause -ne 'start-failed' -and $_.EndCause -ne 'no-start' }).Count
$naturalCnt = @($results | Where-Object { $_.Natural }).Count
$lines += ('completed : ' + $completed + '/' + $results.Count + '   natural wins: ' + $naturalCnt)
foreach ($l in $lines) { Write-Host $l; Add-Content -Path $runLog -Value $l -Encoding UTF8 }

if ($results.Count -gt 0) {
    Write-Host ''
    $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

Stop-BotsFromPidFile
Stop-BotProcs
Stop-YgoProcs 'final'
exit $exitCode
