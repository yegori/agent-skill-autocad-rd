# Объёмы 3D-тел по слоям через MASSPROP (ezdxf тела в формате SAB не читает).
#   .\massprop.ps1 -Dwg "…\006_КВ.dwg" -Layers "inf_gsi_apron_mat","inf_gsi_ditch_wall" [-Out C:\…\mp]
# На каждое тело — .mpr (отчёт MASSPROP: объём, габаритная рамка); итог по слоям — число тел и сумма объёмов.
# Единицы — единицы чертежа (обычно м: объём в м³; если чертёж в мм — делить на 1e9).
param([Parameter(Mandatory)][string]$Dwg, [Parameter(Mandatory)][string[]]$Layers, [string]$Out = "", [string]$Type = "3DSOLID")
. "$PSScriptRoot\..\common.ps1"
if (-not $Out) { $Out = Join-Path $WorkRoot ("massprop\" + [regex]::Match((Split-Path $Dwg -Leaf), '^[0-9A-Za-z_.,\-]+').Value.TrimEnd('.')) }
Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $Out | Out-Null
$j = (Copy-DwgToWork @($Dwg) (Join-Path $WorkRoot "massprop_work"))[0]
$o = ($Out -replace '\\', '/') + '/'
$lays = ($Layers | ForEach-Object { "`"$_`"" }) -join " "
$lsp = $LispHead + @"
(setq n 0)
(foreach lay (list $lays)
  (setq ss (ssget "_X" (list (cons 0 "$Type") (cons 8 lay))) i 0)
  (if ss (repeat (sslength ss)
    (command "_.MASSPROP" (ssname ss i) "" "_Y" (strcat "$o" lay "_" (itoa i) ".mpr"))
    (setq i (1+ i) n (1+ n)))))
(princ (strcat "\nDONE-MP " (itoa n)))
"@ + $LispQuit
$null = Invoke-AccCore $j.Work $lsp (Join-Path $Out "mp.log") 1800
foreach ($lay in $Layers) {
  $vols = @(Get-ChildItem $Out -Filter "${lay}_*.mpr" -ErrorAction SilentlyContinue | ForEach-Object {
    $t = Get-Content $_.FullName -Raw -Encoding 1251
    if ($t -match '(Объем|Volume)\s*:\s*([\d.]+)') { [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) } })
  "{0}: тел {1}, объём {2:N3}" -f $lay, $vols.Count, (($vols | Measure-Object -Sum).Sum)
}
"отчёты .mpr: $Out"
