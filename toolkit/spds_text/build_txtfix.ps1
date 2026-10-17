# Сборка SpdsText.dll (C# 5, csc .NET Framework 4, x64) -> bin\SpdsText.dll
# Ссылки: AutoCAD 2024 (acmgd/acdbmgd/accoremgd) + СПДС GraphiCS 2023 (mapimgd/mapibasetypes). Другие версии — поправить пути.
$A = "C:\Program Files\Autodesk\AutoCAD 2024"; $M = "C:\Program Files\CSoft\СПДС GraphiCS 2023 x64\mg142x64"
New-Item -ItemType Directory -Force "$PSScriptRoot\bin" | Out-Null
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:library /platform:x64 /codepage:65001 /out:"$PSScriptRoot\bin\SpdsText.dll" `
  /r:"$A\acmgd.dll" /r:"$A\acdbmgd.dll" /r:"$A\accoremgd.dll" /r:"$M\mapimgd.dll" /r:"$M\mapibasetypes.dll" "$PSScriptRoot\SpdsText.cs"
if ($LASTEXITCODE -eq 0) { "собрано: $PSScriptRoot\bin\SpdsText.dll" }
