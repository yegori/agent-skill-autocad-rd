# Full wrapper with fake compiler/process API. No Autodesk DLLs or CAD are loaded.
$ErrorActionPreference = 'Stop'
$package = Split-Path $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('dependency-test-' + [guid]::NewGuid().ToString('N'))
$oldWindir, $oldRequest, $oldCount, $oldMode = $env:WINDIR, $env:RDCI_DEP_REQUEST, $env:RDCI_FAKE_COUNT, $env:RDCI_FAKE_MODE
New-Item -ItemType Directory -Path "$root/toolkit/spds_text", "$root/toolkit/dependencies", "$root/toolkit/fake-acad", "$root/input", "$root/windows/Microsoft.NET/Framework64/v4.0.30319" | Out-Null
try {
    $compiler = @'
using System; using System.IO;
class FakeCompiler {
 static int Main(string[] args) {
  bool source=false;
  foreach(string arg in args) {
   if(arg.EndsWith(".cs")) {
    if(arg.Contains("/") || !File.Exists(arg)) return 31;
    source=true;
   }
   if(arg.StartsWith("/r:") && arg != "/r:System.Web.Extensions.dll") {
    string path=arg.Substring(3);
    if(path.Contains("/") || !File.Exists(path)) return 32;
   }
  }
  if(!source) return 33;
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
    Copy-Item -LiteralPath "$package/toolkit/inspect_dependencies.ps1" -Destination "$root/toolkit/inspect_dependencies.ps1"
    [IO.File]::WriteAllText((Join-Path $root 'toolkit/dependencies/DependencyProbe.cs'), '// fake only')
    foreach($name in @('AcDbMgd.dll','AcMgd.dll','AcCoreMgd.dll')) {
        [IO.File]::WriteAllText((Join-Path $root ('toolkit/fake-acad/'+$name)), 'fake assembly')
    }
    [IO.File]::WriteAllText("$root/toolkit/common.ps1", @'
$AcadDir=Join-Path $PSScriptRoot 'fake-acad';$AccCore='fake-never-launched';$LispHead=''
function Write-Scr([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text) }
'@)
    [IO.File]::WriteAllText("$root/toolkit/spds_text/owned_acad.ps1", @'
function Invoke-OwnedTxtfixProcess {
 param($FilePath,$Arguments,$Log,$TimeoutSec)
 [IO.File]::AppendAllText($env:RDCI_FAKE_COUNT,"start`n")
 $request=Get-Content -LiteralPath $env:RDCI_DEP_REQUEST -Raw | ConvertFrom-Json
 if($Arguments[0] -ne '/i' -or [IO.Path]::GetFileName($Arguments[1]) -ne 'host.dwg') { throw 'wrong_host' }
 if([IO.File]::ReadAllText($Arguments[1]) -ne 'safe host') { throw 'source_used_as_host' }
 @{status='observed_partial';source_sha256=(Get-FileHash -LiteralPath $request.source).Hash.ToLowerInvariant();execution_authorized=$false;
   xrefs=@();fonts=@();assets=@();layouts=@(@{name='test'})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $request.report
 [IO.File]::WriteAllText($Log,"ALLDONE`n")
 [pscustomobject]@{AllDone=$true;TimedOut=($env:RDCI_FAKE_MODE -eq 'timeout');RootExitedBeforeStop=$false;Terminated=$true;ElapsedSeconds=0.1}
}
'@)
    $env:WINDIR="$root/windows";$env:RDCI_DEP_REQUEST='preserve-me';$env:RDCI_FAKE_COUNT="$root/count.txt"
    [IO.File]::WriteAllText("$root/input/001 [test].dwg", 'source only')
    [IO.File]::WriteAllText("$root/safe.dwg", 'safe host')
    $inputs=@{SourceDwg="$root/input/001 [test].dwg";HostDwg="$root/safe.dwg";TimeoutSec=2}
    & "$root/toolkit/inspect_dependencies.ps1" @inputs -EvidenceDir "$root/evidence"
    $report=Get-Content -LiteralPath "$root/evidence/probe.json" -Raw | ConvertFrom-Json
    if($report.status -ne 'observed_partial' -or $report.cad_starts -ne 1 -or $null -ne $report.exit_code -or -not $report.cleanup_verified) { throw 'wrapper_result_invalid' }
    if($env:RDCI_DEP_REQUEST -ne 'preserve-me' -or [IO.File]::ReadAllText($inputs.SourceDwg) -ne 'source only') { throw 'source_or_environment_changed' }
    'OK: wrapper reaches fake compiler/owned call without automatic $Host collision; source/host separate and preserved'
    try { & "$root/toolkit/inspect_dependencies.ps1" @inputs -EvidenceDir "$root/evidence"; throw 'existing_accepted' }
    catch { if($_.Exception.Message -eq 'existing_accepted'){throw} }
    try { & "$root/toolkit/inspect_dependencies.ps1" @inputs -EvidenceDir "$root/кириллица"; throw 'nonascii_accepted' }
    catch { if($_.Exception.Message -ne 'dependency_evidence_requires_ascii_path'){throw} }
    if(([IO.File]::ReadAllLines($env:RDCI_FAKE_COUNT)).Count -ne 1){throw 'unexpected_owned_call'}
    'OK: old/non-ASCII output rejected before owned invocation'
    $env:RDCI_FAKE_MODE='timeout'
    try { & "$root/toolkit/inspect_dependencies.ps1" @inputs -EvidenceDir "$root/timed"; throw 'timeout_accepted' }
    catch { if($_.Exception.Message -ne 'dependency_native_incomplete'){throw} }
    if(Test-Path -LiteralPath "$root/timed/probe.json"){throw 'timeout_published_success'}
    if(-not (Test-Path -LiteralPath "$root/timed/failure.json") -or $env:RDCI_DEP_REQUEST -ne 'preserve-me'){throw 'failure_evidence_or_restore_missing'}
    'OK: completion marker does not hide timeout; failure evidence/environment preserved'
} finally {
    $env:WINDIR=$oldWindir;$env:RDCI_DEP_REQUEST=$oldRequest;$env:RDCI_FAKE_COUNT=$oldCount;$env:RDCI_FAKE_MODE=$oldMode
    Remove-Item -LiteralPath $root -Recurse -Force
}
