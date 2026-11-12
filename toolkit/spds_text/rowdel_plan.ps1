# Pure validation, no Autodesk/vendor assembly or CAD process.
function Test-RowDeleteRequest {
  param([string[]]$Files, [string]$Specification, [switch]$Dry, [switch]$Apply, $Options = @{})
  if ($Files.Count -ne 1) { throw 'rowdel_requires_exactly_one_file' }
  if ([IO.Path]::GetExtension($Files[0]) -ine '.dwg') { throw 'rowdel_requires_dwg_extension' }
  if ($Dry -and $Apply) { throw 'rowdel_dry_and_apply_conflict' }
  foreach ($key in @('Find','Repl','Pairs','Seen','Handle','Handles','Class','Prop','From','To','CellFit','CellXScale','Pt','Arrow','Tol')) {
    if ($Options.ContainsKey($key)) { throw "rowdel_incompatible_option:$key" }
  }
  if (-not ('SpdsText.RowDeletion' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'RowDeletion.cs') -ErrorAction Stop }
  $null = [SpdsText.RowDeletion]::Parse($Specification)
}

function Assert-RowDeleteLog {
  param([string]$Log, [switch]$Dry)
  $lines = @(Get-Content -LiteralPath $Log -Encoding utf8 -ErrorAction Stop)
  if (@($lines | Where-Object { $_ -match '^(ERROR|NOTSAVED|NOOBJ|FAILMOD)\|' }).Count -gt 0) { throw 'rowdel_failed: see retained log; no Apply' }
  $ok = @($lines | Where-Object { $_ -match '^ROWDEL_OK\|' })
  $expected = if ($Dry) { '^ROWDEL_OK\|dry=True\|changed=0$' } else { '^ROWDEL_OK\|dry=False\|changed=[1-9][0-9]*$' }
  if ($ok.Count -ne 1 -or $ok[0] -notmatch $expected -or @($lines | Where-Object { $_ -match '^FILE\|' }).Count -ne 1 -or
      @($lines | Where-Object { $_ -match '^DONE\|' }).Count -ne 1 -or $lines -notcontains 'ALLDONE') { throw 'rowdel_incomplete: no Apply' }
  $saved = @($lines | Where-Object { $_ -match '^SAVED\|' }).Count
  if (($Dry -and $saved -ne 0) -or (-not $Dry -and $saved -ne 1)) { throw 'rowdel_save_evidence_invalid' }
}
