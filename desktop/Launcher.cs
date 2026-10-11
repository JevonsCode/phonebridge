using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Launcher {
    [STAThread] static int Main(string[] args) {
        bool headless = Array.IndexOf(args, "--diagnose") >= 0 || Array.IndexOf(args, "--self-test") >= 0 || Array.IndexOf(args, "--no-open") >= 0;
        try {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string report = null; var forward = new List<string>();
            for (int i = 0; i < args.Length; i++) {
                if (args[i] == "--report-path") { if (++i >= args.Length) throw new ArgumentException("Report path required."); report = Path.GetFullPath(args[i]); continue; }
                if (args[i] != "--diagnose" && args[i] != "--self-test" && args[i] != "--no-open") throw new ArgumentException("Unknown argument.");
                forward.Add(args[i]);
            }
            if (report != null && Array.IndexOf(args, "--diagnose") < 0) throw new ArgumentException("Report path requires --diagnose.");
            if (headless) return RunHeadless(root, forward, report);
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new DesktopWindow(root)); return 0;
        } catch (Exception e) {
            if (headless) Console.Error.WriteLine(e.Message);
            else MessageBox.Show(e.Message, "PhoneBridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }
    internal static ProcessStartInfo StartInfo(string root, string arguments) {
        string runtime = Path.Combine(root, "runtime", "node.exe"), entry = Path.Combine(root, "desktop", "server.mjs");
        if (!File.Exists(runtime) || !File.Exists(entry)) throw new IOException("PhoneBridge files are missing. Please reinstall PhoneBridge.");
        return new ProcessStartInfo(runtime, "\"" + entry + "\" " + arguments) {
            WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true
        };
    }
    static int RunHeadless(string root, List<string> forward, string report) {
        bool diagnostic = forward.Contains("--diagnose") || forward.Contains("--self-test");
        var output = new StringBuilder(); var error = new StringBuilder(); var gate = new object();
        using (var first = new ManualResetEvent(false)) using (var process = new Process()) {
            process.StartInfo = StartInfo(root, String.Join(" ", forward.ToArray()));
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data == null) return;
                lock (gate) { if (output.Length + e.Data.Length < 4 * 1024 * 1024) output.AppendLine(e.Data); }
                try { first.Set(); } catch (ObjectDisposedException) { }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                if (e.Data != null) lock (gate) { if (error.Length + e.Data.Length < 65536) error.AppendLine(e.Data); }
            };
            process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
            if (diagnostic) {
                if (!process.WaitForExit(90000)) { KillChild(process); throw new IOException("PhoneBridge diagnostics timed out."); }
                process.WaitForExit();
                string result, failure; lock (gate) { result = output.ToString(); failure = error.ToString(); }
                if (report != null && process.ExitCode == 0) File.WriteAllText(report, result, new UTF8Encoding(false));
                Console.Write(result); Console.Error.Write(failure); return process.ExitCode;
            }
            int waited = 0;
            while (!first.WaitOne(100) && waited < 20000 && !process.HasExited) waited += 100;
            if (!first.WaitOne(0)) { KillChild(process); throw new IOException("PhoneBridge could not start or startup timed out."); }
            // The no-open dashboard intentionally survives this CLI launcher.
            return 0;
        }
    }
    internal static void KillChild(Process process) {
        try { if (process != null && !process.HasExited) process.Kill(); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { }
    }
}
