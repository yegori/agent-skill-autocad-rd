# Pure C# + wrapper validation tests; optional SDK ABI compile, never CAD/vendor execution.
param([string]$WorkDir = (Join-Path $env:TEMP ('rdci-rowdel-test-' + [Guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $WorkDir) { throw 'new_test_work_required' }
New-Item -ItemType Directory -Path $WorkDir | Out-Null
$package = Split-Path $PSScriptRoot
$source = Join-Path $package 'toolkit/spds_text/RowDeletion.cs'
$csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$exe = Join-Path $WorkDir 'RowCases.exe'
& $csc /nologo /target:exe "/out:$exe" $source (Join-Path $PSScriptRoot 'fixtures/rowdel_cases.cs')
if ($LASTEXITCODE -ne 0) { throw 'rowdel_fixture_compile_failed' }
& $exe
if ($LASTEXITCODE -ne 0) { throw 'rowdel_fixture_failed' }
. (Join-Path $package 'toolkit/spds_text/rowdel_plan.ps1')
function Refuses([scriptblock]$Action) {
  $rejected = $false
  try { & $Action } catch { $rejected = $true }
  if (-not $rejected) { throw 'unsafe_request_accepted' }
}
Test-RowDeleteRequest -Files @('one.dwg') -Specification 'A:0=header'
Refuses { Test-RowDeleteRequest -Files @('one.dwg','two.dwg') -Specification 'A:0=header' }
Refuses { Test-RowDeleteRequest -Files @('one.dxf') -Specification 'A:0=header' }
Refuses { Test-RowDeleteRequest -Files @('one.dwg') -Specification 'A:0=' }
Refuses { Test-RowDeleteRequest -Files @('one.dwg') -Specification 'A:0=header' -Dry -Apply }
Refuses { Test-RowDeleteRequest -Files @('one.dwg') -Specification 'A:0=header' -Options @{Find='anything'} }
$log = Join-Path $WorkDir 'fake.log'
$good = @('FILE|one|dry=False','ROWDEL_OK|dry=False|changed=1','SAVED|new.dwg','DONE|changed=1|mcs=1','ALLDONE')
$good | Set-Content $log -Encoding utf8
Assert-RowDeleteLog -Log $log
foreach ($remove in @('ROWDEL_OK','SAVED','DONE','ALLDONE')) {
  @($good | Where-Object { -not $_.StartsWith($remove) }) | Set-Content $log -Encoding utf8
  Refuses { Assert-RowDeleteLog -Log $log }
}
@($good + 'ERROR|rowdel|failed') | Set-Content $log -Encoding utf8
Refuses { Assert-RowDeleteLog -Log $log }
@('FILE|one|dry=True','ROWDEL_OK|dry=True|changed=0','DONE|changed=0|mcs=1','ALLDONE') | Set-Content $log -Encoding utf8
Assert-RowDeleteLog -Log $log -Dry
Refuses { Assert-RowDeleteLog -Log $log }
'OK: one-file/options/guard/dry-run and fail-closed save evidence validation'
$acad = if ($env:RDCI_ACAD_DIR) { $env:RDCI_ACAD_DIR } else { 'C:\Program Files\Autodesk\AutoCAD 2024' }
$spds = if ($env:RDCI_SPDS_DIR) { $env:RDCI_SPDS_DIR } else { 'C:\Program Files\CSoft\СПДС GraphiCS 2023 x64\mg142x64' }
$refs = @('acmgd.dll','acdbmgd.dll','accoremgd.dll') | ForEach-Object { Join-Path $acad $_ }
$refs += @('mapimgd.dll','mapibasetypes.dll') | ForEach-Object { Join-Path $spds $_ }
if (@($refs | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0) {
  $argsRefs = $refs | ForEach-Object { '/r:' + $_ }
  & $csc /nologo /target:library /platform:x64 /codepage:65001 "/out:$(Join-Path $WorkDir 'SpdsText-abi.dll')" @argsRefs $source (Join-Path $package 'toolkit/spds_text/SpdsText.cs') (Join-Path $package 'toolkit/spds_text/SpdsDependencies.cs')
  if ($LASTEXITCODE -ne 0) { throw 'rowdel_sdk_compile_failed' }
  'OK: full plugin SDK ABI compile only; no DLL loading/CAD/DWG/SaveAs/native acceptance'
} else { 'SKIP SDK compile: references unavailable; inert cases do not prove MultiCAD compatibility' }
"Artifacts: $WorkDir"
