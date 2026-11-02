// Scratch-only PSReadLine acceptance fixture. No terminal transcript is retained.
using System;
using System.ComponentModel;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class HistoryGuardNative
{
    [StructLayout(LayoutKind.Sequential)] struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct StartupInfo
    {
        public int cb; public string reserved, desktop, title;
        public int x, y, width, height, charsX, charsY, fill, flags;
        public short show, reservedLength; public IntPtr reserved2, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx { public StartupInfo startup; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct JobBasicLimit {
        public long processTime, jobTime; public uint flags; public UIntPtr minimumWorkingSet, maximumWorkingSet;
        public uint activeProcesses; public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public JobBasicLimit basic; public IoCounters io; public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr security, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out IntPtr read, out IntPtr write, IntPtr security, uint size);
    [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, uint flags, out IntPtr console);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string application, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfoEx startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool member);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr handle, byte[] bytes, uint length, out uint written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadFile(IntPtr handle, byte[] bytes, uint length, out uint read, IntPtr overlapped);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    static void Check(bool ok, string operation) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), operation); }
    static void Close(ref IntPtr handle) { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
    static void Send(IntPtr input, string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text); uint written;
        Check(WriteFile(input, bytes, (uint)bytes.Length, out written, IntPtr.Zero) && written == bytes.Length, "ConPTY input write");
    }
    static string Literal(string value) { return "'" + value.Replace("'", "''") + "'"; }
    public static IntPtr CreateOwnedJob(string name)
    {
        int size = Marshal.SizeOf(typeof(JobLimits));
        if (size != (IntPtr.Size == 8 ? 144 : 112) || Marshal.OffsetOf(typeof(JobBasicLimit), "flags").ToInt32() != 16) throw new Exception("Unexpected job ABI");
        IntPtr job = CreateJobObjectW(IntPtr.Zero, name); Check(job != IntPtr.Zero, "Create owned job");
        var limits = new JobLimits(); limits.basic.flags = 0x2000; // KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref limits, (uint)size)) { CloseHandle(job); throw new Exception("Configure owned job failed"); }
        return job;
    }
    static void VerifyOwnedJob(IntPtr process, string name)
    {
        // Query-only handle is closed immediately, so it cannot keep the
        // kill-on-close job alive if the controller itself is terminated.
        IntPtr job = OpenJobObjectW(4, false, name); Check(job != IntPtr.Zero, "Open owned job for query");
        try { bool member; Check(IsProcessInJob(process, job, out member) && member, "Exact owned-job membership"); }
        finally { CloseHandle(job); }
    }
    static string MachineModule(string executable)
    {
        string direct = Path.Combine(Path.GetDirectoryName(executable), "Modules", "PSReadLine", "PSReadLine.psd1");
        if (File.Exists(direct)) return direct;
        if (!Path.GetFileName(executable).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase)) throw new Exception("pwsh must have its own machine PSReadLine module");
        // Windows PowerShell's inbox module can live in the machine-wide
        // Program Files module root rather than beside powershell.exe.
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules", "PSReadLine");
        string selected = null; Version newest = new Version(0, 0);
        if (Directory.Exists(root)) foreach (string directory in Directory.GetDirectories(root)) {
            Version version; string manifest = Path.Combine(directory, "PSReadLine.psd1");
            if (Version.TryParse(Path.GetFileName(directory), out version) && version > newest && File.Exists(manifest)) { selected = manifest; newest = version; }
        }
        if (selected == null) throw new Exception("Machine PSReadLine module is unavailable");
        return selected;
    }

    // The caller is an owned-job driver on this same explicit private desktop.
    // The retained process handle and inherited job membership establish ownership.
    public static int Run(string executable, string desktop, string directory, string historyPath, string style, string receipt, string jobName)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(desktop, @"^WinSta0\\history-guard-[a-f0-9]{32}$")) throw new Exception("Explicit fixture private desktop required");
        if (style != "SaveNothing" && style != "SaveIncrementally") throw new Exception("Unsupported history style");
        VerifyOwnedJob(GetCurrentProcess(), jobName);
        IntPtr inputRead = IntPtr.Zero, inputWrite = IntPtr.Zero, outputRead = IntPtr.Zero, outputWrite = IntPtr.Zero;
        IntPtr console = IntPtr.Zero, attributes = IntPtr.Zero, environment = IntPtr.Zero;
        ProcessInfo info = new ProcessInfo(); Thread drain = null; Exception drainError = null;
        var promptReady = new ManualResetEvent(false); var inputLock = new object();
        string marker = "HISTORY_GUARD_READY_" + Guid.NewGuid().ToString("N");
        long outputBytes = 0; int cursorReplies = 0;
        bool initialized = false;
        Exception operationFailure = null;
        try
        {
            Check(CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0), "Input pipe");
            Check(CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0), "Output pipe");
            int hr = CreatePseudoConsole(new Coord { X = 160, Y = 40 }, inputRead, outputWrite, 0, out console);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            Close(ref inputRead); Close(ref outputWrite);
            // Drain continuously, including throughout ClosePseudoConsole. Only a
            // short rolling suffix is inspected for our marker / cursor requests.
            drain = new Thread(() => {
                try {
                    byte[] buffer = new byte[4096]; uint count; string tail = "";
                    while (ReadFile(outputRead, buffer, (uint)buffer.Length, out count, IntPtr.Zero) && count != 0) {
                        Interlocked.Add(ref outputBytes, count);
                        tail += Encoding.UTF8.GetString(buffer, 0, (int)count);
                        if (tail.Contains(marker)) promptReady.Set();
                        int query;
                        while ((query = tail.IndexOf("\x1b[6n", StringComparison.Ordinal)) >= 0) {
                            lock (inputLock) Send(inputWrite, "\x1b[1;1R");
                            Interlocked.Increment(ref cursorReplies);
                            tail = tail.Substring(query + 4);
                        }
                        if (tail.Length > 256) tail = tail.Substring(tail.Length - 256);
                    }
                } catch (Exception error) { drainError = error; promptReady.Set(); }
            });
            drain.IsBackground = true; drain.Start();
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(size);
            Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref size), "Initialize attributes"); initialized = true;
            Check(UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x00020016, console, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero), "Attach ConPTY");
            // Importing PSReadLine does not read its history. The path and saving
            // policy are set and checked before the first interactive read.
            string module = MachineModule(executable);
            string phasePath = Literal(receipt + ".startup.txt");
            string startup = "$ErrorActionPreference='Stop'; try { [IO.File]::WriteAllText(" + phasePath + ", 'entered'); Import-Module " + Literal(module) + " -Global; " +
                "if(" + (Path.GetFileName(executable).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase) ? "$PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1" : "$PSVersionTable.PSVersion.Major -ne 7") + "){exit 93}; " +
                "[IO.File]::WriteAllText(" + Literal(receipt + ".api.txt") + ", (([Microsoft.PowerShell.PSConsoleReadLine].GetMethods() | Where-Object {$_.Name -in @('ReadLine','GetHistoryItems')} | ForEach-Object {$_.ToString()}) -join '; ')); " +
                "Set-PSReadLineOption -HistorySavePath " + Literal(historyPath) + " -HistorySaveStyle " + style + "; " +
                "$o=Get-PSReadLineOption; if($o.HistorySavePath -cne " + Literal(historyPath) + " -or [string]$o.HistorySaveStyle -ne '" + style + "'){exit 91}; " +
                "$global:historyGuardReader=(Get-Command PSConsoleHostReadLine).ScriptBlock; function global:PSConsoleHostReadLine { " +
                "try { $line=& $global:historyGuardReader; [IO.File]::WriteAllText(" + Literal(receipt + ".reader.txt") + ", 'PSReadLine-returned; count=' + [Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems().Count); return $line } " +
                "catch { [IO.File]::WriteAllText(" + Literal(receipt + ".reader.txt") + ", 'reader-error: ' + $_.FullyQualifiedErrorId + '; ' + $_.Exception.GetType().Name); throw } }; " +
                "$mods=@(Get-Module PSReadLine); if($mods.Count -ne 1 -or $mods[0].Path -ine " + Literal(Path.ChangeExtension(module, ".psm1")) + "){exit 93}; " +
                "if(-not [Microsoft.PowerShell.PSConsoleReadLine].Assembly.Location.StartsWith(" + Literal(Path.GetDirectoryName(module) + Path.DirectorySeparatorChar) + ", [StringComparison]::OrdinalIgnoreCase)){exit 93}; " +
                "[IO.File]::WriteAllText(" + phasePath + ", 'configured; PowerShell=' + $PSVersionTable.PSVersion + '; PSReadLine=' + [Microsoft.PowerShell.PSConsoleReadLine].Assembly.GetName().Version + '; module=' + $mods[0].Path + '; inputRedirected=' + [Console]::IsInputRedirected + '; outputRedirected=' + [Console]::IsOutputRedirected); function global:prompt { '" + marker + "> ' } " +
                "} catch { [IO.File]::WriteAllText(" + phasePath + ", 'startup-error: ' + $_.FullyQualifiedErrorId + '; ' + $_.Exception.GetType().Name); exit 92 }";
            string command = "\"" + executable + "\" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(startup));
            var si = new StartupInfoEx(); si.startup.cb = Marshal.SizeOf(typeof(StartupInfoEx)); si.startup.desktop = desktop; si.attributes = attributes;
            // Explicit null standard handles let ConPTY initialize console
            // handles instead of inheriting the driver's NUL/log redirection.
            si.startup.flags = 0x100; // STARTF_USESTDHANDLES
            // A pwsh driver otherwise hands Windows PowerShell its PS7 module
            // folders. That can load a newer DLL with the inbox 2.0 wrapper.
            // Supply this host's machine module roots. PowerShell may add user
            // roots at startup, so the script also checks module/assembly paths.
            var entries = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) entries[(string)entry.Key] = (string)entry.Value;
            entries["PSModulePath"] = Path.Combine(Path.GetDirectoryName(executable), "Modules") + ";" +
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules");
            var block = new StringBuilder();
            foreach (var entry in entries) block.Append(entry.Key).Append('=').Append(entry.Value).Append('\0');
            block.Append('\0'); environment = Marshal.StringToHGlobalUni(block.ToString());
            Check(CreateProcessW(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                0x00080000 | 0x00004000 | 0x00000004 | 0x00000400, environment, directory, ref si, out info), "Create hidden PSReadLine shell");
            VerifyOwnedJob(info.process, jobName);
            Check(ResumeThread(info.thread) != UInt32.MaxValue, "Resume shell");
            var promptTimer = Stopwatch.StartNew(); bool ready = false;
            while (!(ready = promptReady.WaitOne(50)) && promptTimer.ElapsedMilliseconds < 20000 && WaitForSingleObject(info.process, 0) == 258) { }
            if (!ready || drainError != null) {
                uint exitCode; Check(GetExitCodeProcess(info.process, out exitCode), "Read early shell exit");
                File.WriteAllText(receipt + ".native.txt", "outputBytes=" + Interlocked.Read(ref outputBytes) + "; cursorReplies=" + cursorReplies + "; exitCode=" + exitCode);
                throw new Exception("PSReadLine prompt not ready (transcript discarded)");
            }
            // An actual submitted line: its execution creates the receipt. No
            // simulated history write and no SendInput/foreground interaction.
            string submittedLine = "[IO.File]::WriteAllText(" + Literal(receipt) + ", 'interactive-command-executed')";
            lock (inputLock) Send(inputWrite, submittedLine + "\r");
            var timer = Stopwatch.StartNew();
            while (!File.Exists(receipt) && timer.ElapsedMilliseconds < 15000) Thread.Sleep(20);
            if (!File.Exists(receipt)) throw new Exception("Interactive command did not execute (transcript discarded)");
            if (!File.Exists(receipt + ".reader.txt") || !File.ReadAllText(receipt + ".reader.txt").StartsWith("PSReadLine-returned;", StringComparison.Ordinal)) throw new Exception("Host bypassed PSReadLine or its reader failed");
            lock (inputLock) Send(inputWrite, "exit\r");
            if (WaitForSingleObject(info.process, 10000) != 0) throw new Exception("Interactive shell exit timed out");
            uint code; Check(GetExitCodeProcess(info.process, out code) && code == 0, "Interactive shell exit");
            // Only the explicitly owned scratch history is read for this
            // attribution check. Real histories are metadata-only elsewhere.
            if (style == "SaveIncrementally" && !File.ReadAllText(historyPath).Contains(submittedLine)) throw new Exception("Scratch history lacks the submitted interactive command");
            return info.pid;
        }
        catch (Exception error) { operationFailure = error; throw; }
        finally
        {
            var cleanupErrors = new List<Exception>();
            try {
                if (info.process != IntPtr.Zero && WaitForSingleObject(info.process, 0) == 258) {
                    VerifyOwnedJob(info.process, jobName);
                    Check(TerminateProcess(info.process, 1), "Terminate owned shell");
                    Check(WaitForSingleObject(info.process, 5000) == 0, "Wait owned shell");
                }
            } catch (Exception error) { cleanupErrors.Add(error); }
            Close(ref info.thread); Close(ref info.process);
            try { if (console != IntPtr.Zero) ClosePseudoConsole(console); }
            catch (Exception error) { cleanupErrors.Add(error); }
            Close(ref inputRead); Close(ref outputWrite);
            bool joined = drain == null || drain.Join(5000);
            if (!joined) cleanupErrors.Add(new Exception("ConPTY drain did not stop"));
            Close(ref inputWrite); Close(ref outputRead);
            if (initialized) DeleteProcThreadAttributeList(attributes);
            if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
            if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            if (joined) promptReady.Dispose();
            if (cleanupErrors.Count != 0) {
                if (operationFailure != null) cleanupErrors.Insert(0, operationFailure);
                throw new AggregateException("ConPTY fixture cleanup failed", cleanupErrors);
            }
        }
    }
}
