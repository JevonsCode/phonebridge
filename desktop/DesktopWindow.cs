using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// This capability stays in memory and is never included in diagnostics or exception messages.
internal sealed class DashboardSession {
    internal readonly string Url, Secret, Origin;
    internal DashboardSession(string url) {
        Match match = Regex.Match(url ?? "", @"\Ahttp://127\.0\.0\.1:([1-9][0-9]{0,4})/session/([A-Za-z0-9_-]{32})\z", RegexOptions.CultureInvariant);
        int port;
        if (!match.Success || !Int32.TryParse(match.Groups[1].Value, out port) || port > 65535) throw new IOException("Invalid PhoneBridge dashboard session.");
        Url = url; Secret = match.Groups[2].Value; Origin = "http://127.0.0.1:" + port;
    }
    internal Dictionary<string, object> Request(string route, string address) {
        if (route != "/status" && route != "/start" && route != "/allow-lan" && route != "/network") throw new ArgumentException("Unsupported dashboard action.");
        var request = (HttpWebRequest)WebRequest.Create(Url + route);
        request.Proxy = null; request.AllowAutoRedirect = false;
        // Owner approval and managed task startup take longer than a status read.
        request.Timeout = route == "/allow-lan" ? 90000 : (route == "/start" || route == "/network") ? 30000 : 5000;
        request.ReadWriteTimeout = request.Timeout;
        request.Method = route == "/status" ? "GET" : "POST";
        if (request.Method == "POST") {
            request.Headers["Origin"] = Origin; request.Headers["X-PhoneBridge-CSRF"] = Secret; request.ContentType = "application/json";
            byte[] bytes = Encoding.UTF8.GetBytes(address == null ? "{}" : new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "address", address } }));
            request.ContentLength = bytes.Length;
            using (Stream stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        }
        try {
            using (var response = (HttpWebResponse)request.GetResponse()) {
                if ((int)response.StatusCode >= 300) throw new IOException("PhoneBridge dashboard refused the request.");
                using (Stream stream = response.GetResponseStream()) using (var buffer = new MemoryStream()) {
                    byte[] chunk = new byte[8192]; int count;
                    while ((count = stream.Read(chunk, 0, chunk.Length)) > 0) { if (buffer.Length + count > 2 * 1024 * 1024) throw new IOException("PhoneBridge response is too large."); buffer.Write(chunk, 0, count); }
                    var data = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 }.DeserializeObject(Encoding.UTF8.GetString(buffer.ToArray())) as Dictionary<string, object>;
                    if (data == null) throw new IOException("Invalid PhoneBridge response.");
                    object problem; if (route != "/status" && data.TryGetValue("error", out problem)) throw new IOException("PhoneBridge could not complete this action.");
                    return data;
                }
            }
        } catch (WebException) { throw new IOException("PhoneBridge dashboard is unavailable. Retry or reopen PhoneBridge."); }
    }
}

internal sealed class DashboardChild : IDisposable {
    readonly object gate = new object();
    bool disposed;
    Process process;
    readonly TaskCompletionSource<DashboardSession> ready = new TaskCompletionSource<DashboardSession>();
    int received;
    internal DashboardSession Start(string root) {
        lock (gate) {
        if (disposed) throw new ObjectDisposedException("DashboardChild");
        process = new Process { StartInfo = Launcher.StartInfo(root, "--native-window"), EnableRaisingEvents = true };
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
            if (e.Data == null) { if (Volatile.Read(ref received) == 0) ready.TrySetException(new IOException("PhoneBridge exited before the dashboard was ready.")); return; }
            if (Interlocked.Exchange(ref received, 1) != 0) return;
            try {
                if (e.Data.Length > 8192) throw new IOException("Invalid PhoneBridge startup response.");
                var data = new JavaScriptSerializer().DeserializeObject(e.Data) as Dictionary<string, object>;
                object value, flag;
                if (data == null || !data.TryGetValue("ready", out flag) || !Object.Equals(flag, true) || !data.TryGetValue("dashboardUrl", out value) || !(value is string)) throw new IOException("Invalid PhoneBridge startup response.");
                ready.TrySetResult(new DashboardSession((string)value));
            } catch { ready.TrySetException(new IOException("PhoneBridge could not establish a private dashboard session.")); }
        };
        // Drain stderr without copying child logs that might contain private session data.
        process.ErrorDataReceived += delegate { };
        process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
        }
        // Exit is not an error: a reused dashboard returns its URL and exits normally.
        if (!((IAsyncResult)ready.Task).AsyncWaitHandle.WaitOne(15000)) throw new IOException("PhoneBridge startup timed out. Retry to start again.");
        try { return ready.Task.Result; } catch (AggregateException e) { throw e.InnerException; }
    }
    public void Dispose() { lock (gate) { disposed = true; ready.TrySetException(new ObjectDisposedException("DashboardChild")); if (process != null) { Launcher.KillChild(process); process.Dispose(); process = null; } } }
}

internal sealed class DesktopWindow : Form {
    readonly string root;
    readonly Label state = new Label(), detail = new Label(), networkLabel = new Label(), qrLabel = new Label(), mcpLabel = new Label();
    readonly Button retry = new Button(), start = new Button(), allow = new Button(), browser = new Button(), copy = new Button();
    readonly ComboBox networks = new ComboBox(), language = new ComboBox();
    readonly PictureBox qr = new PictureBox();
    readonly TextBox configuration = new TextBox();
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    DashboardChild child;
    DashboardSession session;
    bool busy, applying, closing, chinese;
    int generation;
    string stateKey = "loading", address = "", errorEnglish = "", errorChinese = "";

    internal DesktopWindow(string root) {
        this.root = root; chinese = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
        Text = "PhoneBridge"; StartPosition = FormStartPosition.CenterScreen; ClientSize = new Size(700, 780); MinimumSize = new Size(610, 660);
        Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(22), ColumnCount = 1, RowCount = 10, AutoScroll = true };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); Controls.Add(layout);
        for (int i = 0; i < 10; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var heading = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        heading.Controls.Add(new Label { Text = "PhoneBridge", AutoSize = true, Font = new Font(Font.FontFamily, 23, FontStyle.Bold), Margin = new Padding(0, 0, 30, 0) });
        language.DropDownStyle = ComboBoxStyle.DropDownList; language.Width = 130; language.Items.AddRange(new object[] { "English", "中文" }); language.SelectedIndex = chinese ? 1 : 0;
        language.SelectedIndexChanged += delegate { chinese = language.SelectedIndex == 1; Translate(); }; heading.Controls.Add(language); layout.Controls.Add(heading);
        state.AutoSize = true; state.Font = new Font(Font.FontFamily, 13, FontStyle.Bold); state.Margin = new Padding(0, 15, 0, 8); layout.Controls.Add(state);
        detail.AutoSize = true; detail.MaximumSize = new Size(630, 0); detail.Margin = new Padding(0, 0, 0, 15); layout.Controls.Add(detail);
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        foreach (Button button in new[] { retry, start, allow, browser }) { button.AutoSize = true; button.Padding = new Padding(8, 3, 8, 3); actions.Controls.Add(button); } layout.Controls.Add(actions);
        retry.Click += delegate { BeginStartup(); }; start.Click += delegate { Action("/start", null); }; allow.Click += delegate { Action("/allow-lan", null); };
        browser.Click += delegate { if (session != null) try { Process.Start(new ProcessStartInfo(session.Url) { UseShellExecute = true }); } catch { state.Text = T("Could not open the browser.", "无法打开浏览器。"); } };
        var networkRow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 12, 0, 8) };
        networkLabel.AutoSize = true; networks.DropDownStyle = ComboBoxStyle.DropDownList; networks.Width = 440;
        networkRow.Controls.Add(networkLabel); networkRow.Controls.Add(networks); layout.Controls.Add(networkRow);
        networks.SelectedIndexChanged += delegate { if (!applying && networks.SelectedItem != null) Action("/network", ((NetworkChoice)networks.SelectedItem).Address); };
        qrLabel.AutoSize = true; layout.Controls.Add(qrLabel);
        qr.Size = new Size(220, 220); qr.SizeMode = PictureBoxSizeMode.Zoom; qr.Margin = new Padding(0, 8, 0, 10); layout.Controls.Add(qr);
        mcpLabel.AutoSize = true; layout.Controls.Add(mcpLabel);
        configuration.Multiline = true; configuration.ReadOnly = true; configuration.ScrollBars = ScrollBars.Both; configuration.WordWrap = false; configuration.Width = 630; configuration.Height = 140; configuration.Anchor = AnchorStyles.Left | AnchorStyles.Right; configuration.Font = new Font("Consolas", 9); layout.Controls.Add(configuration);
        copy.AutoSize = true; copy.Padding = new Padding(8, 3, 8, 3); layout.Controls.Add(copy);
        copy.Click += delegate { try { if (configuration.Text.Length > 0) { Clipboard.SetText(configuration.Text); copy.Text = T("Copied", "已复制"); } } catch { state.Text = T("Clipboard is busy. Try again.", "剪贴板正忙，请重试。"); } };
        timer.Interval = 2500; timer.Tick += delegate { if (!busy && session != null) Action("/status", null); };
        Shown += delegate { BeginStartup(); };
        FormClosing += delegate { closing = true; generation++; timer.Stop(); if (child != null) child.Dispose(); };
        FormClosed += delegate { timer.Dispose(); if (qr.Image != null) qr.Image.Dispose(); };
        Translate(); SetEnabled(false);
    }
    string T(string en, string zh) { return chinese ? zh : en; }
    void Translate() {
        retry.Text = T("Retry", "重试"); start.Text = T("Start service", "启动服务"); allow.Text = T("Allow LAN connection", "允许局域网连接"); browser.Text = T("Browser troubleshooting", "浏览器排查"); copy.Text = T("Copy MCP", "复制 MCP");
        networkLabel.Text = T("Network", "网络"); qrLabel.Text = T("Scan with the PhoneBridge Android app", "使用 PhoneBridge 安卓应用扫描"); mcpLabel.Text = T("MCP configuration", "MCP 配置"); UpdateState();
    }
    void UpdateState() {
        if (stateKey == "loading") { state.Text = T("Starting PhoneBridge…", "正在启动 PhoneBridge…"); detail.Text = T("Opening the local dashboard. This window will stay open.", "正在连接本机面板，请稍候。"); }
        else if (stateKey == "error") { state.Text = T("PhoneBridge needs attention", "PhoneBridge 需要处理"); detail.Text = T(errorEnglish, errorChinese); }
        else { state.Text = stateKey == "connected" ? T("Phone connected", "手机已连接") : stateKey == "unavailable" ? T("Service unavailable", "服务未连接") : T("Waiting for phone", "等待手机连接"); detail.Text = address; }
    }
    void SetEnabled(bool enabled) { start.Enabled = enabled; allow.Enabled = enabled; networks.Enabled = enabled; copy.Enabled = enabled && configuration.Text.Length > 0; browser.Enabled = session != null; retry.Enabled = !busy; }
    void Ui(Action update) { if (closing || IsDisposed) return; try { BeginInvoke(update); } catch (InvalidOperationException) { } }
    void BeginStartup() {
        if (busy) return;
        int current = ++generation; busy = true; session = null; timer.Stop(); if (child != null) child.Dispose();
        child = new DashboardChild(); DashboardChild pending = child; stateKey = "loading"; UpdateState(); SetEnabled(false);
        Task.Factory.StartNew(delegate {
            try { DashboardSession ready = pending.Start(root); var status = ready.Request("/status", null); Ui(delegate { if (current != generation) return; session = ready; busy = false; ApplyStatus(status); timer.Start(); }); }
            catch { pending.Dispose(); Ui(delegate { if (current != generation) return; busy = false; ShowError("Could not start the local dashboard. Check the installation, then Retry.", "无法启动本机面板。请检查安装后重试。"); }); }
        });
    }
    void Action(string route, string selectedAddress) {
        if (busy || session == null) return;
        busy = true; SetEnabled(false); int current = generation; DashboardSession active = session;
        Task.Factory.StartNew(delegate {
            try { var data = active.Request(route, selectedAddress); if (route != "/status") data = active.Request("/status", null); Ui(delegate { if (current != generation) return; busy = false; ApplyStatus(data); }); }
            catch { Ui(delegate { if (current != generation) return; busy = false; timer.Stop(); ShowError("The action could not complete. Retry to reconnect, or use browser troubleshooting for details.", "操作未完成。请重试连接，或使用浏览器排查查看详情。"); }); }
        });
    }
    void ShowError(string en, string zh) { stateKey = "error"; errorEnglish = en; errorChinese = zh; UpdateState(); SetEnabled(false); browser.Enabled = session != null; }
    static string Value(Dictionary<string, object> data, string key) { object value; return data.TryGetValue(key, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : ""; }
    static bool Flag(Dictionary<string, object> data, string key) { object value; return data.TryGetValue(key, out value) && Object.Equals(value, true); }
    static string Configuration(Dictionary<string, object> data) {
        object value; if (!data.TryGetValue("mcpConfiguration", out value) || value == null) return "";
        if (value is string) return (string)value;
        string json = new JavaScriptSerializer().Serialize(value);
        var formatted = new StringBuilder(); int level = 0; bool quoted = false, escaped = false;
        foreach (char c in json) {
            if (quoted) { formatted.Append(c); if (escaped) escaped = false; else if (c == '\\') escaped = true; else if (c == '"') quoted = false; continue; }
            if (c == '"') { quoted = true; formatted.Append(c); }
            else if (c == '{' || c == '[') { formatted.Append(c); formatted.AppendLine(); formatted.Append(' ', ++level * 2); }
            else if (c == '}' || c == ']') { formatted.AppendLine(); formatted.Append(' ', --level * 2); formatted.Append(c); }
            else if (c == ',') { formatted.Append(c); formatted.AppendLine(); formatted.Append(' ', level * 2); }
            else if (c == ':') formatted.Append(": ");
            else formatted.Append(c);
        }
        return formatted.ToString();
    }
    void ApplyStatus(Dictionary<string, object> data) {
        stateKey = Flag(data, "unavailable") ? "unavailable" : Flag(data, "connected") ? "connected" : "waiting";
        address = Value(data, "name") + "  " + Value(data, "address") + (Value(data, "port") == "" ? "" : ":" + Value(data, "port")); UpdateState();
        if (Value(data, "error") != "") { stateKey = "error"; errorEnglish = errorChinese = Value(data, "error"); UpdateState(); }
        configuration.Text = Configuration(data);
        object items; applying = true; networks.BeginUpdate(); networks.Items.Clear();
        if (data.TryGetValue("networks", out items) && items is IEnumerable) foreach (object item in (IEnumerable)items) {
            var network = item as Dictionary<string, object>; if (network == null) continue;
            var choice = new NetworkChoice(Value(network, "name"), Value(network, "address")); networks.Items.Add(choice);
            if (choice.Address == Value(data, "address")) networks.SelectedItem = choice;
        }
        networks.EndUpdate(); applying = false;
        string encoded = Value(data, "qr"); Image next = null;
        try { const string prefix = "data:image/png;base64,"; if (encoded.StartsWith(prefix, StringComparison.Ordinal) && encoded.Length < 1024 * 1024) using (var stream = new MemoryStream(Convert.FromBase64String(encoded.Substring(prefix.Length)))) using (var image = Image.FromStream(stream)) next = new Bitmap(image); } catch { }
        Image old = qr.Image; qr.Image = next; if (old != null) old.Dispose(); SetEnabled(true);
    }
    sealed class NetworkChoice {
        internal readonly string Address; readonly string name;
        internal NetworkChoice(string name, string address) { this.name = name; Address = address; }
        public override string ToString() { return name + " — " + Address; }
    }
}
