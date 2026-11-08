# Native process tests only: no AutoCAD, source DWG, real MultiCAD DLLs or process-name/PID termination.
param([string]$Helper = (Join-Path $PSScriptRoot '../toolkit/spds_text/owned_acad.ps1'))
$ErrorActionPreference = 'Stop'
. $Helper
$root = Join-Path ([IO.Path]::GetTempPath()) ('owned acad test ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$sentinel = $null
try {
    $source = Join-Path $root 'Fake.cs'
    $exe = Join-Path $root 'Fake.exe'
    [IO.File]::WriteAllText($source, @'
using System;
using System.IO;
using System.Threading;
class Fake {
 static int Main(string[] args) {
  string mode=args[0], log=args[1];
  if (mode=="echo") { File.WriteAllLines(log+".args",args); File.WriteAllText(log,"ALLDONE\n"); return 0; }
  if (mode=="child" || mode=="orphan") {
   var start=new System.Diagnostics.ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location,
     "sentinel \""+log+".child\""); start.UseShellExecute=false;
   var child=System.Diagnostics.Process.Start(start); File.WriteAllText(log+".pid",child.Id.ToString());
   File.WriteAllText(log,"ALLDONE\n"); if (mode=="orphan") return 0;
  }
  if (mode=="done") File.WriteAllText(log,"ALLDONE\n");
  if (mode=="exit") return 17;
  if (mode=="fast") { File.WriteAllText(log,"ALLDONE\n"); return 0; }
  Thread.Sleep(60000); return 0;
 }
}
'@)
    & (Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe') /nologo /target:exe /out:$exe $source
    if ($LASTEXITCODE -ne 0) { throw 'fake_process_build_failed' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe; $start.UseShellExecute = $false
    $start.ArgumentList.Add('sentinel'); $start.ArgumentList.Add((Join-Path $root 'sentinel.log'))
    $sentinel = [Diagnostics.Process]::Start($start)
    $heldSentinel = $sentinel.SafeHandle
    $done = Invoke-OwnedTxtfixProcess -FilePath $exe -Arguments @('done', (Join-Path $root 'done.log')) -Log (Join-Path $root 'done.log') -TimeoutSec 5
    if (-not $done.AllDone -or $done.TimedOut -or -not $done.Terminated) { throw 'all_done_cleanup_failed' }
    'OK: ALLDONE process stopped through private Job; paths with spaces preserved'
    foreach ($mode in 'child','orphan') {
        $log = Join-Path $root ($mode + '.log')
        $family = Invoke-OwnedTxtfixProcess -FilePath $exe -Arguments @($mode, $log) -Log $log -TimeoutSec 5
        if (-not $family.AllDone -or -not $family.Terminated) { throw 'owned_family_cleanup_failed' }
        $childNumber = [int]([IO.File]::ReadAllText($log + '.pid'))
        # Read-only assertion; never terminate a looked-up PID (including a reused one).
        $alive = $null
        try { $alive = [Diagnostics.Process]::GetProcessById($childNumber) } catch [ArgumentException] { }
        if ($alive) { try { if (-not $alive.HasExited) { throw 'owned_child_left_after_cleanup' } } finally { $alive.Dispose() } }
    }
    'OK: ordinary and root-exited descendants stopped; unrelated sentinel stays outside private Job'
    $log = Join-Path $root 'echo.log'
    $vector = @('echo', $log, '', 'a"b', 'x\\" y', 'tail\\', 'Юникод')
    $quoted = Invoke-OwnedTxtfixProcess -FilePath $exe -Arguments $vector -Log $log -TimeoutSec 5
    $actual = [IO.File]::ReadAllLines($log + '.args')
    if (-not $quoted.AllDone -or (Compare-Object $vector $actual -SyncWindow 0)) { throw 'native_argument_quoting_failed' }
    'OK: empty/quoted/backslash/Unicode arguments preserved without shell'
    $timed = Invoke-OwnedTxtfixProcess -FilePath $exe -Arguments @('hang', (Join-Path $root 'hang.log')) -Log (Join-Path $root 'hang.log') -TimeoutSec 1
    if ($timed.AllDone -or -not $timed.TimedOut -or -not $timed.Terminated -or $timed.ElapsedSeconds -gt 12) { throw 'timeout_cleanup_failed' }
    'OK: bounded timeout/cleanup without ALLDONE'
    $exited = Invoke-OwnedTxtfixProcess -FilePath $exe -Arguments @('exit', (Join-Path $root 'exit.log')) -Log (Join-Path $root 'exit.log') -TimeoutSec 5
    if ($exited.AllDone -or $exited.TimedOut -or $exited.Terminated) { throw 'natural_exit_handling_failed' }
    'OK: early natural exit is incomplete, not killed or claimed successful'
    foreach ($n in 1..10) {
        $log = Join-Path $root "fast-$n.log"
        $fast = Invoke-OwnedTxtfixProcess -FilePath $exe -Arguments @('fast', $log) -Log $log -TimeoutSec 5
        if (-not $fast.AllDone -or $fast.TimedOut) { throw 'fast_exit_race_failed' }
    }
    'OK: repeated fast natural-exit/ALLDONE races'
    $failed = $false
    try { Invoke-OwnedTxtfixProcess -FilePath (Join-Path $root 'missing.exe') -Arguments @('none') -Log (Join-Path $root 'missing.log') -TimeoutSec 1 | Out-Null }
    catch { $failed = $true }
    if (-not $failed) { throw 'missing_program_accepted' }
    'OK: launch failure has no fallback'
    if ($sentinel.HasExited -or $heldSentinel.IsClosed) { throw 'foreign_sentinel_affected' }
    $text = [IO.File]::ReadAllText($Helper)
    $caller = [IO.File]::ReadAllText((Join-Path (Split-Path $Helper) 'run_txtfix.ps1'))
    if ($text -match 'GetProcessById|Stop-Process|taskkill' -or $caller -match 'Stop-Process\s+-Id') { throw 'PID_termination_reintroduced' }
    if ($caller -notmatch 'txtfix_incomplete' -or $caller -notmatch 'Invoke-OwnedTxtfixProcess') { throw 'caller_not_fail_closed' }
    'OK: unrelated sentinel survived; source/caller have no PID kill/fallback'
} finally {
    if ($sentinel) {
        try { if (-not $sentinel.HasExited) { $sentinel.Kill() }; if (-not $sentinel.WaitForExit(10000)) { throw 'sentinel_cleanup_failed' } }
        finally { $sentinel.Dispose() }
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
