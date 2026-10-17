# DWG -> DXF (R2018) через accoreconsole на копиях — для анализа геометрии в Python (ezdxf).
#   .\export_dxf.ps1 -Files a.dwg,b.dwg [-Out C:\…\dxf]      или  -DwgDir "…\DWG"
# DXF кладутся в <Out> под именами копий («005~3.dxf»), соответствие — map.txt. Исходники не меняются.
# Внимание: файлы со съёмкой/Civil 3D дают DXF в сотни МБ; ezdxf НЕ читает 3D-тела (SAB) — объёмы тел через massprop.ps1.
param([string[]]$Files = @(), [string]$DwgDir = "", [string]$Out = "", [string]$Exclude = '_recover')
. "$PSScriptRoot\..\common.ps1"
if ($DwgDir) { $Files += @(Get-ChildItem -LiteralPath $DwgDir -Filter *.dwg | Where-Object { -not ($Exclude -and $_.Name -match $Exclude) } | Sort-Object Name | ForEach-Object FullName) }
if (-not $Out) { $Out = Join-Path $WorkRoot "dxf" }
$w = Join-Path $WorkRoot "dxf_work"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Out | Out-Null
$jobs = Copy-DwgToWork $Files $w
$map = @()
foreach ($j in $jobs) {
  $dxf = Join-Path $Out ([IO.Path]::GetFileNameWithoutExtension($j.Work) + ".dxf")
  $r = Invoke-AccCore $j.Work ($LispHead + "(command `"_.DXFOUT`" `"$($dxf -replace '\\','/')`" `"_V`" `"2018`" `"16`")`n(princ `"\nDONE-`")" + $LispQuit) (Join-Path $w "e$($j.N).log") 900
  $ok = Test-Path -LiteralPath $dxf
  "{0}: {1}" -f (Split-Path $j.Src -Leaf), $(if ($ok) { "$dxf ($([math]::Round((Get-Item $dxf).Length / 1MB)) МБ)" } else { "!!! не выгружен" })
  $map += "$(Split-Path $dxf -Leaf)`t$($j.Src)"
}
$map | Set-Content (Join-Path $Out "map.txt") -Encoding utf8
