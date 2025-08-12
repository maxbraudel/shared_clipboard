import Foundation
import Cocoa
import AVFoundation
import AVKit
import Darwin
import ObjectiveC.runtime

private let PipLoggingEnabled = false

@available(macOS 10.15, *)
class PipManager: NSObject {
    static let shared = PipManager()
    
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    // Normalized progress in [0.0, 1.0]
    private var currentProgressNormalized: Double = 0.0
    private var currentFileName: String? = nil
    private var displayTimer: Timer?

    // Private PIP.framework runtime objects
    private var privatePipVCClass: NSViewController.Type?
    private var privatePipVC: NSViewController?
    private var privateContentVC: NSViewController?
    private var privateProgressView: ProgressView?
    private var privateFrameworkLoaded: Bool = false
    
    override init() {
        super.init()
        // Attempt to load private PIP first; fall back to AVKit
        loadPrivatePIPIfAvailable()
        if !privateFrameworkLoaded {
            setupPiP()
        }
    }

    // MARK: - Animation Helpers
    private func fadeIn(view: NSView, duration: TimeInterval = 1.0, delay: TimeInterval = 0.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let superview = view.superview else {
                // If not in hierarchy yet, try again shortly to avoid a jump
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.fadeIn(view: view, duration: duration, delay: 0)
                }
                return
            }
            if superview.wantsLayer == false { superview.wantsLayer = true }
            if view.wantsLayer == false { view.wantsLayer = true }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = 1.0
            }
        }
    }
    
    private func setupPiP() {
        print("🎬 PipManager: Setting up AVKit PiP with sample buffer display layer...")
        
        // Create sample buffer display layer
        sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
        sampleBufferDisplayLayer?.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        sampleBufferDisplayLayer?.videoGravity = .resizeAspect
        
        // Create PiP controller with sample buffer display layer
        if #available(macOS 12.0, *) {
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: sampleBufferDisplayLayer!,
                playbackDelegate: self
            )
            pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController?.delegate = self
            print("✅ PiP controller created successfully with sample buffer display layer")
        } else {
            // Sample-buffer PiP requires macOS 12+
            pipController = nil
            print("ℹ️ AVPictureInPictureController.ContentSource requires macOS 12+. PiP progress rendering disabled on older macOS.")
        }
    }

    // MARK: - Private PIP.framework path (no controls)
    private func loadPrivatePIPIfAvailable() {
         let frameworkPath = "/System/Library/PrivateFrameworks/PIP.framework/PIP"
         if let _ = dlopen(frameworkPath, RTLD_LAZY) {
             print("✅ Loaded private PIP.framework: \(frameworkPath)")
             if let cls = NSClassFromString("PIPViewController") as? NSViewController.Type {
                 self.privatePipVCClass = cls
                 self.privateFrameworkLoaded = true
                 print("✅ Found PIPViewController class")
             } else {
                 print("ℹ️ PIPViewController not found after dlopen; falling back to AVKit")
                 self.privateFrameworkLoaded = false
             }
         } else {
             print("ℹ️ Could not load private PIP.framework; falling back to AVKit")
             self.privateFrameworkLoaded = false
         }
    }

    private class ProgressView: NSView {
        var progress: Double = 0.0 { didSet { needsDisplay = true } }
        var fileName: String? { didSet { needsDisplay = true } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            translatesAutoresizingMaskIntoConstraints = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            autoresizingMask = [.width, .height]
            translatesAutoresizingMaskIntoConstraints = false
        }

        override var isFlipped: Bool { true }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            let bounds = self.bounds.insetBy(dx: 8, dy: 8)

            // Background with rounded corners
            let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
            NSColor.windowBackgroundColor.withAlphaComponent(0.75).setFill()
            bgPath.fill()

            // Title
            let title = "Downloading…"
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(12, min(18, bounds.height * 0.12)), weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            let titleSize = title.size(withAttributes: titleAttrs)
            let titleOrigin = CGPoint(x: bounds.midX - titleSize.width / 2, y: bounds.minY + 10)
            title.draw(at: titleOrigin, withAttributes: titleAttrs)

            // Filename (below title)
            if let name = fileName {
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                para.lineBreakMode = .byTruncatingMiddle
                let fileAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(10, min(14, bounds.height * 0.11)), weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: para
                ]
                // Rect centered horizontally, positioned just above the progress bar area
                let fileRectHeight = max(14, bounds.height * 0.14)
                let fileRect = NSRect(x: bounds.minX + 10,
                                      y: titleOrigin.y + titleSize.height + 4,
                                      width: bounds.width - 20,
                                      height: fileRectHeight)
                (name as NSString).draw(in: fileRect, withAttributes: fileAttrs)
            }

            // Progress bar dimensions responsive to view size
            let barWidth = max(60, bounds.width * 0.8)
            let barHeight = max(8, min(18, bounds.height * 0.14))
            let barX = bounds.midX - barWidth / 2
            let barY = bounds.midY - barHeight / 2
            let barRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)

            // Track (rounded container)
            let trackPath = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
            trackPath.fill()

            // Fill (square-ended)
            let clamped = CGFloat(max(0.0, min(1.0, progress)))
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * clamped, height: barRect.height)
            NSColor.controlAccentColor.setFill()
            NSGraphicsContext.saveGraphicsState()
            trackPath.addClip()
            NSBezierPath(rect: fillRect).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Percentage label above the bar (with decimals)
            let percentValue = progress * 100.0
            let percentText = String(format: "%.1f%%", percentValue)
            let percentAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: max(11, min(16, bounds.height * 0.12)), weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let percentSize = percentText.size(withAttributes: percentAttrs)
            let percentOrigin = CGPoint(x: bounds.midX - percentSize.width / 2, y: barRect.maxY + 6)
            percentText.draw(at: percentOrigin, withAttributes: percentAttrs)
        }
    }
    

    private func presentPrivatePiP() {
         guard privateFrameworkLoaded, let PIPVCType = privatePipVCClass else { return }
         if privatePipVC == nil {
             let pipVC = PIPVCType.init()
             // Configure via KVC to avoid compile-time dependency
             pipVC.setValue(true, forKey: "playing")
             pipVC.setValue("Download", forKey: "title")
             // Example: lock PiP to 400x250 and disable resizing
            pipVC.setValue(NSSize(width: 370, height: 185), forKey: "minSize")
            pipVC.setValue(NSSize(width: 370, height: 185), forKey: "maxSize")
            pipVC.setValue(false, forKey: "userCanResize")
            pipVC.setValue(NSSize(width: 4, height: 2), forKey: "aspectRatio")
             self.privatePipVC = pipVC

             let contentVC = NSViewController()
             // Container view that will resize to PiP content area
             let container = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 185))
             container.wantsLayer = true
             container.layer?.backgroundColor = NSColor.clear.cgColor
             container.translatesAutoresizingMaskIntoConstraints = false
             // Prepare for fade-in to avoid flicker on appearance
             container.alphaValue = 0.0

             let progress = ProgressView(frame: container.bounds)
             // Initialize with current progress (already normalized 0–1)
             progress.progress = max(0.0, min(1.0, currentProgressNormalized))
             // Initialize with current file name if available
             if let name = currentFileName {
                 progress.fileName = (name as NSString).lastPathComponent
             }
             container.addSubview(progress)
             // Pin progress view to all edges of the container
             NSLayoutConstraint.activate([
                 progress.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                 progress.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                 progress.topAnchor.constraint(equalTo: container.topAnchor),
                 progress.bottomAnchor.constraint(equalTo: container.bottomAnchor)
             ])

             contentVC.view = container
             self.privateProgressView = progress
             self.privateContentVC = contentVC
         }
         guard let pipVC = privatePipVC, let contentVC = privateContentVC else { return }
         let sel = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
         if pipVC.responds(to: sel) {
             print("🎬 Presenting private PiP with custom view")
             _ = pipVC.perform(sel, with: contentVC)
             // Fade in the content to mitigate initial flicker
             if let view = self.privateContentVC?.view {
                 self.fadeIn(view: view, duration: 1.0)
             }
         } else {
             print("❌ Private PIPViewController missing presentViewControllerAsPictureInPicture:")
         }
    }

    private func dismissPrivatePiP() {
         guard let pipVC = privatePipVC, let contentVC = privateContentVC else { return }
         let sel = NSSelectorFromString("dismissViewController:")
         if pipVC.responds(to: sel) {
             _ = pipVC.perform(sel, with: contentVC)
         }
    }

    // MARK: - Runtime Introspection Helpers
    private func dumpPIPClass(_ c: AnyClass) {
        let className = NSStringFromClass(c)
        let superName = class_getSuperclass(c).map { NSStringFromClass($0) } ?? "(none)"
        print("🔎 Class: \(className)  super: \(superName)")

        var methodCount: UInt32 = 0
        if let methodList = class_copyMethodList(c, &methodCount) {
            if methodCount > 0 { print("   Methods (\(methodCount)):") }
            for i in 0..<Int(methodCount) {
                let m = methodList[i]
                let sel = method_getName(m)
                let name = NSStringFromSelector(sel)
                if let enc = method_getTypeEncoding(m) {
                    print("     • \(name)  enc: \(String(cString: enc))")
                } else {
                    print("     • \(name)")
                }
            }
            free(methodList)
        }

        var propCount: UInt32 = 0
        if let propList = class_copyPropertyList(c, &propCount) {
            if propCount > 0 { print("   Properties (\(propCount)):") }
            for i in 0..<Int(propCount) {
                let prop = propList[i]
                let cname = property_getName(prop)
                print("     • \(String(cString: cname))")
            }
            free(propList)
        }
    }

    func dumpPrivatePIPMetadata() {
        guard privateFrameworkLoaded else {
            print("ℹ️ Private PIP framework not loaded; nothing to dump")
            return
        }

        // Gather all runtime classes and filter by prefix "PIP"
        let numClasses = objc_getClassList(nil, 0)
        if numClasses <= 0 {
            print("ℹ️ No runtime classes found via objc_getClassList")
            return
        }
        let buffer = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(numClasses))
        defer { buffer.deallocate() }
        let realCount = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), numClasses)
        print("🔎 Scanning \(realCount) classes for PIP* …")

        var pipClasses: [AnyClass] = []
        for i in 0..<Int(realCount) {
            if let cls: AnyClass = buffer[i] {
                let name = NSStringFromClass(cls)
                if name.hasPrefix("PIP") {
                    pipClasses.append(cls)
                }
            }
        }

        if pipClasses.isEmpty {
            print("ℹ️ No PIP* classes discovered in runtime")
        }
        for cls in pipClasses {
            dumpPIPClass(cls)
        }
    }

    // MARK: - Export Introspection to File
    private func exportPrivatePIPMetadata() {
        guard privateFrameworkLoaded else { return }

        // Build a textual dump similar to console but captured in a buffer
        var output = "# PIP.framework Runtime Introspection\n\n"

        let numClasses = objc_getClassList(nil, 0)
        if numClasses <= 0 {
            output += "No runtime classes found via objc_getClassList\n"
            writeDump(output)
            return
        }
        let buffer = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(numClasses))
        defer { buffer.deallocate() }
        let realCount = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), numClasses)
        output += "Scanning \\(" + String(realCount) + ") classes for PIP* …\n\n"

        var pipClasses: [AnyClass] = []
        for i in 0..<Int(realCount) {
            if let cls: AnyClass = buffer[i] {
                let name = NSStringFromClass(cls)
                if name.hasPrefix("PIP") {
                    pipClasses.append(cls)
                }
            }
        }

        if pipClasses.isEmpty {
            output += "No PIP* classes discovered in runtime\n"
        }

        func appendClass(_ c: AnyClass, to s: inout String) {
            let className = NSStringFromClass(c)
            let superName = class_getSuperclass(c).map { NSStringFromClass($0) } ?? "(none)"
            s += "Class: \(className)  super: \(superName)\n"

            var methodCount: UInt32 = 0
            if let methodList = class_copyMethodList(c, &methodCount) {
                if methodCount > 0 { s += "  Methods (\(methodCount)):\n" }
                for i in 0..<Int(methodCount) {
                    let m = methodList[i]
                    let sel = method_getName(m)
                    let name = NSStringFromSelector(sel)
                    if let enc = method_getTypeEncoding(m) {
                        s += "    • \(name)  enc: \(String(cString: enc))\n"
                    } else {
                        s += "    • \(name)\n"
                    }
                }
                free(methodList)
            }

            var propCount: UInt32 = 0
            if let propList = class_copyPropertyList(c, &propCount) {
                if propCount > 0 { s += "  Properties (\(propCount)):\n" }
                for i in 0..<Int(propCount) {
                    let prop = propList[i]
                    let cname = property_getName(prop)
                    s += "    • \(String(cString: cname))\n"
                }
                free(propList)
            }
            s += "\n"
        }

        for cls in pipClasses { appendClass(cls, to: &output) }
        writeDump(output)
    }

    private func writeDump(_ text: String) {
        // Write to Documents, then Application Support, then Temporary
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let fileName = "PIP_runtime_dump_\(stamp).txt"

        let fm = FileManager.default

        func ensureDir(_ url: URL) -> URL? {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            } catch {
                return nil
            }
        }

        // 1) Documents (sandbox-safe)
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           ensureDir(docs) != nil {
            let url = docs.appendingPathComponent(fileName)
            if (try? text.data(using: .utf8)?.write(to: url)) != nil {
                print("📝 Wrote PIP runtime dump to: \(url.path)")
                return
            }
        }

        // 2) Application Support/<bundle id>
        if let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let base = appSup.appendingPathComponent(Bundle.main.bundleIdentifier ?? "SharedClipboard", isDirectory: true)
            if ensureDir(base) != nil {
                let url = base.appendingPathComponent(fileName)
                if (try? text.data(using: .utf8)?.write(to: url)) != nil {
                    print("📝 Wrote PIP runtime dump to: \(url.path)")
                    return
                }
            }
        }

        // 3) Temporary directory
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = tmp.appendingPathComponent(fileName)
        if (try? text.data(using: .utf8)?.write(to: url)) != nil {
            print("📝 Wrote PIP runtime dump to temporary folder: \(url.path)")
        } else {
            print("❌ Failed to write PIP runtime dump to any location")
        }
    }
    
    private func createProgressFrame() -> CVPixelBuffer? {
        let width = 300
        let height = 200
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("❌ Failed to create pixel buffer")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            print("❌ Failed to get pixel buffer base address")
            return nil
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            print("❌ Failed to create graphics context")
            return nil
        }
        
        // Draw progress UI
        drawProgressUI(in: context, width: width, height: height)
        
        return buffer
    }
    
    private func drawProgressUI(in context: CGContext, width: Int, height: Int) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        
        // Clear background
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.9))
        context.fill(rect)
        
        // Draw progress bar background (rounded track)
        let barRect = CGRect(x: 20, y: height/2 - 10, width: width - 40, height: 20)
        let corner = barRect.height / 2
        let trackPath = CGPath(roundedRect: barRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0))
        context.addPath(trackPath)
        context.fillPath()
        
        // Draw progress bar fill (square ends, clipped to rounded track)
        let clamped = max(0.0, min(1.0, currentProgressNormalized))
        let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: CGFloat(barRect.width) * CGFloat(clamped), height: barRect.height)
        context.saveGState()
        context.addPath(trackPath)
        context.clip()
        context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0))
        context.fill(fillRect)
        context.restoreGState()
        
        // Draw percentage text (with decimals)
        let percentText = String(format: "%.1f%%", currentProgressNormalized * 100.0)
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.textMatrix = CGAffineTransform.identity
        
        // Simple text rendering (basic approach)
        let textRect = CGRect(x: width/2 - 20, y: height/2 + 30, width: 40, height: 20)
        // Note: For proper text rendering, we'd need Core Text, but this gives us a basic visual
    }
    
    private func enqueueSampleBuffer() {
        guard let pixelBuffer = createProgressFrame() else { return }
        
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMVideoFormatDescription?
        
        let status1 = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard status1 == noErr, let videoFormatDescription = formatDescription else {
            print("❌ Failed to create format description")
            return
        }
        
        let presentationTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000)
        
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime(seconds: 1.0/30.0, preferredTimescale: 1000000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        let status2 = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormatDescription,
            sampleTiming: &sampleTiming,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status2 == noErr, let buffer = sampleBuffer else {
            print("❌ Failed to create sample buffer")
            return
        }
        
        sampleBufferDisplayLayer?.enqueue(buffer)
    }
    
    func start() {
        if PipLoggingEnabled { print("🎬 PipManager: Starting PiP...") }
        // Prefer private PIP (no controls) if available
        if privateFrameworkLoaded {
            DispatchQueue.main.async {
                // Dump selectors/type encodings for private PIP classes once
                if PipLoggingEnabled { self.dumpPrivatePIPMetadata() }
                if PipLoggingEnabled { self.exportPrivatePIPMetadata() }
                self.presentPrivatePiP()
                if PipLoggingEnabled { print("✅ Private PiP presented") }
            }
            return
        }
        
        guard #available(macOS 10.15, *) else {
            if PipLoggingEnabled { print("❌ PiP requires macOS 10.15 or later") }
            return
        }
        
        guard let pipController = pipController else {
            if PipLoggingEnabled { print("❌ PiP controller not available") }
            return
        }
        
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            if PipLoggingEnabled { print("❌ Picture in Picture is not supported on this device") }
            return
        }
        
        DispatchQueue.main.async {
            // Start rendering frames
            if #available(macOS 12.0, *) {
                self.startFrameTimer()
            }
            
            // Start PiP (AVKit)
            pipController.startPictureInPicture()
            if PipLoggingEnabled { print("✅ PiP started successfully") }
        }
    }
    
    func stop() {
        if PipLoggingEnabled { print("🛑 PipManager: Stopping PiP...") }
        if privateFrameworkLoaded {
            DispatchQueue.main.async {
                self.dismissPrivatePiP()
                if PipLoggingEnabled { print("✅ Private PiP dismissed") }
            }
            return
        }
        
        guard #available(macOS 10.15, *) else { return }
        
        DispatchQueue.main.async {
            self.stopFrameTimer()
            self.pipController?.stopPictureInPicture()
            if PipLoggingEnabled { print("✅ PiP stopped successfully") }
        }
    }
    
    func updateProgress(_ progress: Double) {
        // progress: normalized [0.0, 1.0]
        if PipLoggingEnabled { print("📊 PipManager: Updating normalized progress to \(progress)") }
        let normalized = max(0.0, min(1.0, progress))
        currentProgressNormalized = normalized
        
        // Update custom PiP view immediately (on main thread)
        if privateFrameworkLoaded, let view = privateProgressView {
            DispatchQueue.main.async {
                view.progress = normalized
            }
        }
    }

    func updateFileName(_ name: String) {
        if PipLoggingEnabled { print("📄 PipManager: Updating file name to \(name)") }
        currentFileName = name
        if privateFrameworkLoaded, let view = privateProgressView {
            let displayName = (name as NSString).lastPathComponent
            DispatchQueue.main.async {
                view.fileName = displayName
            }
        }
    }
    
    private func startFrameTimer() {
        stopFrameTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
            self.enqueueSampleBuffer()
        }
    }
    
    private func stopFrameTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
}

// MARK: - AVPictureInPictureControllerDelegate
@available(macOS 10.15, *)
extension PipManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 PiP will start")
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP did start")
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🛑 PiP will stop")
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("✅ PiP did stop")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ PiP failed to start: \(error.localizedDescription)")
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
@available(macOS 12.0, *)
extension PipManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // Keep rendering continuously; ignore external play/pause to avoid showing pause state UI
        print("🎬 PiP setPlaying (ignored): \(playing)")
        startFrameTimer()
    }
    
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Report zero duration to discourage showing a scrubber/timebar
        return CMTimeRange(start: .zero, duration: .zero)
    }
    
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // Always indicate playback to avoid pause UI
        return false
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        print("🎬 PiP did transition to render size: \(newRenderSize.width)x\(newRenderSize.height)")
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        // Disable skipping behavior; complete immediately
        print("🎬 PiP skip requested (disabled)")
        completionHandler()
    }
}
