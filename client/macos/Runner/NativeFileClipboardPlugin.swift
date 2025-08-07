import Cocoa
import FlutterMacOS

public class NativeFileClipboardPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "native_file_clipboard", binaryMessenger: registrar.messenger)
    let instance = NativeFileClipboardPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "putFilesToClipboard":
      putFilesToClipboard(call, result: result)
    case "clearClipboard":
      clearClipboard(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func putFilesToClipboard(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let filePaths = arguments["filePaths"] as? [String] else {
      print("❌ Invalid arguments for putFilesToClipboard")
      result(false)
      return
    }

    print("📁 PUTTING \(filePaths.count) FILES TO CLIPBOARD")
    
    // Create URLs from file paths
    let fileURLs = filePaths.compactMap { path in
      URL(fileURLWithPath: path)
    }
    
    guard !fileURLs.isEmpty else {
      print("❌ NO VALID FILE URLS")
      result(false)
      return
    }
    
    // Clear clipboard and set files
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    
    let success = pasteboard.writeObjects(fileURLs as [NSPasteboardWriting])
    
    if success {
      print("✅ FILES SUCCESSFULLY SET TO CLIPBOARD!")
      print("📋 \(fileURLs.count) file(s) ready to paste")
    } else {
      print("❌ FAILED TO SET FILES TO CLIPBOARD")
    }
    
    result(success)
  }

  private func clearClipboard(_ result: @escaping FlutterResult) {
    print("🗑️ CLEARING CLIPBOARD")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    result(true)
  }
}
