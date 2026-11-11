# Inert CLR Word/process doubles; no Word/COM/NativeOM/OS process API invoked.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'toolkit/cover_document.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
namespace CoverFake {
 public static class State {
  public static string Fail="", Text="TOKEN\r";
  public static List<string> Events=new List<string>();
  public static void Step(string name) { Events.Add(name); if(Fail==name) throw new Exception(name+"_error"); }
 }
 public class Counts { public int Count {get;set;} }
 public class Range {
  Doc doc; int start,end; bool whole;
  public Range(Doc d,int s,int e,bool all) {doc=d;start=s;end=e;whole=all;}
  public int Start {get{return start;}}
  public Counts Fields {get{return new Counts{Count=State.Fail=="Fields"?1:0};}}
  public string Text {
   get { State.Step("Find"); if(!whole && State.Fail=="Mismatch") return "wrong";
         return whole ? doc.text : doc.text.Substring(start,end-start); }
   set { State.Step("Edit"); doc.text=doc.text.Remove(start,end-start).Insert(start,value); }
  }
 }
 public class Stories { public object Item(int index) { return State.Fail=="Stories" ? new Range(new Doc(),0,1,true) : null; } }
 public class Doc {
  public string text=State.Text; public string Path {get{return State.Fail=="StartupForeign" ? "not-an-owned-blank" : "";}}
  public Range Content {get{return new Range(this,0,text.Length,true);}}
  public Counts Shapes {get{return new Counts{Count=State.Fail=="Shapes"?1:0};}}
  public Counts InlineShapes {get{return new Counts();}}
  public Counts Signatures {get{return new Counts{Count=State.Fail=="Signatures"?1:0};}}
  public Stories StoryRanges {get{return new Stories();}}
  public Range Range(int start,int end) {return new Range(this,start,end,false);}
  public void SaveAs2(string path,int format,bool locked,string password,bool recent) {State.Step("Save");File.WriteAllText(path,text);}
  public void ExportAsFixedFormat(string path,int format,bool open) {State.Step("Export");File.WriteAllText(path,"inert-pdf");}
  public void Close(int save) {State.Step("Close");}
 }
 public class Options {
  bool links=true;
  public bool UpdateLinksAtOpen {get{return links;}set{if(value)State.Step("Restore");links=value;}}
  public bool UpdateFieldsAtPrint {get;set;}=true;
  public bool UpdateLinksAtPrint {get;set;}=true;
  public bool SaveNormalPrompt {get;set;}=true;
  public bool ConfirmConversions {get;set;}=true;
 }
 public class Documents {
  App app; public Documents(App value){app=value;} public int Count {get{return State.Fail=="StartupForeign"?1:0;}}
  public Doc Item(int index){return new Doc();}
  public Doc Open(object a=null,object b=null,object c=null,object d=null,object e=null,object f=null,object g=null,object h=null,
                  object i=null,object j=null,object k=null,object l=null,object m=null,object n=null,object o=null,object p=null) {
   if(app.AutomationSecurity!=3 || app.DisplayAlerts!=0 || app.Options.UpdateLinksAtOpen ||
      app.Options.UpdateFieldsAtPrint || app.Options.UpdateLinksAtPrint) throw new Exception("security_order_wrong");
   State.Step("Open");return new Doc();
  }
 }
 public class App {
  int security=1;
  public int AutomationSecurity {get{return security;}set{if(value==3)State.Step("Security");security=value;}}
  public int DisplayAlerts {get;set;}=1;
  public Options Options {get;set;}=new Options();
  public Documents Documents {get;private set;}
  public App(){Documents=new Documents(this);}
 }
}
'@
$work = Join-Path ([IO.Path]::GetTempPath()) ('cover-fake-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
# Inert Open boundary: CLR objects cannot model IDispatch optional Missing marshaling.
# The production Open-CoverSnapshot signature itself is NOT native-tested here.
function Open-CoverSnapshot($Documents, [string]$Snapshot) {
    if ($script:activeApp.AutomationSecurity -ne 3 -or $script:activeApp.DisplayAlerts -ne 0 -or
        $script:activeApp.Options.UpdateLinksAtOpen -or $script:activeApp.Options.UpdateFieldsAtPrint -or
        $script:activeApp.Options.UpdateLinksAtPrint -or $script:activeApp.Options.SaveNormalPrompt -or
        $script:activeApp.Options.ConfirmConversions) {throw 'security_order_wrong'}
    [CoverFake.State]::Step('Open'); return [CoverFake.Doc]::new()
}
function New-FakeApp { $script:activeApp=[CoverFake.App]::new(); return $script:activeApp }
$passed = 0
try {
    foreach ($failure in @('', 'Security','StartupForeign','Open','Find','Save','Export','Close','Mismatch','Shapes','Fields','Stories','Signatures','Missing','Duplicate','Overlap','Restore','Guard')) {
        $script:caseName = $failure
        [CoverFake.State]::Fail = $failure; [CoverFake.State]::Events.Clear()
        [CoverFake.State]::Text = switch ($failure) { 'Missing' {'OTHER' }; 'Duplicate' {'TOKEN TOKEN' }; 'Overlap' {'ABAB'}; default {'TOKEN'} }
        $app = New-FakeApp
        $config = @{snapshot='synthetic.docx'; doc=(Join-Path $work ($failure+'new.docx')); pdf=(Join-Path $work ($failure+'new.pdf')); replace=@{'TOKEN'='VALUE'}; expected_counts=@{'TOKEN'=1}}
        if ($failure -eq 'Overlap') { $config.replace=@{'ABA'='X';'BAB'='Y'};$config.expected_counts=@{'ABA'=1;'BAB'=1} }
        $caught = $null; $actual = $null
        try {
            $actual = Invoke-CoverDocument $app $config {if ($script:caseName -eq 'Guard') {throw 'root_not_live'}} {param($value) return ,$value} {param($phase)}
        } catch { $caught = $_ }
        if ($failure -eq '') {
            if ($caught) {throw $caught}
            if (-not $actual.document_closed -or $actual.replacement_counts[0].observed -ne 1 -or
                [IO.File]::ReadAllText($config.doc) -ne 'VALUE') {throw 'literal_success_unproven'}
        } elseif (-not $caught) {throw "expected failure $failure"}
        if ($failure -eq 'Close' -and @([CoverFake.State]::Events | Where-Object {$_ -eq 'Close'}).Count -ne 1) {throw 'close_error_retried'}
        if ($failure -notin @('Guard','Restore') -and ($app.AutomationSecurity -ne 1 -or -not $app.Options.UpdateLinksAtOpen)) {throw 'options_not_restored'}
        $passed++
    }
    foreach ($token in @('Count','Keys')) {
        [CoverFake.State]::Fail='';[CoverFake.State]::Text=$token
        $app=New-FakeApp
        $config=@{snapshot='synthetic.docx';doc=(Join-Path $work ($token+'doc.docx'));pdf=(Join-Path $work ($token+'doc.pdf'));replace=@{};expected_counts=@{}}
        $config.replace[$token]='VALUE';$config.expected_counts[$token]=1
        $actual=Invoke-CoverDocument $app $config {} {param($v) return ,$v} {param($p)}
        if ($actual.replacement_counts[0].observed -ne 1 -or [IO.File]::ReadAllText($config.doc) -ne 'VALUE') {throw 'dictionary_literal_token_failed'}
        $passed++
    }
    # Explicit passthrough does not invent counts, edit field/text/image contents, or use Find at all.
    [CoverFake.State]::Fail='Find'; [CoverFake.State]::Text='SUPPLIED B/В VALUES'; [CoverFake.State]::Events.Clear()
    $app=New-FakeApp
    $config=@{snapshot='synthetic.docx';doc=(Join-Path $work 'pass.docx');pdf=(Join-Path $work 'pass.pdf');replace=@{};expected_counts=@{}}
    $actual=Invoke-CoverDocument $app $config {} {param($v) return ,$v} {param($p)}
    if ($actual.replacement_counts.Count -ne 0 -or [IO.File]::ReadAllText($config.doc) -ne 'SUPPLIED B/В VALUES') {throw 'passthrough_not_preserved'}
    $passed++
    Write-Output "PASS document pipeline: $passed inert cases; no COM activation"
} finally { [IO.Directory]::Delete($work,$true) }
