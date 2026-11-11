// Direct original-root lifetime with a watchdog that never calls COM.
// A stalled COM host may remain uncertain; only verified closed-document completion can succeed.
using System;
using System.IO;
using System.Threading;
namespace AutocadRd {
 public sealed class CoverOwner : IDisposable {
  readonly object gate = new object(); OwnedCadProcess root; Timer timer;
  public uint OriginalProcessId { get; private set; }
  public bool TimedOut { get; private set; }
  public bool CleanupVerified { get; private set; }
  public bool RootLiveBeforeStop { get; private set; }
  public uint? RootExitCodeBeforeStop { get; private set; }
  public string CleanupError { get; private set; }
  readonly string audit;
  CoverOwner(string executable, int timeoutSeconds, string auditPath) {
   audit = auditPath;
   // /w requests a separate instance WITH a blank; /a and /q retained. Native behavior unproved.
   root = OwnedCadProcess.Start(executable, new string[] { "/w", "/a", "/q" });
   OriginalProcessId = root.OriginalProcessId;
   timer = new Timer(delegate(object unused) {
    lock(gate) {
     if (root == null) return;
     TimedOut = true;
     try { Stop(); } catch(Exception e) { CleanupError = e.Message; }
     try { File.AppendAllText(audit, "watchdog_timeout cleanup=" + CleanupVerified + " error=" + CleanupError + Environment.NewLine); }
     catch { /* Cannot turn missing timeout evidence into success. */ }
    }
   }, null, checked(timeoutSeconds * 1000), Timeout.Infinite);
  }
  public static CoverOwner Start(string executable, int timeoutSeconds, string audit) {
   if(timeoutSeconds < 1 || timeoutSeconds > 3600) throw new ArgumentException("invalid_cover_timeout");
   return new CoverOwner(executable, timeoutSeconds, audit);
  }
  public void Guard() {
   lock(gate) {
    if(TimedOut || root == null || root.HasExited) throw new InvalidOperationException("cover_root_not_live_or_timeout");
   }
  }
  void Stop() {
   if(root == null) return;
   try {
    RootLiveBeforeStop = !root.HasExited;
    RootExitCodeBeforeStop = RootLiveBeforeStop ? null : root.ExitCode;
    root.Stop(); // held Job, waits for empty family; never PID/name kill.
    CleanupVerified = true;
   } catch(Exception e) { CleanupError = e.Message; throw; }
   finally {
    var held = root; root = null;
    try { held.Dispose(); } catch(Exception e) { CleanupVerified = false; CleanupError = e.Message; throw; }
   }
  }
  public void Complete() {
   lock(gate) {
    Guard();
    Stop();
    if(!RootLiveBeforeStop || TimedOut || !CleanupVerified) throw new InvalidOperationException("cover_cleanup_uncertain");
    if(timer != null) { timer.Dispose(); timer = null; }
   }
  }
  public void Dispose() {
   lock(gate) {
    try { Stop(); }
    finally { if(timer != null) { timer.Dispose(); timer = null; } }
   }
  }
 }
}
