# MASSPROP по 3D-телам ГСИ листа 006 (ряд 1 — inf_gsi_apron_mat, ряд 2 — inf_gsi_ditch_wall).
# На каждое тело пишется отдельный .mpr (объём, габаритная рамка). Разбор — analyze_006_gsi.py.
# Запуск из PowerShell после export_dxf.ps1 (нужна копия d006.dwg в $Work).
param([string]$Work = "C:\Users\yegori\AppData\Local\Temp\acc")
$acc = "C:\Program Files\Autodesk\AutoCAD 2024\accoreconsole.exe"
New-Item -ItemType Directory -Force "$Work\mp" | Out-Null
$out = ($Work -replace "\\", "/") + "/mp/"
$lsp = @"
(setvar "FILEDIA" 0)
(setvar "CMDECHO" 0)
(setq n 0)
(foreach lay '("inf_gsi_apron_mat" "inf_gsi_ditch_wall") (setq ss (ssget "_X" (list '(0 . "3DSOLID") (cons 8 lay))) i 0) (if ss (repeat (sslength ss) (command "_.MASSPROP" (ssname ss i) "" "_Y" (strcat "$out" lay "_" (itoa i) ".mpr")) (setq i (1+ i) n (1+ n)))))
(princ (strcat "DONE-MP " (itoa n)))
_.QUIT
_Y

"@
Set-Content -Path "$Work\mp.scr" -Value ($lsp -replace "`r?`n", "`r`n") -Encoding ascii -NoNewline
$p = Start-Process -FilePath $acc -ArgumentList "/i `"$Work\d006.dwg`" /s `"$Work\mp.scr`" /readonly" `
    -NoNewWindow -PassThru -RedirectStandardOutput "$Work\mp.log"
if (-not $p.WaitForExit(900000)) { $p.Kill(); "KILLED" }
(Get-ChildItem "$Work\mp" -Filter *.mpr).Count
