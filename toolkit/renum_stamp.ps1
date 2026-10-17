# Перенумерация листов в штампах: в макетах ищется TEXT/MTEXT с «<Prefix><N>» (напр. «Т7.12»), N заменяется по таблице.
# Остальной текст и формат MTEXT сохраняются (меняется только «<Prefix><N>» -> «<NewPrefix><новый>»).
#   .\renum_stamp.ps1 -Files a.dwg,b.dwg -Prefix "Т7." -Map @{4=2; 5=3} [-NewPrefix ""] [-PdfDir C:\…\pdf] [-Apply]
# Без -Apply — пробный прогон на копиях (ничего не сохраняется в исходники). С -Apply исходный DWG заменяется копией,
# только если все найденные номера заменены, файл не открыт у пользователя; оригинал — в <WorkRoot>\backup\renum_<дата>.
# С -PdfDir каждый изменённый макет печатается в <PdfDir>\l<новый>.pdf.
# Как найти Prefix: .\dump_layout_texts.ps1 -Dwg … (смотреть текст в графе «Лист» штампа). Т и T — разные буквы:
# скрипт принимает обе (кириллица/латиница) в первом символе префикса.
param([Parameter(Mandatory)][string[]]$Files, [Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][hashtable]$Map,
      [string]$NewPrefix = "", [string]$PdfDir = "", [switch]$Apply)
. "$PSScriptRoot\common.ps1"
$bak = Join-Path $WorkRoot ("backup\renum_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$w = Join-Path $WorkRoot "renum"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$jobs = Copy-DwgToWork $Files $w
$mapL = ($Map.GetEnumerator() | ForEach-Object { "($($_.Key) . $($_.Value))" }) -join ""
$rest = $Prefix.Substring(1); $c0 = $Prefix.Substring(0, 1)
$alt = @{ "Т" = "T"; "T" = "Т"; "А" = "A"; "A" = "А"; "В" = "B"; "B" = "В"; "С" = "C"; "C" = "С" }[$c0]
$firsts = ('"' + $c0 + '"') + $(if ($alt) { ' "' + $alt + '"' } else { "" })
if ($PdfDir) { New-Item -ItemType Directory -Force $PdfDir | Out-Null }
$pdfL = $PdfDir -replace '\\', '/'
$core = $LispHead + $LispLayouts + $LispPlot + @"
(setq MAP (quote ($mapL)) REST "$rest" FIRSTS (list $firsts) NEWP "$NewPrefix" OUTD "$pdfL" ok nil)
(defun fixlay (lay / ss i e ed s p q old new hit)
  (setq ss (ssget "_X" (list (cons 410 lay) (cons 0 "TEXT,MTEXT"))) i 0)
  (if ss (repeat (sslength ss)
    (setq e (ssname ss i) i (1+ i) ed (entget e) s (cdr (assoc 1 ed)) p (vl-string-search REST s))
    (if (and p (> p 0) (member (substr s p 1) FIRSTS))
      (progn
        (setq q (+ p (strlen REST)))
        (while (and (< q (strlen s)) (wcmatch (substr s (1+ q) 1) "#")) (setq q (1+ q)))
        (setq old (atoi (substr s (+ p (strlen REST) 1) (- q p (strlen REST)))) new (cdr (assoc old MAP)))
        (if new
          (progn
            (setq s (strcat (substr s 1 (1- p)) NEWP (itoa new) (substr s (1+ q))))
            (if (entmod (subst (cons 1 s) (assoc 1 ed) ed))
              (progn (setq hit new) (princ (strcat "\nOK-" (itoa old) "-" (itoa new))))
              (princ "\nFAIL-")))
          (princ (strcat "\nNOMAP-" (itoa old))))))))
  (if hit (setq ok (cons (cons lay hit) ok))))
(foreach x L (fixlay (cdr x)))
(if ok (command "_.QSAVE"))
(if (/= OUTD "") (foreach x ok (setvar "CTAB" (car x)) (plotpdf (strcat OUTD "/l" (itoa (cdr x)) ".pdf")) (princ (strcat "\nPLOT-" (itoa (cdr x))))))
(princ "\nDONE-")
"@ + $LispQuit
foreach ($j in $jobs) {
  $r = Invoke-AccCore $j.Work $core (Join-Path $w "f$($j.N).log")
  $ok = @($r | Where-Object { $_ -match "^OK-" } | ForEach-Object { $_.Split('"')[0].Trim() })
  $bad = @($r | Where-Object { $_ -match "^(FAIL-|NOMAP-)|^KILLED" } | ForEach-Object { $_.Split('"')[0].Trim() })
  "{0}: замен {1} [{2}] {3}" -f (Split-Path $j.Src -Leaf), $ok.Count, ($ok -join " "), $(if ($bad) { "!!! " + ($bad -join " ") } else { "" })
  if ($Apply -and $ok.Count -gt 0 -and $bad.Count -eq 0) {
    if (-not (Test-FileFree $j.Src)) { "   !!! открыт у пользователя — не заменён (копия: $($j.Work))"; continue }
    New-Item -ItemType Directory -Force $bak | Out-Null
    try { Copy-Item -LiteralPath $j.Src "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)" -Force -ErrorAction Stop
          if ((Get-Item -LiteralPath "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)").Length -ne (Get-Item -LiteralPath $j.Src).Length) { throw "размер копии не совпадает с оригиналом" } }
    catch { "   !!! резервная копия не создана — исходник НЕ заменён: $($_.Exception.Message)"; continue }
    Copy-Item $j.Work -Destination $j.Src -Force
  }
}
if (-not $Apply) { "(пробный прогон: исходники не тронуты; результаты — $w)" }
