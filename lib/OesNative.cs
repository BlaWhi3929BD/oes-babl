using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Oes {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DisplayDevice {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Key;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct Mode {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
        public ushort SpecVersion, DriverVersion, Size, DriverExtra;
        public uint Fields;
        public int X, Y;
        public uint Orientation, FixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string FormName;
        public ushort LogPixels;
        public uint BitsPerPel, Width, Height, Flags, Frequency;
        public uint ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2;
        public uint PanningWidth, PanningHeight;
    }
    public class Display {
        public string Name, Description, Id;
        public bool Active, Primary, IsVdd;
        public Mode Mode;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    public class Window {
        public IntPtr Handle;
        public uint ProcessId;
        public Rect Bounds;
    }
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct MouseInput {
            public int X,Y; public uint Data,Flags,Time; public UIntPtr Extra;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Input { public uint Type; public MouseInput Mouse; }
        [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll", SetLastError=true)] static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, Input[] input, int size);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDevice value, uint flags);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string device, int mode, ref Mode value);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string device, ref Mode value, IntPtr hwnd, uint flags, IntPtr param);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        delegate bool EnumCallback(IntPtr hwnd, IntPtr param);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback callback, IntPtr param);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", EntryPoint="IsWindow")] public static extern bool WindowExists(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect bounds);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
        [DllImport("user32.dll", SetLastError=true)]
        static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

        public static Mode ReadMode(string name, int index) {
            Mode m = new Mode(); m.Size = (ushort)Marshal.SizeOf(typeof(Mode));
            if (!EnumDisplaySettings(name, index, ref m)) throw new InvalidOperationException("Cannot read display mode: " + name);
            return m;
        }
        public static Display[] Displays() {
            var result = new List<Display>();
            for (uint i=0;;i++) {
                DisplayDevice d = new DisplayDevice(); d.cb = Marshal.SizeOf(typeof(DisplayDevice));
                if (!EnumDisplayDevices(null,i,ref d,0)) break;
                if ((d.Flags & 8) != 0) continue;
                // EDID клона может находиться под физическим GPU / identify the adapter, not its cloned monitor.
                bool vdd = IsVddAdapter(d.Id,d.Description);
                bool active=(d.Flags & 1)!=0;
                Mode mode = new Mode();
                if (active) mode=ReadMode(d.Name,-1);
                result.Add(new Display {Name=d.Name, Description=d.Description, Id=d.Id,
                    Active=active, Primary=(d.Flags & 4)!=0, IsVdd=vdd, Mode=mode});
            }
            return result.ToArray();
        }
        public static bool IsVddAdapter(string id,string description) {
            return (id ?? "").IndexOf("mttvdd",StringComparison.OrdinalIgnoreCase)>=0 ||
                String.Equals(description,"Virtual Display Driver",StringComparison.OrdinalIgnoreCase);
        }
        public static Mode FindMode(string name, int width, int height) {
            for (int i=0;;i++) {
                Mode m=new Mode(); m.Size=(ushort)Marshal.SizeOf(typeof(Mode));
                if (!EnumDisplaySettings(name,i,ref m)) break;
                if (m.Width==width && m.Height==height && m.BitsPerPel==32) return m;
            }
            throw new InvalidOperationException("VDD does not advertise " + width + "x" + height +
                ". Add it in VDD settings / vdd_settings.xml, or choose an existing -Size.");
        }
        public static void ApplyMode(string name, Mode mode, bool persist) {
            int result=ChangeDisplaySettingsEx(name,ref mode,IntPtr.Zero,2,IntPtr.Zero); // CDS_TEST
            if (result!=0) throw new InvalidOperationException("Display mode test failed: " + result +
                ". Activate VDD with Extend these displays in Windows Settings and retry.");
            result=ChangeDisplaySettingsEx(name,ref mode,IntPtr.Zero,persist ? 1u : 0u,IntPtr.Zero);
            if (result!=0) throw new InvalidOperationException("Display change failed: " + result +
                (result==1 ? " (restart required)" : ""));
        }
        public static void Detach(string name) {
            Mode m=ReadMode(name,-1);
            m.Fields=0x180020; m.Width=0; m.Height=0;
            int result=ChangeDisplaySettingsEx(name,ref m,IntPtr.Zero,1,IntPtr.Zero);
            if (result!=0) throw new InvalidOperationException("Could not detach VDD: " + result);
        }
        public static Window[] Windows(IntPtr job) {
            var list=new List<Window>();
            EnumCallback callback=delegate(IntPtr hwnd,IntPtr unused) {
                if (!IsWindowVisible(hwnd)) return true;
                uint pid; GetWindowThreadProcessId(hwnd,out pid);
                IntPtr process=OpenProcess(0x1000,false,pid);
                if (process==IntPtr.Zero) return true;
                bool owned;
                try { if (!IsProcessInJob(process,job,out owned) || !owned) return true; }
                finally { CloseHandle(process); }
                var name=new StringBuilder(256); GetClassName(hwnd,name,name.Capacity);
                if (!name.ToString().StartsWith("Chrome_WidgetWin_")) return true;
                Rect bounds; if (!GetWindowRect(hwnd,out bounds)) return true;
                list.Add(new Window {Handle=hwnd, ProcessId=pid, Bounds=bounds});
                return true;
            };
            if (!EnumWindows(callback,IntPtr.Zero)) throw new Win32Exception();
            return list.ToArray();
        }
        public static void Place(IntPtr hwnd, int x, int y, int width, int height) {
            ShowWindow(hwnd,9);
            if (!SetWindowPos(hwnd,IntPtr.Zero,x,y,width,height,0x14) && WindowExists(hwnd)) throw new Win32Exception();
        }
        public static void CloseWindow(IntPtr hwnd) {
            if (!PostMessage(hwnd,0x10,IntPtr.Zero,IntPtr.Zero) && WindowExists(hwnd)) throw new Win32Exception();
        }
        public static void ShowPreview(IntPtr hwnd) {
            // STARTUPINFO can hide the first Form.Show when the PowerShell console is hidden.
            // Повторный ShowWindow показывает именно форму, не консоль.
            ShowWindow(hwnd,5);
            if (!IsWindowVisible(hwnd)) throw new InvalidOperationException("The preview window could not be shown.");
        }
        static Input Mouse(int x,int y,uint flags,uint data) {
            return new Input {Type=0,Mouse=new MouseInput {X=x,Y=y,Flags=flags,Data=data}};
        }
        // Перенаправление только явного ввода в предпросмотре / no polling or input capture.
        public static void PreviewInput(int x,int y,int button,int wheel) {
            Point original;
            if (!GetCursorPos(out original)) throw new Win32Exception();
            int vx=GetSystemMetrics(76),vy=GetSystemMetrics(77),vw=GetSystemMetrics(78),vh=GetSystemMetrics(79);
            if (vw<2 || vh<2) throw new InvalidOperationException("Invalid virtual screen geometry.");
            var events=new List<Input>();
            uint absoluteMove=0xc001; // ABSOLUTE | VIRTUALDESK | MOVE
            events.Add(Mouse((int)((long)(x-vx)*65535/(vw-1)),(int)((long)(y-vy)*65535/(vh-1)),absoluteMove,0));
            if (wheel!=0) events.Add(Mouse(0,0,0x800,unchecked((uint)wheel)));
            else {
                uint down=button==2 ? 8u : (button==3 ? 0x20u : 2u);
                uint up=button==2 ? 0x10u : (button==3 ? 0x40u : 4u);
                events.Add(Mouse(0,0,down,0)); events.Add(Mouse(0,0,up,0));
            }
            events.Add(Mouse((int)((long)(original.X-vx)*65535/(vw-1)),(int)((long)(original.Y-vy)*65535/(vh-1)),absoluteMove,0));
            if (SendInput((uint)events.Count,events.ToArray(),Marshal.SizeOf(typeof(Input)))!=events.Count)
                throw new Win32Exception("Could not forward preview input. Run Chrome and the launcher at the same non-elevated privilege level.");
        }
    }
    // Процессы принадлежат Job, включая фоновые дочерние процессы.
    // Suspended creation prevents races before job assignment; kill-on-close is a backstop.
    public sealed class ChromeJob : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimit {
            public long ProcessTime, JobTime; public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveLimit;
            public UIntPtr Affinity; public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a,b,c,d,e,f; }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimit {
            public BasicLimit Basic; public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        struct Startup {
            public uint Size; public string Reserved, Desktop, Title;
            public uint X,Y,XSize,YSize,XCount,YCount,Fill,Flags;
            public ushort Show, ReservedSize; public IntPtr ReservedPtr, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process,Thread; public uint Pid,Tid; }
        [StructLayout(LayoutKind.Sequential)]
        struct Accounting {
            public long UserTime,KernelTime,UserPeriod,KernelPeriod;
            public uint Faults,Total,Active,Terminated;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetInformationJobObject(IntPtr job,int info,ref ExtendedLimit value,uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool CreateProcess(string app,StringBuilder args,IntPtr pa,IntPtr ta,bool inherit,
            uint flags,IntPtr env,string directory,ref Startup startup,out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool QueryInformationJobObject(IntPtr job,int info,out Accounting value,int size,IntPtr returned);
        public IntPtr Handle {get;private set;}
        public uint ProcessId {get;private set;}
        public ChromeJob(string executable,string arguments) {
            Handle=CreateJobObject(IntPtr.Zero,null);
            if (Handle==IntPtr.Zero) throw new Win32Exception();
            try {
                var limits=new ExtendedLimit(); limits.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE
                if (!SetInformationJobObject(Handle,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimit)))) throw new Win32Exception();
                var startup=new Startup(); startup.Size=(uint)Marshal.SizeOf(typeof(Startup));
                ProcessInfo pi;
                if (!CreateProcess(executable,new StringBuilder("\""+executable+"\" "+arguments),
                    IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,null,ref startup,out pi)) throw new Win32Exception();
                try {
                    if (!AssignProcessToJobObject(Handle,pi.Process) || ResumeThread(pi.Thread)==0xffffffff) {
                        int error=Marshal.GetLastWin32Error();
                        if (!TerminateProcess(pi.Process,1)) throw new Win32Exception();
                        throw new Win32Exception(error);
                    }
                    ProcessId=pi.Pid;
                } finally { Native.CloseHandle(pi.Thread); Native.CloseHandle(pi.Process); }
            } catch { Dispose(); throw; }
        }
        public uint ActiveCount {
            get {
                Accounting a;
                if (!QueryInformationJobObject(Handle,1,out a,Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception();
                return a.Active;
            }
        }
        public void Stop() { if (Handle!=IntPtr.Zero && !TerminateJobObject(Handle,0)) throw new Win32Exception(); }
        public void Dispose() { if (Handle!=IntPtr.Zero) { Native.CloseHandle(Handle); Handle=IntPtr.Zero; } }
    }
    public sealed class Desktops : IDisposable {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true, SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr module,string name);
        [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NoArg();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int OneArg(int n);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int TwoArgs(int n,int fallback);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate Guid GetId(int n);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate Guid GetWindowId(IntPtr hwnd);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetIndex(Guid id);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int MoveWindow(IntPtr hwnd,int n);
        IntPtr module;
        NoArg current,count,create; OneArg go; TwoArgs remove; GetId id; GetIndex index; MoveWindow move; GetWindowId windowId;
        Delegate Bind(string name,Type type) {
            IntPtr address=GetProcAddress(module,name);
            if (address==IntPtr.Zero) throw new InvalidOperationException("VDA is missing export: "+name);
            return Marshal.GetDelegateForFunctionPointer(address,type);
        }
        public Desktops(string path) {
            // Абсолютный путь, безопасный поиск зависимостей / exclude the current directory.
            module=LoadLibraryEx(System.IO.Path.GetFullPath(path),IntPtr.Zero,0x1100);
            if (module==IntPtr.Zero) throw new Win32Exception();
            try {
                current=(NoArg)Bind("GetCurrentDesktopNumber",typeof(NoArg));
                count=(NoArg)Bind("GetDesktopCount",typeof(NoArg));
                create=(NoArg)Bind("CreateDesktop",typeof(NoArg));
                go=(OneArg)Bind("GoToDesktopNumber",typeof(OneArg));
                remove=(TwoArgs)Bind("RemoveDesktop",typeof(TwoArgs));
                id=(GetId)Bind("GetDesktopIdByNumber",typeof(GetId));
                index=(GetIndex)Bind("GetDesktopNumberById",typeof(GetIndex));
                move=(MoveWindow)Bind("MoveWindowToDesktopNumber",typeof(MoveWindow));
                windowId=(GetWindowId)Bind("GetWindowDesktopId",typeof(GetWindowId));
                Check(current()); Check(count());
            } catch { Dispose(); throw; }
        }
        static int Check(int result) {
            if (result<0) throw new InvalidOperationException("VirtualDesktopAccessor rejected the operation. Check Windows build and DLL version.");
            return result;
        }
        public Guid Current() { return Id(Check(current())); }
        public Guid WindowDesktop(IntPtr hwnd) { return windowId(hwnd); }
        public void AttachPreview(IntPtr hwnd,Guid desktop) {
            // Explorer may not have registered the new ApplicationView yet.
            int target=Check(index(desktop));
            for (int i=0;i<40;i++) {
                if (!Native.WindowExists(hwnd)) throw new InvalidOperationException("The preview window closed before desktop assignment.");
                if (windowId(hwnd)==desktop) return;
                move(hwnd,target);
                System.Threading.Thread.Sleep(50);
            }
            if (windowId(hwnd)!=desktop) throw new InvalidOperationException("Could not place the preview on the Chrome session desktop.");
        }
        public Guid Id(int number) {
            Guid value=id(number);
            if (value==Guid.Empty) throw new InvalidOperationException("VDA returned an empty desktop ID.");
            return value;
        }
        public Guid Create() { return Id(Check(create())); }
        public int Index(Guid value) { return index(value); }
        public void Switch(Guid value) {
            Check(go(Check(index(value))));
            for(int i=0;i<40;i++) {
                if (Current()==value) return;
                System.Threading.Thread.Sleep(50);
            }
            throw new InvalidOperationException("Desktop switch timed out.");
        }
        public void Move(IntPtr hwnd,Guid value) {
            int result=move(hwnd,Check(index(value)));
            if (result<0 && Native.WindowExists(hwnd)) Check(result); // Window may close during enumeration.
        }
        public void Remove(Guid owned,Guid original) {
            int n=index(owned);
            if (n<0) return; // Пользователь уже удалил наш рабочий стол.
            int fallback=index(original);
            if (fallback<0) fallback=n==0 ? 1 : 0;
            if (fallback>=Check(count()) || fallback==n) throw new InvalidOperationException("No safe fallback desktop; use Win+Tab to remove the temporary desktop.");
            Guid fallbackId=Id(fallback);
            Switch(fallbackId);
            Check(remove(Check(index(owned)),Check(index(fallbackId))));
            if (index(owned)>=0) throw new InvalidOperationException("Temporary desktop still exists. Remove it with Win+Tab.");
        }
        public void Dispose() { if (module!=IntPtr.Zero) { FreeLibrary(module); module=IntPtr.Zero; } }
    }
}
