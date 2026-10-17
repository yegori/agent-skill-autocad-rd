# Предварительная проверка форматов печати ДО печати: для каждого макета — формат листа и плоттер, есть ли формат на этом ПК.
#   .\check_papers.ps1 -Files a.dwg,b.dwg [-Add]          или   -DwgDir "…\DWG"
# Формат «UserDefinedMetric (…)» должен быть в PMP «DWG To PDF» (%APPDATA%\…\PMP Files\DWG To PDF.pmp), иначе печать
# молча не пройдёт («Нет подходящего носителя»). С -Add недостающие форматы добавляются (add_pmp_size.py, с копией PMP).
# Стандартные форматы (ISO_…, ANSI_…) не проверяются. Если плоттер макета не «DWG To PDF.pc3» — предупреждение:
# скрипты печати подставляют DWG To PDF.pc3, имена форматов у других плоттеров могут не совпасть.
# Возвращает (в конвейер) объекты @{File; Layout; Paper; Device; Status}; при вызове из скрипта — $global:PaperMissing.
param([string[]]$Files = @(), [string]$DwgDir = "", [switch]$Add, [string]$Exclude = '_recover', [string]$PmpPath = "")
. "$PSScriptRoot\common.ps1"
if ($DwgDir) { $Files += @(Get-ChildItem -LiteralPath $DwgDir -Filter *.dwg | Where-Object { -not ($Exclude -and $_.Name -match $Exclude) } | Sort-Object Name | ForEach-Object FullName) }
$pmp = if ($PmpPath) { $PmpPath } else { [Environment]::ExpandEnvironmentVariables('%APPDATA%\Autodesk\AutoCAD 2024\R24.3\rus\Plotters\PMP Files\DWG To PDF.pmp') }
$have = @()
if (Test-Path $pmp) {
  $j = (Get-Content $pmp -Raw -Encoding utf8) -replace '^[^\r\n]*\r?\n', '' | ConvertFrom-Json
  $sz = $j.data.udm.media.size
  if ($sz) { $have = @($sz.PSObject.Properties | ForEach-Object { $_.Value.name }) }
}
$w = Join-Path $WorkRoot "papers"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $w | Out-Null
$rows = @()
$i = 0
foreach ($f in $Files) {
  $i++; $lead = [regex]::Match((Split-Path $f -Leaf), '^[0-9A-Za-z_.,\-]+').Value.TrimEnd('.')
  $c = Join-Path $w ("{0}~{1}.dwg" -f $(if ($lead) { $lead } else { "f" }), $i)
  Copy-Item -LiteralPath $f $c -Force
  $out = (Join-Path $w "p$i.txt") -replace '\\', '/'
  $lsp = $LispHead + $LispLayouts + @"
(setq fo (open "$out" "w" "utf8"))
(foreach x L (setq ed (entget (cdr (assoc 350 (member (cons 3 (cdr x)) (dictsearch (namedobjdict) "ACAD_LAYOUT"))))))
  (write-line (strcat (cdr x) "|" (cdr (assoc 4 ed)) "|" (cdr (assoc 2 ed))) fo))
(close fo)
"@ + $LispQuit
  $null = Invoke-AccCore $c $lsp (Join-Path $w "p$i.log") 600
  $txt = Join-Path $w "p$i.txt"
  if (-not (Test-Path $txt)) { $rows += [pscustomobject]@{ File = (Split-Path $f -Leaf); Layout = "?"; Paper = "?"; Device = "?"; Status = "!!! не прочитан" }; continue }
  foreach ($l in Get-Content $txt -Encoding utf8) {
    $lay, $paper, $dev = $l -split '\|', 3
    $st = if ($paper -like 'UserDefined*') { if ($have -contains $paper) { "есть на ПК" } else { "НЕТ НА ПК" } } else { "стандартный" }
    if ($dev -and $dev -ne 'DWG To PDF.pc3') { $st += "; плоттер не DWG To PDF" }
    $rows += [pscustomobject]@{ File = (Split-Path $f -Leaf); Layout = $lay; Paper = $paper; Device = $dev; Status = $st }
  }
  Remove-Item $c -ErrorAction SilentlyContinue
}
$missing = @($rows | Where-Object { $_.Status -like 'НЕТ НА ПК*' } | ForEach-Object Paper | Sort-Object -Unique)
$global:PaperMissing = $missing
$rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
if ($missing) {
  Write-Host ("Нет на этом ПК: " + ($missing -join "; "))
  if ($Add) { python -I -X utf8 "$PSScriptRoot\add_pmp_size.py" @missing @(if ($PmpPath) { "--pmp"; $PmpPath }) | Write-Host; $global:PaperMissing = @() }
  else { Write-Host "Добавить: повторить с -Add (или python add_pmp_size.py ""<имя>"")" }
} else { Write-Host "Все форматы есть на этом ПК." }
