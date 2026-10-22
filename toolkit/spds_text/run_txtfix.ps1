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
# Режим выносок: -Mode leader -Class mcsDbObjectNotePosition [-Handle 949CE] — сегменты выноски (LEADER|… в журнале);
#   + -Pt 'x,y' -Arrow None [-Tol 1] — сменить стрелку (засечку) у сегмента с концом в этой точке (напр. убрать лишнюю засечку).
# Работает в ОТДЕЛЬНОМ acad.exe (AutoCAD пользователя не трогается). НЕ запускать одновременно с accoreconsole.
param([Parameter(Mandatory)][string[]]$Files, [string]$Find = "(?!)", [string]$Repl = "", [string]$Pairs = "", [string]$Seen = "",
      [string]$Mode = "", [string]$Class = "*", [string]$Prop = "", [string]$From = "", [string]$To = "", [string]$Handle = "", [string]$Handles = "", [string]$CellFit = "", [string]$CellXScale = "", [string]$Pt = "", [string]$Arrow = "", [string]$Tol = "1",
      [switch]$Dry, [switch]$Apply, [int]$TimeoutSec = 3600)
. "$PSScriptRoot\..\common.ps1"
$bak = Join-Path $WorkRoot ("backup\txtfix_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
# dll собирается в рабочую папку; пересборка, если исходник новее (после обновления плагина)
$dll = Join-Path $WorkRoot "bin\SpdsText.dll"
if (-not (Test-Path $dll) -or (Get-Item "$PSScriptRoot\SpdsText.cs").LastWriteTime -gt (Get-Item $dll).LastWriteTime) { & "$PSScriptRoot\build_txtfix.ps1" | Out-Host }
if (-not (Test-Path $dll)) { "!!! нет SpdsText.dll — см. сообщение сборки"; return }
$w = Join-Path $WorkRoot "txtfix"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$jobs = Copy-DwgToWork $Files $w
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
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process $AcadExe -ArgumentList "/nologo /b `"$scr`"" -PassThru
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
  Start-Sleep 3
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern "^ALLDONE" -Quiet)) { Start-Sleep 2; break }
  if ($p.HasExited) { break }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
"сек: " + [int]$sw.Elapsed.TotalSeconds
if (-not (Test-Path $log)) { "!!! журнала нет — команда TXTFIX не стартовала: acad.exe упал (не запускать параллельно с accoreconsole) или не загрузился плагин (см. командную строку окна AutoCAD; путь к dll и перевод строки в конце .scr)"; return }
# разбор журнала по файлам
$cur = $null; $per = @{}; $hits = @{}
foreach ($l in Get-Content $log -Encoding utf8) {
  if ($l -match '^FILE\|(.+?)\|') { $cur = $Matches[1] }
  elseif ($l -match '^DONE\|changed=(\d+)') { $per[$cur] = [int]$Matches[1] }
  if ($l -match '^HIT') { $hits[$cur] = 1 + [int]$hits[$cur] }
  if ($l -match '^(HIT|SEEN|ERROR|NOOBJ)') { "  " + $l.Substring(0, [Math]::Min(200, $l.Length)) }
}
foreach ($j in $jobs) {
  $n = $per[$j.Work]; $fix = $j.Work -replace '\.dwg$', '_fix.dwg'
  "{0}: найдено {1}, заменено {2}" -f (Split-Path $j.Src -Leaf), [int]$hits[$j.Work], $(if ($null -eq $n) { "?? (нет DONE)" } elseif ($Dry) { "0 (пробный прогон)" } else { $n })
  if ($Apply -and -not $Dry -and $n -gt 0 -and (Test-Path $fix)) {
    if (-not (Test-FileFree $j.Src)) { "   !!! открыт у пользователя — не заменён (исправленная копия: $fix)"; continue }
    New-Item -ItemType Directory -Force $bak | Out-Null
    try { Copy-Item -LiteralPath $j.Src "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)" -Force -ErrorAction Stop
          if ((Get-Item -LiteralPath "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)").Length -ne (Get-Item -LiteralPath $j.Src).Length) { throw "размер копии не совпадает с оригиналом" } }
    catch { "   !!! резервная копия не создана — исходник НЕ заменён: $($_.Exception.Message)"; continue }
    Copy-Item $fix -Destination $j.Src -Force; "   заменён"
  }
}
"журнал: $log"
