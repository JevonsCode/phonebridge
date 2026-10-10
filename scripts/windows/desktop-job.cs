using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace PhoneBridge.Desktop
{
    // The wrapper owns the only non-inheritable job handle. Windows closes it even
    // when Task Scheduler forcibly terminates PowerShell, killing the entire tree.
    public sealed class KillOnCloseJob : IDisposable
    {
        private SafeKernelHandle handle;

        public KillOnCloseJob()
        {
            handle = new SafeKernelHandle(Native.CreateJobObjectW(IntPtr.Zero, null));
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new ExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = 0x00002000; // KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!Native.SetInformationJobObject(handle, 9, buffer, (uint)size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            catch { handle.Dispose(); throw; }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        public ChildProcess StartSupervisor(string nodePath, string entryPoint, string workingDirectory)
        {
            var startup = new StartupInformation();
            startup.Size = (uint)Marshal.SizeOf(typeof(StartupInformation));
            ProcessInformation info;
            var command = new StringBuilder(Quote(nodePath) + " " + Quote(entryPoint) + " --allow-lan --remember-pairing");
            // Suspend before any Node code runs: descendants cannot escape assignment.
            if (!Native.CreateProcessW(nodePath, command, IntPtr.Zero, IntPtr.Zero, false,
                0x08000004, IntPtr.Zero, workingDirectory, ref startup, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot start PhoneBridge Supervisor.");
            var process = new SafeKernelHandle(info.Process);
            var thread = new SafeKernelHandle(info.Thread);
            try
            {
                if (!Native.AssignProcessToJobObject(handle, process))
                    throw new JobAssignmentException(Marshal.GetLastWin32Error());
                if (Native.ResumeThread(thread) == UInt32.MaxValue)
                    throw new JobAssignmentException(Marshal.GetLastWin32Error());
                return new ChildProcess(process, info.ProcessId);
            }
            catch
            {
                Native.TerminateProcess(process, 1);
                Native.WaitForSingleObject(process, 5000);
                process.Dispose();
                throw;
            }
            finally { thread.Dispose(); }
        }

        private static string Quote(string value)
        {
            if (value == null || value.IndexOf('\0') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0)
                throw new ArgumentException("Invalid process path.");
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
                result.Append(c);
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            return result.Append('"').ToString();
        }

        public void Dispose() { handle.Dispose(); }
    }

    public sealed class JobAssignmentException : Win32Exception
    {
        public JobAssignmentException(int error) : base(error, "Cannot safely contain PhoneBridge Supervisor in its Windows job.") { }
    }

    public sealed class ChildProcess : IDisposable
    {
        private SafeKernelHandle handle;
        public uint Id { get; private set; }
        internal ChildProcess(SafeKernelHandle processHandle, uint id) { handle = processHandle; Id = id; }
        public int WaitForExit()
        {
            if (Native.WaitForSingleObject(handle, UInt32.MaxValue) != 0)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint exitCode;
            if (!Native.GetExitCodeProcess(handle, out exitCode))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)exitCode);
        }
        public void Dispose() { handle.Dispose(); }
    }

    internal sealed class SafeKernelHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeKernelHandle(IntPtr value) : base(true) { SetHandle(value); }
        protected override bool ReleaseHandle() { return Native.CloseHandle(handle); }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct StartupInformation
    {
        public uint Size;
        public string Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public ushort ShowWindow, Reserved2Size;
        public IntPtr Reserved2, StandardInput, StandardOutput, StandardError;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessInformation
    {
        public IntPtr Process, Thread;
        public uint ProcessId, ThreadId;
    }
    internal static class Native
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(SafeKernelHandle job, int informationClass, IntPtr information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(SafeKernelHandle job, SafeKernelHandle process);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, IntPtr environment,
            string workingDirectory, ref StartupInformation startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint ResumeThread(SafeKernelHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(SafeKernelHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetExitCodeProcess(SafeKernelHandle process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateProcess(SafeKernelHandle process, uint exitCode);
        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
