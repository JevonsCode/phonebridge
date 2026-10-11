import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1120, height: 800))
    self.minSize = NSSize(width: 400, height: 520)
    self.title = "PhoneBridge"
    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
  }
}
