# Номер листа в атрибут штампа: блок с атрибутом -Tag (напр. «НАИМЕНОВАНИЕ» блока «Name», где стоит «#»)
# получает номер листа из имени DWG («003 …» -> 3; «004-005 …» / «004,005 …» -> по порядку вкладок макетов).
#   .\set_sheet_attr.ps1 -Files a.dwg,b.dwg -Tag "НАИМЕНОВАНИЕ" [-Block "Name"] [-OnlyIf "#"] [-Apply]
# -OnlyIf — менять только атрибуты с таким текущим значением (по умолчанию «#»; пусто — любые).
# Без -Apply — пробный прогон на копиях. С -Apply исходник заменяется копией (если файл не открыт), оригинал — в <WorkRoot>\backup\sheetattr_<дата>.
# Где номер листа и в каком объекте — сначала посмотреть dump_layout_texts.ps1.
# ВНИМАНИЕ: «#» часто не пустое значение, а ПОЛЕ от имени файла ($(substr,$(getvar,dwgname),1,3)), которое «#» показывает только
# на переименованной копии. Такое поле не трогать (см. docs\11_pitfalls.md); скрипт — для действительно незаполненных атрибутов.
param([Parameter(Mandatory)][string[]]$Files, [Parameter(Mandatory)][string]$Tag, [string]$Block = "", [string]$OnlyIf = "#", [switch]$Apply)
. "$PSScriptRoot\common.ps1"
$bak = Join-Path $WorkRoot ("backup\sheetattr_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$w = Join-Path $WorkRoot "sheetattr"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$jobs = Copy-DwgToWork $Files $w
function Get-Nums($name) { $r = @(); foreach ($p in ($name -split '[ _]')[0] -split ',') { if ($p -match '^(\d+)-(\d+)$') { $r += [int]$Matches[1]..[int]$Matches[2] } elseif ($p -match '^\d+$') { $r += [int]$p } }; $r }
foreach ($j in $jobs) {
  $nums = @(Get-Nums (Split-Path $j.Src -Leaf))
  if (-not $nums) { "{0}: нет номера в имени — пропущен" -f (Split-Path $j.Src -Leaf); continue }
  $numL = ($nums | ForEach-Object { "`"$_`"" }) -join " "
  $lsp = $LispHead + $LispLayouts + @"
(setq NUMS (list $numL) k 0 nch 0)
(foreach x L
  (setq k (1+ k) v (nth (1- k) NUMS) ss (ssget "_X" (list (cons 410 (cdr x)) (cons 0 "INSERT") (cons 66 1))) i 0)
  (if (and v ss) (repeat (sslength ss)
    (setq e (ssname ss i) i (1+ i) a (entnext e))
    (if (or (= "$Block" "") (= (strcase (cdr (assoc 2 (entget e)))) (strcase "$Block")))
      (while (= "ATTRIB" (cdr (assoc 0 (setq ad (entget a)))))
        (if (and (= (strcase (cdr (assoc 2 ad))) (strcase "$Tag")) (or (= "$OnlyIf" "") (= (cdr (assoc 1 ad)) "$OnlyIf")))
          (if (entmod (subst (cons 1 v) (assoc 1 ad) ad))
            (progn (entupd e) (setq nch (1+ nch)) (princ (strcat "\nOK-" v)))
            (princ "\nFAIL-")))
        (setq a (entnext a)))))))
(if (> nch 0) (command "_.QSAVE"))
(princ "\nDONE-")
"@ + $LispQuit
  $r = Invoke-AccCore $j.Work $lsp (Join-Path $w "f$($j.N).log")
  $ok = @($r | Where-Object { $_ -match "^OK-" } | ForEach-Object { $_.Split('"')[0].Trim() })
  $bad = @($r | Where-Object { $_ -match "^FAIL-|^KILLED" })
  "{0}: листы {1}; изменено {2} [{3}]{4}" -f (Split-Path $j.Src -Leaf), ($nums -join ","), $ok.Count, ($ok -join " "), $(if ($bad) { " !!! ошибки" } else { "" })
  if ($Apply -and $ok.Count -gt 0 -and -not $bad) {
    if (-not (Test-FileFree $j.Src)) { "   !!! открыт у пользователя — не заменён"; continue }
    New-Item -ItemType Directory -Force $bak | Out-Null
    Copy-Item -LiteralPath $j.Src "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)" -Force
    Copy-Item $j.Work -Destination $j.Src -Force; "   заменён (оригинал: $bak)"
  }
}
if (-not $Apply) { "(пробный прогон: исходники не тронуты)" }
