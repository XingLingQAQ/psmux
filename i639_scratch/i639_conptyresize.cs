// Issue #639 probe host: conptycap.cs plus ResizePseudoConsole.
//
// The last uncontrolled variable in the #639 investigation was a resize of the
// OUTER terminal (the ssh client window) while wide CJK glyphs are on screen.
// tests/conptycap.cs creates a pseudo console at a fixed size and never
// resizes it, so the psmux client's ratatui buffer never had to be resized
// under a live wide glyph.
//
// This host resizes the pseudo console once, mid capture, and records the byte
// offset at which it did so into the .log as RESIZE_AT_BYTES=<n>. The replay
// can then start at that offset and interpret the tail at the NEW width, which
// is the only way to reconstruct the final screen correctly.
//
// Usage:
//   i639_conptyresize.exe <outFile> <cols> <rows> <flags> <command...>
// Environment:
//   CONPTYCAP_DRAIN_MS    total drain window
//   I639_RESIZE_AFTER_MS  when to resize
//   I639_RESIZE_COLS      new width
//   I639_RESIZE_ROWS      new height
//
// Compile: csc /nologo /optimize /out:i639_conptyresize.exe i639_conptyresize.cs

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

static class ConPtyResize
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hRead, out IntPtr hWrite, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int ResizePseudoConsole(IntPtr hPC, COORD size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, byte[] buf, uint toRead, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetStdHandle(int nStdHandle, IntPtr hHandle);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO { public int cb; public string r1; public string r2; public string r3; public int dx, dy, dxs, dys, dxc, dyc, fa; public int flags; public short showw; public short r4; public IntPtr r5; public IntPtr si, so, se; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    static string _logPath;
    static long _total = 0;

    static void Log(string msg)
    {
        try { File.AppendAllText(_logPath, msg + "\r\n"); } catch { }
    }

    static int EnvInt(string name, int dflt)
    {
        string v = Environment.GetEnvironmentVariable(name);
        int r;
        if (!string.IsNullOrEmpty(v) && int.TryParse(v, out r)) return r;
        return dflt;
    }

    static void Main(string[] args)
    {
        if (args.Length < 5)
        {
            Console.Error.WriteLine("usage: i639_conptyresize.exe <outFile> <cols> <rows> <flags> <command...>");
            Environment.Exit(2);
        }
        _logPath = args[0] + ".log";
        try { File.WriteAllText(_logPath, ""); } catch { }

        string outFile = args[0];
        short cols = short.Parse(args[1]);
        short rows = short.Parse(args[2]);
        uint ptyFlags = uint.Parse(args[3]);
        string cmd = string.Join(" ", args, 4, args.Length - 4);

        int drainMs = EnvInt("CONPTYCAP_DRAIN_MS", 30000);
        int resizeAfterMs = EnvInt("I639_RESIZE_AFTER_MS", 0);
        short newCols = (short)EnvInt("I639_RESIZE_COLS", cols);
        short newRows = (short)EnvInt("I639_RESIZE_ROWS", rows);

        IntPtr inRead, inWrite, outRead, outWrite;
        CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0);
        CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0);

        COORD size; size.X = cols; size.Y = rows;
        IntPtr hPC;
        int hr = CreatePseudoConsole(size, inRead, outWrite, ptyFlags, out hPC);
        Log("CreatePseudoConsole hr=0x" + hr.ToString("X8") + " flags=" + ptyFlags);
        if (hr != 0) Environment.Exit(3);

        IntPtr lpSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
        IntPtr attr = Marshal.AllocHGlobal(lpSize);
        InitializeProcThreadAttributeList(attr, 1, 0, ref lpSize);
        UpdateProcThreadAttribute(attr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);

        SetStdHandle(-10, IntPtr.Zero);
        SetStdHandle(-11, IntPtr.Zero);
        SetStdHandle(-12, IntPtr.Zero);

        var siex = new STARTUPINFOEX();
        siex.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        siex.lpAttributeList = attr;
        PROCESS_INFORMATION pi;
        bool ok = CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref siex, out pi);
        Log("CreateProcess ok=" + ok + " err=" + Marshal.GetLastWin32Error() + " childPid=" + pi.pid);
        if (!ok) Environment.Exit(4);

        var fs = new FileStream(outFile, FileMode.Create, FileAccess.Write);
        var reader = new Thread(() =>
        {
            byte[] buf = new byte[16384];
            while (true)
            {
                uint r;
                if (!ReadFile(outRead, buf, (uint)buf.Length, out r, IntPtr.Zero) || r == 0) break;
                lock (fs)
                {
                    fs.Write(buf, 0, (int)r);
                    fs.Flush();
                    _total += r;
                }
            }
        });
        reader.IsBackground = true;
        reader.Start();

        if (resizeAfterMs > 0)
        {
            Thread.Sleep(resizeAfterMs);
            long at;
            lock (fs) { at = _total; }
            COORD ns; ns.X = newCols; ns.Y = newRows;
            int rhr = ResizePseudoConsole(hPC, ns);
            // Everything the client paints from this offset on is at the NEW
            // size, so the replay must start here to reconstruct the screen.
            Log("RESIZE_AT_BYTES=" + at);
            Log("ResizePseudoConsole hr=0x" + rhr.ToString("X8") + " to " + newCols + "x" + newRows);
            drainMs = Math.Max(0, drainMs - resizeAfterMs);
        }

        WaitForSingleObject(pi.hProcess, (uint)drainMs);
        Thread.Sleep(2000);
        try { lock (fs) { fs.Flush(); fs.Close(); } } catch { }
        Log("CONPTYCAP_DONE bytes=" + _total);
        Environment.Exit(0);
    }
}
