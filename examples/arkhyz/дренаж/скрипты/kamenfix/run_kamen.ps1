# Запуск KAMENFIX в отдельном полном AutoCAD (нужен СПДС) для списка DWG.
#   .\run_kamen.ps1 -In a.dwg,b.dwg -Out a_fix.dwg,b_fix.dwg -Log x.log [-Dry]
# Ваш открытый AutoCAD не трогается: стартует новый acad.exe без чертежа, плагин сам открывает файлы,
# правит, сохраняет в -Out и закрывает; после «ALLDONE» в журнале процесс закрывается.
param([string[]]$In, [string[]]$Out, [string]$Log, [switch]$Dry, [int]$TimeoutSec = 1800)
# Не запускать одновременно с accoreconsole (печать/ОД): 14.10 так упал acad.exe (Access Violation, см. _claude\служебное).
# Входные файлы — копии во временной папке с латинскими именами; результат класть обратно, только если файл не открыт у пользователя.
$dll = "$PSScriptRoot\bin\KamenFix.dll"   # пересобрать: .\build_kamen.ps1
Remove-Item $Log -ErrorAction SilentlyContinue
$Out | % { Remove-Item $_ -ErrorAction SilentlyContinue }
$env:KAMEN_LOG = $Log; $env:KAMEN_IN = ($In -join "|"); $env:KAMEN_OUT = ($Out -join "|"); $env:KAMEN_DRY = $(if ($Dry) { "1" } else { "0" })
$scr = [IO.Path]::ChangeExtension($Log, ".scr")
$d = $dll -replace '\\','/'
@"
(setvar "FILEDIA" 0)
(setq sl (getvar "SECURELOAD"))
(setvar "SECURELOAD" 0)
(command "_.NETLOAD" "$d")
(setvar "SECURELOAD" sl)
KAMENFIX
"@ | Set-Content $scr -Encoding ascii
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process "C:\Program Files\Autodesk\AutoCAD 2024\acad.exe" -ArgumentList "/nologo /b `"$scr`"" -PassThru
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
  Start-Sleep 3
  if ((Test-Path $Log) -and (Select-String -Path $Log -Pattern "^ALLDONE" -Quiet)) { Start-Sleep 2; break }
  if ($p.HasExited) { break }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
"сек: " + [int]$sw.Elapsed.TotalSeconds
if (Test-Path $Log) { Get-Content $Log -Encoding utf8 } else { "журнала нет" }
