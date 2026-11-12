# Проверка рабочего места для rd-ci: всё ли установлено, чтобы скрипты работали.  pwsh -File check_env.ps1 [-Build]
#   -Build — заодно собрать плагин СПДС (SpdsText.dll) в рабочую папку.
# Ничего не меняет, кроме создания рабочей папки (и dll при -Build).
param([switch]$Build, [string]$PmpPath = '')
. "$PSScriptRoot\common.ps1"
$ok = $true
function Row([string]$what, [bool]$good, [string]$detail, [string]$fix = "", [switch]$Optional) {
  $mark = if ($good) { "OK " } elseif ($Optional) { "-- " } else { "!! " }
  if (-not $good -and -not $Optional) { $script:ok = $false }
  "{0} {1,-34} {2}" -f $mark, $what, $detail
  if (-not $good -and $fix) { "     → $fix" }
}
Row "PowerShell 7 (pwsh)" ($PSVersionTable.PSVersion.Major -ge 7) "версия $($PSVersionTable.PSVersion)" "установить PowerShell 7: winget install Microsoft.PowerShell; запускать скрипты из pwsh"
Row "AutoCAD (accoreconsole)" (Test-Path $AccCore) $AccCore "другая папка — задать переменную RDCI_ACAD_DIR"
Row "AutoCAD (acad.exe)" (Test-Path $AcadExe) $AcadExe ""
$spds = if ($env:RDCI_SPDS_DIR) { $env:RDCI_SPDS_DIR } else { "C:\Program Files\CSoft\СПДС GraphiCS 2023 x64\mg142x64" }
Row "СПДС GraphiCS (MultiCAD API)" (Test-Path (Join-Path $spds "mapimgd.dll")) $spds "другая папка — задать переменную RDCI_SPDS_DIR"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
Row ".NET Framework csc (сборка плагина)" (Test-Path $csc) $csc ""
Row "Рабочая папка без кириллицы" ($WorkRoot -match '^[\x20-\x7E]+$') $WorkRoot "задать переменную RDCI_WORK, напр. C:\rd-ci-work"
. "$PSScriptRoot\pmp_paths.ps1"
$pmpFound = $false; $pmpDetail = 'не определён (нужен Python или явный -PmpPath)'
try {
  $pmpInfo = Get-PmpCatalog -Path $PmpPath
  $pmpFound = $pmpInfo.status -eq 'found'
  $pmpDetail = if ($pmpFound) { $pmpInfo.path } else { "$($pmpInfo.status): $($pmpInfo.candidates -join '; '); укажите -PmpPath" }
} catch { $pmpDetail = "не определён: $($_.Exception.Message); укажите -PmpPath" }
Row "PMP (нестандартные форматы)" $pmpFound $pmpDetail "не обязателен для стандартных ISO/ANSI; перед печатью проверить форматы макетов через check_papers.ps1 без -Add. Нестандартный формат без носителя — ограничение; настройки автоматически не менять" -Optional
$py = Get-Command python -ErrorAction SilentlyContinue
Row "Python 3" ([bool]$py) $(if ($py) { (& python --version 2>&1) } else { "не найден" }) "установить Python 3.11+ (python.org), отметить «Add to PATH»"
if ($py) {
  $mods = 'pymupdf','ezdxf','numpy','scipy','shapely','PIL','openpyxl'
  $missing = @(); foreach ($m in $mods) { & python -I -c "import $m" 2>$null; if ($LASTEXITCODE -ne 0) { $missing += $m } }
  $pipnames = $missing | ForEach-Object { if ($_ -eq 'PIL') { 'pillow' } else { $_ } }
  Row "Пакеты Python" ($missing.Count -eq 0) $(if ($missing) { "нет: $($missing -join ', ')" } else { ($mods -join ', ') }) "python -m pip install $($pipnames -join ' ')"
}
$xl = $null; try { $xl = [Type]::GetTypeFromProgID("Excel.Application") } catch {}
Row "Excel (пересчёт формул в отчётах)" ([bool]$xl) $(if ($xl) { "есть" } else { "нет — отчёты .xlsx без пересчёта формул" }) ""
$wd = $null; try { $wd = [Type]::GetTypeFromProgID("Word.Application") } catch {}
Row "Word (обложки .doc → PDF)" ([bool]$wd) $(if ($wd) { "есть" } else { "нет — make_cover.ps1 не будет работать" }) ""
if ($Build -and (Test-Path $csc)) { "`nСборка плагина СПДС:"; & "$PSScriptRoot\spds_text\build_txtfix.ps1" }
""
if ($ok) { "Базовое окружение готово. Форматы конкретных макетов проверить отдельно; необязательные пункты отмечены --." } else { "Есть замечания (!!) — см. подсказки «→»; применимость к выбранной операции проверять отдельно." }
