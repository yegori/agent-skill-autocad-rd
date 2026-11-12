# Word Window contract fixtures; actual session/Keep/production Bind AST. NEVER native host/COM/Win32.
param([string]$SessionFile='') # Test-only old-source comparison, no production native override.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
if(-not $SessionFile){$SessionFile=Join-Path $root 'toolkit/cover_session.ps1'}
. $SessionFile
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
namespace AutocadRd {
 public static class CoverWindow {
  public static object Bind(long hwnd,uint original){WordFake.State.Events.Add("bind:"+hwnd+":"+original);return WordFake.State.Native;}
 }
}
namespace WordFake {
 // Deliberately NO App.Hwnd. Only the documented App.ActiveWindow -> Window.Hwnd contract.
 public class App {
  public object RawActive; public bool GetterThrows;
  public object ActiveWindow {get{State.Events.Add("active_access");if(GetterThrows)throw new System.Runtime.InteropServices.COMException("OBJECT_DETAIL_NOT_DIAGNOSTIC",unchecked((int)0x80004005));return RawActive;}}
 }
 public class Window {
  public string Kind; public object RawHwnd,RawApplication; public bool HwndThrows,ApplicationThrows;
  public object Hwnd {get{State.Events.Add("hwnd:"+Kind);if(HwndThrows)throw new Exception("OBJECT_DETAIL_NOT_DIAGNOSTIC");return RawHwnd;}}
  public object Application {get{State.Events.Add("application_access");if(ApplicationThrows)throw new Exception("OBJECT_DETAIL_NOT_DIAGNOSTIC");return RawApplication;}}
 }
 public class EnumerableWindow : Window,IEnumerable {public IEnumerator GetEnumerator(){yield return "ENUMERATION_SENTINEL";}}
 public class EnumerableApp : App,IEnumerable {public IEnumerator GetEnumerator(){yield return "ENUMERATION_SENTINEL";}}
 public static class State {
  public static object Native; public static string Mode; public static List<string> Events;
  public static uint Pid(long hwnd){
   if((Mode=="pane_stale" && hwnd==100)||(Mode=="native_stale" && hwnd==200)||(Mode=="active_stale" && hwnd==300))throw new Win32Exception(1400,"inert_invalid_window");
   if((Mode=="pane_foreign" && hwnd==100)||(Mode=="native_foreign" && hwnd==200)||(Mode=="active_foreign" && hwnd==300))return 999;
   if(hwnd!=100 && hwnd!=200 && hwnd!=300)throw new Win32Exception(1400,"inert_invalid_window");return 731;
  }
 }
}
'@
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'toolkit/cover_native_host.ps1'),[ref]$tokens,[ref]$parseErrors)
$bindAst=$ast.Find({param($n) $n -is [Management.Automation.Language.ScriptBlockAst] -and $n.ParamBlock -and
    $n.ParamBlock.Parameters.Count -eq 2 -and $n.Extent.Text -match 'CoverWindow\]::Bind'},$true)
$productionBind=$bindAst.GetScriptBlock()
function Assert-Chain([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message}}
$modes=@('healthy','int64','enumNative','enumApplication','enumActive','allEnumerable','sameWindow','pane_foreign','pane_stale',
 'selector_null','selector_array','selector_string','selector_zero','bind_null','bind_array',
 'app_missing','app_null','app_getter','activeMember_missing','activeMember_null','activeMember_getter',
 'track_native_array','track_app_array','track_active_array','track_clone','track_null','track_extra')
foreach($prefix in @('native','active')){foreach($fault in @('null','zero','array','string','float','missing','getter','foreign','stale')){$modes+=($prefix+'_'+$fault)}}
$passed=0
foreach($mode in $modes){
 $rcws=[Collections.Generic.List[object]]::new();$script:events=[Collections.Generic.List[string]]::new();$script:documents=0
 $owner=[pscustomobject]@{OriginalProcessId=[uint32]731};$owner|Add-Member ScriptMethod Guard {$script:events.Add('guard')}
 $app=if($mode -in @('enumApplication','allEnumerable')){,[WordFake.EnumerableApp]::new()}else{,[WordFake.App]::new()}
 $native=if($mode -in @('enumNative','allEnumerable')){,[WordFake.EnumerableWindow]::new()}else{,[WordFake.Window]::new()}
 $active=if($mode -in @('enumActive','allEnumerable')){,[WordFake.EnumerableWindow]::new()}else{,[WordFake.Window]::new()}
 $native.Kind='native';$native.RawHwnd=[int32]200;$native.RawApplication=$app
 $active.Kind='active';$active.RawHwnd=[int32]300;$app.RawActive=$active
 if($mode -eq 'int64'){$native.RawHwnd=[long]200;$active.RawHwnd=[long]300}
 if($mode -eq 'sameWindow'){$active=$native;$app.RawActive=$native}
 foreach($prefix in @('native','active')){
  $target=if($prefix -eq 'native'){,$native}else{,$active}
  switch($mode){
   ($prefix+'_null') {$target.RawHwnd=$null}
   ($prefix+'_zero') {$target.RawHwnd=[int32]0}
   ($prefix+'_array') {$target.RawHwnd=[int32[]]@(200)}
   ($prefix+'_string') {$target.RawHwnd='200'}
   ($prefix+'_float') {$target.RawHwnd=[double]200}
   ($prefix+'_getter') {$target.HwndThrows=$true}
   ($prefix+'_missing') {if($prefix -eq 'native'){$native=[pscustomobject]@{Application=$app}}else{$active=[pscustomobject]@{};$app.RawActive=$active}}
  }
 }
 switch($mode){
  'app_missing' {$native=[pscustomobject]@{Hwnd=[int32]200}}
  'app_null' {$native.RawApplication=$null}
  'app_getter' {$native.ApplicationThrows=$true}
  'activeMember_missing' {$app=[pscustomobject]@{};$native.RawApplication=$app}
  'activeMember_null' {$app.RawActive=$null}
  'activeMember_getter' {$app.GetterThrows=$true}
 }
 Assert-Chain ($null -eq $app.PSObject.Properties['Hwnd']) 'fixture incorrectly supplies App.Hwnd'
 $script:nativeRef=$native;$script:appRef=$app;$script:activeRef=$active
 [WordFake.State]::Native=$native;[WordFake.State]::Events=$script:events;[WordFake.State]::Mode=$mode
 if($mode -eq 'bind_null'){[WordFake.State]::Native=$null};if($mode -eq 'bind_array'){[WordFake.State]::Native=[object[]]@($native)}
 $find={param($original) $script:events.Add("select:$original");switch($mode){'selector_null'{return $null};'selector_array'{return ,([long[]]@(100))};'selector_string'{return '100'};'selector_zero'{return [long]0};default{return [long]100}}}
 $lookup={param($hwnd) Assert-Chain ($hwnd -is [long]) 'non-scalar lookup';$script:events.Add("pid:$hwnd");[WordFake.State]::Pid($hwnd)}
 $track={param($value)
  if(($mode -eq 'track_native_array' -and [object]::ReferenceEquals($value,$script:nativeRef)) -or
     ($mode -eq 'track_app_array' -and [object]::ReferenceEquals($value,$script:appRef)) -or
     ($mode -eq 'track_active_array' -and [object]::ReferenceEquals($value,$script:activeRef))){return ,@($value)}
  switch($mode){'track_clone'{return [WordFake.Window]::new()};'track_null'{return $null};'track_extra'{$value;'EXTRA';return};default{Keep-CoverRcw $value}}
 }
 $doc={param($application) $script:events.Add('document');$script:documents++;Assert-Chain ([object]::ReferenceEquals($application,$script:appRef)) 'different app adopted';@{document_closed=$true}}
 $evidence=@{};$caught=$null
 try{$result=Invoke-CoverSession $owner $find $productionBind $lookup $track $doc $(if($mode -eq 'selector_zero'){1}else{30}) $evidence}catch{$caught=$_}
 $json=$evidence|ConvertTo-Json -Depth 10 -Compress
 Assert-Chain ($json -notmatch 'OBJECT_DETAIL_NOT_DIAGNOSTIC|ENUMERATION_SENTINEL|WordFake' -and $json.Length -lt 3072) 'unsafe provenance'
 if($mode -in @('healthy','int64','enumNative','enumApplication','enumActive','allEnumerable','sameWindow')){
  Assert-Chain ($null -eq $caught -and $script:documents -eq 1) ("healthy Word contract failed $mode : $caught; evidence=$json")
  $order=@($script:events|Where-Object{$_ -ne 'guard'}) -join ','
  $expectedOrder=if($mode -eq 'sameWindow'){'select:731,pid:100,bind:100:731,hwnd:native,pid:200,application_access,active_access,hwnd:native,pid:200,document'}else{'select:731,pid:100,bind:100:731,hwnd:native,pid:200,application_access,active_access,hwnd:active,pid:300,document'}
  Assert-Chain ($order -eq $expectedOrder) 'incorrect callback/getter/PID order'
  Assert-Chain ($script:events[$script:events.Count-2] -eq 'guard') 'no final owner guard'
  Assert-Chain ($evidence.pane_pid_matches_original -and $evidence.native_window_pid_matches_original -and $evidence.application_active_window_pid_matches_original) 'three PID gates absent'
  Assert-Chain ($result.ownership.native_window_hwnd -eq 200 -and $result.ownership.application_active_window_hwnd -eq $(if($mode -eq 'sameWindow'){200}else{300}) -and $result.ownership.pane_hwnd -eq 100) 'window evidence incorrect'
  Assert-Chain (-not $result.ownership.ContainsKey('application_hwnd') -and -not $evidence.ContainsKey('application_hwnd')) 'misleading App.Hwnd alias'
  $expectedRefs=if($mode -eq 'sameWindow'){2}else{3}
  Assert-Chain ($rcws.Count -eq $expectedRefs) 'scalar RCWs not retained';Keep-CoverRcw $app|Out-Null;Assert-Chain ($rcws.Count -eq $expectedRefs) 'duplicate RCW retained'
 }else{
  Assert-Chain ($null -ne $caught -and $script:documents -eq 0) ('invalid contract reached Document: '+$mode)
  Assert-Chain ($evidence.error_component -eq $evidence.substep -and $evidence.ContainsKey('error_hresult')) 'failure provenance missing'
  foreach($prefix in @('native','active')){
   $key=if($prefix -eq 'native'){'native_window'}else{'application_active_window'}
   if($mode -eq ($prefix+'_stale')){Assert-Chain ($evidence.substep -eq ($key+'_pid_lookup') -and $evidence.native_error -eq 1400) 'stale window provenance'}
   if($mode -eq ($prefix+'_foreign')){Assert-Chain ($evidence.substep -eq ($key+'_pid_lookup') -and -not $evidence[$key+'_pid_matches_original']) 'foreign window accepted'}
   if($mode -eq ($prefix+'_null')){Assert-Chain ($evidence[$key+'_hwnd'].shape -eq 'null' -and $evidence.substep -eq ($key+'_hwnd_validate')) 'null erased'}
   if($mode -eq ($prefix+'_missing')){Assert-Chain ($evidence[$key+'_hwnd'].shape -eq 'missing' -and $evidence.substep -eq ($key+'_hwnd_get')) 'missing getter erased'}
   if($mode -eq ($prefix+'_getter')){Assert-Chain ($evidence.substep -eq ($key+'_hwnd_get')) 'getter provenance lost'}
  }
  if($mode -like 'native_*'){Assert-Chain (-not ($script:events -contains 'application_access')) 'Application read before native Window PID proof'}
  Assert-Chain (-not ($script:events -contains 'pid:0')) 'zero lookup attempted'
  if($mode -eq 'activeMember_missing'){Assert-Chain ($evidence.substep -eq 'application_active_window_access' -and $evidence.application_active_window_member_state -eq 'missing') 'missing ActiveWindow erased'}
  if($mode -eq 'activeMember_null'){Assert-Chain ($evidence.substep -eq 'application_active_window_track' -and $evidence.application_active_window_member_state -eq 'null') 'null ActiveWindow erased'}
  if($mode -eq 'activeMember_getter'){Assert-Chain ($evidence.substep -eq 'application_active_window_access' -and $evidence.error_inner_hresult -eq -2147467259) 'no-activewindow exception lost'}
 }
 $passed++
}
Write-Output "PASS documented Word Window identity contract: $passed inert cases; App has NO Hwnd; no host/COM/WindowAPI activation"
