# Disposable PMP + fake metadata reader; never CAD, real registry mutation or user Plotters writes.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('rdci-pmp-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$package = Split-Path $PSScriptRoot
foreach ($file in @('check_papers.ps1','pmp_paths.ps1','pmp_catalog.py','add_pmp_size.py')) {
  Copy-Item -LiteralPath (Join-Path $package "toolkit/$file") -Destination $root
}
[IO.File]::WriteAllText((Join-Path $root 'common.ps1'), @'
$Global:WorkRoot = Join-Path $PSScriptRoot 'work'
$Global:LispHead = ''; $Global:LispLayouts = ''; $Global:LispQuit = ''
function Invoke-AccCore($Dwg,$ScriptText,$Log,$TimeoutSec) {
  $target = Join-Path (Split-Path $Log) 'p1.txt'
  [IO.File]::WriteAllText($target,"Layout|$env:RDCI_FAKE_PAPER|DWG To PDF.pc3`n")
  return 'fake read; never CAD'
}
'@)
$old = $env:RDCI_FAKE_PAPER
try {
  $pmp = Join-Path $root 'форматы [тест].pmp'
  $body = @{data=@{udm=@{media=@{size=@{'0'=@{name='User-1';localized_name='Прежний размер листа (891.00 x 420.00 мм)'}};description=@{}}}}} | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText($pmp,"PIAFILEVERSION_3.0,json`n$body")
  $inputFile = Join-Path $root 'source.dwg'; [IO.File]::WriteAllText($inputFile,'synthetic, not a DWG')
  . (Join-Path $root 'pmp_paths.ps1')
  $info = Get-PmpCatalog -Path $pmp -Inspect
  if ($info.status -ne 'found' -or (Get-PmpPaperMatch $info 'UserDefinedMetric (891.00 x 420.00мм)') -ne 'dimensions_only') { throw 'dimension_match_failed' }
  if ((Get-PmpPaperMatch $info 'UserDefinedMetric (420.00 x 891.00мм)') -ne 'missing') { throw 'orientation_not_preserved' }
  $before = (Get-FileHash -LiteralPath $pmp).Hash
  $env:RDCI_FAKE_PAPER = 'UserDefinedMetric (891.00 x 420.00мм)'
  & (Join-Path $root 'check_papers.ps1') -Files @($inputFile) -PmpPath $pmp -Add | Out-Host
  if ($global:PaperMissing.Count -ne 0 -or (Get-FileHash -LiteralPath $pmp).Hash -ne $before -or @(Get-ChildItem $root -Filter '*.bak_*').Count -ne 0) { throw 'duplicate_size_written' }
  $env:RDCI_FAKE_PAPER = 'UserDefinedMetric (630.00 x 297.00мм)'
  & (Join-Path $root 'check_papers.ps1') -Files @($inputFile) -PmpPath $pmp -Add | Out-Host
  $info = Get-PmpCatalog -Path $pmp -Inspect
  if ((Get-PmpPaperMatch $info $env:RDCI_FAKE_PAPER) -ne 'exact_name' -or @(Get-ChildItem $root -Filter '*.bak_*').Count -ne 1) { throw 'explicit_temp_pmp_add_failed' }
  $env:RDCI_FAKE_PAPER = 'UserDefinedMetric invalid'
  $failed = $false
  try { & (Join-Path $root 'check_papers.ps1') -Files @($inputFile) -PmpPath $pmp -Add | Out-Host } catch { if ($_.Exception.Message -like 'pmp_add_failed*') { $failed=$true } else { throw } }
  if (-not $failed -or $global:PaperMissing.Count -ne 1) { throw 'failed_add_cleared_missing' }
  'OK: shared resolver explicit Unicode PMP, dimension-only match, no duplicate/config overwrite, disposable add and fail-closed PaperMissing'
} finally { $env:RDCI_FAKE_PAPER = $old }
"Artifacts: $root"
