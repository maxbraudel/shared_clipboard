import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
  
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    
    // Register the NativeFileClipboard plugin
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      NativeFileClipboardPlugin.register(with: controller.registrar(forPlugin: "NativeFileClipboardPlugin"))
      print("✅ Native File Clipboard Plugin registered successfully")
    }
  }
}
