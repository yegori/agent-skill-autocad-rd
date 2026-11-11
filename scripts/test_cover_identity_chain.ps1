# Actual Invoke-CoverSession + actual pure Keep-CoverRcw, no host activation/COM/Win32.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
. (Join-Path $root 'toolkit/cover_session.ps1')
# Baseline can load ONLY this pure helper's AST, never execute the native host top level.
if (-not (Get-Command Keep-CoverRcw -ErrorAction SilentlyContinue)) {
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'toolkit/cover_native_host.ps1'),[ref]$tokens,[ref]$parseErrors)
    $helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Keep-CoverRcw'},$true)
    # Include the function header parameters, not merely its body ScriptBlock.
    Invoke-Expression $helper.Extent.Text
}
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.ComponentModel;
namespace AutocadRd {
 public static class CoverWindow {
  public static object Bind(long hwnd,uint original){IdentityFake.Binding.Events.Add("bind:"+hwnd+":"+original);if(IdentityFake.Binding.Mode=="bindError")throw new System.Runtime.InteropServices.COMException("OBJECT_DETAIL_NOT_DIAGNOSTIC",unchecked((int)0x80004005));return IdentityFake.Binding.Value;}
 }
}
namespace IdentityFake {
 public class UnwritableEvidence : System.Collections.Hashtable {public override object this[object key] {get{return "selector";}set{throw new Exception("inert_diagnostic_failure");}}}
 public class App { public virtual object Hwnd {get;set;} }
 public class ThrowingApp : App {public override object Hwnd {get{throw new Exception("OBJECT_DETAIL_NOT_DIAGNOSTIC");}set{}}}
 public class Pane { public virtual object Application {get;set;} }
 public class ThrowingPane : Pane {public override object Application {get{throw new Exception("OBJECT_DETAIL_NOT_DIAGNOSTIC");}set{}}}
 public class EnumerablePane : Pane, IEnumerable {public IEnumerator GetEnumerator(){yield return "ENUMERATION_SENTINEL";}}
 public class EnumerableApp : App, IEnumerable {public IEnumerator GetEnumerator(){yield return "ENUMERATION_SENTINEL";}}
 public static class Binding {
  public static object Value; public static string Mode;
  public static System.Collections.Generic.List<string> Events;
  public static object Bind(){return Value;}
  public static uint Pid(long hwnd){if(hwnd!=100 && hwnd!=200)throw new Win32Exception(1400,"inert_invalid_window");return 731;}
 }
}
'@
$tokens=$null;$parseErrors=$null
$hostAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'toolkit/cover_native_host.ps1'),[ref]$tokens,[ref]$parseErrors)
$bindAst=$hostAst.Find({param($node) $node -is [Management.Automation.Language.ScriptBlockAst] -and
    $node.ParamBlock -and $node.ParamBlock.Parameters.Count -eq 2 -and $node.Extent.Text -match 'CoverWindow\]::Bind'},$true)
$productionBind=$bindAst.GetScriptBlock()
$passed=0
function Assert-Chain([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
foreach($mode in @('scalar','int64App','enumerablePane','enumerableApp','nullSelector','arraySelector','stringSelector','pointerSelector','overflowSelector','zeroSelector',
    'nullAppHwnd','missingAppHwnd','zeroAppHwnd','arrayAppHwnd','stringAppHwnd','floatAppHwnd','signedStaleApp',
    'foreignPane','foreignApp','stalePane','staleApp','pidArray','bindNull','bindArray','bindError','missingApplication','nullApplication','appGetter','hwndGetter',
    'trackArray','trackNull','trackClone','trackApplicationArray','trackExtra')) {
    $rcws=[Collections.Generic.List[object]]::new();$script:events=[Collections.Generic.List[string]]::new();$script:documents=0
    $owner=[pscustomobject]@{OriginalProcessId=[uint32]731};$owner|Add-Member ScriptMethod Guard {$script:events.Add('guard')}
    $app=if($mode -eq 'enumerableApp'){,[IdentityFake.EnumerableApp]::new()}else{,[IdentityFake.App]::new()}
    $app.Hwnd=[int32]200
    switch($mode){
        'int64App' {$app.Hwnd=[long]200}
        'nullAppHwnd' {$app.Hwnd=$null}
        'missingAppHwnd' {$app=[pscustomobject]@{}}
        'zeroAppHwnd' {$app.Hwnd=[long]0}
        'arrayAppHwnd' {$app.Hwnd=[long[]]@(200)}
        'stringAppHwnd' {$app.Hwnd='200'}
        'floatAppHwnd' {$app.Hwnd=[double]200}
        'signedStaleApp' {$app.Hwnd=[int32]::MinValue}
        'hwndGetter' {$app=[IdentityFake.ThrowingApp]::new()}
    }
    $pane=if($mode -eq 'enumerablePane'){,[IdentityFake.EnumerablePane]::new()}else{,[IdentityFake.Pane]::new()}
    if($mode -eq 'appGetter'){$pane=[IdentityFake.ThrowingPane]::new()}
    $pane.Application=$app
    if($mode -eq 'missingApplication'){$pane=[pscustomobject]@{}}
    if($mode -eq 'nullApplication'){$pane.Application=$null}
    [IdentityFake.Binding]::Value=$pane;[IdentityFake.Binding]::Events=$script:events;[IdentityFake.Binding]::Mode=$mode
    if($mode -eq 'bindNull'){[IdentityFake.Binding]::Value=$null}
    if($mode -eq 'bindArray'){[IdentityFake.Binding]::Value=[object[]]@($pane)}
    $find={param($original)
        $script:events.Add("select:$original")
        switch($mode){'nullSelector' {return $null};'arraySelector' {return ,([long[]]@(100))};'stringSelector' {return '100'};'pointerSelector' {return [IntPtr]::new(100)};'overflowSelector' {return [uint64]::MaxValue};'zeroSelector' {return [long]0};default{return [long]100}}
    }
    # Execute the ACTUAL production callback AST against the inert static CoverWindow stub.
    $bind=$productionBind
    $lookup={param($hwnd)
        $script:events.Add("pid:$hwnd")
        Assert-Chain ($hwnd -is [long]) 'lookup argument was not scalar Int64'
        if(($mode -eq 'stalePane' -and $hwnd -eq 100) -or ($mode -eq 'staleApp' -and $hwnd -eq 200)){[IdentityFake.Binding]::Pid(-1);return}
        if($mode -eq 'pidArray'){return ,([uint32[]]@(731))}
        if(($mode -eq 'foreignPane' -and $hwnd -eq 100) -or ($mode -eq 'foreignApp' -and $hwnd -eq 200)){[uint32]999;return}
        [IdentityFake.Binding]::Pid($hwnd)
    }
    $track=switch($mode){
        'trackArray' {{param($value) return ,@($value)}}
        'trackNull' {{param($value) return $null}}
        'trackClone' {{param($value) return [IdentityFake.Pane]::new()}}
        'trackApplicationArray' {{param($value) if($value -is [IdentityFake.App]){return ,@($value)};Keep-CoverRcw $value}}
        'trackExtra' {{param($value) $value;'EXTRA_OUTPUT'}}
        default {${function:Keep-CoverRcw}}
    }
    $document={param($application)
        $script:events.Add('document');$script:documents++
        Assert-Chain ([object]::ReferenceEquals($application,$app)) 'Document did not receive original application'
        @{document_closed=$true}
    }
    $caught=$null;$evidence=@{}
    try{$result=Invoke-CoverSession $owner $find $bind $lookup $track $document $(if($mode -eq 'zeroSelector'){1}else{30}) $evidence}catch{$caught=$_}
    $json=$evidence|ConvertTo-Json -Depth 10 -Compress
    Assert-Chain ($json -notmatch 'OBJECT_DETAIL_NOT_DIAGNOSTIC|ENUMERATION_SENTINEL|IdentityFake' -and $json.Length -lt 2048) 'provenance serialized object/details'
    if($mode -in @('scalar','int64App','enumerablePane','enumerableApp')) {
        Assert-Chain ($null -eq $caught -and $script:documents -eq 1) ("healthy chain failed $mode : $caught; events="+($script:events -join ','))
        Assert-Chain (($script:events -join ',') -eq 'guard,select:731,guard,pid:100,bind:100:731,guard,pid:200,guard,document') 'callback order/arguments changed'
        Assert-Chain ($result.ownership.identity_verified -and $result.ownership.pane_hwnd -eq 100 -and $result.ownership.application_hwnd -eq 200) 'ownership proof missing'
        Assert-Chain ($evidence.pane_pid_matches_original -and $evidence.application_pid_matches_original -and $evidence.substep -eq 'document') 'PID checks not recorded'
        Assert-Chain ($rcws.Count -eq 2) 'actual Keep did not retain scalar pane/application'
        Keep-CoverRcw $app | Out-Null
        Assert-Chain ($rcws.Count -eq 2) 'Keep duplicate references not deduplicated'
    } else {
        Assert-Chain ($null -ne $caught -and $script:documents -eq 0) ("invalid chain reached Document: $mode")
        Assert-Chain ($evidence.error_component -eq $evidence.substep -and $evidence.ContainsKey('error_hresult')) 'failure substep/HRESULT missing'
        if($mode -in @('stalePane','staleApp','signedStaleApp')) {
            Assert-Chain ($evidence.native_error -eq 1400 -and $caught.ToString() -match 'inert_invalid_window') 'nested Win32 error/primary not preserved'
            Assert-Chain ($evidence.substep -eq $(if($mode -eq 'stalePane'){'pane_pid_lookup'}else{'application_pid_lookup'})) 'ambiguous ProcessId substep'
        }
        if($mode -eq 'missingApplication'){Assert-Chain ($evidence.substep -eq 'application_access' -and $evidence.application_member_state -eq 'missing') 'missing Application not recorded'}
        if($mode -eq 'nullApplication'){Assert-Chain ($evidence.application_member_state -eq 'null' -and $evidence.substep -eq 'application_track') 'null Application not recorded'}
        if($mode -eq 'bindError'){Assert-Chain ($evidence.error_inner_hresult -eq -2147467259 -and $evidence.substep -eq 'bind') 'inner COM HRESULT missing'}
        if($mode -eq 'signedStaleApp'){Assert-Chain ($evidence.application_hwnd.value -eq [int32]::MinValue -and $evidence.application_hwnd.type -eq 'System.Int32') 'signed HWND reinterpreted'}
        if($mode -eq 'nullAppHwnd'){Assert-Chain ($evidence.application_hwnd.shape -eq 'null' -and $evidence.substep -eq 'application_hwnd_validate') 'null erased by cast'}
        if($mode -eq 'missingAppHwnd'){Assert-Chain ($evidence.application_hwnd.shape -eq 'missing' -and $evidence.substep -eq 'application_hwnd_get') 'missing member erased by cast'}
        if($mode -in @('foreignPane','stalePane','nullSelector','arraySelector','stringSelector','pointerSelector','overflowSelector')) {
            Assert-Chain (@($script:events|Where-Object{$_ -like 'bind:*'}).Count -eq 0) 'bind reached before pane identity proof'
        }
        if($mode -eq 'floatAppHwnd'){Assert-Chain ($evidence.application_hwnd.type -eq 'System.Double') 'numeric type missing'}
        if($mode -eq 'pointerSelector'){Assert-Chain ($evidence.pane_hwnd.type -eq 'System.IntPtr') 'unsupported pointer type missing'}
        if($mode -eq 'zeroAppHwnd'){Assert-Chain ($evidence.application_hwnd.value -eq 0 -and -not ($script:events -contains 'pid:0')) 'zero app HWND looked up'}
        if($mode -eq 'appGetter'){Assert-Chain ($evidence.substep -eq 'application_access') ('app getter substep missing: '+$json)}
        if($mode -eq 'hwndGetter'){Assert-Chain ($evidence.substep -eq 'application_hwnd_get') 'HWND getter substep missing'}
    }
    $passed++
}
$primary=[ComponentModel.Win32Exception]::new(1400,'inert_primary')
Set-CoverIdentityError ([IdentityFake.UnwritableEvidence]::new()) $primary
Assert-Chain ($primary.NativeErrorCode -eq 1400 -and $primary.Message -eq 'inert_primary') 'diagnostic failure masked primary'
$passed++
Write-Output "PASS actual identity chain: $passed inert cases; no host/COM/WindowAPI/process activation"
