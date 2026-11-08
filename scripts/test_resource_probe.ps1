# Generated fake accoreconsole only. Never opens a DWG in Autodesk or changes plot settings.
$ErrorActionPreference = 'Stop'
$package = Split-Path $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('resource test ' + [guid]::NewGuid().ToString('N'))
$oldAcad, $oldWork, $oldCounter = $env:RDCI_ACAD_DIR, $env:RDCI_WORK, $env:RDCI_FAKE_STARTS
New-Item -ItemType Directory -Path $root, "$root/acad", "$root/input", "$root/work" | Out-Null
try {
    $source = @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
class Fake {
 static int Main(string[] args) {
  string dwg=null, scr=null;
  for(int i=0;i+1<args.Length;i++) { if(args[i]=="/i")dwg=args[i+1]; if(args[i]=="/s")scr=args[i+1]; }
  File.AppendAllText(Environment.GetEnvironmentVariable("RDCI_FAKE_STARTS"),"start\n");
  string mode=File.ReadAllText(dwg);
  if(mode=="hang") { Thread.Sleep(60000); return 0; }
  if(mode=="delay") Thread.Sleep(700);
  string text=File.ReadAllText(scr,Encoding.GetEncoding(1251));
  var matches=Regex.Matches(text,"\\(open \\\"([^\\\"]+)\\\" \\\"w\\\" \\\"utf8\\\"\\)");
  if(matches.Count==0)return 19;
  File.WriteAllText(matches[0].Groups[1].Value,"Layout1|ISO_A4|DWG To PDF.pc3\n",new UTF8Encoding(false));
  if(mode=="badexit")return 17;
  if(matches.Count>1) { File.WriteAllText(matches[1].Groups[1].Value,"ALLDONE\n",new UTF8Encoding(false)); Thread.Sleep(60000); }
  Console.WriteLine("fake complete");return 0;
 }
}
'@
    $fakeSource = Join-Path $root 'Fake.cs'; $fakeExe = Join-Path $root 'acad/accoreconsole.exe'
    [IO.File]::WriteAllText($fakeSource, $source)
    & (Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe') /nologo /target:exe /out:$fakeExe $fakeSource
    if ($LASTEXITCODE -ne 0) { throw 'fake_build_failed' }
    $env:RDCI_ACAD_DIR = "$root/acad"; $env:RDCI_WORK = "$root/work"; $env:RDCI_FAKE_STARTS = "$root/starts.txt"
    foreach ($n in 1..3) { [IO.File]::WriteAllText("$root/input/00$n.dwg", 'delay') }
    $files = @(Get-ChildItem "$root/input/*.dwg" | Sort-Object Name | ForEach-Object FullName)
    & "$package/toolkit/check_papers.ps1" -Files @($files[0]) -TimeoutSec 5 | Out-Host
    if ($Global:AccCoreLastRun.Status -ne 'completed' -or $Global:AccCoreLastRun.ExitCode -ne 0) { throw 'natural_exit_metadata_failed' }
    [IO.File]::WriteAllText($env:RDCI_FAKE_STARTS, '')
    'OK: legacy natural-exit API preserves delayed process exit code through original handle'
    & "$package/toolkit/inspect_resources.ps1" -InputRoot "$root/input" -Files $files -ResultFile "$root/probe.json"
    $data = [IO.File]::ReadAllText("$root/probe.json") | ConvertFrom-Json
    if ($data.status -ne 'observed' -or $data.files.Count -ne 3 -or $data.files[0].layout_count -ne 1 -or $data.files[0].layouts[0].paper_status -ne 'standard_unverified' -or $null -ne $data.files[0].exit_code -or -not $data.files[0].controlled_cleanup_verified) { throw 'observations_missing' }
    if (([IO.File]::ReadAllLines($env:RDCI_FAKE_STARTS)).Count -ne 3) { throw 'not_one_start_per_file' }
    'OK: three delayed serial probes, original handles/exit codes, separate raw evidence, SHA/layout/duration metadata'
    $before = [IO.File]::ReadAllText("$root/probe.json")
    try { & "$package/toolkit/inspect_resources.ps1" -InputRoot "$root/input" -Files $files -ResultFile "$root/probe.json"; throw 'existing_output_accepted' }
    catch { if ($_.Exception.Message -eq 'existing_output_accepted') { throw } }
    if ([IO.File]::ReadAllText("$root/probe.json") -ne $before -or ([IO.File]::ReadAllLines($env:RDCI_FAKE_STARTS)).Count -ne 3) { throw 'old_output_or_start_changed' }
    'OK: existing output refused before CAD'
    [IO.File]::WriteAllText($files[0], 'badexit')
    try { & "$package/toolkit/inspect_resources.ps1" -InputRoot "$root/input" -Files $files -ResultFile "$root/bad.json"; throw 'nonzero_exit_accepted' }
    catch { if ($_.Exception.Message -eq 'nonzero_exit_accepted') { throw } }
    $bad = [IO.File]::ReadAllText("$root/bad.json") | ConvertFrom-Json
    if ($bad.status -ne 'failed' -or $bad.files.Count -ne 0 -or ([IO.File]::ReadAllLines($env:RDCI_FAKE_STARTS)).Count -ne 4) { throw 'continued_after_failure' }
    'OK: partial metadata/nonzero exit cannot authorize next CAD'
    [IO.File]::WriteAllText($files[0], 'hang')
    try { & "$package/toolkit/inspect_resources.ps1" -InputRoot "$root/input" -Files $files -ResultFile "$root/timed.json" -PerFileTimeoutSec 1; throw 'timeout_accepted' }
    catch { if ($_.Exception.Message -eq 'timeout_accepted') { throw } }
    $timed = [IO.File]::ReadAllText("$root/timed.json") | ConvertFrom-Json
    if ($timed.status -ne 'failed' -or $timed.files.Count -ne 0 -or ([IO.File]::ReadAllLines($env:RDCI_FAKE_STARTS)).Count -ne 5) { throw 'continued_after_timeout' }
    'OK: timeout waits owned process cleanup and stops batch, not another CAD start'
} finally {
    $env:RDCI_ACAD_DIR = $oldAcad; $env:RDCI_WORK = $oldWork; $env:RDCI_FAKE_STARTS = $oldCounter
    Remove-Item -LiteralPath $root -Recurse -Force
}
