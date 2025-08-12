import Cocoa
import FlutterMacOS

private let PipLoggingEnabled = false

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Configure window to appear on current desktop without switching Spaces
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    self.level = NSWindow.Level.floating
    self.isMovableByWindowBackground = true
    
    // Make window appear on top and stay visible
    self.hidesOnDeactivate = false
    
    RegisterGeneratedPlugins(registry: flutterViewController)
    
    // Register custom method channels after Flutter engine is ready
    if PipLoggingEnabled { print("🚀 MainFlutterWindow: Registering method channels...") }
    registerCustomChannels(flutterViewController: flutterViewController)

    super.awakeFromNib()
  }
  
  private func registerCustomChannels(flutterViewController: FlutterViewController) {
    if PipLoggingEnabled { print("📋 Registering clipboard channel...") }
    let clipboardChannel = FlutterMethodChannel(name: "clipboard_channel", binaryMessenger: flutterViewController.engine.binaryMessenger)
    clipboardChannel.setMethodCallHandler { (call, result) in
      if PipLoggingEnabled { print("CLIPBOARD CHANNEL: Received method call: \(call.method)") }
      switch call.method {
      case "getClipboardFiles":
        // Handle clipboard files
        result([])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if PipLoggingEnabled { print("✅ Clipboard channel registered successfully") }
    
    if PipLoggingEnabled { print("🖼️ Registering PiP channel...") }
    let pipChannel = FlutterMethodChannel(name: "pip_controller", binaryMessenger: flutterViewController.engine.binaryMessenger)
    pipChannel.setMethodCallHandler { (call, result) in
      if PipLoggingEnabled { print("PIP CHANNEL: Received method call: \(call.method)") }
      
      guard #available(macOS 10.15, *) else {
        if PipLoggingEnabled { print("❌ PiP requires macOS 10.15 or later") }
        result(FlutterError(code: "UNAVAILABLE", message: "PiP requires macOS 10.15 or later", details: nil))
        return
      }
      
      switch call.method {
      case "startPip":
        if PipLoggingEnabled { print("PIP: Starting PiP window...") }
        PipManager.shared.start()
        result(true)
      case "stopPip":
        if PipLoggingEnabled { print("PIP: Stopping PiP window...") }
        PipManager.shared.stop()
        result(true)
      case "updatePipProgress":
        if let args = call.arguments as? [String: Any],
           let progress = args["progress"] as? Double {
          if PipLoggingEnabled { print("PIP: Updating progress to \(progress)%") }
          PipManager.shared.updateProgress(progress)
          result(true)
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid progress value", details: nil))
        }
      case "updatePipFileName":
        if let args = call.arguments as? [String: Any],
           let name = args["name"] as? String {
          if PipLoggingEnabled { print("PIP: Updating file name to \(name)") }
          PipManager.shared.updateFileName(name)
          result(true)
        } else {
          result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid file name value", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if PipLoggingEnabled { print("✅ PiP channel registered successfully") }
  }
}
