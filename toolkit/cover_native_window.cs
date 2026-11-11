// NativeOM access ONLY to a pane of the ORIGINAL directly-created Word root.
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace AutocadRd {
 public static class CoverWindow {
  delegate bool EnumProc(IntPtr hwnd, IntPtr context);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr context);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hwnd, EnumProc callback, IntPtr context);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint objectId,
    ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object result);
  public static uint ProcessId(long hwnd) {
   uint pid; if (GetWindowThreadProcessId(new IntPtr(hwnd), out pid) == 0) throw new InvalidOperationException("window_identity_unavailable");
   return pid;
  }
  public static long FindPane(uint originalPid) {
   IntPtr found = IntPtr.Zero;
   EnumProc child = delegate(IntPtr h, IntPtr unused) {
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (pid == originalPid) {
     var text = new StringBuilder(128); GetClassName(h, text, text.Capacity);
     if (text.ToString() == "_WwG") { found = h; return false; }
    }
    return true;
   };
   EnumWindows(delegate(IntPtr h, IntPtr unused) {
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (pid == originalPid) EnumChildWindows(h, child, IntPtr.Zero);
    return found == IntPtr.Zero;
   }, IntPtr.Zero);
   return found.ToInt64();
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
