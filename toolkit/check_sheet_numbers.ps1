# Проверка номеров листов в штампах БЕЗ печати: ожидаемый номер (из имени DWG по порядку вкладок) против того, что будет напечатано.
#   .\check_sheet_numbers.ps1 -DwgDir "…\DWG" [-Tag "НАИМЕНОВАНИЕ"] [-Block "Name"]     или  -Files a.dwg,b.dwg
# Номер ищется: 1) в атрибуте -Tag блока -Block (часто ПОЛЕ $(substr,$(getvar,dwgname),1,3) — первые 3 символа имени файла);
#               2) если такого атрибута нет — среди TEXT/MTEXT макета, состоящих только из цифр (номер текстом в графе «Лист»).
# Поля пересчитываются при открытии (FIELDEVAL; UPDATEFIELD в консоли нет). Копия получает латинское начало исходного имени
# («003~1.dwg»), поэтому поля от имени файла считаются как в оригинале.
# Статус: OK (поле) / OK (текст) / РАСХОЖДЕНИЕ / НЕ НАЙДЕН / НЕТ НОМЕРА В ИМЕНИ / ЛИШНИЙ МАКЕТ (макетов больше, чем номеров в имени).
param([string[]]$Files = @(), [string]$DwgDir = "", [string]$Tag = "НАИМЕНОВАНИЕ", [string]$Block = "Name", [string]$Exclude = '_recover')
. "$PSScriptRoot\common.ps1"
if ($DwgDir) { $Files += @(Get-ChildItem -LiteralPath $DwgDir -Filter *.dwg | Where-Object { -not ($Exclude -and $_.Name -match $Exclude) } | Sort-Object Name | ForEach-Object FullName) }
function Get-Nums($name) { $r = @(); foreach ($p in ($name -split '[ _]')[0] -split ',') { if ($p -match '^(\d+)-(\d+)$') { $r += [int]$Matches[1]..[int]$Matches[2] } elseif ($p -match '^\d+$') { $r += [int]$p } }; $r }
$w = Join-Path $WorkRoot "sheetnums"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$jobs = Copy-DwgToWork $Files $w
$rows = @()
foreach ($j in $jobs) {
  $name = Split-Path $j.Src -Leaf; $nums = @(Get-Nums $name)
  $out = (Join-Path $w "n$($j.N).txt") -replace '\\', '/'
  $lsp = $LispHead + $LispLayouts + @"
(setq fo (open "$out" "w" "utf8"))
(write-line (strcat "F|" (itoa (getvar "FIELDEVAL"))) fo)
(defun fldexpr (fid / fd r)   ; самая глубокая формула поля
  (setq fd (entget fid))
  (foreach g fd (if (and (= (car g) 360) (/= (cdr g) fid) (= "FIELD" (cdr (assoc 0 (entget (cdr g)))))) (setq r (fldexpr (cdr g)))))
  (if (and (not r) (assoc 2 fd) (not (wcmatch (cdr (assoc 2 fd)) "*_FldIdx*"))) (setq r (cdr (assoc 2 fd))))
  r)
(defun plain (s / p)   ; MTEXT: текст после последнего «;» внутри {}, без скобок
  (while (setq p (vl-string-search ";" s)) (setq s (substr s (+ p 2))))
  (vl-string-trim " {}" s))
(foreach x L
  (write-line (strcat "L|" (cdr x)) fo)
  (setq ss (ssget "_X" (list (cons 410 (cdr x)) (cons 0 "INSERT") (cons 66 1))) i 0)
  (if ss (repeat (sslength ss)
    (setq e (ssname ss i) i (1+ i) a (entnext e))
    (if (or (= "$Block" "") (= (strcase (cdr (assoc 2 (entget e)))) (strcase "$Block")))
      (while (= "ATTRIB" (cdr (assoc 0 (setq ad (entget a)))))
        (if (= (strcase (cdr (assoc 2 ad))) (strcase "$Tag"))
          (progn
            (setq src "текст")
            (if (assoc 360 ad) (progn
              (setq fl (dictsearch (cdr (assoc 360 ad)) "ACAD_FIELD"))
              (if fl (progn (setq tf (dictsearch (cdr (assoc -1 fl)) "TEXT"))
                (if tf (setq src (strcat "поле: " (vl-princ-to-string (fldexpr (cdr (assoc -1 tf)))))))))))
            (write-line (strcat "A|" (cdr (assoc 1 ad)) "|" src) fo)))
        (setq a (entnext a))))))
  (setq ss (ssget "_X" (list (cons 410 (cdr x)) (cons 0 "TEXT,MTEXT"))) i 0)
  (if ss (repeat (sslength ss)
    (setq e (ssname ss i) i (1+ i) s (plain (cdr (assoc 1 (entget e)))))
    (if (wcmatch s "#,##,###") (write-line (strcat "T|" s) fo)))))
(close fo)
"@ + $LispQuit
  $null = Invoke-AccCore $j.Work $lsp (Join-Path $w "n$($j.N).log") 600
  $txt = $out -replace '/', '\'
  if (-not (Test-Path $txt)) { $rows += [pscustomobject]@{ File = $name; Layout = "?"; Expected = ""; Found = ""; Source = ""; Status = "!!! не прочитан" }; continue }
  $lays = @(); $cur = $null
  foreach ($l in Get-Content $txt -Encoding utf8) {
    $k, $a, $b = $l -split '\|', 3
    switch ($k) {
      'F' { if ($a -notmatch '[13579]$') { $rows += [pscustomobject]@{ File = $name; Layout = "-"; Expected = ""; Found = "FIELDEVAL=$a"; Source = ""; Status = "!!! поля не пересчитываются при открытии" } } }
      'L' { $cur = [pscustomobject]@{ Name = $a; Attr = @(); Text = @() }; $lays += $cur }
      'A' { $cur.Attr += , @($a, $b) }
      'T' { $cur.Text += $a }
    }
  }
  for ($m = 0; $m -lt $lays.Count; $m++) {
    $L = $lays[$m]; $exp = if ($m -lt $nums.Count) { [string]$nums[$m] } else { "" }
    $hitA = @($L.Attr | Where-Object { $_[0].Trim() -eq $exp })
    $found = (@($L.Attr | ForEach-Object { $_[0] }) + @($L.Text | ForEach-Object { "т:$_" })) -join ", "
    $srcs = (@($L.Attr | ForEach-Object { $_[1] }) | Sort-Object -Unique) -join "; "
    $st = if (-not $nums) { "НЕТ НОМЕРА В ИМЕНИ" } elseif ($m -ge $nums.Count) { "ЛИШНИЙ МАКЕТ" }
          elseif ($hitA) { if ($hitA[0][1] -like 'поле*') { "OK (поле)" } else { "OK (атрибут-текст)" } }
          elseif ($L.Attr.Count) { "РАСХОЖДЕНИЕ" }
          elseif ($L.Text -contains $exp) { "OK (текст)" } else { "НЕ НАЙДЕН" }
    $rows += [pscustomobject]@{ File = $name; Layout = $L.Name; Expected = $exp; Found = $found; Source = $srcs; Status = $st }
  }
}
$rows | Format-Table -AutoSize | Out-String -Width 260
$bad = @($rows | Where-Object { $_.Status -notlike 'OK*' -and $_.Status -ne 'НЕТ НОМЕРА В ИМЕНИ' })
if ($bad) { "Требуют внимания: $($bad.Count)" } else { "Все номера листов в порядке." }
