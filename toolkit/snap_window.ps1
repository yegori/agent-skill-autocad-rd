# Снимок окон процесса (диагностика зависшего AutoCAD: модальный диалог, ненажатый Enter в командной строке и т.п.).
#   .\snap_window.ps1 -ProcessName acad [-Out C:\…\snaps]       # все процессы acad.exe
#   .\snap_window.ps1 -ProcessId 12345
# Сохраняет PNG каждого видимого окна (PrintWindow — работает и для перекрытых окон) и печатает заголовки.
# Окно «Информация о прокси-объектах» = нужен PROXYNOTICE=0; команда в строке без выполнения = нет перевода строки в конце .scr.
param([string]$ProcessName = "", [int]$ProcessId = 0, [string]$Out = "")
. "$PSScriptRoot\common.ps1"
if (-not $Out) { $Out = Join-Path $WorkRoot ("snaps\" + (Get-Date -Format "yyyyMMdd_HHmmss")) }
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type -AssemblyName System.Drawing
if (-not ("RdWin" -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Text;
public class RdWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  public struct RECT { public int L, T, R, B; }
  public static List<IntPtr> Of(uint pid) { var r = new List<IntPtr>(); EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static string Title(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
}
"@
}
$procs = if ($ProcessId) { @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) } else { @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) }
if (-not $procs) { "процессов не найдено"; return }
foreach ($p in $procs) {
  $i = 0
  foreach ($h in [RdWin]::Of([uint32]$p.Id)) {
    $r = New-Object RdWin+RECT; [void][RdWin]::GetWindowRect($h, [ref]$r)
    $wdt = $r.R - $r.L; $hgt = $r.B - $r.T; $t = [RdWin]::Title($h)
    "{0} [{1}] {2}x{3} «{4}»" -f $p.ProcessName, $p.Id, $wdt, $hgt, $t
    if ($wdt -lt 20 -or $hgt -lt 20) { continue }
    $bmp = New-Object Drawing.Bitmap $wdt, $hgt; $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc(); [void][RdWin]::PrintWindow($h, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
    $i++; $f = Join-Path $Out ("{0}_{1}_{2}.png" -f $p.ProcessName, $p.Id, $i); $bmp.Save($f); $bmp.Dispose()
    "   -> $f"
  }
}
