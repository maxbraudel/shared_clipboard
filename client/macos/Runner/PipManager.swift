import Foundation
import Cocoa
import AVFoundation
import AVKit
import Darwin

@available(macOS 10.15, *)
class PipManager: NSObject {
    static let shared = PipManager()
    
    private var pipController: AVPictureInPictureController?
    private var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer?
    private var currentProgress: Double = 0.0
    private var displayTimer: Timer?

    // Private PIP.framework runtime objects
    private var privatePipVCClass: NSViewController.Type?
    private var privatePipVC: NSViewController?
    private var privateContentVC: NSViewController?
    private var privateFrameworkLoaded: Bool = false
    
    override init() {
        super.init()
        // Attempt to load private PIP first; fall back to AVKit
        loadPrivatePIPIfAvailable()
        if !privateFrameworkLoaded {
            setupPiP()
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
         override var isFlipped: Bool { true }
         override func draw(_ dirtyRect: NSRect) {
             super.draw(dirtyRect)
             guard let ctx = NSGraphicsContext.current?.cgContext else { return }
             // Background
             ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.95))
             ctx.fill(bounds)
             // Bar background
             let barRect = CGRect(x: 20, y: bounds.height/2 - 10, width: bounds.width - 40, height: 20)
             ctx.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1))
             let bgPath = CGPath(roundedRect: barRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
             ctx.addPath(bgPath)
             ctx.fillPath()
             // Fill
             let fillWidth = barRect.width * CGFloat(progress / 100.0)
             let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
             ctx.setFillColor(CGColor(red: 0.0, green: 0.55, blue: 1.0, alpha: 1))
             let fillPath = CGPath(roundedRect: fillRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
             ctx.addPath(fillPath)
             ctx.fillPath()
         }
    }

    private func presentPrivatePiP() {
         guard privateFrameworkLoaded, let PIPVCType = privatePipVCClass else { return }
         if privatePipVC == nil {
             let pipVC = PIPVCType.init()
             // Configure via KVC to avoid compile-time dependency
             pipVC.setValue(true, forKey: "playing")
             pipVC.setValue(NSSize(width: 3, height: 2), forKey: "aspectRatio")
             pipVC.setValue("Download", forKey: "title")
             self.privatePipVC = pipVC

             let contentVC = NSViewController()
             contentVC.view = ProgressView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
             self.privateContentVC = contentVC
         }
         guard let pipVC = privatePipVC, let contentVC = privateContentVC else { return }
         let sel = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
         if pipVC.responds(to: sel) {
             print("🎬 Presenting private PiP with custom view")
             _ = pipVC.perform(sel, with: contentVC)
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
        
        // Draw progress bar background
        let barRect = CGRect(x: 20, y: height/2 - 10, width: width - 40, height: 20)
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0))
        context.fillEllipse(in: barRect)
        
        // Draw progress bar fill
        let fillWidth = Double(barRect.width) * (currentProgress / 100.0)
        let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
        context.setFillColor(CGColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 1.0))
        context.fillEllipse(in: fillRect)
        
        // Draw percentage text
        let percentText = String(format: "%.0f%%", currentProgress)
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
        print("🎬 PipManager: Starting PiP...")
        // Prefer private PIP (no controls) if available
        if privateFrameworkLoaded {
            DispatchQueue.main.async {
                self.presentPrivatePiP()
                print("✅ Private PiP presented")
            }
            return
        }
        
        guard #available(macOS 10.15, *) else {
            print("❌ PiP requires macOS 10.15 or later")
            return
        }
        
        guard let pipController = pipController else {
            print("❌ PiP controller not available")
            return
        }
        
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("❌ Picture in Picture is not supported on this device")
            return
        }
        
        DispatchQueue.main.async {
            // Start rendering frames
            if #available(macOS 12.0, *) {
                self.startFrameTimer()
            }
            
            // Start PiP (AVKit)
            pipController.startPictureInPicture()
            print("✅ PiP started successfully")
        }
    }
    
    func stop() {
        print("🛑 PipManager: Stopping PiP...")
        if privateFrameworkLoaded {
            DispatchQueue.main.async {
                self.dismissPrivatePiP()
                print("✅ Private PiP dismissed")
            }
            return
        }
        
        guard #available(macOS 10.15, *) else { return }
        
        DispatchQueue.main.async {
            self.stopFrameTimer()
            self.pipController?.stopPictureInPicture()
            print("✅ PiP stopped successfully")
        }
    }
    
    func updateProgress(_ progress: Double) {
        print("📊 PipManager: Updating progress to \(progress)%")
        currentProgress = progress
        
        // The progress will be rendered in the next frame update
        if privateFrameworkLoaded, let view = privateContentVC?.view as? ProgressView {
            view.progress = progress
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
