# Fake CAD only; validates orchestration/PDF gates, not Autodesk rendering.
$ErrorActionPreference = 'Stop'
$package = Split-Path $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('plot test ' + [guid]::NewGuid().ToString('N'))
$oldAcad,$oldWork,$oldTemplate,$oldCounter = $env:RDCI_ACAD_DIR,$env:RDCI_WORK,$env:RDCI_FAKE_PDF,$env:RDCI_FAKE_COUNTER
New-Item -ItemType Directory -Path $root,"$root/acad","$root/input" | Out-Null
try {
    $env:RDCI_FAKE_PDF = Join-Path $root 'template.pdf';$env:RDCI_FAKE_COUNTER = Join-Path $root 'starts.txt'
    python -I -c 'import fitz,sys;d=fitz.open();d.new_page();d.save(sys.argv[1]);d.close()' $env:RDCI_FAKE_PDF
    if ($LASTEXITCODE -ne 0) { throw 'pdf_fixture_failed' }
    $source = @'
using System;using System.IO;using System.Text;using System.Text.RegularExpressions;using System.Threading;
class Fake {
 static int Main(string[] args) {
  string dwg=null,scr=null;
  for(int i=0;i+1<args.Length;i++){if(args[i]=="/i")dwg=args[i+1];if(args[i]=="/s")scr=args[i+1];}
  File.AppendAllText(Environment.GetEnvironmentVariable("RDCI_FAKE_COUNTER"),"start\n");
  string mode=File.ReadAllText(dwg),text=File.ReadAllText(scr,Encoding.GetEncoding(1251));
  var output=Regex.Match(text,"\\(plotpdf \\(strcat \\\"([^\\\"]+)/p\\\"");
  if(!output.Success)return 12;string pdf=Path.Combine(output.Groups[1].Value,"p1.pdf");
  if(mode!="missing") {if(mode=="invalid")File.WriteAllText(pdf,"not PDF");else File.Copy(Environment.GetEnvironmentVariable("RDCI_FAKE_PDF"),pdf);}
  var marker=Regex.Match(text,"\\(open \\\"([^\\\"]+)\\\" \\\"w\\\" \\\"utf8\\\"\\)");
  if(marker.Success){File.WriteAllText(marker.Groups[1].Value,"ALLDONE\n");Thread.Sleep(60000);}
  return 17;
 }
}
'@
    $cs = Join-Path $root 'Fake.cs';$exe = Join-Path $root 'acad/accoreconsole.exe';[IO.File]::WriteAllText($cs,$source)
    & (Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe') /nologo /target:exe /out:$exe $cs
    if ($LASTEXITCODE -ne 0) { throw 'fake_plot_build_failed' }
    $env:RDCI_ACAD_DIR = "$root/acad"
    $inputDwg = Join-Path $root 'input/001 test.dwg'
    foreach ($mode in 'valid','missing','invalid','natural') {
        [IO.File]::WriteAllText($inputDwg,$mode);$env:RDCI_WORK = Join-Path $root ($mode+'-work')
        $failed = $false
        try { & "$package/toolkit/plot_set.ps1" -DwgDir "$root/input" -OutDir "$root/$mode-out" -SetPdf "$root/$mode-merged.pdf" -NoPaperCheck -ControlledPlot:($mode -ne 'natural') }
        catch { $failed = $true }
        if (($mode -eq 'valid') -eq $failed) { throw "wrong_plot_outcome_$mode" }
    }
    'OK: controlled valid sheet + separate merge; missing/invalid PDF and natural nonzero exit refuse'
    $count = ([IO.File]::ReadAllLines($env:RDCI_FAKE_COUNTER)).Count
    try { & "$package/toolkit/plot_set.ps1" -DwgDir "$root/input" -OutDir "$root/valid-out" -NoPaperCheck -ControlledPlot; throw 'existing_plot_output_accepted' }
    catch { if ($_.Exception.Message -eq 'existing_plot_output_accepted') { throw } }
    if (([IO.File]::ReadAllLines($env:RDCI_FAKE_COUNTER)).Count -ne $count) { throw 'reused_output_started_cad' }
    'OK: reused output refused before CAD; no old files overwritten'
} finally {
    $env:RDCI_ACAD_DIR=$oldAcad;$env:RDCI_WORK=$oldWork;$env:RDCI_FAKE_PDF=$oldTemplate;$env:RDCI_FAKE_COUNTER=$oldCounter
    Remove-Item -LiteralPath $root -Recurse -Force
}
