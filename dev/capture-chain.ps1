# Poll both control ports for chain prompts and save any with chainDepth >= 2.
param(
    [int]$Seconds = 600,
    [string]$OutDir = 'ranked\logs\chain-capture'
)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$deadline = (Get-Date).AddSeconds($Seconds)
$best = 0
while ((Get-Date) -lt $deadline) {
    foreach ($port in 7788, 7789) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/prompt" -TimeoutSec 3 -UseBasicParsing
            $o = $r.Content | ConvertFrom-Json
            $d = [int]$o.chainDepth
            if ($d -ge 2 -and $o.seq) {
                $f = Join-Path $OutDir ("chain-p{0}-seq{1}-d{2}.json" -f $port, $o.seq, $d)
                if (-not (Test-Path $f)) {
                    $r.Content | Set-Content -Path $f -Encoding UTF8
                    Write-Output ("CAPTURED depth={0} port={1} seq={2} -> {3}" -f $d, $port, $o.seq, $f)
                }
                if ($d -gt $best) { $best = $d }
            }
        } catch { }
    }
    Start-Sleep -Milliseconds 400
}
Write-Output ("done; max chainDepth seen = {0}" -f $best)
