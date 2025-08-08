import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Keep app running in background when window is closed
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
  
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    
    // Ensure the app starts with no visible window (menubar-only)
    self.mainFlutterWindow?.orderOut(nil)

    // Register channel using controller.engine messenger with retry to avoid timing issues
    registerClipboardChannelWithRetry()
  }

  private func registerClipboardChannelWithRetry(_ attempt: Int = 0) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "native_file_clipboard", binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        switch call.method {
        case "putFilesToClipboard":
          guard let args = call.arguments as? [String: Any], let filePaths = args["filePaths"] as? [String] else {
            result(false)
            return
          }
          self?.putFilesToClipboard(filePaths: filePaths, result: result)
        case "clearClipboard":
          self?.clearClipboard(result: result)
        case "getFilesFromClipboard":
          self?.getFilesFromClipboard(result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      print("✅ native_file_clipboard channel registered in AppDelegate")
    } else if attempt < 10 {
      print("⏳ Waiting for FlutterViewController to register channel (attempt \(attempt + 1))")
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
        self?.registerClipboardChannelWithRetry(attempt + 1)
      }
    } else {
      print("❌ Failed to register native_file_clipboard channel: FlutterViewController not available")
    }
  }

  private func putFilesToClipboard(filePaths: [String], result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let urls = filePaths.compactMap { path -> URL? in
      let url = URL(fileURLWithPath: path)
      return FileManager.default.fileExists(atPath: path) ? url : nil
    }
    let success = pasteboard.writeObjects(urls as [NSPasteboardWriting])
    result(success)
  }

  private func clearClipboard(result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    result(true)
  }

  private func getFilesFromClipboard(result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    var paths: [String] = []

    // 1) Modern file URLs via readObjects(forClasses:options:)
    let classes: [AnyClass] = [NSURL.self]
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = pasteboard.readObjects(forClasses: classes, options: options) as? [URL], !urls.isEmpty {
      paths.append(contentsOf: urls.filter { $0.isFileURL }.map { $0.path })
    }

    // 2) Fallback: iterate items for public.file-url strings
    if paths.isEmpty, let items = pasteboard.pasteboardItems {
      for item in items {
        if let s = item.string(forType: .fileURL), let url = URL(string: s), url.isFileURL {
          paths.append(url.path)
        }
      }
    }

    // 3) Legacy fallback: NSFilenamesPboardType
    if paths.isEmpty {
      let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
      if let plist = pasteboard.propertyList(forType: legacyType) as? [String] {
        paths.append(contentsOf: plist)
      }
    }

    result(paths)
  }
}
