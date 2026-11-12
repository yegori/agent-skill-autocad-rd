# Focused changed-option tests: fake DB/process only, plus metadata-only SDK compile. Never launches CAD.
param([Parameter(Mandatory)][string]$WorkDir, [switch]$ManagedOnly)
$ErrorActionPreference='Stop'
$package=Split-Path $PSScriptRoot
if(Test-Path -LiteralPath $WorkDir){throw 'new_test_work_required'}
$work=[IO.Path]::GetFullPath($WorkDir);New-Item -ItemType Directory -Path $work | Out-Null
$csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$source=Join-Path $package 'toolkit/dependencies/DependencyProbe.cs'
$stubs=Join-Path $PSScriptRoot 'fixtures/targeted_block_stubs.cs';$cases=Join-Path $PSScriptRoot 'fixtures/targeted_block_cases.cs'
$testExe=Join-Path $work 'TargetedCases.exe'
& $csc /nologo /target:exe "/out:$testExe" /r:System.Web.Extensions.dll $source $stubs $cases
if($LASTEXITCODE -ne 0){throw 'targeted_stub_compile_failed'}
& $testExe
if($LASTEXITCODE -ne 0){throw 'targeted_inert_cases_failed'}
$acad=if($env:RDCI_ACAD_DIR){$env:RDCI_ACAD_DIR}else{'C:\Program Files\Autodesk\AutoCAD 2024'}
$refs=@('AcDbMgd.dll','AcMgd.dll','AcCoreMgd.dll') | ForEach-Object {Join-Path $acad $_}
if(@($refs | Where-Object {-not (Test-Path -LiteralPath $_)}).Count -eq 0){
  $referenceArgs=$refs | ForEach-Object {'/r:'+$_}
  & $csc /nologo /target:library "/out:$(Join-Path $work 'DependencyProbe-sdk.dll')" @referenceArgs /r:System.Web.Extensions.dll $source
  if($LASTEXITCODE -ne 0){throw 'targeted_sdk_compile_failed'}
  'OK: actual SDK ABI compile only, no assembly loading/database open/native execution'
}else{'SKIP: SDK reference files unavailable; stub compile is NOT SDK/native acceptance'}

if($ManagedOnly){'PASS: changed managed-only cases/SDK compile; unchanged wrapper cases deliberately not repeated';return}

# Isolated wrapper sandbox, synthetic .dwg extension bytes only (not valid drawings).
$oldWindir=$env:WINDIR;$oldRequest=$env:RDCI_DEP_REQUEST;$oldMode=$env:RDCI_TARGET_FAKE_MODE
New-Item -ItemType Directory -Path "$work/toolkit/spds_text","$work/toolkit/dependencies","$work/fake-sdk","$work/windows/Microsoft.NET/Framework64/v4.0.30319" | Out-Null
try {
 $fakeCode=Join-Path $work 'FakeCompiler.cs'
 [IO.File]::WriteAllText($fakeCode,@'
using System;using System.IO;
class FakeCompiler {static int Main(string[] args){foreach(string arg in args)if(arg.StartsWith("/out:"))File.WriteAllText(arg.Substring(5),"inert fake DLL");return 0;}}
'@)
 & $csc /nologo /target:exe "/out:$(Join-Path $work 'windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe')" $fakeCode
 if($LASTEXITCODE -ne 0){throw 'fake_compiler_failed'}
 Copy-Item -LiteralPath (Join-Path $package 'toolkit/inspect_dependencies.ps1') -Destination "$work/toolkit/inspect_dependencies.ps1"
 [IO.File]::WriteAllText("$work/toolkit/dependencies/DependencyProbe.cs",'// fake compiler only')
 [IO.File]::WriteAllText("$work/toolkit/common.ps1",@'
$AcadDir=Join-Path (Split-Path $PSScriptRoot) 'fake-sdk';$AccCore='fake-never-launched';$LispHead=''
function Write-Scr([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text)}
'@)
 [IO.File]::WriteAllText("$work/toolkit/spds_text/owned_acad.ps1",@'
function Invoke-OwnedTxtfixProcess {
 param($FilePath,$Arguments,$Log,$TimeoutSec)
 $request=Get-Content -LiteralPath $env:RDCI_DEP_REQUEST -Raw | ConvertFrom-Json
 $root=Split-Path (Split-Path $PSScriptRoot)
 [IO.File]::AppendAllText((Join-Path $root 'calls.txt'),"fake-owned`n")
 if($FilePath -ne 'fake-never-launched'){throw 'nonfake forbidden'}
 $status=if($env:RDCI_TARGET_FAKE_MODE -eq 'needs'){'needs_input'}else{'observed_partial'}
 $native=@{status='observed_partial';source_sha256=(Get-FileHash -LiteralPath $request.source).Hash.ToLowerInvariant();execution_authorized=$false;completion_hold='inside_managed_command';xrefs=@();fonts=@();assets=@();layouts=@()}
 if($request.PSObject.Properties.Name -contains 'target_reference'){
  if($request.target_reference -cne 'A1' -or $request.target_block -cne 'B2' -or $request.expected_source_sha256 -cne $native.source_sha256){throw 'target binding not transported'}
  $native.kind='side_database_targeted_block';$native.coverage='exact_edge_and_target_local_definition';$native.status=$status
  $native.targeted_block=@{status=$status;source_sha256=$native.source_sha256;requested_reference='A1';requested_block='B2';complete=$false;truncated=$false;link_verified=($status -eq 'observed_partial');max_blocks=2048;max_entities=20000}
  if($env:RDCI_TARGET_FAKE_MODE -eq 'badbinding'){$native.targeted_block.requested_block='B3'}
 }elseif(@($request.PSObject.Properties).Count -ne 3){throw 'default request schema changed'}
 $native | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $request.report -Encoding utf8
 [IO.File]::WriteAllText($Log,"ALLDONE`n")
 [pscustomobject]@{AllDone=$true;TimedOut=$false;RootExitedBeforeStop=$false;Terminated=$true;ElapsedSeconds=0.01}
}
'@)
 [IO.File]::WriteAllText("$work/source [unicode-исходник].dwg",'synthetic not DWG');[IO.File]::WriteAllText("$work/host.dwg",'synthetic host not DWG')
 $sourcePath=Join-Path $work 'source [unicode-исходник].dwg';$sha=(Get-FileHash -LiteralPath $sourcePath).Hash.ToLowerInvariant()
 $env:WINDIR=Join-Path $work 'windows';$env:RDCI_DEP_REQUEST='restore-sentinel'
 $invoke=Join-Path $work 'toolkit/inspect_dependencies.ps1'
 $argsBase=@{SourceDwg=$sourcePath;HostDwg="$work/host.dwg";TimeoutSec=2}
 $argsTarget=@{TargetReferenceHandle='a1';TargetBlockHandle='b2';ExpectedSourceSha256=$sha}
 & $invoke @argsBase @argsTarget -EvidenceDir "$work/targeted" | Out-Null
 $report=Get-Content -LiteralPath "$work/targeted/probe.json" -Raw | ConvertFrom-Json
 if($report.kind -ne 'targeted_block_probe' -or $report.status -ne 'observed_partial' -or $report.coverage -ne 'exact_edge_and_target_local_definition' -or $report.target_request.block -cne 'B2' -or -not $report.cleanup_verified -or $null -ne $report.exit_code){throw 'targeted wrapper evidence failed'}
 $env:RDCI_TARGET_FAKE_MODE='needs'
 & $invoke @argsBase @argsTarget -EvidenceDir "$work/needs" | Out-Null
 if((Get-Content "$work/needs/probe.json" -Raw | ConvertFrom-Json).status -ne 'needs_input'){throw 'semantic needs_input hidden'}
 $env:RDCI_TARGET_FAKE_MODE='badbinding'
 try{& $invoke @argsBase @argsTarget -EvidenceDir "$work/badbinding";throw 'binding_accepted'}catch{if($_.Exception.Message -ne 'dependency_target_report_invalid'){throw}}
 if(Test-Path "$work/badbinding/probe.json"){throw 'bad binding published'}
 $env:RDCI_TARGET_FAKE_MODE=''
 & $invoke @argsBase -EvidenceDir "$work/default" | Out-Null
 $default=Get-Content "$work/default/probe.json" -Raw | ConvertFrom-Json
 if($default.kind -ne 'dependency_probe' -or $default.coverage -ne 'direct_tables_and_asset_dictionaries' -or $default.PSObject.Properties.Name -contains 'target_request'){throw 'default wrapper changed'}
 'OK: targeted UTF8 transport/source binding/status evidence; needs_input not hidden; malformed native binding refused; narrow default request/probe compatibility'
 $negative=@(
  @{TargetReferenceHandle='A1'},
  @{TargetReferenceHandle='A*';TargetBlockHandle='B2';ExpectedSourceSha256=$sha},
  @{TargetReferenceHandle='01';TargetBlockHandle='B2';ExpectedSourceSha256=$sha},
  @{TargetReferenceHandle='A1';TargetBlockHandle='B2';ExpectedSourceSha256='invalid'},
  @{TargetReferenceHandle='A1';TargetBlockHandle='B2';ExpectedSourceSha256=('0'*64)}
 )
 $i=0
 foreach($bad in $negative){$i++;$dest="$work/reject$i";try{& $invoke @argsBase @bad -EvidenceDir $dest;throw 'invalid_accepted'}catch{if($_.Exception.Message -eq 'invalid_accepted'){throw}};if(Test-Path $dest){throw 'invalid option reached work/native'}}
 if(@(Get-Content "$work/calls.txt").Count -ne 4 -or $env:RDCI_DEP_REQUEST -ne 'restore-sentinel' -or (Get-FileHash -LiteralPath $sourcePath).Hash.ToLowerInvariant() -ne $sha){throw 'unexpected call/environment/source mutation'}
 'OK: incomplete/invalid handle/path aliases/SHA mismatch rejected pre-work/pre-owned; synthetic source and caller env preserved'
}finally{$env:WINDIR=$oldWindir;$env:RDCI_DEP_REQUEST=$oldRequest;$env:RDCI_TARGET_FAKE_MODE=$oldMode}
'PASS: changed-option tests complete; artifacts retained, no actual DWG/CAD/Word/WindowAPI/native trial'
