# Печать всех листов комплекта в PDF\по листам + сборка комплекта PDF\01_В590_110504_1_6_ИЗn.pdf
# (первые 2 страницы — обложка и титул из текущего комплекта, далее листы по номерам).
#   .\plot_pd.ps1 -Iz ИЗ16,ИЗ18,ИЗ19 [-Override @{ "ИЗ19|002 Разрез 1-1.dwg" = "C:\...\k12_fix.dwg" }]
# Номера листов — из имени DWG («009,012 …»), по порядку вкладок макетов; имена PDF — как уже лежат в «по листам».
param([string[]]$Iz, [hashtable]$Override = @{})
$b   = Split-Path (Split-Path $PSScriptRoot)
$acc = "C:\Program Files\Autodesk\AutoCAD 2024\accoreconsole.exe"
$lsp = @'
(setvar "FILEDIA" 0)
(setvar "CMDECHO" 0)
(setq L nil)
(foreach x (dictsearch (namedobjdict) "ACAD_LAYOUT")
  (if (= (car x) 3) (setq nm (cdr x)))
  (if (and (= (car x) 350) (/= nm "Model"))
    (setq L (cons (cons (cdr (assoc 71 (entget (cdr x)))) nm) L))))
(setq L (vl-sort L (function (lambda (a b) (< (car a) (car b))))) i 0)
(foreach x L
  (setq i (1+ i))
  (setvar "CTAB" (cdr x))
  (command "_.-PLOT" "_N" "" "" "DWG To PDF.pc3" (strcat OUTD "/p" (itoa i) ".pdf") "_N" "_Y")
  (princ (strcat "\nPLOT-" (itoa i))))
(princ (strcat "\nCOUNT-" (itoa i)))
(command "_.QUIT" "_N")
'@
foreach ($iz in $Iz) {
  $root = (Get-ChildItem -LiteralPath $b -Directory -Filter "*$iz *" | % { Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "2026.10.14 - *" }).FullName
  $pl = "$root\PDF\по листам"
  $names = @{}; Get-ChildItem -LiteralPath $pl -Filter *.pdf | % { $names[[int]$_.Name.Substring(0, 3)] = $_.Name }
  $w = "C:\Users\yegori\AppData\Local\Temp\acc\plot_$($iz.Substring(2))"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $w | Out-Null
  Copy-Item -LiteralPath "$root\DWG\Внешние_ссылки" "$w\" -Recurse -Force
  $i = 0; $got = @{}
  foreach ($f in Get-ChildItem -LiteralPath "$root\DWG" -Filter *.dwg | Sort Name) {
    $i++; $nums = @(($f.Name -split ' ')[0] -split ',' | % { [int]$_ })
    $src = $Override["$iz|$($f.Name)"]; if (-not $src) { $src = $f.FullName }
    Copy-Item -LiteralPath $src "$w\f$i.dwg" -Force
    New-Item -ItemType Directory -Force "$w\o$i" | Out-Null
    [IO.File]::WriteAllText("$w\f$i.scr", "(setq OUTD `"$(("$w\o$i") -replace '\\','/')`")`r`n" + $lsp, [Text.Encoding]::GetEncoding(1251))
    $p = Start-Process $acc -ArgumentList "/i `"$w\f$i.dwg`" /s `"$w\f$i.scr`" /l ru-RU" -NoNewWindow -PassThru -RedirectStandardOutput "$w\f$i.log"
    if (-not $p.WaitForExit(900000)) { $p.Kill(); "$iz $($f.Name): KILLED" }
    $pdfs = @(Get-ChildItem "$w\o$i" -Filter "p*.pdf" | Sort { [int]$_.BaseName.Substring(1) })
    if ($pdfs.Count -ne $nums.Count) { "$iz $($f.Name): макетов напечатано $($pdfs.Count), номеров в имени $($nums.Count) — !!! проверить"; }
    for ($j = 0; $j -lt [Math]::Min($pdfs.Count, $nums.Count); $j++) { $got[$nums[$j]] = $pdfs[$j].FullName }
    "$iz $($f.Name): листы $($nums -join ',') ok"
  }
  foreach ($n in $got.Keys) { Copy-Item $got[$n] "$pl\$($names[$n])" -Force }
  "$iz : напечатано $($got.Count) из $($names.Count)"
  # комплект: обложка+титул (стр. 1–2 текущего файла) + листы
  $set = "$root\PDF\01_В590_110504_1_6_$iz.pdf"
  python -I -X utf8 -c @"
import pymupdf, glob, os, sys
set_, pl = sys.argv[1], sys.argv[2]
c = pymupdf.open(set_); out = pymupdf.open(); out.insert_pdf(c, from_page=0, to_page=1); c.close()
for s in sorted(glob.glob(os.path.join(pl, '[0-9][0-9][0-9] *.pdf'))): out.insert_pdf(pymupdf.open(s))
out.save(set_ + '.tmp', garbage=3, deflate=True); n = len(out); out.close(); os.replace(set_ + '.tmp', set_); print('комплект', n, 'стр.')
"@ $set $pl
}
