# Разведка DWG: все TEXT/MTEXT/атрибуты по макетам (и, с -Model, в модели) + сводка типов объектов.
# Нужна, чтобы найти: где номер листа в штампе, шифр, заголовки, объекты СПДС (ACAD_PROXY_ENTITY в консоли).
#   .\dump_layout_texts.ps1 -Dwg "…\лист.dwg" [-Model] [-Filter "7."]
# Результат: <WorkRoot>\dump\<имя>.txt (UTF-8) и вывод на экран. Исходный DWG не меняется (работа на копии).
param([Parameter(Mandatory)][string]$Dwg, [switch]$Model, [string]$Filter = "")
. "$PSScriptRoot\common.ps1"
$w = Join-Path $WorkRoot "dump"; New-Item -ItemType Directory -Force $w | Out-Null
$base = [IO.Path]::GetFileNameWithoutExtension($Dwg) -replace '[^\w\-]', '_'
$lead = [regex]::Match((Split-Path $Dwg -Leaf), '^[0-9A-Za-z_.,\-]+').Value.TrimEnd('.')   # начало имени — для полей от dwgname
$copy = Join-Path $w ($(if ($lead) { $lead } else { "d" }) + "~.dwg"); Copy-Item -LiteralPath $Dwg $copy -Force
$out = (Join-Path $w "$base.txt") -replace '\\', '/'
$lsp = $LispHead + $LispLayouts + @"
(setq fo (open "$out" "w" "utf8"))
(defun dumplay (lay / ss i e ed ty cnt a ad s)
  (write-line (strcat "===== " lay) fo)
  (setq ss (ssget "_X" (list (cons 410 lay))) i 0 cnt nil)
  (if ss (repeat (sslength ss)
    (setq e (ssname ss i) i (1+ i) ed (entget e) ty (cdr (assoc 0 ed)))
    (if (assoc ty cnt) (setq cnt (subst (cons ty (1+ (cdr (assoc ty cnt)))) (assoc ty cnt) cnt)) (setq cnt (cons (cons ty 1) cnt)))
    (cond
      ((member ty '("TEXT" "MTEXT"))
        (setq s (cdr (assoc 1 ed)))
        (if (wcmatch s "*$Filter*") (write-line (strcat ty " " (cdr (assoc 5 ed)) " [" (rtos (car (cdr (assoc 10 ed))) 2 1) "," (rtos (cadr (cdr (assoc 10 ed))) 2 1) "] " s) fo)))
      ((and (= ty "INSERT") (= 1 (cdr (assoc 66 ed))))
        (setq a (entnext e))
        (while (= "ATTRIB" (cdr (assoc 0 (setq ad (entget a)))))
          (if (wcmatch (cdr (assoc 1 ad)) "*$Filter*")
            (write-line (strcat "ATTRIB " (cdr (assoc 5 ad)) " " (cdr (assoc 2 ed)) "." (cdr (assoc 2 ad)) " = " (cdr (assoc 1 ad))) fo))
          (setq a (entnext a)))))))
  (write-line (strcat "TYPES " (vl-princ-to-string cnt)) fo))
(foreach x L (dumplay (cdr x)))
$(if ($Model) { '(dumplay "Model")' } else { '' })
(close fo)
(princ "\nDONE-")
"@ + $LispQuit
$r = Invoke-AccCore $copy $lsp (Join-Path $w "d.log") 900
if (-not ($r -match "DONE-")) { "!!! консоль не дошла до конца, см. $w\d.log" }
Get-Content ($out -replace '/', '\') -Encoding utf8
