import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var filesChannel: FlutterMethodChannel?
  private var choosingFile = false
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1120, height: 800))
    self.minSize = NSSize(width: 400, height: 520)
    self.title = "PhoneBridge"
    RegisterGeneratedPlugins(registry: flutterViewController)
    filesChannel = FlutterMethodChannel(name: "dev.phonebridge/files", binaryMessenger: flutterViewController.engine.binaryMessenger)
    filesChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "chooseFile" else { result(FlutterMethodNotImplemented); return }
      guard let self = self, !self.choosingFile else {
        result(FlutterError(code: "BUSY", message: "A file chooser is already open.", details: nil)); return
      }
      self.choosingFile = true
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.resolvesAliases = false
      panel.beginSheetModal(for: self) { response in
        self.choosingFile = false
        result(response == .OK ? panel.url?.path : nil)
      }
    }
    super.awakeFromNib()
  }
}
