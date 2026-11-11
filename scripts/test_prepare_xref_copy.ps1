# Offline wrapper fake compiler/process only. No Autodesk assembly loads, CAD or source documents.
$ErrorActionPreference = 'Stop'
$package = Split-Path $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('prepare-fake-' + [guid]::NewGuid().ToString('N'))
$oldWindir, $oldRequest, $oldMode, $oldCount = $env:WINDIR, $env:RDCI_PREPARE_REQUEST, $env:RDCI_PREPARE_FAKE_MODE, $env:RDCI_PREPARE_FAKE_COUNT
$fakePackage = Join-Path $root 'package'
New-Item -ItemType Directory -Path "$fakePackage/toolkit/spds_text", "$fakePackage/toolkit/dependencies", "$fakePackage/toolkit/fake-acad", "$root/host", "$root/windows/Microsoft.NET/Framework64/v4.0.30319" | Out-Null
try {
    $compiler = @'
using System; using System.IO;
class FakeCompiler {
 static int Main(string[] args) {
  bool source=false,output=false;
  foreach(string arg in args) {
   if(arg.EndsWith(".cs")) {
    if(arg.Contains("/") || !Path.IsPathRooted(arg) || !File.Exists(arg)) return 31;
    source=true;
   }
   if(arg.StartsWith("/r:") && arg != "/r:System.Web.Extensions.dll") {
    string path=arg.Substring(3);
    if(path.Contains("/") || !Path.IsPathRooted(path) || !File.Exists(path)) return 32;
   }
   if(arg.StartsWith("/out:")) {
    string path=arg.Substring(5);
    if(path.Contains("/") || !Path.IsPathRooted(path) || !Directory.Exists(Path.GetDirectoryName(path))) return 34;
    output=true;
   }
  }
  if(!source || !output) return 33;
  foreach(string arg in args) if(arg.StartsWith("/out:")) File.WriteAllText(arg.Substring(5),"fake dll");
  return 0;
 }
}
'@
    $fakeSource = Join-Path $root 'Fake.cs'
    $fakeCompiler = Join-Path $root 'windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    [IO.File]::WriteAllText($fakeSource, $compiler)
    & (Join-Path $oldWindir 'Microsoft.NET/Framework64/v4.0.30319/csc.exe') /nologo /target:exe "/out:$fakeCompiler" $fakeSource
    if ($LASTEXITCODE -ne 0) { throw 'fake_compiler_build_failed' }
    foreach($name in @('prepare_xref_copy.ps1','prepare_xref_copy.py','stage_inputs.py','resource_inventory.py','plan_stages.py')) {
        Copy-Item -LiteralPath (Join-Path $package ('toolkit/'+$name)) -Destination (Join-Path $fakePackage ('toolkit/'+$name))
    }
    # No real C# compile / ABI claim: the fake compiler validates native argument paths only.
    [IO.File]::WriteAllText((Join-Path $fakePackage 'toolkit/dependencies/PrepareXrefCopy.cs'), '// fake only')
    foreach($name in @('AcDbMgd.dll','AcMgd.dll','AcCoreMgd.dll')) {
        [IO.File]::WriteAllText((Join-Path $fakePackage ('toolkit/fake-acad/'+$name)), 'fake assembly')
    }
    [IO.File]::WriteAllText((Join-Path $fakePackage 'toolkit/common.ps1'), @'
$AcadDir=Join-Path $PSScriptRoot 'fake-acad';$AccCore='fake-never-launched';$LispHead=''
function Write-Scr([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text) }
'@)
    [IO.File]::WriteAllText((Join-Path $fakePackage 'toolkit/spds_text/owned_acad.ps1'), @'
function Invoke-OwnedTxtfixProcess {
 param($FilePath,$Arguments,$Log,$TimeoutSec)
 [IO.File]::AppendAllText($env:RDCI_PREPARE_FAKE_COUNT,"start`n")
 $q=Get-Content -LiteralPath $env:RDCI_PREPARE_REQUEST -Raw | ConvertFrom-Json
 if($Arguments[0] -ne '/i' -or [IO.File]::ReadAllText($Arguments[1]) -ne 'safe host'){throw 'source_as_host'}
 $lisp=[IO.File]::ReadAllText($Arguments[3])
 if($lisp.Contains('DELAY') -or $lisp.Contains('QUIT') -or $lisp.Contains('old-missing')){throw 'unsafe_lisp'}
 $pos=@('(setq rd_prepare_sl (getvar "SECURELOAD"))','(setvar "SECURELOAD" 0)',"(vl-catch-all-apply '(lambda () (command",'(setvar "SECURELOAD" rd_prepare_sl)','(if (and (not (vl-catch-all-error-p rd_prepare_load)) (= (getvar "SECURELOAD") rd_prepare_sl))','(command "RDPREPAREXREFCOPY")') | ForEach-Object {$lisp.IndexOf($_)}
 $prev=-1;foreach($i in $pos){if($i -le $prev){throw 'load_restore_order'};$prev=$i}
 $mode=$env:RDCI_PREPARE_FAKE_MODE
 if($mode -eq 'nativefailure') {
   @{schema_version=1;kind='explicit_xref_copy_failure';status='failed';phase='save_as';exception_type='System.InvalidOperationException';message='synthetic API failure'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $q.report) 'native.failure.json')
   return [pscustomobject]@{AllDone=$false;TimedOut=$true;RootExitedBeforeStop=$false;RootExitCodeBeforeStop=$null;Terminated=$true;ElapsedSeconds=0.1}
 }
 # Synthetic native fail-before identity model; actual C# identities still require real acceptance.
 foreach($m in $q.mappings){
   $expected=[Convert]::ToInt32($m.handle,16)-1
   if($expected -lt 0 -or $expected -gt 2 -or $m.name -ne "ref$expected" -or $m.old_path -ne "Z:\old-missing$expected.dwg"){throw 'fake_stale_btr_identity'}
 }
 [IO.File]::WriteAllText($q.output,'fake derived output')
 $native=@{schema_version=1;kind='explicit_xref_copy';status='prepared_candidate';completion_hold='inside_managed_prepare_command';
   request_sha256=(Get-FileHash -LiteralPath $env:RDCI_PREPARE_REQUEST).Hash.ToLowerInvariant();source_sha256=$q.source_sha256;
   output=$q.output;output_sha256=(Get-FileHash -LiteralPath $q.output).Hash.ToLowerInvariant();changed_count=3;
   verified_direct_xref_count=3;mappings=$q.mappings;dependency_complete=$false;semantic_identity_proven=$false;execution_authorized=$false}
 if($mode -eq 'count'){$native.changed_count=2}
 if($mode -eq 'path'){$native.mappings[0].new_path='wrong'}
 if($mode -eq 'target'){[IO.File]::AppendAllText($q.mappings[0].target,'mutation')}
 if($mode -eq 'source'){[IO.File]::AppendAllText($q.source,'mutation')}
 $native | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $q.report -Encoding utf8
 if($mode -ne 'marker'){[IO.File]::WriteAllText($Log,"ALLDONE`n")}
 if($mode -eq 'uncertain'){throw 'owned_job_cleanup_uncertain'}
 [pscustomobject]@{AllDone=($mode -ne 'marker');TimedOut=($mode -eq 'timeout');RootExitedBeforeStop=($mode -eq 'early');RootExitCodeBeforeStop=$(if($mode -eq 'early'){0}else{$null});Terminated=($mode -ne 'early');ElapsedSeconds=0.1}
}
'@)
    $env:WINDIR=Join-Path $root 'windows';$env:RDCI_PREPARE_REQUEST='preserve-me';$env:RDCI_PREPARE_FAKE_COUNT=Join-Path $root 'count.txt'
    $hostFile=Join-Path $root 'host/safe.dwg';[IO.File]::WriteAllText($hostFile,'safe host')
    $hostSha=(Get-FileHash -LiteralPath $hostFile).Hash.ToLowerInvariant()
    $passed=0
    foreach($mode in @('happy','sameparent','outputcollision','hardlink','nativefailure','count','path','target','source','marker','early','timeout','uncertain','stalehandle','stalename','staleold','preflight')) {
        $case=Join-Path $root $mode
        New-Item -ItemType Directory -Path "$case/sources","$case/issue/refs" | Out-Null
        $source=Join-Path $case 'sources/001 sample.dwg';[IO.File]::WriteAllText($source,'synthetic source')
        $sameParent = $mode -in @('sameparent','outputcollision','hardlink')
        $targetDir = if($sameParent){Join-Path $case 'issue/prepared/Внешние_ссылки'}else{Join-Path $case 'issue/refs'}
        if($sameParent){New-Item -ItemType Directory -Path $targetDir | Out-Null}
        $maps=@(0..2 | ForEach-Object {
            $target=Join-Path $targetDir "$_.dwg";[IO.File]::WriteAllText($target,"target$_")
            $newPath=if($sameParent){".\Внешние_ссылки\$_.dwg"}else{"..\refs\$_.dwg"}
            @{handle=[string]($_+1);name="ref$_";old_path="Z:\old-missing$_.dwg";new_path=$newPath;target_sha256=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant()}
        })
        if($mode -eq 'outputcollision'){[IO.File]::WriteAllText((Join-Path $case 'issue/prepared/001 sample.dwg'),'protected existing')}
        if($mode -eq 'hardlink'){New-Item -ItemType HardLink -Path (Join-Path $case 'alias.dwg') -Target (Join-Path $targetDir '0.dwg') | Out-Null}
        $spec=@{schema_version=1;source_root=(Join-Path $case 'sources');source_path='001 sample.dwg';source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant();issue_root=(Join-Path $case 'issue');output_path='prepared/001 sample.dwg';mappings=$maps}
        if($mode -eq 'stalehandle'){$maps[0].handle='A'}
        if($mode -eq 'stalename'){$maps[0].name='different'}
        if($mode -eq 'staleold'){$maps[0].old_path='different'}
        if($mode -eq 'preflight'){$spec.source_sha256='0'*64}
        $specFile=Join-Path $case 'spec.json';$spec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $specFile -Encoding utf8
        $evidence=Join-Path $case 'evidence';$env:RDCI_PREPARE_FAKE_MODE=$mode
        $failed=$false
        try { & (Join-Path $fakePackage 'toolkit/prepare_xref_copy.ps1') -Spec $specFile -HostDwg $hostFile -HostSha256 $hostSha -EvidenceDir $evidence -TimeoutSec 2 }
        catch {$failed=$true;"EXPECTED failure [$mode]: $($_.Exception.Message)"}
        $output=Join-Path $case 'issue/prepared/001 sample.dwg'
        if($mode -in @('happy','sameparent')) {
            if($failed -or -not (Test-Path -LiteralPath "$evidence/prepared.json") -or -not (Test-Path -LiteralPath $output)){throw 'happy_failed'}
            $report=Get-Content -LiteralPath "$evidence/prepared.json" -Raw | ConvertFrom-Json
            if($null -ne $report.exit_code -or -not $report.cleanup_verified -or $report.dependency_complete -or $report.publication_approved){throw 'false_claim'}
        } else {
            if(-not $failed -or (Test-Path -LiteralPath "$evidence/prepared.json") -or ((Test-Path -LiteralPath $output) -and $mode -ne 'outputcollision')){throw "failure_published_$mode"}
            if($mode -eq 'outputcollision' -and [IO.File]::ReadAllText($output) -ne 'protected existing'){throw 'collision_overwritten'}
            if($mode -notin @('preflight','outputcollision','hardlink') -and -not (Test-Path -LiteralPath "$evidence/failure.json")){throw 'failure_evidence_missing'}
            if($mode -in @('outputcollision','hardlink') -and (Test-Path -LiteralPath $evidence)){throw 'alias_or_collision_reached_native'}
        }
        if($env:RDCI_PREPARE_REQUEST -ne 'preserve-me' -or [IO.File]::ReadAllText($source) -ne 'synthetic source'){throw 'original_or_env_mutated'}
        if($mode -eq 'sameparent') {
            $actual=Get-Content -LiteralPath "$evidence/request.json" -Raw | ConvertFrom-Json
            for($i=0;$i -lt 3;$i++){
                if($actual.mappings[$i].new_path -ne ".\Внешние_ссылки\$i.dwg" -or (Get-FileHash -LiteralPath (Join-Path $targetDir "$i.dwg")).Hash.ToLowerInvariant() -ne $maps[$i].target_sha256){throw 'sameparent_mapping_or_target_changed'}
            }
        }
        if($mode -eq 'nativefailure') {
            $nativeError=Get-Content -LiteralPath "$evidence/native.failure.json" -Raw | ConvertFrom-Json
            $failure=Get-Content -LiteralPath "$evidence/failure.json" -Raw | ConvertFrom-Json
            if($nativeError.phase -ne 'save_as' -or -not $failure.owned.TimedOut -or (Test-Path -LiteralPath "$evidence/native.complete")){throw 'native_error_conflated_or_success_marker'}
        }
        if($mode -eq 'early') {
            $failure=Get-Content -LiteralPath "$evidence/failure.json" -Raw | ConvertFrom-Json
            if($failure.owned.RootExitCodeBeforeStop -ne 0 -or -not $failure.owned.RootExitedBeforeStop){throw 'exit_observation_lost'}
        }
        $passed++;"OK: $mode"
    }
    if(([IO.File]::ReadAllLines($env:RDCI_PREPARE_FAKE_COUNT)).Count -ne 14){throw 'preflight_started_native'}
    "PASS: $passed fake-wrapper cases; source/reference/out compiler arguments are native existing paths"
} finally {
    $env:WINDIR=$oldWindir;$env:RDCI_PREPARE_REQUEST=$oldRequest;$env:RDCI_PREPARE_FAKE_MODE=$oldMode;$env:RDCI_PREPARE_FAKE_COUNT=$oldCount
    Remove-Item -LiteralPath $root -Recurse -Force
}
