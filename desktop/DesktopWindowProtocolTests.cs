// Compile with Launcher.cs and DesktopWindow.cs, /main:DesktopWindowProtocolTests.
// Uses only temporary fixtures and loopback TCP: no installed service, identity or firewall changes.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class DesktopWindowProtocolTests {
    static int checks;
    static readonly string secret = new string('a', 32);
    static void Assert(bool value, string message) { if (!value) throw new Exception(message); checks++; }
    [STAThread] static int Main(string[] args) {
        try {
            if (args.Length != 2) throw new Exception("Provide node.exe path and artifact directory.");
            Directory.CreateDirectory(args[1]);
            ValidateUrls(); TestHttp(); TestChild(args[0], args[1]); TestWindow(args[1]);
            Console.WriteLine("PASS: " + checks + " native protocol/window checks"); return 0;
        } catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }
    static void ValidateUrls() {
        new DashboardSession("http://127.0.0.1:43210/session/" + secret); checks++;
        foreach (string bad in new[] {
            "https://127.0.0.1:43210/session/", "http://localhost:43210/session/", "http://127.0.0.1:65536/session/",
            "http://127.0.0.1:0/session/", "http://127.0.0.1:04321/session/", "http://user@127.0.0.1:43210/session/",
            "http://127.0.0.1:43210/session/%61", "http://evil.example:43210/session/"
        }) { bool denied = false; try { new DashboardSession(bad + secret); } catch (IOException) { denied = true; } Assert(denied, "Unsafe session accepted"); }
        foreach (string suffix in new[] { "/", "?x=1", "#a", "\r\n" }) { bool denied = false; try { new DashboardSession("http://127.0.0.1:43210/session/" + secret + suffix); } catch (IOException) { denied = true; } Assert(denied, "Session suffix accepted"); }
    }
    static void TestHttp() {
        using (var server = new FakeHttp(200, "{\"connected\":false,\"unavailable\":true}")) {
            var session = new DashboardSession(server.Url);
            var task = server.Receive(); var result = session.Request("/network", "192.168.1.22"); task.Wait();
            Assert(server.Headers.Contains("Origin: " + session.Origin), "Origin absent");
            Assert(server.Headers.Contains("X-PhoneBridge-CSRF: " + secret), "CSRF absent");
            Assert(server.Headers.StartsWith("POST /session/" + secret + "/network "), "Wrong POST session path");
            Assert(server.Body == "{\"address\":\"192.168.1.22\"}", "Network body changed");
        }
        using (var server = new FakeHttp(200, "{\"connected\":false,\"error\":\"Saved network unavailable\"}")) {
            var task = server.Receive(); var result = new DashboardSession(server.Url).Request("/status", null); task.Wait();
            Assert(result.ContainsKey("error"), "Startup status error lost");
            Assert(server.Headers.StartsWith("GET /session/" + secret + "/status "), "Wrong GET path");
        }
        using (var server = new FakeHttp(302, "{}")) {
            var task = server.Receive(); bool denied = false;
            try { new DashboardSession(server.Url).Request("/status", null); } catch (IOException) { denied = true; }
            task.Wait(); Assert(denied, "Redirect accepted"); Assert(!server.Pending(), "Redirect followed");
        }
        foreach (string route in new[] { "/start", "/allow-lan" }) {
            using (var server = new FakeHttp(200, "{}", 5500)) {
                var task = server.Receive(); var result = new DashboardSession(server.Url).Request(route, null); task.Wait();
                Assert(result != null, "Long owner/start action timed out at the status deadline");
            }
        }
    }
    static void TestChild(string node, string artifacts) {
        string root = Path.Combine(artifacts, "fake-bundle-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "runtime")); Directory.CreateDirectory(Path.Combine(root, "desktop"));
        File.Copy(node, Path.Combine(root, "runtime", "node.exe"));
        string entry = Path.Combine(root, "desktop", "server.mjs");
        File.WriteAllText(entry, "if(!process.argv.includes('--native-window'))process.exit(7); console.error('x'.repeat(200000)); console.log(JSON.stringify({ready:true,dashboardUrl:'http://127.0.0.1:43210/session/" + secret + "'}));");
        using (var child = new DashboardChild()) {
            DashboardSession result = child.Start(root); Assert(result.Origin == "http://127.0.0.1:43210", "Reused exiting child failed");
        }
        File.WriteAllText(entry, "console.log(JSON.stringify({ready:true,dashboardUrl:'http://evil.example:43210/session/" + secret + "'}));");
        using (var child = new DashboardChild()) { bool denied = false; try { child.Start(root); } catch (IOException) { denied = true; } Assert(denied, "Foreign child URL accepted"); }
        File.WriteAllText(entry, "process.exit(1);");
        using (var child = new DashboardChild()) { bool denied = false; var watch = Stopwatch.StartNew(); try { child.Start(root); } catch (IOException) { denied = true; } Assert(denied && watch.ElapsedMilliseconds < 5000, "Early exit was not reported promptly"); }
        using (var child = new DashboardChild()) { child.Dispose(); bool denied = false; try { child.Start(root); } catch (ObjectDisposedException) { denied = true; } Assert(denied, "Disposed child started"); }
        string pidPath = Path.Combine(root, "child.pid");
        File.WriteAllText(entry, "import {writeFileSync} from 'node:fs'; writeFileSync(new URL('../child.pid',import.meta.url),String(process.pid)); console.log(JSON.stringify({ready:true,dashboardUrl:'http://127.0.0.1:43210/session/" + secret + "'})); setInterval(()=>{},1000);");
        var owned = new DashboardChild(); owned.Start(root); int pid = Int32.Parse(File.ReadAllText(pidPath));
        using (var process = Process.GetProcessById(pid)) { Assert(!process.HasExited, "Fresh dashboard child exited unexpectedly"); owned.Dispose(); Assert(process.WaitForExit(5000), "Owned dashboard child survived close"); }
        // Exercise the actual Launcher headless entry in a separate executable rooted in the fake bundle.
        string launcher = Path.Combine(root, "PhoneBridge.exe");
        string nativeExe = Path.Combine(artifacts, "..", "PhoneBridge-native-test.exe");
        Assert(File.Exists(nativeExe), "Compile PhoneBridge-native-test.exe into the artifact directory first");
        {
            File.Copy(nativeExe, launcher);
            File.WriteAllText(entry, "if(process.argv.includes('--diagnose')){console.error('x'.repeat(200000));console.log(JSON.stringify({test:true}));} else if(process.argv.includes('--self-test'))console.log(JSON.stringify({selfTest:true})); else if(process.argv.includes('--no-open'))console.log(JSON.stringify({ready:true})); else process.exit(9);");
            string report = Path.Combine(root, "diagnostic.json");
            foreach (string flags in new[] { "--diagnose --report-path \"" + report + "\"", "--self-test", "--no-open" }) {
                using (var cli = Process.Start(new ProcessStartInfo(launcher, flags) { UseShellExecute = false, CreateNoWindow = true })) { Assert(cli.WaitForExit(5000) && cli.ExitCode == 0, "Headless CLI failed"); }
            }
            Assert(File.ReadAllText(report).Contains("\"test\":true"), "Diagnostic report was not written");
        }
        // Fixture directory is private test output, retained for reproduction; it contains no real identity.
    }
    static void Pump(int ms) { var watch = Stopwatch.StartNew(); while (watch.ElapsedMilliseconds < ms) { Application.DoEvents(); Thread.Sleep(10); } }
    static T Field<T>(DesktopWindow window, string name) { return (T)typeof(DesktopWindow).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance).GetValue(window); }
    static void Snapshot(DesktopWindow window, string path) { using (var image = new Bitmap(window.Width, window.Height)) { window.DrawToBitmap(image, new Rectangle(0, 0, image.Width, image.Height)); image.Save(path); } }
    static void TestWindow(string artifacts) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        IDataObject previousClipboard = null; try { previousClipboard = Clipboard.GetDataObject(); } catch { }
        try {
        using (var window = new DesktopWindow(Path.Combine(artifacts, "missing-bundle"))) {
            window.Show(); Pump(350);
            Assert(window.Visible && Field<string>(window, "stateKey") == "error" && Field<Label>(window, "detail").Text.Length > 0, "Error window disappeared");
            Assert(Field<Button>(window, "retry").Enabled, "Retry unavailable after startup failure");
            Snapshot(window, Path.Combine(artifacts, "native-startup-error.png"));
            Field<ComboBox>(window, "language").SelectedIndex = 0; Assert(Field<Label>(window, "detail").Text.Contains("Could not start"), "Error language did not switch");
            var data = new JavaScriptSerializer().DeserializeObject("{\"connected\":true,\"unavailable\":false,\"address\":\"192.168.1.22\",\"port\":54321,\"name\":\"Test computer\",\"networks\":[{\"name\":\"Wi-Fi\",\"address\":\"192.168.1.22\"}],\"mcpConfiguration\":\"{\\r\\n  \\\"mcpServers\\\": {}\\r\\n}\",\"qr\":\"\"}") as Dictionary<string, object>;
            data["mcpConfiguration"] = new JavaScriptSerializer().DeserializeObject("{\"mcpServers\":{\"phonebridge\":{\"command\":\"node.exe\",\"args\":[\"C:\\\\fixture\\\\mcp.mjs\"],\"env\":{\"PHONEBRIDGE_TOKEN\":\"fake-test-token\"}}}}");
            using (var image = new Bitmap(32, 32)) using (var graphics = Graphics.FromImage(image)) using (var buffer = new MemoryStream()) { graphics.Clear(Color.DarkOrange); image.Save(buffer, System.Drawing.Imaging.ImageFormat.Png); data["qr"] = "data:image/png;base64," + Convert.ToBase64String(buffer.ToArray()); }
            typeof(DesktopWindow).GetMethod("ApplyStatus", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(window, new object[] { data });
            Assert(Field<ComboBox>(window, "networks").SelectedIndex == 0, "Selected network not rendered");
            Assert(Field<PictureBox>(window, "qr").Image != null, "QR PNG did not decode");
            Assert(Field<TextBox>(window, "configuration").ReadOnly && Field<TextBox>(window, "configuration").Text.Contains("mcpServers"), "Selectable MCP absent");
            Field<Button>(window, "copy").PerformClick(); Assert(Clipboard.GetText().Contains("mcpServers"), "Native clipboard failed");
            var copied = new JavaScriptSerializer().DeserializeObject(Clipboard.GetText()) as Dictionary<string, object>;
            Assert(copied != null && copied.ContainsKey("mcpServers"), "Dictionary MCP configuration was not copied as valid JSON");
            Field<ComboBox>(window, "language").SelectedIndex = 1; Assert(Field<Button>(window, "start").Text == "启动服务", "Chinese switch failed");
            Field<ComboBox>(window, "language").SelectedIndex = 0; Assert(Field<Button>(window, "start").Text == "Start service", "English switch failed");
            Pump(50); Snapshot(window, Path.Combine(artifacts, "native-connected.png"));
            data["error"] = "Saved network unavailable";
            typeof(DesktopWindow).GetMethod("ApplyStatus", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(window, new object[] { data });
            Assert(Field<string>(window, "stateKey") == "error" && Field<Label>(window, "detail").Text == "Saved network unavailable", "Server startup error not rendered");
            window.Close();
        }
        } finally { try { if (previousClipboard != null) Clipboard.SetDataObject(previousClipboard, true); else Clipboard.Clear(); } catch { } }
    }
    sealed class FakeHttp : IDisposable {
        readonly TcpListener listener; readonly int status, delay; readonly string response;
        internal string Headers = "", Body = ""; internal readonly string Url;
        internal FakeHttp(int status, string response, int delay = 0) { this.status = status; this.response = response; this.delay = delay; listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(); Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/session/" + secret; }
        internal Task Receive() { return Task.Factory.StartNew(delegate {
            using (var client = listener.AcceptTcpClient()) using (var stream = client.GetStream()) {
                stream.ReadTimeout = 5000; var bytes = new List<byte>(); int value;
                while ((value = stream.ReadByte()) >= 0) { bytes.Add((byte)value); int count = bytes.Count; if (count >= 4 && bytes[count-4] == 13 && bytes[count-3] == 10 && bytes[count-2] == 13 && bytes[count-1] == 10) break; if (count > 65536) throw new Exception("Headers too large"); }
                Headers = Encoding.ASCII.GetString(bytes.ToArray()); int length = 0;
                foreach (string line in Headers.Split(new[] { "\r\n" }, StringSplitOptions.None)) if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(line.Substring(15).Trim());
                byte[] body = new byte[length]; for (int i = 0; i < length; i++) body[i] = (byte)stream.ReadByte(); Body = Encoding.UTF8.GetString(body);
                if (delay > 0) Thread.Sleep(delay);
                byte[] payload = Encoding.UTF8.GetBytes(response); string head = "HTTP/1.1 " + status + " Test\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + payload.Length + "\r\n" + (status == 302 ? "Location: " + Url + "/outside\r\n" : "") + "\r\n";
                byte[] header = Encoding.ASCII.GetBytes(head); stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length);
            }
        }); }
        internal bool Pending() { return listener.Pending(); }
        public void Dispose() { listener.Stop(); }
    }
}
