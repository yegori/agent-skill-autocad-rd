# Execute actual managed exception handler against inert API STUBS, never Autodesk/CAD or real SDK.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$package=Split-Path $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('prepare-failure-'+[guid]::NewGuid().ToString('N'))
$oldRequest,$oldMode=$env:RDCI_PREPARE_REQUEST,$env:RDCI_FAILURE_STUB_MODE
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $stub=@'
using System;
using System.IO;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;
namespace Autodesk.AutoCAD.Runtime {
 public enum CommandFlags { Session }
 public class CommandMethodAttribute : Attribute { public CommandMethodAttribute(string n, CommandFlags f) {} }
}
namespace Autodesk.AutoCAD.DatabaseServices {
 public enum FileOpenMode { OpenForReadAndAllShare }
 public enum OpenMode { ForRead, ForWrite }
 public enum DwgVersion { Current }
 public struct Handle {
  public long Value; public Handle(long v) { Value=v; }
  public override string ToString() { return Value.ToString("X"); }
 }
 public struct ObjectId { public int Value; public Handle Handle { get { return new Handle(Value); } } }
 public class BlockTableRecord {
  public string Name, PathName; public bool IsFromExternalReference=true, IsDependent=false;
 }
 public class BlockTable : IEnumerable<ObjectId> {
  public IEnumerator<ObjectId> GetEnumerator() { for(int i=1;i<=3;i++) yield return new ObjectId { Value=i }; }
  IEnumerator IEnumerable.GetEnumerator() { return GetEnumerator(); }
 }
 public class Transaction : IDisposable {
  public object GetObject(ObjectId id, OpenMode mode) { return id.Value==0 ? (object)new BlockTable() : Database.Rows[id.Value-1]; }
  public void Commit() {} public void Dispose() {}
 }
 public class TransactionManager {
  public Transaction StartTransaction() { return new Transaction(); }
  public Transaction StartOpenCloseTransaction() { return new Transaction(); }
 }
 public class Database : IDisposable {
  public static BlockTableRecord[] Rows;
  public ObjectId BlockTableId { get { return new ObjectId { Value=0 }; } }
  public TransactionManager TransactionManager=new TransactionManager();
  public Database(bool a,bool b) {}
  public void ReadDwgFile(string p,FileOpenMode m,bool b,string s) {
   if(Environment.GetEnvironmentVariable("RDCI_FAILURE_STUB_MODE")=="read") throw new InvalidOperationException("synthetic read failure");
  }
  public void CloseInput(bool b) {}
  public ObjectId GetObjectId(bool b,Handle h,int n) { return new ObjectId { Value=(int)h.Value }; }
  public void SaveAs(string p,DwgVersion v) {
   if(Environment.GetEnvironmentVariable("RDCI_FAILURE_STUB_MODE")=="marker") { File.WriteAllText(p,"INERT stub output"); return; }
   throw new InvalidOperationException("synthetic save-as failure");
  }
  public void Dispose() {}
 }
}
class StubMain {
 static int Main() {
  var json=new JavaScriptSerializer();
  var q=json.Deserialize<RdPrepareXrefCopy.Request>(File.ReadAllText(Environment.GetEnvironmentVariable("RDCI_PREPARE_REQUEST")));
  var rows=new List<Autodesk.AutoCAD.DatabaseServices.BlockTableRecord>();
  foreach(var m in q.mappings) rows.Add(new Autodesk.AutoCAD.DatabaseServices.BlockTableRecord { Name=m.name,PathName=m.old_path });
  Autodesk.AutoCAD.DatabaseServices.Database.Rows=rows.ToArray();
  try { new RdPrepareXrefCopy().Run(); return 99; }
  catch(Exception error) { Console.WriteLine(error.GetType().FullName+": "+error.Message); return 17; }
 }
}
'@
    $stubPath=Join-Path $root 'ApiStubs.cs';[IO.File]::WriteAllText($stubPath,$stub)
    $exe=Join-Path $root 'ManagedFailureStub.exe'
    $csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $code=Join-Path $package 'toolkit/dependencies/PrepareXrefCopy.cs'
    & $csc /nologo /target:exe "/out:$exe" /r:System.Web.Extensions.dll $stubPath $code
    if($LASTEXITCODE -ne 0){throw 'stub_compile_failed_NOT_vendor_ABI'}
    foreach($mode in @('read','save','marker','previous')) {
        $case=Join-Path $root $mode
        New-Item -ItemType Directory -Path "$case/source","$case/issue/dwg/refs","$case/host" | Out-Null
        $source=Join-Path $case 'source/001 Generic.dwg';[IO.File]::WriteAllText($source,'INERT source text')
        $hostFile=Join-Path $case 'host/safe.dwg';[IO.File]::WriteAllText($hostFile,'INERT host text')
        $maps=@(0..2 | ForEach-Object {
            $target=Join-Path $case "issue/dwg/refs/$_.dwg";[IO.File]::WriteAllText($target,"INERT target $_")
            @{handle=[string]($_+1);name="Generic$_";old_path="Z:\old\$_.dwg";new_path=".\refs\$_.dwg";target_sha256=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant()}
        })
        $spec=@{schema_version=1;source_root=(Join-Path $case 'source');source_path='001 Generic.dwg';source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant();issue_root=(Join-Path $case 'issue');output_path='dwg/001 Generic.dwg';mappings=$maps}
        $specFile=Join-Path $case 'spec.json';$spec|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $specFile -Encoding utf8
        $evidence=Join-Path $case 'evidence'
        & python -I (Join-Path $package 'toolkit/prepare_xref_copy.py') preflight $specFile --host $hostFile --host-sha (Get-FileHash -LiteralPath $hostFile).Hash.ToLowerInvariant() --evidence $evidence
        if($LASTEXITCODE -ne 0){throw 'stub_preflight_failed'}
        $env:RDCI_PREPARE_REQUEST=Join-Path $evidence 'request.json';$env:RDCI_FAILURE_STUB_MODE=$mode
        $nativeFailure=Join-Path $evidence 'native.failure.json'
        if($mode -eq 'previous'){[IO.File]::WriteAllText($nativeFailure,'protected earlier evidence')}
        if($mode -eq 'marker'){[IO.File]::WriteAllText((Join-Path $evidence 'native.complete.pending'),'protected marker partial')}
        $console=& $exe
        if($LASTEXITCODE -ne 17){throw 'managed_exception_swallowed'}
        if((Test-Path -LiteralPath "$evidence/native.complete") -or ((Test-Path -LiteralPath "$evidence/native.json") -and $mode -ne 'marker') -or (Test-Path -LiteralPath "$case/issue/dwg/001 Generic.dwg")){throw 'failure_emitted_success'}
        if($mode -eq 'previous') {
            if([IO.File]::ReadAllText($nativeFailure) -ne 'protected earlier evidence' -or $console -notmatch 'AggregateException'){throw 'failure_evidence_overwritten_or_exception_lost'}
        } else {
            $failure=Get-Content -LiteralPath $nativeFailure -Raw|ConvertFrom-Json
            $phase=if($mode -eq 'read'){'read_source'}elseif($mode -eq 'marker'){'write_marker'}else{'save_as'}
            $type=if($mode -eq 'marker'){'System.IO.IOException'}else{'System.InvalidOperationException'}
            if($failure.phase -ne $phase -or $failure.exception_type -ne $type -or -not $failure.message -or $failure.status -ne 'failed'){throw 'managed_failure_fields_lost'}
            if($mode -eq 'marker' -and [IO.File]::ReadAllText((Join-Path $evidence 'native.complete.pending')) -ne 'protected marker partial'){throw 'marker_partial_overwritten'}
        }
        if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -ne $spec.source_sha256){throw 'stub_modified_source'}
        for($i=0;$i -lt 3;$i++){if((Get-FileHash -LiteralPath (Join-Path $case "issue/dwg/refs/$i.dwg")).Hash.ToLowerInvariant() -ne $maps[$i].target_sha256){throw 'stub_modified_target'}}
        "OK: actual managed catch with inert API stubs: $mode; rethrown error=$console"
    }
    'PASS: 4 managed exception/no-overwrite cases; STUB compile only, NOT SDK ABI/native acceptance'
} finally {
    $env:RDCI_PREPARE_REQUEST=$oldRequest;$env:RDCI_FAILURE_STUB_MODE=$oldMode
    Remove-Item -LiteralPath $root -Recurse -Force
}
