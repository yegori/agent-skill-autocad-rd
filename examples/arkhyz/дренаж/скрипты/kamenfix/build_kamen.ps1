# Сборка KamenFix.dll (C# 5, .NET Framework 4 csc, x64) -> bin\KamenFix.dll
$A = "C:\Program Files\Autodesk\AutoCAD 2024"; $M = "C:\Program Files\CSoft\СПДС GraphiCS 2023 x64\mg142x64"
New-Item -ItemType Directory -Force "$PSScriptRoot\bin" | Out-Null
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:library /platform:x64 /codepage:65001 /out:"$PSScriptRoot\bin\KamenFix.dll" `
  /r:"$A\acmgd.dll" /r:"$A\acdbmgd.dll" /r:"$A\accoremgd.dll" /r:"$M\mapimgd.dll" /r:"$M\mapibasetypes.dll" "$PSScriptRoot\KamenFix.cs"
