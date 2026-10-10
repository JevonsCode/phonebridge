using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Launcher {
    [STAThread] static int Main(string[] args) {
        try {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string runtime = Path.Combine(root, "runtime", "node.exe");
            string entry = Path.Combine(root, "desktop", "server.mjs");
            if (!File.Exists(runtime) || !File.Exists(entry)) throw new IOException("PhoneBridge files are missing. Please reinstall PhoneBridge.");
            string report = null; var forward = new System.Collections.Generic.List<string>();
            for (int i=0;i<args.Length;i++) { if (args[i] == "--report-path") { if (++i >= args.Length) throw new ArgumentException("Report path required."); report = Path.GetFullPath(args[i]); continue; } if (args[i] != "--diagnose" && args[i] != "--self-test" && args[i] != "--no-open") throw new ArgumentException("Unknown argument."); forward.Add(args[i]); }
            if (report != null && Array.IndexOf(args,"--diagnose") < 0) throw new ArgumentException("Report path requires --diagnose.");
            var info = new ProcessStartInfo(runtime, "\"" + entry + "\" " + String.Join(" ", forward.ToArray()));
            info.WorkingDirectory = root; info.UseShellExecute = false; info.CreateNoWindow = true;
            bool diagnostic = Array.IndexOf(args, "--diagnose") >= 0 || Array.IndexOf(args, "--self-test") >= 0;
            info.RedirectStandardError = true; info.RedirectStandardOutput = true;
            var process = Process.Start(info);
            string first = process.StandardOutput.ReadLine();
            if (diagnostic) { string output = first + Environment.NewLine + process.StandardOutput.ReadToEnd(); string error = process.StandardError.ReadToEnd(); process.WaitForExit(); if (report != null && process.ExitCode == 0) File.WriteAllText(report, output, new System.Text.UTF8Encoding(false)); Console.Write(output); Console.Error.Write(error); return process.ExitCode; }
            if (first == null) { string error = process.StandardError.ReadToEnd(); process.WaitForExit(); throw new IOException(String.IsNullOrWhiteSpace(error) ? "PhoneBridge could not start." : error.Trim()); }
            process.Dispose(); return 0;
        } catch (Exception e) { if (Array.IndexOf(args, "--diagnose") >= 0 || Array.IndexOf(args, "--self-test") >= 0 || Array.IndexOf(args, "--no-open") >= 0) Console.Error.WriteLine(e.Message); else MessageBox.Show(e.Message, "PhoneBridge", MessageBoxButtons.OK, MessageBoxIcon.Warning); return 1; }
    }
}
