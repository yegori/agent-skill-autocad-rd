# Сборка SpdsText.dll (C# 5, csc .NET Framework 4, x64) -> <WorkRoot>\bin\SpdsText.dll
# Собирается на каждом ПК (в git dll нет): нужны AutoCAD 2024 (acmgd/acdbmgd/accoremgd) и СПДС GraphiCS 2023 (mapimgd/mapibasetypes).
# Другие версии — переменные RDCI_ACAD_DIR и RDCI_SPDS_DIR. Папка плагина — кэш (только чтение), поэтому dll кладётся в рабочую папку.
. "$PSScriptRoot\..\common.ps1"
$M = if ($env:RDCI_SPDS_DIR) { $env:RDCI_SPDS_DIR } else { "C:\Program Files\CSoft\СПДС GraphiCS 2023 x64\mg142x64" }
$out = Join-Path $WorkRoot "bin\SpdsText.dll"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:library /platform:x64 /codepage:65001 /out:"$out" `
  /r:"$AcadDir\acmgd.dll" /r:"$AcadDir\acdbmgd.dll" /r:"$AcadDir\accoremgd.dll" /r:"$M\mapimgd.dll" /r:"$M\mapibasetypes.dll" "$PSScriptRoot\SpdsText.cs"
if ($LASTEXITCODE -eq 0) { "собрано: $out" } else { "!!! сборка не удалась (проверьте пути AutoCAD/СПДС: RDCI_ACAD_DIR, RDCI_SPDS_DIR)" }
