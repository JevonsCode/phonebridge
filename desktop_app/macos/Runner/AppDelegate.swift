import Cocoa
import FlutterMacOS
import Darwin

@main
class AppDelegate: FlutterAppDelegate {
  private var quitting = false
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateNow }
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return .terminateNow }
    quitting = true
    var replied = false
    let finish = { if !replied { replied = true; sender.reply(toApplicationShouldTerminate: true) } }
    FlutterMethodChannel(name: "phonebridge/lifecycle", binaryMessenger: controller.engine.binaryMessenger).invokeMethod("shutdown", arguments: nil) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: finish)
    return .terminateLater
  }
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains(where: { ["--diagnose", "--self-test", "--no-open", "--report-path", "--uninstall-service"].contains($0) }) {
      guard let root = Bundle.main.resourceURL else { exit(1) }
      let child = Process()
      child.executableURL = root.appendingPathComponent("runtime/node")
      child.arguments = [root.appendingPathComponent("desktop/macos/server.mjs").path] + arguments
      child.currentDirectoryURL = root
      child.standardInput = FileHandle.standardInput
      child.standardOutput = FileHandle.standardOutput
      child.standardError = FileHandle.standardError
      do {
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
        FileHandle.standardError.write(Data("PhoneBridge: bundled runtime could not start.\n".utf8))
        exit(1)
      }
    }
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  // Closing hides the window while the menu bar icon is on; the Dock icon brings it back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { mainFlutterWindow?.makeKeyAndOrderFront(nil) }
    return true
  }
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
