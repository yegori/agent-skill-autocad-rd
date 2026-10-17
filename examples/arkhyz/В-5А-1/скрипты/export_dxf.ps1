# Выгрузка DWG -> DXF (R2018) через консольный AutoCAD без интерфейса.
# Открытая сессия AutoCAD не затрагивается, исходные DWG открываются только на чтение.
#
# Запуск:  .\export_dxf.ps1 -Src "<папка выдачи>\dwg" -Work "C:\Users\yegori\AppData\Local\Temp\acc"
# Важно:
#  - запускать из PowerShell, не из Git Bash (Bash портит ключи /i и /s);
#  - Work — короткий путь без кириллицы, туда копируются DWG под латинскими именами;
#  - AutoCAD не загружает .lsp вне доверенных папок (SECURELOAD), поэтому LISP пишем прямо в .scr.
param(
    [string]$Src,
    [string]$Work = "C:\Users\yegori\AppData\Local\Temp\acc",
    [hashtable]$Files = @{
        "d002" = "002 План,Разрез,цпп.dwg"
        "d005" = "005 Км-1.dwg"
        "d006" = "006 Выходные_крепления_В-5А-1.dwg"
        "d007" = "007 Защита откосов.dwg"
    }
)
$acc = "C:\Program Files\Autodesk\AutoCAD 2024\accoreconsole.exe"
New-Item -ItemType Directory -Force $Work | Out-Null
$workFwd = $Work -replace "\\", "/"
foreach ($n in $Files.Keys) {
    Copy-Item -LiteralPath (Join-Path $Src $Files[$n]) "$Work\$n.dwg" -Force
    $scr = "(setvar `"FILEDIA`" 0)`r`n(command `"_.DXFOUT`" `"$workFwd/$n.dxf`" `"_V`" `"2018`" `"16`")`r`n(princ `"DONE-EXPORT`")`r`n_.QUIT`r`n_Y`r`n"
    Set-Content -Path "$Work\$n.scr" -Value $scr -Encoding ascii -NoNewline
    $p = Start-Process -FilePath $acc -ArgumentList "/i `"$Work\$n.dwg`" /s `"$Work\$n.scr`" /readonly" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$Work\$n.log"
    if (-not $p.WaitForExit(600000)) { $p.Kill(); "$n : KILLED (timeout)" ; continue }
    $ok = ((Get-Content "$Work\$n.log" -Raw) -replace "`0", "") -match "DONE-EXPORT"
    "$n : $ok"
}
