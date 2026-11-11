# CHANGED startup/window/diagnostic/blank guards ONLY. Inert doubles; never enumerate real windows/Word.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'toolkit/cover_session.ps1')
. (Join-Path $root 'toolkit/cover_document.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('pane-inert-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
$stub=@'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using AutocadRd;
namespace AutocadRd {
 public sealed class OwnedCadProcess : IDisposable {
  public static string[] Arguments; public static int Stops;
  public uint OriginalProcessId {get{return 731;}} public bool HasExited {get{return false;}}
  public uint? ExitCode {get{return null;}}
  public static OwnedCadProcess Start(string exe,string[] args){Arguments=args;return new OwnedCadProcess();}
  public bool Stop(){Stops++;return true;} public void Dispose(){}
 }
}
namespace PaneFake {
 public class Node {public uint Pid;public string Class;public bool Visible=true;}
 public class Windows : ICoverWindows {
  public Dictionary<long,Node> Nodes=new Dictionary<long,Node>();
  public List<long> Tops=new List<long>(); public Dictionary<long,List<long>> Child=new Dictionary<long,List<long>>();
  public int Error {get;set;} public bool TopFails, ChildReturn=false, FlipOnClass;
  public long ClassError, PidError; public int ForeignClassReads;
  public void Add(long h,uint pid,string name,bool top){Nodes[h]=new Node{Pid=pid,Class=name};if(top)Tops.Add(h);}
  public bool Top(Func<long,bool> callback){if(TopFails)return false;foreach(long h in Tops)if(!callback(h))return false;return true;}
  public bool Children(long h,Func<long,bool> callback){if(Child.ContainsKey(h))foreach(long c in Child[h])if(!callback(c))return false;return ChildReturn;}
  public uint Pid(long h){if(PidError==h)throw new Win32Exception(6,"fake_pid_error");return Nodes[h].Pid;}
  public string Class(long h){if(Nodes[h].Pid!=731){ForeignClassReads++;throw new Exception("foreign_class_read");}
   if(ClassError==h)throw new Win32Exception(5,"fake_class_error");if(FlipOnClass)Nodes[h].Pid=999;return Nodes[h].Class;}
  public bool Visible(long h){return Nodes[h].Visible;}
 }
}
'@
$passed=0
function Assert-Case([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Expect-Failure([scriptblock]$Code,[string]$Pattern){
    $caught=$null;try{& $Code|Out-Null}catch{$caught=$_}
    Assert-Case ($null -ne $caught -and $caught.ToString() -match $Pattern) ('missing failure '+$Pattern)
}
function New-Windows {
    $api=[PaneFake.Windows]::new();$api.Add(100,731,'OpusApp',$true)
    $api.Add(101,999,'FOREIGN_NEVER_RECORD',$false);$api.Add(102,731,'_WwG',$false)
    $api.Child[100]=[Collections.Generic.List[long]]@(101,102)
    return $api
}
function New-Blank {
    $blank=[pscustomobject]@{Path='';Saved=$true;Type=0;ReadOnly=$false;ProtectionType=-1;CloseCalls=0;
        Content=[pscustomobject]@{Start=0;End=1;StoryType=1;NextStoryRange=$null}}
    $blank.Content|Add-Member ScriptProperty Text {throw 'DOCUMENT_TEXT_MUST_NOT_BE_READ'}
    foreach($key in @('Characters','Paragraphs','Sections','StoryRanges')){$blank|Add-Member NoteProperty $key ([pscustomobject]@{Count=1})}
    foreach($key in @('Fields','Shapes','InlineShapes','Tables','Frames','ContentControls','Hyperlinks','Comments','Revisions','Footnotes','Endnotes','Variables')) {
        $blank|Add-Member NoteProperty $key ([pscustomobject]@{Count=0})
    }
    $blank|Add-Member ScriptMethod Close {param($save) $this.CloseCalls++}
    return $blank
}
# Replace ONLY actual COM Open boundary. The pipeline must refuse unexpected startup data before this.
function Open-CoverSnapshot($Documents,[string]$Snapshot){$script:openCalls++;throw 'APPROVED_SNAPSHOT_OPEN_TRIPWIRE'}
try {
    $stubPath=Join-Path $work 'stub.cs';[IO.File]::WriteAllText($stubPath,$stub)
    Add-Type -Path @($stubPath,(Join-Path $root 'toolkit/cover_native_window.cs'),(Join-Path $root 'toolkit/cover_owner.cs'))
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',120,(Join-Path $work 'audit.log'))
    try {
        Assert-Case (([AutocadRd.OwnedCadProcess]::Arguments -join ' ') -ceq '/w /a /q') 'startup flags/source argument changed'
    } finally {$owner.Dispose()};$passed++
    $api=New-Windows;$api.Error=5
    Assert-Case ([AutocadRd.CoverWindow]::FindPane(731,$api) -eq 102) 'callback stop was treated as API failure'
    Assert-Case ($api.ForeignClassReads -eq 0) 'foreign class read';$passed++
    $api=New-Windows;$api.Nodes[102].Class='_WwG_not_exact'
    Assert-Case ([AutocadRd.CoverWindow]::FindPane(731,$api) -eq 0) 'foreign/non-exact pane accepted';$passed++
    $api=New-Windows;$api.TopFails=$true;$api.Error=5
    Expect-Failure {[AutocadRd.CoverWindow]::FindPane(731,$api)} 'owned_enum_windows_failed';$passed++
    $api=New-Windows;$api.TopFails=$true;$api.Error=0
    Expect-Failure {[AutocadRd.CoverWindow]::FindPane(731,$api)} 'owned_enum_windows_failed';$passed++
    $api=New-Windows;$api.ClassError=102
    Expect-Failure {[AutocadRd.CoverWindow]::FindPane(731,$api)} 'fake_class_error';$passed++
    $api=New-Windows;$api.PidError=100
    Expect-Failure {[AutocadRd.CoverWindow]::FindPane(731,$api)} 'fake_pid_error';$passed++
    $api=New-Windows;$api.FlipOnClass=$true
    Expect-Failure {[AutocadRd.CoverWindow]::FindPane(731,$api)} 'owned_window_identity_changed';$passed++
    $api=New-Windows;$api.Child[100].Clear() # ChildReturn=false is explicitly NOT an API error contract.
    Assert-Case ([AutocadRd.CoverWindow]::FindPane(731,$api) -eq 0) 'unused child return misclassified';$passed++
    $api=[PaneFake.Windows]::new()
    for($i=1;$i -le 2100;$i++){$api.Add($i,999,'FOREIGN_NEVER_RECORD',$true)}
    Expect-Failure {[AutocadRd.CoverWindow]::FindPane(731,$api)} 'owned_window_scan_limited';$passed++
    $api=New-Windows
    for($i=103;$i -lt 140;$i++){$api.Add($i,731,('Я'*300),$false);$api.Child[100].Add($i)}
    $snapshot=[AutocadRd.CoverWindow]::Capture(731,$api)
    $json=$snapshot|ConvertTo-Json -Depth 10 -Compress
    Assert-Case ($snapshot.Windows.Count -eq 16 -and $snapshot.Limited) 'diagnostic record cap absent'
    Assert-Case ([Text.Encoding]::UTF8.GetByteCount($json) -lt 8192 -and $json -notmatch 'FOREIGN_NEVER_RECORD') 'diagnostic not bounded/redacted'
    Assert-Case (@($snapshot.Windows|Where-Object{$_.Class.Length -gt 64}).Count -eq 0) 'class cap absent';$passed++
    $api=New-Windows;$api.FlipOnClass=$true
    $snapshot=[AutocadRd.CoverWindow]::Capture(731,$api)
    Assert-Case ($snapshot.Windows.Count -eq 0 -and $snapshot.Error -eq 'capture_failed') 'identity change leaked record';$passed++
    $api=New-Windows;$api.TopFails=$true;$api.Error=5
    $snapshot=[AutocadRd.CoverWindow]::Capture(731,$api)
    Assert-Case ($snapshot.Error -eq 'win32_error_5') 'diagnostic API error absent';$passed++
    # Failure diagnostic is before own cleanup, never a success/primary-error override.
    foreach($captureFails in @($false,$true)) {
        $owner=[AutocadRd.CoverOwner]::Start('inert.exe',120,(Join-Path $work 'audit.log'))
        $script:captureCalls=0;$primary=$null;$status='failed'
        try {Invoke-CoverSession $owner {throw 'owned_enum_windows_failed'} {} {} {param($v)return ,$v} {throw 'DOCUMENT_MUST_NOT_RUN'} 30}
        catch {
            $primary=$_.ToString()
            $diagnostic=Get-CoverReadinessFailureEvidence $owner {param($id)
                $script:captureCalls++;if($captureFails){throw 'CAPTURE_DETAIL_MUST_NOT_LEAK'}
                [AutocadRd.CoverWindow]::Capture($id,(New-Windows))
            }
        } finally {$owner.Dispose()}
        Assert-Case ($status -eq 'failed' -and $primary -match 'owned_enum_windows_failed' -and $owner.CleanupVerified -and $script:captureCalls -eq 1) 'diagnostic masked failure/cleanup'
        if($captureFails){Assert-Case ($diagnostic.error -eq 'readiness_capture_unavailable') 'diagnostic leaked exception'}
        $passed++
    }
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',120,(Join-Path $work 'audit.log'));$owner.Dispose()
    $diagnostic=Get-CoverReadinessFailureEvidence $owner {throw 'CAPTURE_MUST_NOT_RUN'}
    Assert-Case ($diagnostic.error -eq 'readiness_capture_unavailable') 'dead root capture allowed';$passed++
    $owner=[AutocadRd.CoverOwner]::Start('inert.exe',120,(Join-Path $work 'audit.log'))
    $diagnostic=Get-CoverReadinessFailureEvidence $owner {param($id) $owner.Dispose();[AutocadRd.CoverWindow]::Capture($id,(New-Windows))}
    Assert-Case ($diagnostic.error -eq 'readiness_capture_unavailable' -and -not $diagnostic.ContainsKey('snapshot')) 'post-capture root guard bypassed';$passed++
    foreach($mode in @('fresh','path','recovered','body','fields','shapes','inline','tables','stories','comments','revisions','missing','protected','template','next')) {
        $script:startup=New-Blank;$script:openCalls=0
        switch($mode){
            'path' {$script:startup.Path='unexpected'}
            'recovered' {$script:startup.Saved=$false}
            'body' {$script:startup.Content.End=2;$script:startup.Characters.Count=2}
            'fields' {$script:startup.Fields.Count=1}
            'shapes' {$script:startup.Shapes.Count=1}
            'inline' {$script:startup.InlineShapes.Count=1}
            'tables' {$script:startup.Tables.Count=1}
            'stories' {$script:startup.StoryRanges.Count=2}
            'comments' {$script:startup.Comments.Count=1}
            'revisions' {$script:startup.Revisions.Count=1}
            'missing' {$script:startup.PSObject.Properties.Remove('Saved')}
            'protected' {$script:startup.ProtectionType=0}
            'template' {$script:startup.Type=1}
            'next' {$script:startup.Content.NextStoryRange=[pscustomobject]@{}}
        }
        $docs=[pscustomobject]@{Count=1};$docs|Add-Member ScriptMethod Item {param($index)return $script:startup}
        $app=[pscustomobject]@{AutomationSecurity=1;DisplayAlerts=1;Documents=$docs;Options=[pscustomobject]@{
            UpdateLinksAtOpen=$true;UpdateFieldsAtPrint=$true;UpdateLinksAtPrint=$true;SaveNormalPrompt=$true;ConfirmConversions=$true}}
        $expected=if($mode -eq 'fresh'){'APPROVED_SNAPSHOT_OPEN_TRIPWIRE'}else{'startup_document_not_fresh_blank'}
        Expect-Failure {Invoke-CoverDocument $app @{snapshot='inert';replace=@{}} {} {param($v)return ,$v} {param($phase)}} $expected
        Assert-Case ($script:startup.CloseCalls -eq $(if($mode -eq 'fresh'){1}else{0}) -and
                     $script:openCalls -eq $(if($mode -eq 'fresh'){1}else{0})) ('unexpected Close/Open '+$mode)
        Assert-Case ($app.AutomationSecurity -eq 1 -and $app.Options.UpdateLinksAtOpen) 'own options not restored'
        $passed++
    }
    Write-Output "PASS changed pane/startup/blank guards: $passed inert cases; no live Win32/COM/process/Word calls"
} finally {[IO.Directory]::Delete($work,$true)}
