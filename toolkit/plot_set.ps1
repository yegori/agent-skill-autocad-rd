# Печать всех листов комплекта в PDF и сборка сводного PDF (обложка + листы по номерам).
#   .\plot_set.ps1 -DwgDir "…\DWG" -OutDir "…\PDF\по листам" [-Titles @{1="Общие данные"; 2="Разрез 1-1"}]
#                  [-CoverPdf "…\обложка.pdf" -CoverPages 2 -SetPdf "…\PDF\01_…_ИЗn.pdf"] [-Override @{"002 Разрез.dwg"="C:\копия.dwg"}]
# Номера листов — из начала имени DWG: «001 ОД.dwg», «004,005 Схема….dwg» (через запятую) или «004-005 …» (диапазон), в порядке ВКЛАДОК макетов.
# Файлы, подходящие под -Exclude (по умолчанию _recover), не печатаются.
# Файлы без номера в начале имени пропускаются. Имя PDF: «NNN <наименование>.pdf»; наименование — из -Titles,
# иначе из уже лежащего в OutDir «NNN *.pdf», иначе из имени DWG без номера.
# Печать — по параметрам листа, сохранённым в макете (DWG To PDF.pc3). Работа на копиях, исходники не меняются.
# Нужен python с pymupdf для сборки сводного PDF. Перед печатью — проверка форматов (check_papers.ps1 -Add); -NoPaperCheck отключает.
param([Parameter(Mandatory)][string]$DwgDir, [Parameter(Mandatory)][string]$OutDir, [hashtable]$Titles = @{},
      [string]$CoverPdf = "", [int]$CoverPages = 2, [string]$SetPdf = "", [hashtable]$Override = @{}, [string]$Exclude = '_recover', [switch]$NoPaperCheck)
. "$PSScriptRoot\common.ps1"
$w = Join-Path $WorkRoot "plotset"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $w, $OutDir | Out-Null
$existing = @{}; Get-ChildItem -LiteralPath $OutDir -Filter *.pdf -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(\d{3}) (.+)\.pdf$' } | ForEach-Object { $existing[[int]$Matches[1]] = $Matches[2] }
$rxNum = '^\d+([,-]\d+)*[ _]'
$all = Get-ChildItem -LiteralPath $DwgDir -Filter *.dwg
$files = $all | Where-Object { $_.Name -match $rxNum -and -not ($Exclude -and $_.Name -match $Exclude) } | Sort-Object Name
$all | Where-Object { $files.Name -notcontains $_.Name } | ForEach-Object { "пропущен (нет номера в имени или -Exclude): $($_.Name)" }
function Get-Nums($name) {   # «004-005» -> 4,5 ; «009,012» -> 9,12
  $r = @(); foreach ($p in ($name -split '[ _]')[0] -split ',') { if ($p -match '^(\d+)-(\d+)$') { $r += [int]$Matches[1]..[int]$Matches[2] } else { $r += [int]$p } }; $r }
# 0. Предварительная проверка форматов: нестандартные форматы, которых нет в «DWG To PDF» этого ПК, добавляются ДО печати
if (-not $NoPaperCheck) {
  & "$PSScriptRoot\check_papers.ps1" -Files ($files | ForEach-Object { if ($Override[$_.Name]) { $Override[$_.Name] } else { $_.FullName } }) -Add
  if ($global:PaperMissing) { throw "не удалось добавить форматы: $($global:PaperMissing -join '; ')" }
}
$jobs = Copy-DwgToWork ($files | ForEach-Object { if ($Override[$_.Name]) { $Override[$_.Name] } else { $_.FullName } }) $w
$got = @{}
for ($k = 0; $k -lt $files.Count; $k++) {
  $f = $files[$k]; $j = $jobs[$k]
  $nums = @(Get-Nums $f.Name)
  $od = Join-Path $w "o$($j.N)"; New-Item -ItemType Directory -Force $od | Out-Null
  $lsp = $LispHead + $LispLayouts + $LispPlot + @"
(setq i 0)
(foreach x L (setq i (1+ i)) (setvar "CTAB" (cdr x)) (plotpdf (strcat "$($od -replace '\\','/')/p" (itoa i) ".pdf")))
(princ "\nDONE-")
"@ + $LispQuit
  $null = Invoke-AccCore $j.Work $lsp (Join-Path $w "f$($j.N).log")
  $pdfs = @(Get-ChildItem $od -Filter "p*.pdf" | Sort-Object { [int]$_.BaseName.Substring(1) })
  $warn = if ($pdfs.Count -ne $nums.Count) { "  !!! макетов напечатано $($pdfs.Count), номеров в имени $($nums.Count) — проверить (лог: $w\f$($j.N).log; «Нет подходящего носителя» = нет формата в PMP)" } else { "" }
  "{0}: листы {1}{2}" -f $f.Name, ($nums -join ","), $warn
  for ($m = 0; $m -lt [Math]::Min($pdfs.Count, $nums.Count); $m++) {
    $n = $nums[$m]
    $t = if ($Titles[$n]) { $Titles[$n] } elseif ($existing[$n]) { $existing[$n] } else { ($f.BaseName -replace '^\d+([,-]\d+)*[ _]+', '') + $(if ($nums.Count -gt 1) { " ($n)" } else { "" }) }
    $dst = Join-Path $OutDir ("{0:000} {1}.pdf" -f $n, $t)
    Get-ChildItem -LiteralPath $OutDir -Filter ("{0:000} *.pdf" -f $n) | Where-Object { $_.FullName -ne $dst } | Remove-Item
    Copy-Item $pdfs[$m].FullName $dst -Force; $got[$n] = $dst
  }
}
"напечатано листов: $($got.Count)"
if ($SetPdf) {
  python -I -X utf8 "$PSScriptRoot\merge_set.py" $SetPdf $OutDir $CoverPdf $CoverPages
}
