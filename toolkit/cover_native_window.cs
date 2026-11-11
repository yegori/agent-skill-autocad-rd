// NativeOM ONLY to the ORIGINAL root. No window text/captions/UIA/foreign metadata.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace AutocadRd {
 // Narrow inert-test seam; production always uses NativeWindows, never an injected CLI provider.
 public interface ICoverWindows {
  bool Top(Func<long,bool> callback);
  bool Children(long hwnd, Func<long,bool> callback);
  int Error { get; }
  uint Pid(long hwnd);
  string Class(long hwnd);
  bool Visible(long hwnd);
 }
 public sealed class CoverWindowRecord {
  public long Hwnd; public string Kind, Class; public bool Visible;
 }
 public sealed class CoverWindowSnapshot {
  public uint OriginalPid; public bool Limited; public string Error;
  public string ChildReturnContract = "unused_not_coverage_proof";
  public List<CoverWindowRecord> Windows = new List<CoverWindowRecord>();
 }
 public static class CoverWindow {
  delegate bool EnumProc(IntPtr hwnd, IntPtr context);
  [DllImport("user32.dll", SetLastError=true)] static extern bool EnumWindows(EnumProc callback, IntPtr context);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hwnd, EnumProc callback, IntPtr context);
  [DllImport("user32.dll", SetLastError=true)] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("kernel32.dll")] static extern void SetLastError(uint error);
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint objectId,
    ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object result);
  sealed class NativeWindows : ICoverWindows {
   public int Error { get; private set; }
   public bool Top(Func<long,bool> callback) {
    SetLastError(0);
    bool ok = EnumWindows(delegate(IntPtr h, IntPtr unused) { return callback(h.ToInt64()); }, IntPtr.Zero);
    Error = Marshal.GetLastWin32Error(); return ok;
   }
   public bool Children(long hwnd, Func<long,bool> callback) {
    // Win32 documents this return as unused, NOT a reliable success/last-error contract.
    return EnumChildWindows(new IntPtr(hwnd), delegate(IntPtr h, IntPtr unused) { return callback(h.ToInt64()); }, IntPtr.Zero);
   }
   public uint Pid(long hwnd) {
    uint pid; SetLastError(0);
    if(GetWindowThreadProcessId(new IntPtr(hwnd), out pid) == 0)
     throw new Win32Exception(Marshal.GetLastWin32Error(), "window_identity_unavailable");
    return pid;
   }
   public string Class(long hwnd) {
    var text = new StringBuilder(65); SetLastError(0);
    if(GetClassNameW(new IntPtr(hwnd), text, text.Capacity) == 0)
     throw new Win32Exception(Marshal.GetLastWin32Error(), "owned_window_class_failed");
    return text.ToString();
   }
   public bool Visible(long hwnd) { return IsWindowVisible(new IntPtr(hwnd)); }
  }
  public static uint ProcessId(long hwnd) { return new NativeWindows().Pid(hwnd); }
  public static long FindPane(uint originalPid) { return FindPane(originalPid, new NativeWindows()); }
  public static long FindPane(uint originalPid, ICoverWindows api) {
   long found = 0; Exception failure = null; int visits = 0; var clock = Stopwatch.StartNew();
   Func<long,bool> child = delegate(long h) {
    try {
     if(++visits > 2048 || clock.ElapsedMilliseconds >= 100) throw new InvalidOperationException("owned_window_scan_limited");
     if(api.Pid(h) == originalPid && api.Class(h) == "_WwG") {
      if(api.Pid(h) != originalPid) throw new InvalidOperationException("owned_window_identity_changed");
      found = h; return false;
     }
     return true;
    } catch(Exception e) { failure = e; return false; }
   };
   bool ok = api.Top(delegate(long h) {
    try {
     if(++visits > 2048 || clock.ElapsedMilliseconds >= 100) throw new InvalidOperationException("owned_window_scan_limited");
     if(api.Pid(h) == originalPid) api.Children(h, child); // Return deliberately NOT interpreted.
     return found == 0 && failure == null;
    } catch(Exception e) { failure = e; return false; }
   });
   if(failure != null) throw failure;
   if(!ok && found == 0) throw new Win32Exception(api.Error, "owned_enum_windows_failed");
   return found;
  }
  public static CoverWindowSnapshot Capture(uint originalPid) { return Capture(originalPid, new NativeWindows()); }
  public static CoverWindowSnapshot Capture(uint originalPid, ICoverWindows api) {
   var snapshot = new CoverWindowSnapshot(); snapshot.OriginalPid = originalPid;
   var clock = Stopwatch.StartNew(); int visits = 0; Exception failure = null;
   Func<long,string,bool> record = delegate(long h, string kind) {
    if(++visits > 512 || snapshot.Windows.Count >= 16 || clock.ElapsedMilliseconds >= 250) {
     snapshot.Limited = true; return false;
    }
    if(api.Pid(h) != originalPid) return true;
    string name = api.Class(h); if(name.Length > 64) name = name.Substring(0,64);
    bool visible = api.Visible(h);
    if(api.Pid(h) != originalPid) throw new InvalidOperationException("owned_window_identity_changed");
    snapshot.Windows.Add(new CoverWindowRecord { Hwnd=h, Kind=kind, Class=name, Visible=visible });
    return true;
   };
   try {
    bool ok = api.Top(delegate(long h) {
     try {
      if(!record(h,"top")) return false;
      if(api.Pid(h) == originalPid) api.Children(h, delegate(long c) {
       try { return record(c,"child"); } catch(Exception e) { failure=e; return false; }
      });
      return !snapshot.Limited && failure == null;
     } catch(Exception e) { failure=e; return false; }
    });
    if(failure != null) throw failure;
    if(!ok && !snapshot.Limited) throw new Win32Exception(api.Error,"owned_enum_windows_failed");
   } catch(Exception e) {
    var win32 = e as Win32Exception;
    snapshot.Error = win32 == null ? "capture_failed" : "win32_error_" + win32.NativeErrorCode;
   }
   return snapshot;
  }
  public static object Bind(long hwnd, uint originalPid) {
   if (ProcessId(hwnd) != originalPid) throw new InvalidOperationException("pane_foreign_pid");
   Guid dispatch = new Guid("00020400-0000-0000-C000-000000000046"); object result;
   int hr = AccessibleObjectFromWindow(new IntPtr(hwnd), 0xFFFFFFF0, ref dispatch, out result);
   if (hr < 0 || result == null) Marshal.ThrowExceptionForHR(hr < 0 ? hr : unchecked((int)0x80004005));
   return result;
  }
 }
}
