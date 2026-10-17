# Сборка ОД + штампа (+ обложки) для водопропуска по образцу В-5А-2 ИЗ11.
# Запуск из PowerShell (не из Git Bash):
#   .\run_od.ps1 -Keys 54            # собрать во временной папке + проверочная печать
#   .\run_od.ps1 -Keys 54 -Deploy    # + создать папку выдачи «<сооружение>\<дата> - 01_B590.110504.1.6-<ИЗ>»
# Параметры сооружения — в gen_od.py (словарь S) и в $map ниже.
param([string[]]$Keys, [switch]$Deploy, [string]$Date = (Get-Date -Format "yyyy.MM.dd"))

$here = $PSScriptRoot
$b    = Split-Path (Split-Path $here)                     # ...\Водопропуски
$src  = "$b\В-5А-2\2026.10.14 - 01_B590.110504.1.6-ИЗ11\DWG"  # образец
$G    = "C:\Users\yegori\AppData\Local\Temp\acc\gen"      # короткий путь без кириллицы для accoreconsole
$acc  = "C:\Program Files\Autodesk\AutoCAD 2024\accoreconsole.exe"
# ключ -> сооружение, шифр, трасса
$map = @{ "52"=@("В-5А-2","ИЗ11","T5A"); "41"=@("В-4А-1","ИЗ1","T4A"); "42"=@("В-4А-2","ИЗ2","T4A");
          "43"=@("В-4А-3","ИЗ3","T4A"); "53"=@("В-5А-3","ИЗ12","T5A"); "54"=@("В-5А-4","ИЗ13","T5A") }

function RunAcc($dwg, $scr, $log) {
  $p = Start-Process -FilePath $acc -ArgumentList "/i `"$dwg`" /s `"$scr`" /l ru-RU" -NoNewWindow -PassThru -RedirectStandardOutput $log
  if (-not $p.WaitForExit(300000)) { $p.Kill(); return "KILLED" }
  $t = (Get-Content $log -Raw) -replace "`0",""
  return (($t -split "`n" | Select-String -Pattern "^(OK|FAIL)-|^DONE" | ForEach-Object { $_.Line.Split('"')[0].Trim() }) -join " ")
}

New-Item -ItemType Directory -Force $G | Out-Null
# 1. DXF образца (нужен gen_od.py, чтобы найти старые объекты ведомостей)
if (-not (Test-Path "$G\base.dxf")) {
  Copy-Item -LiteralPath "$src\001 ОД.dwg" "$G\base.dwg" -Force
  Set-Content "$G\base.scr" "(setvar `"FILEDIA`" 0)`r`n(command `"_.DXFOUT`" `"$($G -replace '\\','/')/base.dxf`" `"_V`" `"2018`" `"16`")`r`n_.QUIT`r`n_Y`r`n" -Encoding ascii -NoNewline
  RunAcc "$G\base.dwg" "$G\base.scr" "$G\base.log" | Out-Null
}

foreach ($k in $Keys) {
  $code, $iz, $tr = $map[$k]
  python -I -X utf8 "$here\gen_od.py" "$G\base.dxf" $G $k
  $w = "$G\w$k"; New-Item -ItemType Directory -Force "$w\Внешние_ссылки\подписи" | Out-Null
  Copy-Item -LiteralPath "$src\001 ОД.dwg" "$w\od.dwg" -Force
  Copy-Item -LiteralPath "$src\Внешние_ссылки\штамп.dwg" "$w\Внешние_ссылки\штамп.dwg" -Force
  Copy-Item "$src\Внешние_ссылки\подписи\*" "$w\Внешние_ссылки\подписи\" -Force
  "$k штамп: " + (RunAcc "$w\Внешние_ссылки\штамп.dwg" "$G\${k}_sh.scr" "$w\sh.log")
  "$k ОД:    " + (RunAcc "$w\od.dwg" "$G\${k}_od.scr" "$w\od.log")
  # 2. проверочная печать (на копии — PLOT не должен трогать результат)
  Copy-Item "$w\od.dwg" "$w\odp.dwg" -Force
  $scr = "(setvar `"FILEDIA`" 0)`r`n(setvar `"CTAB`" `"ОД`")`r`n(command `"_.-PLOT`" `"_N`" `"`" `"`" `"DWG To PDF.pc3`" `"$(($w -replace '\\','/'))/check.pdf`" `"_N`" `"_Y`")`r`n_.QUIT`r`n_Y`r`n"
  [IO.File]::WriteAllText("$w\plot.scr", $scr, [Text.Encoding]::GetEncoding(1251))   # кириллица в .scr — только cp1251
  RunAcc "$w\odp.dwg" "$w\plot.scr" "$w\plot.log" | Out-Null
  "$k проверочная печать: $w\check.pdf"

  if ($Deploy) {
    $root = "$b\$code\$Date - 01_B590.110504.1.6-$iz"
    if (Test-Path -LiteralPath "$root\DWG\001 ОД.dwg") { "$k : $root\DWG\001 ОД.dwg уже есть — не перезаписываю"; continue }
    New-Item -ItemType Directory -Force "$root\DWG\Внешние_ссылки\подписи", "$root\PDF", "$b\$code\_claude" | Out-Null
    Copy-Item "$w\od.dwg" "$root\DWG\001 ОД.dwg"
    Copy-Item "$w\Внешние_ссылки\штамп.dwg" "$root\DWG\Внешние_ссылки\штамп.dwg" -Force
    Copy-Item "$w\Внешние_ссылки\подписи\*" "$root\DWG\Внешние_ссылки\подписи\" -Force
    Copy-Item "$w\check.pdf" "$b\$code\_claude\ОД_${iz}_проверочная_печать_$Date.pdf" -Force
    # обложка: копия обложки В-5А-2 ИЗ11 с заменой трёх фраз (не трогать «T5A» в названии проекта!)
    $doc = "$root\DWG\01_В590_110504_1_6_$iz.doc"
    Copy-Item -LiteralPath "$src\01_В590_110504_1_6_ИЗ11.doc" $doc
    $wd = New-Object -ComObject Word.Application; $wd.Visible = $false
    try {
      $d = $wd.Documents.Open($doc, $false, $false)
      foreach ($p in @(@("ВОДОПРОПУСКНОЕ СООРУЖЕНИЕ В-5А-2", "ВОДОПРОПУСКНОЕ СООРУЖЕНИЕ $code"),
                       @("ГОРНОЛЫЖНАЯ ТРАССА T5A", "ГОРНОЛЫЖНАЯ ТРАССА $tr"),
                       @("01/B590.110504.1.6-ИЗ11", "01/B590.110504.1.6-$iz"))) {
        $f = $d.Content.Find; $null = $f.Execute($p[0], $true, $false, $false, $false, $false, $true, 0, $false, $p[1], 2) }
      $d.Save(); $d.ExportAsFixedFormat("$root\PDF\01_В590_110504_1_6_$iz.pdf", 17); $d.Close($false)
    } finally { $wd.Quit() }
    "$k развернуто: $root"
  }
}
