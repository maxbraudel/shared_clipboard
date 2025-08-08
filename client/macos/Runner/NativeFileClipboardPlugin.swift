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
    case "getFilesFromClipboard":
      getFilesFromClipboard(result)
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

  private func getFilesFromClipboard(_ result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    // Prefer modern URL reading API
    let classes: [AnyClass] = [NSURL.self]
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]

    var paths: [String] = []

    if let urls = pasteboard.readObjects(forClasses: classes, options: options) as? [URL], !urls.isEmpty {
      paths = urls.map { $0.path }
    } else if let items = pasteboard.pasteboardItems {
      // Fallback: iterate items for fileURL type strings
      for item in items {
        if let fileUrlString = item.string(forType: .fileURL), let url = URL(string: fileUrlString) {
          paths.append(url.path)
        }
      }
    }

    print("📋 macOS pasteboard file paths count: \(paths.count)")
    result(paths)
  }
}
