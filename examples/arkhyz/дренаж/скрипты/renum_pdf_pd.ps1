# Перенумерация листов (Т7.x -> новая нумерация комплекта) в штампах DWG папки выдачи + печать всех листов в PDF.
# Запуск из PowerShell:  .\renum_pdf_pd.ps1 -Keys 4A,5A,5B
# Номер листа в DWG — MTEXT «Т7.N» в макете; скрипт меняет только номер (по таблице $map), печатает макет
# в PDF\по листам\<номер> <наименование>.pdf и, если все найденные номера заменены, кладёт DWG обратно в папку выдачи.
param([string[]]$Keys)

$b   = Split-Path (Split-Path $PSScriptRoot)     # ...\площадной дренаж
$G   = "C:\Users\yegori\AppData\Local\Temp\acc\renum"
$acc = "C:\Program Files\Autodesk\AutoCAD 2024\accoreconsole.exe"

function pl($n, $parts) { $r = @(); foreach ($u in $parts) { $r += "Схема расположения площадного дренажа Уч. $u", "Схема котлована Уч. $u", "Картограмма земляных масс котлована Уч. $u" }; $r }
# ключ -> шифр, (старый номер Т7.N -> новый), наименования листов 1..n (как в ведомости ОД)
$map = @{
 "4A" = @("ИЗ16", "(4 . 2)(5 . 3)(6 . 4)(7 . 5)(8 . 6)(9 . 7)(10 . 8)(11 . 9)(12 . 10)(13 . 11)(14 . 12)(15 . 13)(16 . 14)",
          (@("Общие данные", "Разрез 1-1") + (pl 0 @("4А-1", "4А-2", "4А-3", "4А-4"))))
 "5A" = @("ИЗ18", "(4 . 2)(1 . 3)(2 . 4)(3 . 5)", (@("Общие данные", "Разрез 1-1") + (pl 0 @("5А-1"))))
 "5B" = @("ИЗ19", "(4 . 2)(17 . 3)(18 . 4)(19 . 5)(20 . 6)(21 . 7)(22 . 8)",
          @("Общие данные", "Разрез 1-1", "Схема расположения площадного дренажа Уч. 5В-1", "Схема расположения площадного дренажа Уч. 5В-2",
            "Схема котлована Уч. 5В-1", "Картограмма земляных масс котлована Уч. 5В-1", "Схема котлована Уч. 5В-2", "Картограмма земляных масс котлована Уч. 5В-2"))
}

function RunAcc($dwg, $scr, $log) {
  $p = Start-Process -FilePath $acc -ArgumentList "/i `"$dwg`" /s `"$scr`" /l ru-RU" -NoNewWindow -PassThru -RedirectStandardOutput $log
  if (-not $p.WaitForExit(900000)) { $p.Kill(); return @("KILLED") }
  return (((Get-Content $log -Raw) -replace "`0","") -split "`n" | Where-Object { $_ -match "^(OK|FAIL|PLOT|DONE)-" } | ForEach-Object { $_.Split('"')[0].Trim() })
}

$common = @'
(vl-load-com)
(setvar "FILEDIA" 0)
(setvar "CMDECHO" 0)
(setq ok nil)
(defun fixlay (lay / ss i e ed s p q old new hit)
  (setq ss (ssget "_X" (list (cons 410 lay) (cons 0 "TEXT,MTEXT"))) i 0)
  (if ss
    (repeat (sslength ss)
      (setq e (ssname ss i) i (1+ i) ed (entget e) s (cdr (assoc 1 ed)) p (vl-string-search "7." s))
      (if (and p (> p 0) (member (substr s p 1) (list "T" "Т")))
        (progn
          (setq q (+ p 2))
          (while (and (< q (strlen s)) (wcmatch (substr s (1+ q) 1) "#")) (setq q (1+ q)))
          (setq old (atoi (substr s (+ p 3) (- q p 2))) new (cdr (assoc old MAP)))
          (if new
            (progn
              (setq s (strcat (substr s 1 (1- p)) (itoa new) (substr s (1+ q))))
              (if (entmod (subst (cons 1 s) (assoc 1 ed) ed))
                (progn (setq hit new) (princ (strcat "\nOK-" (itoa old) "-" (itoa new) "-" lay)))
                (princ (strcat "\nFAIL-" (cdr (assoc 5 ed)))))))))))
  (if hit (setq ok (cons (cons lay hit) ok))))
(foreach x (dictsearch (namedobjdict) "ACAD_LAYOUT")
  (if (and (= (car x) 3) (/= (cdr x) "Model")) (fixlay (cdr x))))
(if ok (command "_.QSAVE"))
(foreach x ok
  (setvar "CTAB" (car x))
  (command "_.-PLOT" "_N" "" "" "DWG To PDF.pc3" (strcat OUTD "/l" (itoa (cdr x)) ".pdf") "_N" "_Y")
  (princ (strcat "\nPLOT-" (itoa (cdr x)))))
(princ "\nDONE-")
(command "_.QUIT" "_N")
'@

New-Item -ItemType Directory -Force $G | Out-Null
foreach ($k in $Keys) {
  $iz, $lmap, $titles = $map[$k]
  $root = (Get-ChildItem -LiteralPath $b -Directory | Where-Object { $_.Name -like "*-$iz *" } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "2026.10.14 - *" }).FullName
  $w = "$G\$k"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force "$w\pdf" | Out-Null
  Copy-Item -LiteralPath "$root\DWG\Внешние_ссылки" "$w\" -Recurse -Force
  $wf = $w -replace '\\','/'
  $files = Get-ChildItem -LiteralPath "$root\DWG" -Filter *.dwg | Sort-Object Name
  $i = 0
  foreach ($f in $files) {
    $i++; $t = "$w\f$i.dwg"
    Copy-Item -LiteralPath $f.FullName $t -Force
    if ($f.Name -eq "001 ОД.dwg") {
      $scr = "(setvar `"FILEDIA`" 0)`r`n(setvar `"CTAB`" `"ОД`")`r`n(command `"_.-PLOT`" `"_N`" `"`" `"`" `"DWG To PDF.pc3`" `"$wf/pdf/l1.pdf`" `"_N`" `"_Y`")`r`n(princ `"\nPLOT-1`")`r`n(princ `"\nDONE-`")`r`n(command `"_.QUIT`" `"_N`")`r`n"
    } else {
      $scr = "(setq MAP (quote ($lmap)) OUTD `"$wf/pdf`")`r`n" + $common
    }
    [IO.File]::WriteAllText("$w\f$i.scr", $scr, [Text.Encoding]::GetEncoding(1251))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = RunAcc $t "$w\f$i.scr" "$w\f$i.log"
    $okn = @($r | Where-Object { $_ -like "OK-*" }).Count; $pn = @($r | Where-Object { $_ -like "PLOT-*" }).Count
    $bad = @($r | Where-Object { $_ -like "FAIL-*" -or $_ -eq "KILLED" }).Count
    "{0} {1}: замен {2}, печать {3}, ошибок {4}, {5} с  [{6}]" -f $k, $f.Name, $okn, $pn, $bad, [int]$sw.Elapsed.TotalSeconds, (($r | Where-Object { $_ -like "OK-*" }) -join " ")
    if ($okn -gt 0 -and $bad -eq 0 -and $okn -eq $pn) { Copy-Item $t -Destination $f.FullName -Force }
    elseif ($f.Name -ne "001 ОД.dwg") { "   !!! DWG не заменён" }
  }
  # PDF по листам: «PDF\по листам\<номер> <наименование>.pdf» (комплект 01_В590…pdf = обложка+титул+листы, собирается отдельно)
  New-Item -ItemType Directory -Force "$root\PDF\по листам" | Out-Null
  foreach ($p in Get-ChildItem "$w\pdf" -Filter "l*.pdf") {
    $n = [int]($p.BaseName.Substring(1))
    Copy-Item $p.FullName ("$root\PDF\по листам\{0:000} {1}.pdf" -f $n, $titles[$n - 1]) -Force
  }
  $got = (Get-ChildItem "$w\pdf" -Filter "l*.pdf").Count
  "$k ($iz): PDF листов $got из $($titles.Count)"
}
