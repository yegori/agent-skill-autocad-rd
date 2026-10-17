# Переименование и удаление макетов (листов) в DWG.
#   .\fix_layouts.ps1 -File "…\лист.dwg" [-Rename @{"старое"="новое"}] [-Delete "Layout2","Лист1"] [-Apply]
# Удаляется только ПУСТОЙ макет (нет объектов, кроме видовых экранов без содержимого — т.е. нет ничего, кроме VIEWPORT).
# Без -Apply — пробный прогон на копии (печатает, что будет сделано). С -Apply исходник заменяется копией, если файл не открыт;
# оригинал — в <WorkRoot>\backup\layouts_<дата>. Копия сохраняет латинское начало имени (поля от dwgname не ломаются).
param([Parameter(Mandatory)][string]$File, [hashtable]$Rename = @{}, [string[]]$Delete = @(), [switch]$Apply)
. "$PSScriptRoot\common.ps1"
$bak = Join-Path $WorkRoot ("backup\layouts_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$w = Join-Path $WorkRoot "layouts"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$j = (Copy-DwgToWork @($File) $w)[0]
$out = (Join-Path $w "res.txt") -replace '\\', '/'
$ren = ($Rename.GetEnumerator() | ForEach-Object { "(cons `"$($_.Key)`" `"$($_.Value)`")" }) -join " "
$del = ($Delete | ForEach-Object { "`"$_`"" }) -join " "
$lsp = $LispHead + $LispLayouts + @"
(setq fo (open "$out" "w" "utf8") REN (list $ren) DEL (list $del) names (mapcar 'cdr L) ch 0)
(foreach x DEL
  (if (member x names)
    (progn
      (setq ss (ssget "_X" (list (cons 410 x))) n 0 other 0)
      (if ss (repeat (sslength ss) (if (/= "VIEWPORT" (cdr (assoc 0 (entget (ssname ss n))))) (setq other (1+ other))) (setq n (1+ n))))
      (if (= other 0)
        (progn (command "_.-LAYOUT" "_D" x) (setq ch (1+ ch)) (write-line (strcat "DEL|" x) fo))
        (write-line (strcat "NOTEMPTY|" x "|" (itoa other)) fo)))
    (write-line (strcat "NOLAYOUT|" x) fo)))
(foreach p REN
  (cond ((not (member (car p) names)) (write-line (strcat "NOLAYOUT|" (car p)) fo))
        ((member (cdr p) names) (write-line (strcat "EXISTS|" (cdr p)) fo))
        (T (command "_.-LAYOUT" "_R" (car p) (cdr p)) (setq ch (1+ ch)) (write-line (strcat "REN|" (car p) "|" (cdr p)) fo))))
$LispLayouts
(write-line (strcat "NOW|" (apply 'strcat (mapcar '(lambda (x) (strcat (cdr x) " ; ")) L))) fo)
(close fo)
(if (> ch 0) (command "_.QSAVE"))
"@ + $LispQuit
$null = Invoke-AccCore $j.Work $lsp (Join-Path $w "res.log") 900
$res = Get-Content ($out -replace '/', '\') -Encoding utf8 -ErrorAction SilentlyContinue
"{0}:" -f (Split-Path $File -Leaf); $res | ForEach-Object { "   $_" }
$bad = @($res | Where-Object { $_ -match '^(NOTEMPTY|NOLAYOUT|EXISTS)' })
$did = @($res | Where-Object { $_ -match '^(DEL|REN)\|' })
if ($Apply -and $did -and -not $bad) {
  if (-not (Test-FileFree $File)) { "   !!! открыт у пользователя — не заменён"; return }
  New-Item -ItemType Directory -Force $bak | Out-Null
  try { Copy-Item -LiteralPath $File (Join-Path $bak (Split-Path $File -Leaf)) -Force -ErrorAction Stop
        if ((Get-Item -LiteralPath (Join-Path $bak (Split-Path $File -Leaf))).Length -ne (Get-Item -LiteralPath $File).Length) { throw "размер копии не совпадает с оригиналом" } }
  catch { "   !!! резервная копия не создана — исходник НЕ заменён: $($_.Exception.Message)"; return }
  Copy-Item $j.Work -Destination $File -Force; "   заменён (оригинал: $bak)"
} elseif ($Apply -and $bad) { "   !!! есть замечания — исходник НЕ заменён" }
elseif (-not $Apply) { "   (пробный прогон: исходник не тронут)" }
