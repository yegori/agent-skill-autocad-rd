# Read-only shared PMP resolver; no common.ps1/work directory or CAD side effects.
function Get-PmpCatalog([string]$Path = '', [switch]$Inspect) {
  $arguments = @('-I', '-X', 'utf8', (Join-Path $PSScriptRoot 'pmp_catalog.py'))
  if ($Path) { $arguments += @('--pmp', $Path) }
  if ($Inspect) { $arguments += '--inspect' }
  $previousEncoding = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $json = & python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'pmp_catalog_failed' }
  } finally { [Console]::OutputEncoding = $previousEncoding }
  $json | ConvertFrom-Json
}

function Get-PmpPaperMatch($Catalog, [string]$Paper) {
  foreach ($entry in $Catalog.entries) { if ($entry.name -ceq $Paper) { return 'exact_name' } }
  $m = [regex]::Match($Paper, '\((\d+(?:[.,]\d+)?)\s*[xх×]\s*(\d+(?:[.,]\d+)?)', 'IgnoreCase')
  if ($m.Success) {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $width = [double]::Parse($m.Groups[1].Value.Replace(',', '.'), $ci)
    $height = [double]::Parse($m.Groups[2].Value.Replace(',', '.'), $ci)
    foreach ($entry in $Catalog.entries) {
      if ($entry.dimensions_mm.Count -eq 2 -and [Math]::Abs($width - $entry.dimensions_mm[0]) -le 0.05 -and [Math]::Abs($height - $entry.dimensions_mm[1]) -le 0.05) { return 'dimensions_only' }
    }
  }
  return 'missing'
}
