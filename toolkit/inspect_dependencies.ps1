# One read-only side-database probe; host must be a separately approved safe DWG. No source Document.Open.
param([Parameter(Mandatory)][string]$SourceDwg, [Parameter(Mandatory)][string]$HostDwg,
      [Parameter(Mandatory)][string]$EvidenceDir, [ValidateRange(1,300)][int]$TimeoutSec = 120,
      [string]$TargetReferenceHandle, [string]$TargetBlockHandle, [string]$ExpectedSourceSha256)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/spds_text/owned_acad.ps1"
$targetKeys = @('TargetReferenceHandle','TargetBlockHandle','ExpectedSourceSha256')
$targetCount = @($targetKeys | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count
$targeted = $targetCount -gt 0
if ($targeted) {
  if ($targetCount -ne 3) { throw 'dependency_target_request_incomplete' }
  foreach ($value in @($TargetReferenceHandle,$TargetBlockHandle)) {
    if ($value -cnotmatch '\A[1-9a-fA-F][0-9a-fA-F]{0,15}\z' -or [Convert]::ToInt64($value,16) -le 0) { throw 'dependency_target_positive_hex_required' }
  }
  if ($ExpectedSourceSha256 -cnotmatch '\A[0-9a-fA-F]{64}\z') { throw 'dependency_target_sha_required' }
  $TargetReferenceHandle=$TargetReferenceHandle.ToUpperInvariant();$TargetBlockHandle=$TargetBlockHandle.ToUpperInvariant()
  $ExpectedSourceSha256=$ExpectedSourceSha256.ToLowerInvariant()
}
if (Test-Path -LiteralPath $EvidenceDir) { throw 'dependency_evidence_exists' }
foreach ($candidate in @($SourceDwg,$HostDwg,$EvidenceDir)) {
  $itemPath = [IO.Path]::GetFullPath($candidate)
  while ($itemPath) {
    if ((Test-Path -LiteralPath $itemPath) -and ((Get-Item -LiteralPath $itemPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'dependency_reparse_point' }
    $itemPath = [IO.Path]::GetDirectoryName($itemPath)
  }
}
# $Host is a read-only automatic PowerShell variable (names are case-insensitive).
$source = (Resolve-Path -LiteralPath $SourceDwg).Path;$hostSource = (Resolve-Path -LiteralPath $HostDwg).Path
if ([IO.Path]::GetExtension($source) -ine '.dwg' -or [IO.Path]::GetExtension($hostSource) -ine '.dwg') { throw 'dependency_requires_dwg' }
$evidence = [IO.Path]::GetFullPath($EvidenceDir)
if ($evidence -notmatch '^[\x20-\x7E]+$') { throw 'dependency_evidence_requires_ascii_path' }
foreach ($file in @($source,$hostSource)) {
  if ($file.StartsWith($evidence.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'dependency_evidence_overlap' }
}
$sourceSha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$hostSha = (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant()
if ($targeted -and $sourceSha -cne $ExpectedSourceSha256) { throw 'dependency_target_source_sha_mismatch' }
New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
$copyDir = Join-Path $evidence 'input';New-Item -ItemType Directory -Path $copyDir | Out-Null
$copy = Join-Path $copyDir ([IO.Path]::GetFileName($source));Copy-Item -LiteralPath $source -Destination $copy -ErrorAction Stop
$hostCopy = Join-Path $evidence 'host.dwg';Copy-Item -LiteralPath $hostSource -Destination $hostCopy -ErrorAction Stop
if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha -or (Get-FileHash -LiteralPath $hostCopy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hostSha) { throw 'dependency_copy_changed' }
$marker = Join-Path $evidence 'native.complete';$raw = Join-Path $evidence 'native.json';$dll = Join-Path $evidence 'DependencyProbe.dll'
$request = Join-Path $evidence 'request.json'
$requestData = @{source=$copy;report=$raw;marker=$marker}
if ($targeted) {
  $requestData.target_reference=$TargetReferenceHandle;$requestData.target_block=$TargetBlockHandle;$requestData.expected_source_sha256=$ExpectedSourceSha256
}
$requestData | ConvertTo-Json | Set-Content -LiteralPath $request -Encoding utf8
$previous = $env:RDCI_DEP_REQUEST
$owned = $null
try {
  $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
  # Framework csc normalizes mixed-slash source arguments incorrectly; use native paths throughout.
  $code = Join-Path $PSScriptRoot 'dependencies/DependencyProbe.cs'
  $references = @('AcDbMgd.dll','AcMgd.dll','AcCoreMgd.dll') | ForEach-Object { '/r:' + (Join-Path $AcadDir $_) }
  & $csc /nologo /target:library "/out:$dll" @references /r:System.Web.Extensions.dll $code 2>&1 | Set-Content -LiteralPath (Join-Path $evidence 'build.txt') -Encoding utf8
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) { throw 'dependency_build_failed' }
  $env:RDCI_DEP_REQUEST = $request
  # Same temporary NETLOAD policy as run_txtfix; restore before any source database read.
  $lisp = $LispHead + @"

(progn
  (setq rd_dep_sl (getvar "SECURELOAD"))
  (setq rd_dep_dll "$($dll.Replace('\','/'))")
  (setvar "SECURELOAD" 0)
  (setq rd_dep_load (vl-catch-all-apply '(lambda () (command "_.NETLOAD" rd_dep_dll)) nil))
  (setvar "SECURELOAD" rd_dep_sl)
  (if (and (not (vl-catch-all-error-p rd_dep_load)) (= (getvar "SECURELOAD") rd_dep_sl))
    (command "RDDEPENDENCIES")))
"@
  $scr = Join-Path $evidence 'probe.scr';Write-Scr $scr $lisp
  $owned = Invoke-OwnedTxtfixProcess -FilePath $AccCore -Arguments @('/i',$hostCopy,'/s',$scr,'/l','ru-RU') -Log $marker -TimeoutSec $TimeoutSec
  if (-not $owned.AllDone -or $owned.TimedOut -or $owned.RootExitedBeforeStop -ne $false -or -not $owned.Terminated) { throw 'dependency_native_incomplete' }
  if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha -or (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha -or (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hostSha) { throw 'dependency_source_or_host_changed' }
  $native = Get-Content -LiteralPath $raw -Raw -Encoding utf8 | ConvertFrom-Json
  if ($native.source_sha256 -ne $sourceSha -or $native.execution_authorized -ne $false -or $native.completion_hold -ne 'inside_managed_command') { throw 'dependency_native_report_invalid' }
  if ($targeted) {
    $target = $native.targeted_block
    if ($native.kind -cne 'side_database_targeted_block' -or $native.coverage -cne 'exact_edge_and_target_local_definition' -or
        $native.status -cnotin @('observed_partial','needs_input') -or $target.status -cne $native.status -or
        $target.source_sha256 -cne $sourceSha -or $target.requested_reference -cne $TargetReferenceHandle -or $target.requested_block -cne $TargetBlockHandle -or
        $target.complete -ne $false -or $target.max_blocks -ne 2048 -or $target.max_entities -ne 20000 -or
        ($native.status -eq 'observed_partial' -and ($target.link_verified -ne $true -or $target.truncated -ne $false))) { throw 'dependency_target_report_invalid' }
  } elseif ($native.status -ne 'observed_partial') { throw 'dependency_native_report_invalid' }
  $report = @{ schema_version=1;kind='dependency_probe';status='observed_partial';source_sha256=$sourceSha;host_sha256=$hostSha;
               completion_mode='owned_job_after_side_database_read';native_hold=$native.completion_hold;exit_code=$null;root_alive_before_stop=$true;cleanup_verified=$true;
               elapsed_seconds=$owned.ElapsedSeconds;cad_starts=1;native_sha256=(Get-FileHash -LiteralPath $raw -Algorithm SHA256).Hash.ToLowerInvariant();
               execution_authorized=$false;coverage='direct_tables_and_asset_dictionaries' }
  if ($targeted) {
    $report.kind='targeted_block_probe';$report.status=$native.status;$report.coverage=$native.coverage
    $report.target_request=@{reference=$TargetReferenceHandle;block=$TargetBlockHandle;source_sha256=$ExpectedSourceSha256}
  }
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'probe.json') -Encoding utf8
  if ($targeted) {
    [pscustomobject]@{status=$native.status;reason=$target.reason;reference=$TargetReferenceHandle;block=$TargetBlockHandle;
      link_verified=$target.link_verified;entity_count=$target.entity_count;truncated=$target.truncated;execution_authorized=$false} | ConvertTo-Json -Compress
  } else {
  [pscustomobject]@{status='observed_partial';xrefs=@($native.xrefs).Count;fonts=@($native.fonts).Count;assets=@($native.assets).Count;layouts=@($native.layouts).Count;execution_authorized=$false} | ConvertTo-Json -Compress
  }
} catch {
  @{status='failed';execution_authorized=$false;error=$_.Exception.Message;owned=$owned} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'failure.json') -Encoding utf8
  throw
} finally { $env:RDCI_DEP_REQUEST = $previous }
