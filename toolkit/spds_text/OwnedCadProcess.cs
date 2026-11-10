// One suspended CreateProcess assigned to a private kill-on-close Job BEFORE its first instruction.
// No process enumeration, PID lookup, tree walk, breakaway, shell broker or foreign-process attachment.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace AutocadRd {
 public sealed class OwnedCadProcess : IDisposable {
  IntPtr job = IntPtr.Zero, process = IntPtr.Zero;
  [StructLayout(LayoutKind.Sequential)] struct Limits {
   public long processTime, jobTime; public uint flags;
   public UIntPtr minWorking, maxWorking; public uint activeLimit;
   public UIntPtr affinity; public uint priority, scheduling;
  }
  [StructLayout(LayoutKind.Sequential)] struct Io {
   public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes;
  }
  [StructLayout(LayoutKind.Sequential)] struct Extended {
   public Limits basic; public Io io; public UIntPtr processMemory, jobMemory, peakProcess, peakJob;
  }
  [StructLayout(LayoutKind.Sequential)] struct Accounting {
   public long user, kernel, periodUser, periodKernel;
   public uint faults, total, active, terminated;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
   public uint size; public string reserved, desktop, title;
   public uint x, y, width, height, charsX, charsY, fill, flags;
   public ushort show, reservedSize; public IntPtr reserved2, input, output, error;
  }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
   public IntPtr process, thread; public uint processId, threadId;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
  static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool SetInformationJobObject(IntPtr job, int kind, ref Extended limits, uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting value, uint size, IntPtr returned);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
  static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttrs, IntPtr threadAttrs,
   bool inherit, uint flags, IntPtr env, string cwd, ref Startup startup, out ProcessInfo info);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);

  static void Check(bool ok, string code) {
   if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), code);
  }
  static string Quote(string value) {
   if (value == null || value.IndexOf('\0') >= 0) throw new ArgumentException("invalid_owned_argument");
   var text = new StringBuilder("\""); int slashes = 0;
   foreach (char c in value) {
    if (c == '\\') { slashes++; continue; }
    text.Append('\\', c == '"' ? slashes * 2 + 1 : slashes); text.Append(c); slashes = 0;
   }
   return text.Append('\\', slashes * 2).Append('"').ToString();
  }
  OwnedCadProcess() { }
  public static OwnedCadProcess Start(string executable, string[] arguments) {
   var owner = new OwnedCadProcess(); var info = new ProcessInfo(); bool assigned = false;
   try {
    var command = new StringBuilder(Quote(executable));
    foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
    if (command.Length >= 32767) throw new ArgumentException("owned_command_too_long");
    owner.job = CreateJobObjectW(IntPtr.Zero, null);
    Check(owner.job != IntPtr.Zero, "owned_job_create_failed");
    Check(SetHandleInformation(owner.job, 1, 0), "owned_job_noninherit_failed");
    var limits = new Extended(); limits.basic.flags = 0x2000; // KILL_ON_JOB_CLOSE; no BREAKAWAY.
    Check(SetInformationJobObject(owner.job, 9, ref limits, (uint)Marshal.SizeOf(typeof(Extended))), "owned_job_limits_failed");
    var startup = new Startup(); startup.size = (uint)Marshal.SizeOf(typeof(Startup));
    Check(CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, false, 4, IntPtr.Zero, null,
                         ref startup, out info), "owned_process_create_failed"); // CREATE_SUSPENDED.
    owner.process = info.process;
    Check(AssignProcessToJobObject(owner.job, owner.process), "owned_job_assignment_failed");
    assigned = true;
    Check(ResumeThread(info.thread) != UInt32.MaxValue, "owned_process_resume_failed");
    return owner;
   } catch {
    try {
     // Unassigned child is still suspended; only its original CreateProcess HANDLE may be stopped.
     if (!assigned && owner.process != IntPtr.Zero) {
      Check(TerminateProcess(owner.process, 1), "owned_suspended_cleanup_failed");
      Check(WaitForSingleObject(owner.process, 10000) == 0, "owned_suspended_not_stopped");
     }
    } finally { owner.Dispose(); }
    throw;
   } finally {
    if (info.thread != IntPtr.Zero && !CloseHandle(info.thread)) {
     var error = new Win32Exception(Marshal.GetLastWin32Error(), "owned_thread_close_failed");
     owner.Dispose(); throw error;
    }
   }
  }
  public bool HasExited {
   get {
    uint value = WaitForSingleObject(process, 0);
    if (value == 0) return true;
    if (value == 258) return false;
    throw new Win32Exception(Marshal.GetLastWin32Error(), "owned_process_wait_failed");
   }
  }
  // Read only from the original held handle, before owner termination. Null while alive; keep NTSTATUS bits.
  public uint? ExitCode {
   get {
    if (!HasExited) return null;
    uint code; Check(GetExitCodeProcess(process, out code), "owned_process_exit_code_failed");
    return code;
   }
  }
  public void Wait(int milliseconds) {
   uint value = WaitForSingleObject(process, (uint)milliseconds);
   Check(value == 0 || value == 258, "owned_process_wait_failed");
  }
  uint Active() {
   Accounting value;
   Check(QueryInformationJobObject(job, 1, out value, (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero), "owned_job_query_failed");
   return value.active;
  }
  public bool Stop() {
   if (job == IntPtr.Zero) return false;
   bool terminated = Active() != 0;
   if (terminated) Check(TerminateJobObject(job, 1), "owned_job_stop_failed");
   var clock = Stopwatch.StartNew();
   while (Active() != 0) {
    if (clock.Elapsed.TotalSeconds >= 10) throw new InvalidOperationException("owned_job_cleanup_uncertain");
    Thread.Sleep(20);
   }
   if (process != IntPtr.Zero) Check(WaitForSingleObject(process, 10000) == 0, "owned_process_not_stopped");
   return terminated;
  }
  public void Dispose() {
   try { Stop(); }
   finally {
    try { if (process != IntPtr.Zero) { IntPtr handle = process; process = IntPtr.Zero; Check(CloseHandle(handle), "owned_process_close_failed"); } }
    finally { if (job != IntPtr.Zero) { IntPtr handle = job; job = IntPtr.Zero; Check(CloseHandle(handle), "owned_job_close_failed"); } }
   }
  }
 }
}
