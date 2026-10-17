# Проверка S3: мусор в папке выдачи (.bak, _recover, plot.log, ~$-файлы Word, .tmp, .dwl/.dwl2, .err).
#   .\clean_issue.ps1 -Dir "…\2026.10.14 - 01_B590…-ИЗn" [-Apply] [-KeepDwl]
# Без -Apply — только список. С -Apply файлы ПЕРЕНОСЯТСЯ в <WorkRoot>\backup\clean_<дата>\… (не удаляются).
# .dwl/.dwl2 могут означать, что файл открыт у пользователя: такие пропускаются, если сам DWG занят.
param([Parameter(Mandatory)][string]$Dir, [switch]$Apply, [switch]$KeepDwl,
      [string]$Pattern = '\.bak$|_recover\.dwg$|^plot\.log$|^~\$|^~WRL.*\.tmp$|\.tmp$|\.err$|\.dwl2?$')
. "$PSScriptRoot\common.ps1"
$bak = Join-Path $WorkRoot ("backup\clean_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$junk = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | Where-Object { $_.Name -match $Pattern })
if ($KeepDwl) { $junk = @($junk | Where-Object { $_.Extension -notmatch '^\.dwl2?$' }) }
$n = 0
foreach ($f in $junk) {
  $rel = $f.FullName.Substring($Dir.Length).TrimStart('\')
  if ($f.Extension -match '^\.dwl2?$') {
    $dwg = [IO.Path]::ChangeExtension($f.FullName, '.dwg')
    if ((Test-Path -LiteralPath $dwg) -and -not (Test-FileFree $dwg)) { "открыт у пользователя, пропуск: $rel"; continue }
  }
  if ($Apply) {
    $to = Join-Path $bak $rel; New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    try { Move-Item -LiteralPath $f.FullName $to -Force -ErrorAction Stop; $n++; "убрано: $rel" } catch { "!!! не убрано: $rel — $($_.Exception.Message)" }
  } else { $n++; "мусор: $rel  ($([math]::Round($f.Length / 1KB)) КБ)" }
}
if ($Apply) { "перенесено файлов: $n -> $bak" } else { "найдено: $n (пробный прогон; -Apply — перенести в резервную папку)" }
