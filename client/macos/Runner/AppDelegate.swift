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
      let pluginClass = NSClassFromString("NativeFileClipboardPlugin")
      if let pluginClass = pluginClass as? NSObject.Type {
        if pluginClass.responds(to: Selector(("registerWithRegistrar:"))) {
          let registrar = controller.registrar(forPlugin: "NativeFileClipboardPlugin")
          pluginClass.perform(Selector(("registerWithRegistrar:")), with: registrar)
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
