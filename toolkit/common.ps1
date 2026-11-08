# Общие функции для пакетной работы с AutoCAD 2024 (accoreconsole). Подключение:  . "$PSScriptRoot\common.ps1"
# Запускать из PowerShell (не из Git Bash: тот портит ключи /i /s).

# Пути можно переопределить переменными окружения: RDCI_ACAD_DIR (папка AutoCAD), RDCI_WORK (рабочая папка).
$Global:AcadDir  = if ($env:RDCI_ACAD_DIR) { $env:RDCI_ACAD_DIR } else { "C:\Program Files\Autodesk\AutoCAD 2024" }
$Global:AccCore  = "$AcadDir\accoreconsole.exe"
$Global:AcadExe  = "$AcadDir\acad.exe"
# Рабочая папка (копии DWG, журналы, резервные копии) — короткий путь БЕЗ кириллицы: accoreconsole и NETLOAD ломаются на ней.
# Если профиль Windows назван кириллицей, %LOCALAPPDATA% тоже кириллический — тогда берётся C:\rd-ci-work.
$Global:WorkRoot = if ($env:RDCI_WORK) { $env:RDCI_WORK }
                   elseif ("$env:LOCALAPPDATA" -match '^[\x20-\x7E]+$') { Join-Path $env:LOCALAPPDATA "Temp\acc" }
                   else { "C:\rd-ci-work" }
New-Item -ItemType Directory -Force $Global:WorkRoot | Out-Null

# Записать .scr в cp1251 (accoreconsole читает кириллицу в .scr только так).
function Write-Scr([string]$Path, [string]$Text) {
  # последняя строка .scr тоже должна кончаться переводом строки — иначе последняя команда «набрана», но не выполнена
  $t = ($Text -replace "`r?`n", "`r`n"); if (-not $t.EndsWith("`r`n")) { $t += "`r`n" }
  [IO.File]::WriteAllText($Path, $t, [Text.Encoding]::GetEncoding(1251))
}

# Проверка баланса скобок LISP (несбалансированный скрипт вешает консоль на «(_>»).
function Test-LispParens([string]$Text) {
  $o = ($Text -replace '"(\\.|[^"\\])*"', '').ToCharArray()
  (@($o | Where-Object { $_ -eq '(' }).Count) -eq (@($o | Where-Object { $_ -eq ')' }).Count)
}

# Запуск accoreconsole: DWG + текст скрипта. Возвращает строки лога (без NUL).
# Скрипт должен заканчиваться выходом: (command "_.QUIT" "_N") — или "_.QSAVE" перед ним.
function Invoke-AccCore([string]$Dwg, [string]$ScriptText, [string]$Log, [int]$TimeoutSec = 900) {
  $Global:AccCoreLastRun = $null
  if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 2147483) { throw 'invalid_accore_timeout' }
  if (-not (Test-LispParens $ScriptText)) { throw "Несбалансированные скобки в скрипте для $Dwg" }
  $scr = [IO.Path]::ChangeExtension($Log, ".scr")
  Write-Scr $scr $ScriptText
  # Start-Process -PassThru may lose the native handle and yield a null ExitCode after a long wait.
  # Direct Process.Start retains its original CreateProcess handle (also used for any termination).
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $AccCore; $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.CreateNoWindow = $true
  foreach ($argument in @('/i', $Dwg, '/s', $scr, '/l', 'ru-RU')) { $start.ArgumentList.Add($argument) }
  $p = [Diagnostics.Process]::new(); $p.StartInfo = $start
  $stream = [IO.File]::Open($Log, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  $started = $false
  try {
    if (-not $p.Start()) { throw 'accore_start_failed' }
    $started = $true
    $held = $p.SafeHandle
    if ($held.IsInvalid -or $held.IsClosed) { throw 'accore_handle_unavailable' }
    $pump = $p.StandardOutput.BaseStream.CopyToAsync($stream)
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
      try { $p.Kill() } catch [InvalidOperationException], [ComponentModel.Win32Exception] { if (-not $p.HasExited) { throw } }
      if (-not $p.WaitForExit(10000)) { throw 'accore_cleanup_uncertain' }
    }
    if (-not $pump.Wait(10000)) { throw 'accore_stdout_cleanup_uncertain' }
    $stream.Flush()
    $Global:AccCoreLastRun = @{ Status = $(if ($timedOut) { 'timed_out' } elseif ($p.ExitCode -eq 0) { 'completed' } else { 'failed' }); ExitCode = $p.ExitCode }
    if ($timedOut) { return @('KILLED') }
    return ((Get-Content $Log -Raw) -replace "`0", "") -split "`n"
  } finally {
    try {
      if ($started -and -not $p.HasExited) {
        $p.Kill()
        if (-not $p.WaitForExit(10000)) { throw 'accore_cleanup_uncertain' }
      }
    } finally { $p.Dispose(); $stream.Dispose() }
  }
}

# Файл свободен (не открыт в AutoCAD у пользователя)? .dwl рядом бывают старыми — им не верить.
function Test-FileFree([string]$Path) {
  try { $s = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None'); $s.Close(); $true } catch { $false }
}

# Скопировать DWG во временную рабочую папку вместе с Внешние_ссылки. Возвращает список @{Src=…; Work=…; N=…}.
# Имя копии сохраняет латинское начало исходного имени («003 Профиль.dwg» -> «003~2.dwg»): в штампах бывают ПОЛЯ
# от имени файла, напр. номер листа = $(substr,$(getvar,dwgname),1,3). С именем «f2.dwg» такое поле печатает «#».
function Copy-DwgToWork([string[]]$Files, [string]$WorkDir) {
  New-Item -ItemType Directory -Force $WorkDir | Out-Null
  $res = @(); $i = 0
  foreach ($f in $Files) {
    $i++; $lead = [regex]::Match((Split-Path $f -Leaf), '^[0-9A-Za-z_.,\-]+').Value.TrimEnd('.')
    $w = Join-Path $WorkDir ("{0}~{1}.dwg" -f $(if ($lead) { $lead } else { "f" }), $i)
    Copy-Item -LiteralPath $f $w -Force
    # xref-пути в листах обычно относительные .\Внешние_ссылки\… ; папка бывает и глубже («Новая папка\Внешние_ссылки»)
    # и называется по-разному: «Внешние_ссылки», «внешние ссылки» (ГТО) — регистр, пробел/подчёркивание не важны
    $xr = Get-ChildItem -LiteralPath (Split-Path $f) -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^(?i)внешние[ _]ссылки$' } | Select-Object -First 1
    if ($xr -and -not (Test-Path -LiteralPath (Join-Path $WorkDir $xr.Name))) { Copy-Item -LiteralPath $xr.FullName $WorkDir -Recurse -Force }
    $res += [pscustomobject]@{ Src = $f; Work = $w; N = $i }
  }
  $res
}

# LISP: список макетов (без Model) в порядке вкладок -> переменная L = ((taborder . "имя") ...).
# Имя макета — ключ словаря (группа 3 перед 350). В объекте Layout первая группа 1 — имя набора печати, не макета!
$Global:LispLayouts = @'
(setq L nil nm nil)
(foreach x (dictsearch (namedobjdict) "ACAD_LAYOUT")
  (if (= (car x) 3) (setq nm (cdr x)))
  (if (and (= (car x) 350) (/= nm "Model"))
    (setq L (cons (cons (cdr (assoc 71 (entget (cdr x)))) nm) L))))
(setq L (vl-sort L (function (lambda (a b) (< (car a) (car b))))))
'@

# LISP: печать текущего макета в PDF по его параметрам листа.  (plotpdf "C:/путь/файл.pdf")
$Global:LispPlot = @'
(defun plotpdf (f) (command "_.-PLOT" "_N" "" "" "DWG To PDF.pc3" f "_N" "_Y"))
'@

$Global:LispHead = "(vl-load-com)`n(setvar `"FILEDIA`" 0)`n(setvar `"CMDECHO`" 0)`n"
$Global:LispQuit = "`n(command `"_.QUIT`" `"_N`")`n"   # с переводом строки в начале: here-string перед ним не кончается переводом строки
$Global:LispSaveQuit = "`n(command `"_.QSAVE`")`n(command `"_.QUIT`" `"_N`")`n"
