# Сборка ОД + штампа (+ обложки) площадного дренажа по образцу ОД водопропуска В-5А-2 ИЗ11.
# Запуск из PowerShell (не из Git Bash):
#   .\run_od_pd.ps1 -Keys 4A,5A,5B           # собрать во временной папке + проверочная печать
#   .\run_od_pd.ps1 -Keys 4A -Deploy         # + папка выдачи «<трасса>\<дата> - 01_B590.110504.1.6-<ИЗ>»
# Параметры — в gen_od_pd.py (словарь S) и в $map ниже.
param([string[]]$Keys, [switch]$Deploy, [string]$Date = (Get-Date -Format "yyyy.MM.dd"))

$here = $PSScriptRoot
$b    = Split-Path (Split-Path $here)                     # ...\площадной дренаж
$src  = "$(Split-Path $b)\Водопропуски\В-5А-2\2026.10.14 - 01_B590.110504.1.6-ИЗ11\DWG"  # образец ОД, штампа, обложки
$G    = "C:\Users\yegori\AppData\Local\Temp\acc\gen_pd"   # короткий путь без кириллицы для accoreconsole
$acc  = "C:\Program Files\Autodesk\AutoCAD 2024\accoreconsole.exe"
# ключ -> шифр, трасса, папка листов (относительно папки трассы), папка Трассы/съемка
$map = @{ "4A"=@("ИЗ16","T4A","2026.10.14\dwg","2026.10.14\dwg\Внешние_ссылки");
          "5A"=@("ИЗ18","T5A","2026.10.14\dwg","2026.10.14\dwg\Новая папка\Внешние_ссылки");
          "5B"=@("ИЗ19","T5B","2026.10.14\01 Ред. формат","2026.10.14\01 Ред. формат\Новая папка\Внешние_ссылки") }

function RunAcc($dwg, $scr, $log) {
  $p = Start-Process -FilePath $acc -ArgumentList "/i `"$dwg`" /s `"$scr`" /l ru-RU" -NoNewWindow -PassThru -RedirectStandardOutput $log
  if (-not $p.WaitForExit(300000)) { $p.Kill(); return "KILLED" }
  $t = (Get-Content $log -Raw) -replace "`0",""
  return (($t -split "`n" | Select-String -Pattern "^(OK|FAIL)-|^DONE" | ForEach-Object { $_.Line.Split('"')[0].Trim() }) -join " ")
}

New-Item -ItemType Directory -Force $G | Out-Null
if (-not (Test-Path "$G\base.dxf")) {
  Copy-Item -LiteralPath "$src\001 ОД.dwg" "$G\base.dwg" -Force
  Set-Content "$G\base.scr" "(setvar `"FILEDIA`" 0)`r`n(command `"_.DXFOUT`" `"$($G -replace '\\','/')/base.dxf`" `"_V`" `"2018`" `"16`")`r`n_.QUIT`r`n_Y`r`n" -Encoding ascii -NoNewline
  RunAcc "$G\base.dwg" "$G\base.scr" "$G\base.log" | Out-Null
}

foreach ($k in $Keys) {
  $iz, $tr, $dwgDir, $xrDir = $map[$k]
  $trail = (Get-ChildItem -LiteralPath $b -Directory | Where-Object { $_.Name -like "*-$iz *" }).FullName
  python -I -X utf8 "$here\gen_od_pd.py" "$G\base.dxf" $G $k
  $w = "$G\w$k"; New-Item -ItemType Directory -Force "$w\Внешние_ссылки\подписи" | Out-Null
  Copy-Item -LiteralPath "$src\001 ОД.dwg" "$w\od.dwg" -Force
  Copy-Item -LiteralPath "$src\Внешние_ссылки\штамп.dwg" "$w\Внешние_ссылки\штамп.dwg" -Force
  Copy-Item "$src\Внешние_ссылки\подписи\*" "$w\Внешние_ссылки\подписи\" -Force
  "$k штамп: " + (RunAcc "$w\Внешние_ссылки\штамп.dwg" "$G\${k}_sh.scr" "$w\sh.log")
  "$k ОД:    " + (RunAcc "$w\od.dwg" "$G\${k}_od.scr" "$w\od.log")
  Copy-Item "$w\od.dwg" "$w\odp.dwg" -Force
  $scr = "(setvar `"FILEDIA`" 0)`r`n(setvar `"CTAB`" `"ОД`")`r`n(command `"_.-PLOT`" `"_N`" `"`" `"`" `"DWG To PDF.pc3`" `"$(($w -replace '\\','/'))/check.pdf`" `"_N`" `"_Y`")`r`n_.QUIT`r`n_Y`r`n"
  [IO.File]::WriteAllText("$w\plot.scr", $scr, [Text.Encoding]::GetEncoding(1251))   # кириллица в .scr — только cp1251
  RunAcc "$w\odp.dwg" "$w\plot.scr" "$w\plot.log" | Out-Null
  "$k проверочная печать: $w\check.pdf"

  if ($Deploy) {
    $root = "$trail\$Date - 01_B590.110504.1.6-$iz"
    if (Test-Path -LiteralPath "$root\DWG\001 ОД.dwg") { "$k : $root\DWG\001 ОД.dwg уже есть — не перезаписываю"; continue }
    New-Item -ItemType Directory -Force "$root\DWG\Внешние_ссылки\подписи", "$root\PDF", "$trail\_claude" | Out-Null
    Copy-Item "$w\od.dwg" "$root\DWG\001 ОД.dwg"
    Copy-Item "$w\Внешние_ссылки\штамп.dwg" "$root\DWG\Внешние_ссылки\штамп.dwg" -Force
    Copy-Item "$w\Внешние_ссылки\подписи\*" "$root\DWG\Внешние_ссылки\подписи\" -Force
    foreach ($x in "Трассы.dwg", "съемка 500 этап 1.dwg") { Copy-Item -LiteralPath "$trail\$xrDir\$x" "$root\DWG\Внешние_ссылки\$x" -Force }
    # листы — как есть (номера листов в их штампах правит пользователь)
    Get-ChildItem -LiteralPath "$trail\$dwgDir" -Filter *.dwg | Where-Object { $_.Name -notmatch "_recover" } |
      ForEach-Object { Copy-Item -LiteralPath $_.FullName "$root\DWG\$($_.Name)" }
    if ($k -eq "5B") {   # у 5В в папке нет DWG «Разрез 1-1» — общий лист, берётся из 4А
      $t4 = (Get-ChildItem -LiteralPath $b -Directory | Where-Object { $_.Name -like "*-ИЗ16 *" }).FullName
      Copy-Item -LiteralPath "$t4\2026.10.14\dwg\004 Разрез 1-1.dwg" "$root\DWG\004 Разрез 1-1.dwg"
    }
    Copy-Item "$w\check.pdf" "$trail\_claude\ОД_${iz}_проверочная_печать_$Date.pdf" -Force
    # обложка: копия обложки В-5А-2 ИЗ11 с заменой трёх фраз (не трогать «T5A» в названии проекта!)
    $doc = "$root\DWG\01_В590_110504_1_6_$iz.doc"
    Copy-Item -LiteralPath "$src\01_В590_110504_1_6_ИЗ11.doc" $doc
    $wd = New-Object -ComObject Word.Application; $wd.Visible = $false
    try {
      $d = $wd.Documents.Open($doc, $false, $false)
      foreach ($p in @(@("ВОДОПРОПУСКНОЕ СООРУЖЕНИЕ В-5А-2", "ПЛОЩАДНОЙ ДРЕНАЖ"),
                       @("ГОРНОЛЫЖНАЯ ТРАССА T5A", "ГОРНОЛЫЖНАЯ ТРАССА $tr"),
                       @("01/B590.110504.1.6-ИЗ11", "01/B590.110504.1.6-$iz"))) {
        $f = $d.Content.Find; $null = $f.Execute($p[0], $true, $false, $false, $false, $false, $true, 0, $false, $p[1], 2) }
      $d.Save(); $d.ExportAsFixedFormat("$root\PDF\01_В590_110504_1_6_$iz.pdf", 17); $d.Close($false)
    } finally { $wd.Quit() }
    "$k развернуто: $root"
  }
}
