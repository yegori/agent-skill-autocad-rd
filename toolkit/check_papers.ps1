# Предварительная проверка форматов печати ДО печати: для каждого макета — формат листа и плоттер, есть ли формат на этом ПК.
#   .\check_papers.ps1 -Files a.dwg,b.dwg [-Add]          или   -DwgDir "…\DWG"
# Формат «UserDefinedMetric (…)» должен быть в PMP «DWG To PDF» (%APPDATA%\…\PMP Files\DWG To PDF.pmp), иначе печать
# молча не пройдёт («Нет подходящего носителя»). С -Add недостающие форматы добавляются (add_pmp_size.py, с копией PMP).
# Стандартные форматы (ISO_…, ANSI_…) не проверяются. Если плоттер макета не «DWG To PDF.pc3» — предупреждение:
# скрипты печати подставляют DWG To PDF.pc3, имена форматов у других плоттеров могут не совпасть.
# Возвращает (в конвейер) объекты @{File; Layout; Paper; Device; Status}; при вызове из скрипта — $global:PaperMissing.
param([string[]]$Files = @(), [string]$DwgDir = "", [switch]$Add, [string]$Exclude = '_recover', [string]$PmpPath = "", [ValidateRange(1,1200)][int]$TimeoutSec = 600, [switch]$ControlledRead)
. "$PSScriptRoot\common.ps1"
if ($DwgDir) { $Files += @(Get-ChildItem -LiteralPath $DwgDir -Filter *.dwg | Where-Object { -not ($Exclude -and $_.Name -match $Exclude) } | Sort-Object Name | ForEach-Object FullName) }
. "$PSScriptRoot\pmp_paths.ps1"
$pmpInfo = Get-PmpCatalog -Path $PmpPath -Inspect
if ($Add -and $pmpInfo.status -eq 'ambiguous') { throw "pmp_ambiguous: укажите -PmpPath: $($pmpInfo.existing -join '; ')" }
if ($Add -and $pmpInfo.status -ne 'found') { throw 'pmp_missing: -Add требует существующий PMP; укажите -PmpPath' }
if ($pmpInfo.status -ne 'found') { Write-Host "PMP $($pmpInfo.status); стандартные форматы не блокируются, нестандартные не подтверждены. Укажите -PmpPath." }
$pmp = $pmpInfo.path
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
"@
  if ($ControlledRead) {
    # Completion of read-only metadata is explicit; do NOT call QUIT (some Civil files crash there).
    # Keep the root alive until the owner checks the marker and closes its private Job.
    $complete = Join-Path $w "p$i.complete"
    $signalPath = $complete.Replace('\', '/')
    $lsp += "`n(setq ready (open `"$signalPath`" `"w`" `"utf8`"))`n(write-line `"ALLDONE`" ready)`n(close ready)`n(while T (command `"_.DELAY`" 1000))`n"
    # One expression: any LISP error aborts BEFORE the completion marker (no later script-line fallthrough).
    $lsp = "(progn`n" + $lsp + ")`n"
    if (-not (Test-LispParens $lsp)) { throw 'resource_lisp_unbalanced' }
    $scr = Join-Path $w "p$i.scr"
    Write-Scr $scr $lsp
    . "$PSScriptRoot/spds_text/owned_acad.ps1"
    $owned = Invoke-OwnedTxtfixProcess -FilePath $AccCore -Arguments @('/i', $c, '/s', $scr, '/l', 'ru-RU') -Log $complete -TimeoutSec $TimeoutSec
    $Global:AccCoreLastRun = @{ Status = 'failed'; ExitCode = $null; CompletionMode = 'owned_job_after_metadata' }
    if (-not $owned.AllDone -or $owned.TimedOut -or $owned.RootExitedBeforeStop -ne $false -or -not $owned.Terminated) { throw 'resource_controlled_read_incomplete' }
    $Global:AccCoreLastRun = @{ Status = 'completed_controlled'; ExitCode = $null; CompletionMode = 'owned_job_after_metadata';
                              CleanupVerified = $true; RootAliveBeforeStop = $true; CompletionMarker = $complete }
  } else {
    $lsp += $LispQuit
    $null = Invoke-AccCore $c $lsp (Join-Path $w "p$i.log") $TimeoutSec
  }
  $txt = Join-Path $w "p$i.txt"
  if (-not (Test-Path $txt)) { $rows += [pscustomobject]@{ File = (Split-Path $f -Leaf); Layout = "?"; Paper = "?"; Device = "?"; Status = "!!! не прочитан" }; continue }
  foreach ($l in Get-Content $txt -Encoding utf8) {
    $lay, $paper, $dev = $l -split '\|', 3
    $match = if ($paper -like 'UserDefined*') { if ($pmpInfo.status -ne 'found') { 'unresolved' } else { Get-PmpPaperMatch $pmpInfo $paper } } else { 'standard' }
    $st = switch ($match) {
      'exact_name' { 'есть на ПК' }
      'dimensions_only' { 'размер есть; имя носителя не подтверждено' }
      'missing' { 'НЕТ НА ПК' }
      'unresolved' { 'НЕТ ПОДТВЕРЖДЕНИЯ PMP' }
      default { 'стандартный' }
    }
    if ($dev -and $dev -ne 'DWG To PDF.pc3') { $st += "; плоттер не DWG To PDF" }
    $rows += [pscustomobject]@{ File = (Split-Path $f -Leaf); Layout = $lay; Paper = $paper; Device = $dev; Status = $st }
  }
  Remove-Item $c -ErrorAction SilentlyContinue
}
$missing = @($rows | Where-Object { $_.Status -like 'НЕТ *' } | ForEach-Object Paper | Sort-Object -Unique)
$global:PaperMissing = $missing
$rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
if ($missing) {
  Write-Host ("Нет на этом ПК: " + ($missing -join "; "))
  if ($Add) {
    python -I -X utf8 "$PSScriptRoot\add_pmp_size.py" @missing --pmp $pmp | Write-Host
    if ($LASTEXITCODE -ne 0) { throw 'pmp_add_failed: PaperMissing сохранён' }
    $global:PaperMissing = @()
  }
  else { Write-Host "Добавить: повторить с -Add (или python add_pmp_size.py ""<имя>"")" }
} else { Write-Host "Отсутствующие размеры не выявлены. Совпадение размера не подтверждает имя носителя или качество печати." }
