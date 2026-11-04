# Tests use generated dummy assemblies only, never the real MultiCAD DLLs.
param([string]$ResolverPath = (Join-Path $PSScriptRoot '../toolkit/spds_text/SpdsDependencies.cs'))
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$work = Join-Path ([IO.Path]::GetTempPath()) ('spds-resolver-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work, (Join-Path $work 'fake'), (Join-Path $work 'empty') | Out-Null
try {
    $fake = Join-Path $work 'Fake.cs'
    [IO.File]::WriteAllText($fake, '[assembly: System.Reflection.AssemblyVersion("1.2.3.4")] public class Dummy {}')
    & $csc /nologo /target:library /out:"$work/fake/mapimgd.dll" $fake
    if ($LASTEXITCODE -ne 0) { throw 'Dummy assembly compilation failed' }
    & $csc /nologo /target:library /out:"$work/fake/mapibasetypes.dll" $fake
    if ($LASTEXITCODE -ne 0) { throw 'Dummy base assembly compilation failed' }
    $harness = @'
using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
using SpdsText;
class Harness {
 static int Main(string[] args) {
  string mode=args[0], root=args[1];
  var events=new List<string>();
  try {
   if (mode=="before-install") {
    try { SpdsDependencies.Preload(); return 1; }
    catch (InvalidOperationException) { return 0; }
   }
   if (mode=="relative") {
    try { SpdsDependencies.Install(".",events.Add); return 1; }
    catch (ArgumentException) { return 0; }
   }
   if (mode=="reinstall") SpdsDependencies.Install(Path.Combine(root,"empty"),events.Add);
   SpdsDependencies.Install(Path.Combine(root,(mode=="missing" || mode=="preload-missing")?"empty":"fake"),events.Add);
   foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
    if (a.GetName().Name=="mapimgd") throw new Exception("Unexpected eager load");
   if (mode=="preload-missing") {
    try { SpdsDependencies.Preload(); return 1; }
    catch (FileNotFoundException) { return 0; }
   }
   if (mode=="preload") {
    SpdsDependencies.Preload();
    var loadedEvents=events.FindAll(s=>s.StartsWith("DEPENDENCY|"));
    bool ordered=loadedEvents.Count==2 && loadedEvents[0].ToLowerInvariant().Contains("mapibasetypes,") && loadedEvents[1].Contains("mapimgd,");
    if (!ordered) Console.Error.WriteLine(string.Join(Environment.NewLine,events.ToArray()));
    return ordered ? 0 : 1;
   }
   string name=mode=="unknown"?"not_allowed":"mapimgd";
   string version=mode=="version"?"9.0.0.0":"1.2.3.4";
   string culture=mode=="culture"?"fr":"neutral";
   string token=mode=="token"?"0102030405060708":"null";
   bool expect=mode=="valid" || mode=="reinstall";
   try {
    Assembly a=Assembly.Load(name+", Version="+version+", Culture="+culture+", PublicKeyToken="+token);
    if (!expect || a.GetName().Version.ToString()!="1.2.3.4") return 1;
   } catch (FileNotFoundException) { if (expect) throw; }
     catch (FileLoadException) { if (expect) throw; }
   int loaded=events.FindAll(s=>s.StartsWith("DEPENDENCY|")).Count;
   int errors=events.FindAll(s=>s.StartsWith("DEPENDENCY_ERROR|")).Count;
   if (expect && loaded!=1) return 1;
   if (!expect && loaded!=0) return 1;
   if (mode=="unknown" && errors!=0) return 1;
   if (!expect && mode!="unknown" && errors==0) return 1;
   return 0;
  } catch (Exception e) { Console.Error.WriteLine(e); return 1; }
 }
}
'@
    $source = Join-Path $work 'Harness.cs'
    [IO.File]::WriteAllText($source, $harness)
    $exe = Join-Path $work 'Harness.exe'
    & $csc /nologo /target:exe /out:$exe $ResolverPath $source
    if ($LASTEXITCODE -ne 0) { throw 'Resolver harness compilation failed' }
    foreach ($mode in 'valid','version','culture','token','missing','unknown','reinstall','relative','preload','preload-missing','before-install') {
        & $exe $mode $work
        if ($LASTEXITCODE -ne 0) { throw "Resolver test failed: $mode" }
        "OK: $mode"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
