# Найти и заменить текст в DWG, включая таблицы и выноски СПДС (без взрыва). Нужен полный AutoCAD + СПДС.
#   .\run_txtfix.ps1 -Files a.dwg,b.dwg -Find 'фр\.?\s*120\s*[-–]\s*150' -Repl 'ср. размер 150' [-Seen '120'] [-Dry] [-Apply]
#   -Pairs pairs.txt — вместо -Find/-Repl: файл UTF-8, строки «regex<TAB>замена», все замены за один запуск acad.exe;
#   -Handles 69D1,69D2 — заменять только в этих объектах (по handle); замена TEXT на пустую строку удаляет его;
#   -CellFit Shrink — в изменённых ячейках таблиц СПДС сжимать текст по ширине графы (None/Shrink/Wrap);
#   -CellXScale 0.85 — коэффициент ширины текста в изменённых ячейках (то, что видно в печати);
#   -Dry   — только найти (журнал HIT/SEEN), ничего не сохраняется;
#   без -Apply — исправленные копии в <WorkRoot>\txtfix\*_fix.dwg, исходники не трогаются;
#   -Apply — исходник заменяется исправленной копией, если в нём были замены и он не открыт у пользователя
#            (оригинал -> <WorkRoot>\backup\txtfix_<дата>). -Seen — «маяк» для поиска пропусков (строки с ним, где шаблон не совпал).
# Режим свойств (числовые значения объектов СПДС, напр. отметки уровня):
#   -Mode props -Class mcsDbObjectLevelMark [-Prop <имя> -From 1885.86 -To 2113.10] [-Dry] — без -Prop только выводит все свойства (PROP|… в журнале).
# Удаление строк: -Mode rowdel -RowDel '2A49D:5=ожидаемый текст;2A49D:8=другой текст' [-Dry]
#   Только один DWG; индексы с нуля; условие обязательно. Сначала -Dry, затем копия без -Apply и проверка PDF.
# Режим выносок: -Mode leader -Class mcsDbObjectNotePosition [-Handle 949CE] — сегменты выноски (LEADER|… в журнале);
#   + -Pt 'x,y' -Arrow None [-Tol 1] — сменить стрелку (засечку) у сегмента с концом в этой точке (напр. убрать лишнюю засечку).
# Работает в ОТДЕЛЬНОМ acad.exe (AutoCAD пользователя не трогается). НЕ запускать одновременно с accoreconsole.
param([Parameter(Mandatory)][string[]]$Files, [string]$Find = "(?!)", [string]$Repl = "", [string]$Pairs = "", [string]$Seen = "",
      [string]$Mode = "", [string]$RowDel = "", [string]$Class = "*", [string]$Prop = "", [string]$From = "", [string]$To = "", [string]$Handle = "", [string]$Handles = "", [string]$CellFit = "", [string]$CellXScale = "", [string]$Pt = "", [string]$Arrow = "", [string]$Tol = "1",
      [switch]$Dry, [switch]$Apply, [int]$TimeoutSec = 3600)
. "$PSScriptRoot\rowdel_plan.ps1"
if ($RowDel -and $Mode -ne 'rowdel') { throw 'RowDel требует -Mode rowdel' }
if ($Mode -eq 'rowdel') {
  $Mode = 'rowdel'
  Test-RowDeleteRequest -Files $Files -Specification $RowDel -Dry:$Dry -Apply:$Apply -Options $PSBoundParameters
  $rowSource = (Resolve-Path -LiteralPath $Files[0] -ErrorAction Stop).Path
  $rowSourceHash = (Get-FileHash -LiteralPath $rowSource -Algorithm SHA256 -ErrorAction Stop).Hash
}
. "$PSScriptRoot\..\common.ps1"
$backupName = 'txtfix_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
if ($Mode -eq 'rowdel') { $backupName += '_' + [Guid]::NewGuid().ToString('N') }
$bak = Join-Path $WorkRoot (Join-Path 'backup' $backupName)
# dll собирается в рабочую папку; пересборка, если исходник новее (после обновления плагина)
$dll = Join-Path $WorkRoot "bin\SpdsText.dll"
$sourceTime = (Get-Item "$PSScriptRoot\SpdsText.cs", "$PSScriptRoot\SpdsDependencies.cs", "$PSScriptRoot\RowDeletion.cs" | Measure-Object LastWriteTime -Maximum).Maximum
if (-not (Test-Path $dll) -or $sourceTime -gt (Get-Item $dll).LastWriteTime) { & "$PSScriptRoot\build_txtfix.ps1" | Out-Host }
if (-not (Test-Path $dll)) { "!!! нет SpdsText.dll — см. сообщение сборки"; return }
if ($Mode -eq 'rowdel' -and $sourceTime -gt (Get-Item $dll).LastWriteTime) { throw 'rowdel_plugin_build_stale_or_failed' }
$w = if ($Mode -eq 'rowdel') { Join-Path $WorkRoot ('txtfix_rowdel_' + [Guid]::NewGuid().ToString('N')) } else { Join-Path $WorkRoot 'txtfix' }
if ($Mode -ne 'rowdel') { Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue }
$jobs = @(Copy-DwgToWork $Files $w)
if ($Mode -eq 'rowdel' -and ((Get-FileHash -LiteralPath $jobs[0].Work -Algorithm SHA256).Hash -ne $rowSourceHash)) { throw 'rowdel_source_changed_during_copy' }
$jobs | ForEach-Object { "$($_.N)`t$($_.Src)" } | Set-Content (Join-Path $w "map.txt") -Encoding utf8   # копия <начало имени>~N.dwg -> исходник (для find_codes.py)
# dll — в рабочую папку: путь без кириллицы (иначе NETLOAD из .scr не находит файл) и исходная dll не блокируется
$dllW = Join-Path $WorkRoot ("txtfix_dll\SpdsText_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".dll")   # уникальное имя: старую копию может держать другой acad.exe
New-Item -ItemType Directory -Force (Split-Path $dllW) | Out-Null; Copy-Item $dll $dllW -Force
$log = Join-Path $w "txtfix.log"
$env:TXT_IN = ($jobs.Work -join "|"); $env:TXT_OUT = (($jobs | ForEach-Object { $_.Work -replace '\.dwg$', '_fix.dwg' }) -join "|")
$env:TXT_MODE = $Mode; $env:TXT_HANDLE = $Handle; $env:TXT_HANDLES = $Handles; $env:TXT_CELLFIT = $CellFit; $env:TXT_CELLXSCALE = $CellXScale; $env:TXT_PT = $Pt; $env:TXT_ARROW = $Arrow; $env:TXT_TOL = $Tol; $env:TXT_CLASS = $Class; $env:TXT_PROP = $Prop; $env:TXT_FROM = $From; $env:TXT_TO = $To; $env:TXT_FIND = $Find; $env:TXT_REPL = $Repl; $env:TXT_PAIRS = $(if ($Pairs) { (Resolve-Path $Pairs).Path } else { "" }); $env:TXT_SEEN = $Seen; $env:TXT_LOG = $log; $env:TXT_DRY = $(if ($Dry) { "1" } else { "0" })
$scr = Join-Path $w "run.scr"
Write-Scr $scr @"
(setvar "FILEDIA" 0)
(setq sl (getvar "SECURELOAD"))
(setvar "SECURELOAD" 0)
(command "_.NETLOAD" "$($dllW.Replace('\', '/'))")
(setvar "SECURELOAD" sl)
TXTFIX
"@
. "$PSScriptRoot\owned_acad.ps1"
$oldRowDel = $env:TXT_ROWDEL
try {
  # Never let a stale inherited row specification affect another mode.
  $env:TXT_ROWDEL = if ($Mode -eq 'rowdel') { $RowDel } else { '' }
  $execution = Invoke-OwnedTxtfixProcess -FilePath $AcadExe -Arguments @('/nologo', '/b', $scr) -Log $log -TimeoutSec $TimeoutSec
} finally { $env:TXT_ROWDEL = $oldRowDel }
"сек: " + [int]$execution.ElapsedSeconds
if (-not $execution.AllDone) { throw "txtfix_incomplete: timed_out=$($execution.TimedOut); owned process stopped" }
if (-not (Test-Path $log)) { "!!! журнала нет — команда TXTFIX не стартовала: acad.exe упал (не запускать параллельно с accoreconsole) или не загрузился плагин (см. командную строку окна AutoCAD; путь к dll и перевод строки в конце .scr)"; return }
if ($Mode -eq 'rowdel') { Assert-RowDeleteLog -Log $log -Dry:$Dry }
# разбор журнала по файлам
$cur = $null; $per = @{}; $hits = @{}
foreach ($l in Get-Content $log -Encoding utf8) {
  if ($l -match '^FILE\|(.+?)\|') { $cur = $Matches[1] }
  elseif ($l -match '^DONE\|changed=(\d+)') { $per[$cur] = [int]$Matches[1] }
  if ($l -match '^HIT') { $hits[$cur] = 1 + [int]$hits[$cur] }
  if ($l -match '^(HIT|SEEN|ERROR|NOOBJ|ROWDEL)') { "  " + $l.Substring(0, [Math]::Min(200, $l.Length)) }
}
foreach ($j in $jobs) {
  $n = $per[$j.Work]; $fix = $j.Work -replace '\.dwg$', '_fix.dwg'
  "{0}: найдено {1}, заменено {2}" -f (Split-Path $j.Src -Leaf), [int]$hits[$j.Work], $(if ($null -eq $n) { "?? (нет DONE)" } elseif ($Dry) { "0 (пробный прогон)" } else { $n })
  if ($Apply -and -not $Dry -and $n -gt 0 -and (Test-Path $fix)) {
    if (-not (Test-FileFree $j.Src)) { "   !!! открыт у пользователя — не заменён (исправленная копия: $fix)"; continue }
    if ($Mode -eq 'rowdel' -and (Get-FileHash -LiteralPath $j.Src -Algorithm SHA256).Hash -ne $rowSourceHash) { throw 'rowdel_source_changed_before_apply' }
    New-Item -ItemType Directory -Force $bak | Out-Null
    try { Copy-Item -LiteralPath $j.Src "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)" -Force -ErrorAction Stop
          if ((Get-Item -LiteralPath "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)").Length -ne (Get-Item -LiteralPath $j.Src).Length) { throw "размер копии не совпадает с оригиналом" }
          if ($Mode -eq 'rowdel' -and (Get-FileHash -LiteralPath "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)" -Algorithm SHA256).Hash -ne $rowSourceHash) { throw 'rowdel_backup_hash_mismatch' } }
    catch { "   !!! резервная копия не создана — исходник НЕ заменён: $($_.Exception.Message)"; continue }
    Copy-Item -LiteralPath $fix -Destination $j.Src -Force -ErrorAction Stop; "   заменён"
  }
}
"журнал: $log"
