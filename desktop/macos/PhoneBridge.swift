import AppKit
import Foundation
import Darwin

// The dashboard capability stays in memory. Never print it or child output in GUI mode.
struct DashboardSession {
    let url: URL
    let origin: String
    let secret: String

    init(_ raw: String) throws {
        guard let parts = URLComponents(string: raw), parts.scheme == "http",
              parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.count == 41,
              parts.path.range(of: "^/session/[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil,
              raw == "http://127.0.0.1:\(port)\(parts.path)", let url = parts.url else {
            throw ClientError.invalidSession
        }
        self.url = url
        self.origin = "http://127.0.0.1:\(port)"
        self.secret = String(parts.path.dropFirst("/session/".count))
    }
}

enum ClientError: Error { case invalidSession, missingRuntime }

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

func bundledProcess(arguments: [String]) throws -> Process {
    guard let resources = Bundle.main.resourceURL else { throw ClientError.missingRuntime }
    let runtime = resources.appendingPathComponent("runtime/node")
    let script = resources.appendingPathComponent("desktop/macos/server.mjs")
    guard FileManager.default.isExecutableFile(atPath: runtime.path),
          FileManager.default.fileExists(atPath: script.path) else { throw ClientError.missingRuntime }
    let process = Process()
    process.executableURL = runtime
    process.arguments = [script.path] + arguments
    process.currentDirectoryURL = resources
    return process
}

func validateNativeProtocol() -> Bool {
    let token = String(repeating: "a", count: 32)
    guard (try? DashboardSession("http://127.0.0.1:8767/session/\(token)")) != nil else { return false }
    let rejected = ["https://127.0.0.1:8767/session/\(token)", "http://localhost:8767/session/\(token)",
                    "http://127.1:8767/session/\(token)", "http://127.0.0.1/session/\(token)",
                    "http://user@127.0.0.1:8767/session/\(token)", "http://127.0.0.1:8767/session/\(token)?x=1",
                    "http://127.0.0.1:8767/session/\(token)#x", "http://127.0.0.1:8767/session/\(token)/",
                    "http://127.0.0.1:8767/session/short", "http://127.0.0.1:08767/session/\(token)",
                    "http://127.0.0.1:0/session/\(token)", "http://127.0.0.1:65536/session/\(token)",
                    "http://127.0.0.1:8767/other/../session/\(token)",
                    "http://127.0.0.1:8767/session/\(token)\n",
                    "http://127.0.0.1:8767/%73ession/\(token)"]
    return rejected.allSatisfy { (try? DashboardSession($0)) == nil }
}

final class PhoneBridgeApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var session: DashboardSession?
    private var generation = 0
    private var lineBuffer = Data()
    private var timer: Timer?
    private var pollInFlight = false
    private var mutating = false
    private var networkAddresses: [String] = []
    private var currentAddress = ""
    private var lastStatus: [String: Any]?
    private var zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    private var failureKey: String?
    private let redirectDelegate = NoRedirect()
    private lazy var http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()
    private let headline = NSTextField(labelWithString: "PhoneBridge")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let networkTitle = NSTextField(labelWithString: "")
    private let network = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qr = NSImageView()
    private let pairTitle = NSTextField(wrappingLabelWithString: "")
    private let mcpTitle = NSTextField(labelWithString: "MCP")
    private let mcp = NSTextView()
    private let start = NSButton()
    private let copy = NSButton()
    private let retry = NSButton()
    private let browser = NSButton()
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)

    private func text(_ en: String, _ cn: String) -> String { zh ? cn : en }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: text("Quit PhoneBridge", "退出 PhoneBridge"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: text("Edit", "编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editItem.title)
        editMenu.addItem(withTitle: text("Copy", "复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: text("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        beginLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PhoneBridge"
        window.minSize = NSSize(width: 580, height: 680)
        window.delegate = self
        window.center()
        let content = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        headline.font = .boldSystemFont(ofSize: 25)
        language.addItems(withTitles: ["English", "中文"])
        language.selectItem(at: zh ? 1 : 0)
        language.target = self
        language.action = #selector(changeLanguage)
        let header = NSStackView(views: [headline, language])
        header.orientation = .horizontal
        header.spacing = 30
        stack.addArrangedSubview(header)
        state.font = .boldSystemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        detail.isSelectable = true
        stack.addArrangedSubview(state)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(networkTitle)
        network.target = self
        network.action = #selector(changeNetwork)
        stack.addArrangedSubview(network)
        configure(start, #selector(startService))
        configure(retry, #selector(retryLaunch))
        configure(browser, #selector(openBrowser))
        let actions = NSStackView(views: [start, retry, browser])
        actions.orientation = .horizontal
        actions.spacing = 10
        stack.addArrangedSubview(actions)
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.setAccessibilityLabel(text("Phone pairing QR code", "手机配对二维码"))
        NSLayoutConstraint.activate([qr.widthAnchor.constraint(equalToConstant: 180), qr.heightAnchor.constraint(equalToConstant: 180)])
        let pairing = NSStackView(views: [qr, pairTitle])
        pairing.orientation = .horizontal
        pairing.spacing = 20
        stack.addArrangedSubview(pairing)
        pairing.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pairTitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -200).isActive = true
        stack.addArrangedSubview(mcpTitle)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        mcp.isEditable = false
        mcp.isSelectable = true
        mcp.isRichText = false
        mcp.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        mcp.autoresizingMask = [.width]
        mcp.textContainer?.widthTracksTextView = true
        mcp.textContainerInset = NSSize(width: 8, height: 8)
        mcp.minSize = NSSize(width: 0, height: 120)
        mcp.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        mcp.isVerticallyResizable = true
        scroll.documentView = mcp
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            state.widthAnchor.constraint(equalTo: stack.widthAnchor),
            network.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        configure(copy, #selector(copyMcp))
        stack.addArrangedSubview(copy)
        for view in stack.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in header.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in actions.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false }
        for view in pairing.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false }
        refreshLabels()
    }

    private func configure(_ button: NSButton, _ action: Selector) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private func refreshLabels() {
        networkTitle.stringValue = text("Computer network", "电脑网络")
        start.title = text("Start service", "启动服务")
        retry.title = text("Retry", "重试")
        browser.title = text("Open troubleshooting", "打开浏览器排查")
        copy.title = text("Copy MCP configuration", "复制 MCP 配置")
        pairTitle.stringValue = text("Scan this QR code in the PhoneBridge Android app. Keep your phone and computer on the same private network.", "使用 PhoneBridge 安卓应用扫描二维码，确保手机与电脑连接同一私人网络。")
        mcpTitle.stringValue = text("MCP configuration — select or copy", "MCP 配置 — 可选择或复制")
        if let failureKey { showFailure(failureKey) }
        else if let lastStatus { render(lastStatus) }
        else { state.stringValue = text("Starting PhoneBridge…", "正在启动 PhoneBridge…") }
    }

    @objc private func changeLanguage() { zh = language.indexOfSelectedItem == 1; refreshLabels() }
    @objc private func retryLaunch() { beginLaunch() }

    private func beginLaunch() {
        cleanupChild()
        generation += 1
        let current = generation
        session = nil
        lastStatus = nil
        failureKey = nil
        lineBuffer.removeAll()
        pollInFlight = false
        mutating = false
        network.removeAllItems()
        networkAddresses = []
        qr.image = nil
        mcp.string = ""
        detail.stringValue = ""
        setControls(ready: false)
        state.stringValue = text("Starting PhoneBridge…", "正在启动 PhoneBridge…")
        do {
            let child = try bundledProcess(arguments: ["--native-window"])
            let stdout = Pipe(), stderr = Pipe()
            process = child; output = stdout; errors = stderr
            child.standardOutput = stdout; child.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async { self?.readReady(data, generation: current) }
            }
            // Drain stderr to prevent blocking; error messages may contain capabilities.
            stderr.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
            child.terminationHandler = { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let self, self.generation == current else { return }
                    if self.session == nil { self.showFailure("startup") }
                    // A reused dashboard child intentionally exits after its ready message.
                }
            }
            try child.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
                guard let self, self.generation == current, self.session == nil else { return }
                self.cleanupChild()
                self.showFailure("timeout")
            }
        } catch { cleanupChild(); showFailure("runtime") }
    }

    private func readReady(_ data: Data, generation current: Int) {
        guard current == generation, session == nil else { return }
        lineBuffer.append(data)
        guard lineBuffer.count <= 65536 else { cleanupChild(); showFailure("startup"); return }
        guard let newline = lineBuffer.firstIndex(of: 10) else { return }
        let firstLine = Data(lineBuffer[..<newline])
        lineBuffer.removeAll()
        guard let message = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any],
              message["ready"] as? Bool == true, let raw = message["dashboardUrl"] as? String,
              let validated = try? DashboardSession(raw) else {
            cleanupChild(); showFailure("session"); return
        }
        session = validated
        failureKey = nil
        browser.isEnabled = true
        pollStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollStatus() }
    }

    private func request(_ route: String, body: [String: String]? = nil,
                         completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let session else { completion(nil, text("Dashboard unavailable.", "本地面板不可用。")); return }
        let current = generation
        var request = URLRequest(url: session.url.appendingPathComponent(route))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue(session.origin, forHTTPHeaderField: "Origin")
            request.setValue(session.secret, forHTTPHeaderField: "X-PhoneBridge-CSRF")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        http.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                guard error == nil, let response = response as? HTTPURLResponse,
                      response.url == request.url, let data, data.count <= 2_000_000,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    completion(nil, self.text("The local dashboard did not respond. Try again.", "本地面板未响应，请重试。")); return
                }
                guard (200...299).contains(response.statusCode) else {
                    completion(nil, self.safeDetail(object["error"] as? String) ?? self.text("The request was refused. Try again.", "操作被拒绝，请重试。")); return
                }
                completion(object, nil)
            }
        }.resume()
    }

    // Never display an accidental bearer token or private dashboard capability from an error.
    private func safeDetail(_ value: String?) -> String? {
        guard let value, !value.contains("/session/"), !value.lowercased().contains("bearer"),
              !value.lowercased().contains("token"), value.count <= 1200 else { return nil }
        guard zh else { return value }
        let translations = [
            "The saved network is unavailable. Select your current network.": "已保存的网络不可用，请选择当前网络。",
            "Select an active private network.": "请选择可用的私人网络。",
            "Disconnect the phone before changing networks.": "切换网络前请先断开手机连接。",
            "Disconnect the phone before moving or upgrading the desktop App.": "移动或升级电脑应用前请先断开手机连接。",
            "The service is starting. Please wait.": "服务正在启动，请稍候。",
            "Connect to a private Wi-Fi or Ethernet network.": "请连接私人 Wi-Fi 或以太网。"
        ]
        return translations[value] ?? ("服务信息：" + value)
    }

    private func pollStatus() {
        guard !pollInFlight, !mutating, session != nil else { return }
        pollInFlight = true
        request("status") { [weak self] object, error in
            guard let self else { return }
            self.pollInFlight = false
            if let object { self.lastStatus = object; self.failureKey = nil; self.render(object) }
            else { self.state.stringValue = self.text("Dashboard unavailable", "本地面板不可用"); self.detail.stringValue = error ?? ""; self.setControls(ready: false) }
        }
    }

    private func render(_ object: [String: Any]) {
        guard let connected = object["connected"] as? Bool, let address = object["address"] as? String,
              let port = object["port"] as? Int else { showFailure("session"); return }
        let unavailable = object["unavailable"] as? Bool ?? true
        state.stringValue = unavailable ? text("Service unavailable", "服务暂不可用") : connected ? text("Phone connected", "手机已连接") : text("Waiting for your phone", "等待手机连接")
        let error = safeDetail(object["error"] as? String)
        detail.stringValue = "\(object["name"] as? String ?? "PhoneBridge") · \(address):\(port)" + (error.map { "\n" + $0 } ?? "")
        let networks = object["networks"] as? [[String: String]] ?? []
        let addresses = networks.compactMap { $0["address"] }
        if networkAddresses != addresses || currentAddress != address {
            networkAddresses = addresses
            currentAddress = address
            network.removeAllItems()
            for item in networks { if let ip = item["address"] { network.addItem(withTitle: "\(item["name"] ?? "Network") · \(ip)") } }
            if let index = addresses.firstIndex(of: address) { network.selectItem(at: index) }
            else { network.insertItem(withTitle: text("Saved network unavailable: ", "已保存网络不可用：") + address, at: 0); networkAddresses.insert("", at: 0); network.selectItem(at: 0) }
        }
        if let dataURI = object["qr"] as? String, dataURI.hasPrefix("data:image/png;base64,"),
           let bytes = Data(base64Encoded: String(dataURI.dropFirst("data:image/png;base64,".count))), bytes.count <= 1_000_000 {
            qr.image = NSImage(data: bytes)
        } else { qr.image = nil }
        if let config = object["mcpConfiguration"], JSONSerialization.isValidJSONObject(config),
           let bytes = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let value = String(data: bytes, encoding: .utf8) { mcp.string = value }
        else { mcp.string = "" }
        setControls(ready: true)
    }

    private func setControls(ready: Bool) {
        start.isEnabled = ready && !mutating
        network.isEnabled = ready && !mutating && !networkAddresses.filter({ !$0.isEmpty }).isEmpty
        copy.isEnabled = ready && !mcp.string.isEmpty
        browser.isEnabled = session != nil
        retry.isEnabled = !mutating
    }

    private func showFailure(_ key: String) {
        failureKey = key
        state.stringValue = text("PhoneBridge could not start", "PhoneBridge 启动失败")
        switch key {
        case "runtime": detail.stringValue = text("The bundled runtime is missing or cannot start. Reinstall the complete PhoneBridge.app and try again.", "应用内置运行时缺失或无法启动。请重新安装完整的 PhoneBridge.app 后重试。")
        case "session": detail.stringValue = text("The local dashboard session could not be verified. Retry or reinstall the app.", "无法验证本地面板会话。请重试或重新安装应用。")
        case "timeout": detail.stringValue = text("Startup timed out. Check that the app is copied to Applications and a private network is available, then retry.", "启动超时。请将应用复制到 Applications，并连接私人网络后重试。")
        default: detail.stringValue = text("Check that PhoneBridge.app is copied to Applications and that your private Wi-Fi or Ethernet network is available, then retry. Run --diagnose from Terminal for a safe report.", "请将 PhoneBridge.app 复制到 Applications，确认私人 Wi-Fi 或以太网可用后重试。可在终端运行 --diagnose 获取诊断报告。")
        }
        setControls(ready: false)
    }

    private func mutate(_ route: String, body: [String: String]) {
        guard !mutating else { return }
        mutating = true
        setControls(ready: true)
        request(route, body: body) { [weak self] _, error in
            guard let self else { return }
            self.mutating = false
            self.setControls(ready: true)
            if let error {
                let alert = NSAlert()
                alert.messageText = self.text("Unable to complete the request", "无法完成操作")
                alert.informativeText = error
                alert.beginSheetModal(for: self.window)
                self.currentAddress = "" // Restore the saved selection on the next poll.
            }
            self.pollStatus()
        }
    }

    @objc private func startService() { mutate("start", body: [:]) }
    @objc private func changeNetwork() {
        let index = network.indexOfSelectedItem
        guard networkAddresses.indices.contains(index), !networkAddresses[index].isEmpty else { return }
        mutate("network", body: ["address": networkAddresses[index]])
    }
    @objc private func copyMcp() {
        guard !mcp.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcp.string, forType: .string)
        copy.title = text("Copied", "已复制")
    }
    @objc private func openBrowser() { if let session { NSWorkspace.shared.open(session.url) } }

    private func cleanupChild() {
        timer?.invalidate(); timer = nil
        // Only the process launched by this window is terminated. LaunchAgent is independent.
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        try? errors?.fileHandleForReading.close()
        process = nil; output = nil; errors = nil
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { generation += 1; cleanupChild(); http.invalidateAndCancel() }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--diagnose") || arguments.contains("--self-test") || arguments.contains("--no-open") || arguments.contains("--report-path") || arguments.contains("--uninstall-service") {
    do {
        if arguments.contains("--self-test"), !validateNativeProtocol() { throw ClientError.invalidSession }
        let child = try bundledProcess(arguments: arguments)
        child.standardInput = FileHandle.standardInput
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        try child.run()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { if child.isRunning { child.interrupt() } }
        terminate.setEventHandler { if child.isRunning { child.terminate() } }
        interrupt.resume(); terminate.resume()
        child.waitUntilExit()
        interrupt.cancel(); terminate.cancel()
        exit(child.terminationStatus)
    } catch {
        FileHandle.standardError.write(Data("PhoneBridge: bundled runtime or native protocol validation failed.\n".utf8))
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = PhoneBridgeApp()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
