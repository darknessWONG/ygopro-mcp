# Capture the two YGOPro client windows to PNG files.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File bridge\shot.ps1 -Tag ui1
param(
    [string]$Tag = 'shot',
    [string]$OutDir = 'ranked\logs'
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinShot {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

function Save-WindowShot {
    param([IntPtr]$Handle, [string]$Path)
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    $r = New-Object WinShot+RECT
    if (-not [WinShot]::GetWindowRect($Handle, [ref]$r)) { return $false }
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { return $false }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [WinShot]::PrintWindow($Handle, $hdc, 2)  # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    if (-not $ok) {
        # fall back to a screen copy of the window rect
        $bmp2 = New-Object System.Drawing.Bitmap($w, $h)
        $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
        $g2.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
        $g2.Dispose()
        $bmp.Dispose()
        $bmp = $bmp2
    }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $true
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$procs = @(Get-Process YGOPro -ErrorAction SilentlyContinue | Sort-Object Id)
$i = 0
foreach ($p in $procs) {
    $i++
    $path = Join-Path $OutDir ("lan-{0}-{1}.png" -f $Tag, $i)
    $ok = Save-WindowShot -Handle $p.MainWindowHandle -Path $path
    if ($ok) { Write-Output ("saved pid={0} -> {1}" -f $p.Id, $path) }
    else { Write-Output ("failed pid={0} (handle={1})" -f $p.Id, $p.MainWindowHandle) }
}
if ($procs.Count -eq 0) { Write-Output 'no YGOPro process running' }
