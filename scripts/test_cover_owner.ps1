# Actual CoverOwner managed watchdog logic, with an inert process stub (no native process/COM).
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'toolkit/cover_session.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('cover-owner-fake-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$fake=@'
using System;
namespace AutocadRd {
 public sealed class OwnedCadProcess : IDisposable {
  public static bool EarlyExit, Uncertain; public static int Starts, Stops;
  public uint OriginalProcessId {get{return 731;}}
  public bool HasExited {get{return EarlyExit;}}
  public uint? ExitCode {get{return EarlyExit ? (uint?)0 : null;}}
  public static OwnedCadProcess Start(string exe,string[] args) {
   if(args.Length!=3 || args[0]!="/w" || args[1]!="/a" || args[2]!="/q") throw new Exception("flags_wrong");
   Starts++;return new OwnedCadProcess();
  }
  public bool Stop(){Stops++;if(Uncertain)throw new Exception("fake_cleanup_uncertain");return true;}
  public void Dispose(){if(Uncertain)throw new Exception("fake_dispose_uncertain");}
 }
}
'@
try {
    $stub=Join-Path $work 'stub.cs';[IO.File]::WriteAllText($stub,$fake)
    Add-Type -Path @($stub,(Join-Path $root 'toolkit/cover_owner.cs'))
    $audit=Join-Path $work 'audit.log'; $passed=0
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',2,$audit)
    $owner.Guard(); $owner.Complete(); $owner.Dispose()
    if (-not $owner.CleanupVerified -or -not $owner.RootLiveBeforeStop -or $owner.TimedOut) {throw 'completion_unproven'}
    $passed++
    [AutocadRd.OwnedCadProcess]::EarlyExit=$true
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',2,$audit)
    $caught=$false;try {$owner.Guard()}catch{$caught=$true};$owner.Dispose()
    if (-not $caught -or $owner.RootLiveBeforeStop -or $owner.RootExitCodeBeforeStop -ne 0) {throw 'early_exit0_must_fail'}
    [AutocadRd.OwnedCadProcess]::EarlyExit=$false;$passed++
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',1,$audit)
    Start-Sleep -Milliseconds 1300
    if (-not $owner.TimedOut -or -not $owner.CleanupVerified) {throw 'watchdog_hang_cleanup_unproven'}
    $owner.Dispose();$passed++
    [AutocadRd.OwnedCadProcess]::Uncertain=$true
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',2,$audit)
    $caught=$false;try {$owner.Complete()}catch{$caught=$true};$owner.Dispose()
    if (-not $caught -or $owner.CleanupVerified -or -not $owner.CleanupError) {throw 'uncertainty_hidden'}
    [AutocadRd.OwnedCadProcess]::Uncertain=$false;$passed++
    # Foreign enumeration refuses before an owner start. Errors are not treated as WINWORD=0.
    $foreign=[pscustomobject]@{Disposed=$false};$foreign|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $starts=[AutocadRd.OwnedCadProcess]::Starts;$caught=$false
    try {Assert-NoCoverWordProcess {,$foreign}}catch{$caught=$true}
    if (-not $caught -or -not $foreign.Disposed -or $starts -ne [AutocadRd.OwnedCadProcess]::Starts) {throw 'foreign_word_touched'}
    $caught=$false;try {Assert-NoCoverWordProcess {throw 'enumeration_uncertain'}}catch{$caught=$true}
    if (-not $caught) {throw 'enumeration_uncertain_hidden'};$passed+=2
    foreach ($mode in @('success','foreignPane','foreignApplication','paneTimeout','earlyexit0')) {
        $owner=[AutocadRd.CoverOwner]::Start('inert.exe',3,$audit)
        if ($mode -eq 'earlyexit0') {[AutocadRd.OwnedCadProcess]::EarlyExit=$true}
        $script:docCalls=0;$caught=$false
        $find={param($id) if ($mode -eq 'paneTimeout') {0} else {100}}
        $bind={param($hwnd,$id) [pscustomobject]@{Hwnd=200;Application=[pscustomobject]@{ActiveWindow=[pscustomobject]@{Hwnd=300}}}}
        $windowPid={param($hwnd) if (($mode -eq 'foreignPane' -and $hwnd -eq 100) -or ($mode -eq 'foreignApplication' -and $hwnd -eq 300)) {999} else {731}}
        try {$result=Invoke-CoverSession $owner $find $bind $windowPid {param($v) return ,$v} {$script:docCalls++; @{document_closed=$true}} 1}
        catch {$caught=$true}
        finally {$owner.Dispose();[AutocadRd.OwnedCadProcess]::EarlyExit=$false}
        if ($mode -eq 'success') {
            if ($caught -or $script:docCalls -ne 1 -or -not $result.ownership.identity_verified) {throw 'owned_session_failed'}
        } elseif (-not $caught -or $script:docCalls -ne 0) {throw "ownership gate failed $mode"}
        $passed++
    }
    Write-Output "PASS ownership/watchdog: $passed inert cases; no native process/COM"
} finally { [IO.Directory]::Delete($work,$true) }
