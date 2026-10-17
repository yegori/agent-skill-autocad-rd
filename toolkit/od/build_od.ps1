# Сборка ОД по образцу: копия образца ОД + копия штампа (внешней ссылки) -> генератор .scr -> accoreconsole -> проверочная печать.
#   .\build_od.ps1 -SampleDwg "…\образец\001 ОД.dwg" -Gen "…\мой_gen_od.py" -Key 41 [-Layout "ОД"] [-OutDir C:\…\od_41]
# Генератор вызывается так:  python -I gen.py <base.dxf> <out_dir> <key>  и должен записать <key>_od.scr и (необязательно) <key>_sh.scr
# (см. example_gen_od.py, библиотека od_lib.py). base.dxf — DXF-выгрузка образца (нужна, чтобы найти handle старых таблиц).
# Результат: <OutDir>\od.dwg, <OutDir>\Внешние_ссылки\штамп.dwg (+ подписи), <OutDir>\check.pdf. В выдачу копировать вручную.
param([Parameter(Mandatory)][string]$SampleDwg, [Parameter(Mandatory)][string]$Gen, [Parameter(Mandatory)][string]$Key,
      [string]$Layout = "ОД", [string]$OutDir = "")
. "$PSScriptRoot\..\common.ps1"
$G = Join-Path $WorkRoot "od"; New-Item -ItemType Directory -Force $G | Out-Null
if (-not $OutDir) { $OutDir = Join-Path $G "w$Key" }
$srcDir = Split-Path $SampleDwg
# 1. DXF образца (кэш по дате изменения образца)
$stamp = (Get-Item -LiteralPath $SampleDwg).LastWriteTime.ToString("yyyyMMddHHmmss")
$base = Join-Path $G "base_$stamp.dxf"
if (-not (Test-Path $base)) {
  Copy-Item -LiteralPath $SampleDwg "$G\base.dwg" -Force
  $null = Invoke-AccCore "$G\base.dwg" ($LispHead + "(command `"_.DXFOUT`" `"$($base -replace '\\','/')`" `"_V`" `"2018`" `"16`")`n" + $LispQuit) "$G\base.log"
}
# 2. генератор
python -I -X utf8 $Gen $base $G $Key
if ($LASTEXITCODE -ne 0) { throw "генератор завершился с ошибкой" }
# 3. копии образца и штампа, правка
New-Item -ItemType Directory -Force "$OutDir\Внешние_ссылки" | Out-Null
Copy-Item -LiteralPath $SampleDwg "$OutDir\od.dwg" -Force
if (Test-Path -LiteralPath "$srcDir\Внешние_ссылки") { Copy-Item -Path "$srcDir\Внешние_ссылки\*" "$OutDir\Внешние_ссылки\" -Recurse -Force }
$ok = { param($r) (($r | Where-Object { $_ -match "^(OK|FAIL)-|^DONE" } | ForEach-Object { $_.Split('"')[0].Trim() }) -join " ") }
if (Test-Path "$G\${Key}_sh.scr") {
  $r = Invoke-AccCore "$OutDir\Внешние_ссылки\штамп.dwg" (Get-Content "$G\${Key}_sh.scr" -Raw -Encoding 1251) "$OutDir\sh.log"; "штамп: " + (& $ok $r)
}
$r = Invoke-AccCore "$OutDir\od.dwg" (Get-Content "$G\${Key}_od.scr" -Raw -Encoding 1251) "$OutDir\od.log"; "ОД:    " + (& $ok $r)
# 4. проверочная печать (на копии — PLOT не должен менять результат)
Copy-Item "$OutDir\od.dwg" "$OutDir\odp.dwg" -Force
$null = Invoke-AccCore "$OutDir\odp.dwg" ($LispHead + $LispPlot + "(setvar `"CTAB`" `"$Layout`")`n(plotpdf `"$(($OutDir -replace '\\','/'))/check.pdf`")`n" + $LispQuit) "$OutDir\plot.log"
Remove-Item "$OutDir\odp.dwg" -ErrorAction SilentlyContinue
"проверочная печать: $OutDir\check.pdf  (FAIL-… выше = handle не найден в образце)"
