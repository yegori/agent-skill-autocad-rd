# One read-only side-database probe; host must be a separately approved safe DWG. No source Document.Open.
param([Parameter(Mandatory)][string]$SourceDwg, [Parameter(Mandatory)][string]$HostDwg,
      [Parameter(Mandatory)][string]$EvidenceDir, [ValidateRange(1,300)][int]$TimeoutSec = 120)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
. "$PSScriptRoot/spds_text/owned_acad.ps1"
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
New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
$copyDir = Join-Path $evidence 'input';New-Item -ItemType Directory -Path $copyDir | Out-Null
$copy = Join-Path $copyDir ([IO.Path]::GetFileName($source));Copy-Item -LiteralPath $source -Destination $copy -ErrorAction Stop
$hostCopy = Join-Path $evidence 'host.dwg';Copy-Item -LiteralPath $hostSource -Destination $hostCopy -ErrorAction Stop
if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha -or (Get-FileHash -LiteralPath $hostCopy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hostSha) { throw 'dependency_copy_changed' }
$marker = Join-Path $evidence 'native.complete';$raw = Join-Path $evidence 'native.json';$dll = Join-Path $evidence 'DependencyProbe.dll'
$request = Join-Path $evidence 'request.json';@{source=$copy;report=$raw;marker=$marker} | ConvertTo-Json | Set-Content -LiteralPath $request -Encoding utf8
$previous = $env:RDCI_DEP_REQUEST
try {
  $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
  & $csc /nologo /target:library "/out:$dll" "/r:$AcadDir/AcDbMgd.dll" "/r:$AcadDir/AcMgd.dll" "/r:$AcadDir/AcCoreMgd.dll" /r:System.Web.Extensions.dll "$PSScriptRoot/dependencies/DependencyProbe.cs" 2>&1 | Set-Content -LiteralPath (Join-Path $evidence 'build.txt') -Encoding utf8
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) { throw 'dependency_build_failed' }
  $env:RDCI_DEP_REQUEST = $request
  $lisp = $LispHead + "`n(command `"_.NETLOAD`" `"$($dll.Replace('\','/'))`")`n(command `"RDDEPENDENCIES`")`n(while T (command `"_.DELAY`" 1000))`n"
  $scr = Join-Path $evidence 'probe.scr';Write-Scr $scr $lisp
  $owned = Invoke-OwnedTxtfixProcess -FilePath $AccCore -Arguments @('/i',$hostCopy,'/s',$scr,'/l','ru-RU') -Log $marker -TimeoutSec $TimeoutSec
  if (-not $owned.AllDone -or $owned.TimedOut -or $owned.RootExitedBeforeStop -ne $false -or -not $owned.Terminated) { throw 'dependency_native_incomplete' }
  if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha -or (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceSha -or (Get-FileHash -LiteralPath $hostSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hostSha) { throw 'dependency_source_or_host_changed' }
  $native = Get-Content -LiteralPath $raw -Raw -Encoding utf8 | ConvertFrom-Json
  if ($native.status -ne 'observed_partial' -or $native.source_sha256 -ne $sourceSha -or $native.execution_authorized -ne $false) { throw 'dependency_native_report_invalid' }
  $report = @{ schema_version=1;kind='dependency_probe';status='observed_partial';source_sha256=$sourceSha;host_sha256=$hostSha;
               completion_mode='owned_job_after_side_database_read';exit_code=$null;root_alive_before_stop=$true;cleanup_verified=$true;
               elapsed_seconds=$owned.ElapsedSeconds;cad_starts=1;native_sha256=(Get-FileHash -LiteralPath $raw -Algorithm SHA256).Hash.ToLowerInvariant();
               execution_authorized=$false;coverage='direct_tables_and_asset_dictionaries' }
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'probe.json') -Encoding utf8
  [pscustomobject]@{status='observed_partial';xrefs=@($native.xrefs).Count;fonts=@($native.fonts).Count;assets=@($native.assets).Count;layouts=@($native.layouts).Count;execution_authorized=$false} | ConvertTo-Json -Compress
} catch {
  @{status='failed';execution_authorized=$false;error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'failure.json') -Encoding utf8
  throw
} finally { $env:RDCI_DEP_REQUEST = $previous }
