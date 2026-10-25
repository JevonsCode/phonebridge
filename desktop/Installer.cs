using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;
using System.Web.Script.Serialization;

internal static class Installer {
    const string Version = "__VERSION__";
    static bool DirectoryEntry(string name) { return name.Replace('\\','/').EndsWith("/", StringComparison.Ordinal); }
    static string EntryName(string name) {
        if (String.IsNullOrEmpty(name)) throw new IOException("Invalid package path.");
        string normalized = name.Replace('\\','/');
        if (normalized.StartsWith("/") || normalized.IndexOf(':') >= 0) throw new IOException("Invalid package path.");
        if (normalized.EndsWith("/", StringComparison.Ordinal)) normalized = normalized.Substring(0, normalized.Length - 1);
        foreach (string part in normalized.Split('/')) {
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal) || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) throw new IOException("Invalid package path.");
            string stem = part.Split('.')[0].ToUpperInvariant();
            if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && stem[3] >= '1' && stem[3] <= '9')) throw new IOException("Invalid package path.");
        }
        return normalized;
    }
    static string Contained(string root, string name) {
        string path = Path.GetFullPath(Path.Combine(root, EntryName(name).Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("Package path escapes installation.");
        return path;
    }
    static void Validate(ZipArchive zip, string root) {
        bool launcher = false, node = false, entry = false; long total = 0;
        var names = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var directories = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        ZipArchiveEntry manifest = null;
        foreach (ZipArchiveEntry e in zip.Entries) {
            string name = EntryName(e.FullName); bool directory = DirectoryEntry(e.FullName);
            Contained(root, name);
            if (!names.Add(name)) throw new IOException("Duplicate package path.");
            if (!directory && directories.Contains(name)) throw new IOException("Conflicting package path.");
            if (directory) directories.Add(name); else files.Add(name);
            for (int slash = name.IndexOf('/'); slash >= 0; slash = name.IndexOf('/', slash + 1)) {
                string parent = name.Substring(0, slash);
                if (files.Contains(parent)) throw new IOException("Conflicting package path.");
                directories.Add(parent);
            }
            total = checked(total + e.Length); if (total > 600L * 1024 * 1024) throw new IOException("Package too large.");
            if (directory) continue;
            launcher |= String.Equals(name, "PhoneBridge.exe", StringComparison.OrdinalIgnoreCase);
            node |= String.Equals(name, "runtime/node.exe", StringComparison.OrdinalIgnoreCase);
            entry |= String.Equals(name, "desktop/server.mjs", StringComparison.OrdinalIgnoreCase);
            if (String.Equals(name, "package-manifest.json", StringComparison.OrdinalIgnoreCase)) manifest = e;
        }
        if (!launcher || !node || !entry) throw new IOException("Incomplete PhoneBridge package.");
        if (manifest == null) throw new IOException("Package identity missing.");
        using (var reader = new StreamReader(manifest.Open())) { var metadata = new JavaScriptSerializer().Deserialize<System.Collections.Generic.Dictionary<string,object>>(reader.ReadToEnd()); if ((string)metadata["product"] != "PhoneBridge" || (string)metadata["version"] != Version || (string)metadata["platform"] != "windows-x64") throw new IOException("Package identity mismatch."); }
    }
    [STAThread] static int Main(string[] args) {
        bool dry = Array.IndexOf(args, "--diagnose") >= 0 || Array.IndexOf(args, "--self-test") >= 0;
        try {
            string report = null;
            for (int i=0;i<args.Length;i++) { if (args[i] == "--report-path") { if (++i >= args.Length) throw new ArgumentException("Report path required."); report=Path.GetFullPath(args[i]); continue; } if (args[i] != "--diagnose" && args[i] != "--self-test" && args[i] != "--silent" && args[i] != "--no-launch") throw new ArgumentException("Unknown argument."); }
            if (report != null && Array.IndexOf(args,"--diagnose") < 0) throw new ArgumentException("Report path requires --diagnose.");
            // User-profile storage stays visible to unpackaged Task Scheduler when an Agent runs inside MSIX.
            string parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".phonebridge", "app", "versions");
            string destination;
            using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("PhoneBridgePackage")) {
                if (payload == null) throw new IOException("Installer package missing.");
                string bundleId;
                using (var hash = System.Security.Cryptography.SHA256.Create()) bundleId = BitConverter.ToString(hash.ComputeHash(payload)).Replace("-","").ToLowerInvariant().Substring(0,12);
                payload.Position = 0;
                destination = Path.Combine(parent,Version,"bundle-" + bundleId);
                using (var zip = new ZipArchive(payload, ZipArchiveMode.Read)) {
                    Validate(zip, destination);
                    if (dry) { bool rejected = false; try { Contained(destination, "../escape.txt"); } catch (IOException) { rejected = true; } if (!rejected) throw new IOException("Containment self-test failed."); string result = new JavaScriptSerializer().Serialize(new { product="PhoneBridge",version=Version,platform="windows-x64",dryRun=true,embeddedPackageValid=true,pathContainmentPassed=true }); if (report != null) File.WriteAllText(report,result,new System.Text.UTF8Encoding(false)); Console.WriteLine(result); return 0; }
                    Directory.CreateDirectory(parent);
                    if (!Directory.Exists(destination)) {
                        string staging = destination + ".staging-" + Guid.NewGuid().ToString("N");
                        Directory.CreateDirectory(staging);
                        try { foreach (ZipArchiveEntry e in zip.Entries) { string path = Contained(staging, e.FullName); if (DirectoryEntry(e.FullName)) { Directory.CreateDirectory(path); continue; } Directory.CreateDirectory(Path.GetDirectoryName(path)); using (Stream from = e.Open()) using (Stream to = new FileStream(path, FileMode.CreateNew)) from.CopyTo(to); } Directory.Move(staging, destination); }
                        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
                    }
                }
            }
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            var setup = new ProcessStartInfo(ps, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(destination, "desktop", "setup.ps1") + "\" -PackageRoot \"" + destination + "\"");
            setup.UseShellExecute = false; setup.CreateNoWindow = true; setup.RedirectStandardOutput = true; setup.RedirectStandardError = true;
            using (var p = Process.Start(setup)) { string output = p.StandardOutput.ReadToEnd(); string error = p.StandardError.ReadToEnd(); p.WaitForExit(); if (p.ExitCode != 0) throw new IOException(error); }
            if (Array.IndexOf(args, "--no-launch") < 0) Process.Start(Path.Combine(destination, "PhoneBridge.exe"));
            if (Array.IndexOf(args, "--silent") < 0) MessageBox.Show(System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh") ? "PhoneBridge 已安装。可使用 PhoneBridge 快捷方式再次打开。" : "PhoneBridge is installed. Open it again using the PhoneBridge shortcut.", "PhoneBridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        } catch (Exception e) { if (dry || Array.IndexOf(args, "--silent") >= 0) Console.Error.WriteLine(e.Message); else MessageBox.Show(e.Message, "PhoneBridge", MessageBoxButtons.OK, MessageBoxIcon.Warning); return 1; }
    }
}
