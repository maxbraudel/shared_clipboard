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
    
    // Register native file clipboard plugin using runtime lookup
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      // Use runtime to call the Objective-C plugin registration
      if let pluginClass: AnyClass = NSClassFromString("NativeFileClipboardPlugin") {
        let registrar = controller.registrar(forPlugin: "NativeFileClipboardPlugin")
        
        // Use performSelector to call the register method - use the immediate version
        let selector = NSSelectorFromString("registerWithRegistrar:")
        if pluginClass.responds(to: selector) {
          let _ = pluginClass.perform(selector, with: registrar, afterDelay: 0)
          print("✅ Native File Clipboard Plugin registered successfully via runtime")
        } else {
          print("❌ Plugin class doesn't respond to registerWithRegistrar:")
        }
      } else {
        print("❌ Could not find NativeFileClipboardPlugin class")
      }
    }
  }
}
