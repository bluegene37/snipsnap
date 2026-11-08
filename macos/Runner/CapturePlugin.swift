import AppKit
// Gene - Nov, 08, 2026: Added AVFoundation and CoreMedia imports for native H.264 MP4 screen & area recording, frame extraction, and video trimming.
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import FlutterMacOS

/// Native macOS Screen Capture Plugin.
/// Provides interactive screen capture overlay where:
/// - Clicking once (without drag) captures the whole screen.
/// - Clicking and dragging captures the selected rectangular area.
/// - Pressing any key escapes and cancels capture (no screenshot taken).
class CapturePlugin: NSObject {
  // Gene - Oct, 27, 2026: Retain FlutterMethodChannel reference and scrolling HUD windows on CapturePlugin instance.
  // Old implementation:
  // static func register(with registrar: FlutterPluginRegistrar) {
  //   let channel = FlutterMethodChannel(
  //     name: "snipsnap/capture",
  //     binaryMessenger: registrar.messenger
  //   )
  //   let instance = CapturePlugin()
  //   channel.setMethodCallHandler { call, result in
  //     instance.handle(call, result: result)
  //   }
  // }
  //
  // private var activeWindows: [CaptureOverlayWindow] = []
  // private var localKeyMonitor: Any?
  // private var globalKeyMonitor: Any?
  // private var activeResult: FlutterResult?
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "snipsnap/capture",
      binaryMessenger: registrar.messenger
    )
    let instance = CapturePlugin()
    instance.channel = channel
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private var channel: FlutterMethodChannel?
  private var activeWindows: [CaptureOverlayWindow] = []
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var activeResult: FlutterResult?

  private var scrollingGuideWindow: NSPanel?
  private var scrollingHudWindow: NSPanel?
  private var scrollingKeyMonitor: Any?
  private var scrollingLocalKeyMonitor: Any?

  // Gene - Nov, 08, 2026: Added screen recording session state and floating recording HUD windows.
  private var recordingGuideWindow: NSPanel?
  private var recordingHudWindow: NSPanel?
  private var recordingSession: MacScreenRecordingSession?

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "captureInteractive":
      // Gene - Nov, 08, 2026: Support optional initialMode ("capture" or "record") in captureInteractive.
      // Old implementation:
      // guard
      //   let args = call.arguments as? [String: Any],
      //   let targetPath = args["targetPath"] as? String
      // else {
      //   result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
      //   return
      // }
      // startInteractiveCapture(targetPath: targetPath, result: result)
      guard
        let args = call.arguments as? [String: Any],
        let targetPath = args["targetPath"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
        return
      }
      let initialMode = (args["initialMode"] as? String) ?? "capture"
      startInteractiveCapture(targetPath: targetPath, initialMode: initialMode, result: result)

    case "captureFullScreen":
      guard
        let args = call.arguments as? [String: Any],
        let targetPath = args["targetPath"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
        return
      }
      captureFullScreen(targetPath: targetPath, result: result)

    case "screenCaptureAuthorized":
      // Preflight only. It never prompts, so a granted app pays nothing and a
      // refused one gets a plain `false` the Dart side can act on.
      //
      // Without this, a missing grant is invisible: CGWindowListCreateImage
      // quietly returns desktop wallpaper with no windows in it, and
      // `screencapture` exits 0 having written a file — so every guard on the
      // Dart side passes and the user just gets a blank-looking capture.
      //
      // The request used to live here too, fired whenever preflight said no.
      // That put the system dialog on screen for every single capture, which
      // is exactly what an ad-hoc signed build hits after a rebuild: TCC keys
      // the Screen Recording grant to the binary's cdhash, so the toggle in
      // System Settings still reads "on" for the previous build while this
      // one is refused. Requesting is now its own method so Dart can decide
      // to ask once per launch instead of once per capture.
      result(CGPreflightScreenCaptureAccess())

    case "requestScreenCaptureAccess":
      // Shows the system prompt (or, when an entry already exists, nothing).
      // Returns false on first call; the grant only takes effect after a
      // relaunch, which is why the Dart side words its message that way.
      result(CGRequestScreenCaptureAccess())

    // Gene - Nov, 03, 2026: Added accessibility checks and settings deep link for macOS global capture hotkeys.
    case "accessibilityAuthorized":
      result(AXIsProcessTrusted())

    case "requestAccessibilityAccess":
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      let options = [promptKey: true] as CFDictionary
      result(AXIsProcessTrustedWithOptions(options))

    case "openAccessibilitySettings":
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
        result(true)
      } else {
        result(false)
      }

    // Gene - Oct, 27, 2026: Added captureRect and simulateScroll for panoramic scrolling capture.
    // Gene - Oct, 27, 2026: Updated captureRect to convert Retina pixel coordinates to Quartz points using backingScaleFactor.
    case "captureRect":
      guard
        let args = call.arguments as? [String: Any],
        let xVal = (args["x"] as? NSNumber)?.doubleValue ?? (args["x"] as? Double),
        let yVal = (args["y"] as? NSNumber)?.doubleValue ?? (args["y"] as? Double),
        let wVal = (args["width"] as? NSNumber)?.doubleValue ?? (args["width"] as? Double),
        let hVal = (args["height"] as? NSNumber)?.doubleValue ?? (args["height"] as? Double)
      else {
        result(FlutterError(code: "bad_args", message: "rect parameters missing", details: nil))
        return
      }
      // Old implementation:
      // let rect = CGRect(x: CGFloat(xVal), y: CGFloat(yVal), width: CGFloat(wVal), height: CGFloat(hVal))
      // guard
      //   let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
      // else {
      //   result(nil)
      //   return
      // }
      let scale = NSScreen.screens.first?.backingScaleFactor ?? 1.0
      let pointRect = CGRect(
        x: CGFloat(xVal) / scale,
        y: CGFloat(yVal) / scale,
        width: CGFloat(wVal) / scale,
        height: CGFloat(hVal) / scale
      )
      guard
        let image = CGWindowListCreateImage(pointRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
      else {
        result(nil)
        return
      }
      let rep = NSBitmapImageRep(cgImage: image)
      guard let data = rep.representation(using: .png, properties: [:]) else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: data))

    // Gene - Oct, 27, 2026: Added native floating HUD controls for panoramic scrolling capture.
    case "showScrollingHud":
      guard
        let args = call.arguments as? [String: Any],
        let xVal = (args["x"] as? NSNumber)?.doubleValue ?? (args["x"] as? Double),
        let yVal = (args["y"] as? NSNumber)?.doubleValue ?? (args["y"] as? Double),
        let wVal = (args["width"] as? NSNumber)?.doubleValue ?? (args["width"] as? Double),
        let hVal = (args["height"] as? NSNumber)?.doubleValue ?? (args["height"] as? Double)
      else {
        result(FlutterError(code: "bad_args", message: "rect parameters missing", details: nil))
        return
      }
      let rect = CGRect(x: CGFloat(xVal), y: CGFloat(yVal), width: CGFloat(wVal), height: CGFloat(hVal))
      showScrollingHud(for: rect)
      result(true)

    case "updateScrollingHud":
      guard
        let args = call.arguments as? [String: Any],
        let height = (args["height"] as? NSNumber)?.intValue ?? (args["height"] as? Int),
        let frameCount = (args["frameCount"] as? NSNumber)?.intValue ?? (args["frameCount"] as? Int)
      else {
        result(FlutterError(code: "bad_args", message: "stats parameters missing", details: nil))
        return
      }
      updateScrollingHud(height: height, frameCount: frameCount)
      result(true)

    case "closeScrollingHud":
      closeScrollingHud()
      result(true)

    case "simulateScroll":
      guard
        let args = call.arguments as? [String: Any],
        let deltaY = (args["deltaY"] as? NSNumber)?.int32Value ?? (args["deltaY"] as? Int32)
      else {
        result(nil)
        return
      }
      let scrollEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
      )
      if let xVal = (args["x"] as? NSNumber)?.doubleValue ?? (args["x"] as? Double),
         let yVal = (args["y"] as? NSNumber)?.doubleValue ?? (args["y"] as? Double) {
        scrollEvent?.location = CGPoint(x: CGFloat(xVal), y: CGFloat(yVal))
      }
      scrollEvent?.post(tap: .cghidEventTap)
      result(true)

    // Gene - Nov, 08, 2026: Added native NSPasteboard clipboard operations (eliminating osascript subprocess overhead) and native screen recording / video frame / trim methods.
    case "copyImageToClipboard":
      guard let args = call.arguments as? [String: Any] else {
        result(false)
        return
      }
      if let typedBytes = args["bytes"] as? FlutterStandardTypedData {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setData(typedBytes.data, forType: .png)
        result(ok)
        return
      }
      if let filePath = args["filePath"] as? String,
         let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setData(data, forType: .png)
        result(ok)
        return
      }
      result(false)

    case "pasteImageFromClipboard":
      guard
        let args = call.arguments as? [String: Any],
        let targetPath = args["targetPath"] as? String
      else {
        result(nil)
        return
      }
      let pb = NSPasteboard.general
      if let pngData = pb.data(forType: .png) {
        do {
          try pngData.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
          result(targetPath)
          return
        } catch {}
      }
      if let img = NSImage(pasteboard: pb),
         let tiffData = img.tiffRepresentation,
         let rep = NSBitmapImageRep(data: tiffData),
         let pngData = rep.representation(using: .png, properties: [:]) {
        do {
          try pngData.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
          result(targetPath)
          return
        } catch {}
      }
      result(nil)

    case "copyFileToClipboard":
      guard
        let args = call.arguments as? [String: Any],
        let filePath = args["filePath"] as? String
      else {
        result(false)
        return
      }
      let url = URL(fileURLWithPath: filePath) as NSURL
      let pb = NSPasteboard.general
      pb.clearContents()
      let ok = pb.writeObjects([url])
      result(ok)

    case "startScreenRecording":
      guard
        let args = call.arguments as? [String: Any],
        let targetPath = args["targetPath"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
        return
      }
      let thumbnailPath = (args["thumbnailPath"] as? String) ?? ""
      let fullScreen = (args["fullScreen"] as? Bool) ?? false
      let xVal = (args["x"] as? NSNumber)?.doubleValue ?? (args["x"] as? Double) ?? 0.0
      let yVal = (args["y"] as? NSNumber)?.doubleValue ?? (args["y"] as? Double) ?? 0.0
      let wVal = (args["width"] as? NSNumber)?.doubleValue ?? (args["width"] as? Double) ?? 0.0
      let hVal = (args["height"] as? NSNumber)?.doubleValue ?? (args["height"] as? Double) ?? 0.0
      let fps = (args["fps"] as? NSNumber)?.intValue ?? (args["fps"] as? Int) ?? 30
      let recordAudio = (args["recordAudio"] as? Bool) ?? false

      startNativeScreenRecording(
        targetPath: targetPath,
        thumbnailPath: thumbnailPath,
        fullScreen: fullScreen,
        rect: CGRect(x: xVal, y: yVal, width: wVal, height: hVal),
        fps: fps,
        recordAudio: recordAudio,
        result: result
      )

    case "pauseScreenRecording":
      recordingSession?.pause()
      updateRecordingHudState()
      result(true)

    case "resumeScreenRecording":
      recordingSession?.resume()
      updateRecordingHudState()
      result(true)

    case "stopScreenRecording":
      stopNativeScreenRecording(cancel: false, result: result)

    case "cancelScreenRecording":
      stopNativeScreenRecording(cancel: true, result: result)

    case "extractVideoFrame":
      guard
        let args = call.arguments as? [String: Any],
        let videoPath = args["videoPath"] as? String,
        let targetPath = args["targetPath"] as? String
      else {
        result(nil)
        return
      }
      let timestampMs = (args["timestampMs"] as? NSNumber)?.int64Value ?? (args["timestampMs"] as? Int64) ?? 0
      extractFrameFromVideo(videoPath: videoPath, timestampMs: timestampMs, targetPath: targetPath, result: result)

    case "trimVideo":
      guard
        let args = call.arguments as? [String: Any],
        let videoPath = args["videoPath"] as? String,
        let targetPath = args["targetPath"] as? String
      else {
        result(nil)
        return
      }
      let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? (args["startMs"] as? Int64) ?? 0
      let endMs = (args["endMs"] as? NSNumber)?.int64Value ?? (args["endMs"] as? Int64) ?? 0
      trimVideoFile(videoPath: videoPath, startMs: startMs, endMs: endMs, targetPath: targetPath, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Full Screen Capture

  private func captureFullScreen(targetPath: String, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let screen = NSScreen.main ?? NSScreen.screens.first
      guard let screen = screen else {
        result(FlutterError(code: "no_screen", message: "No active screen found", details: nil))
        return
      }

      guard let image = self.captureScreenImage(for: screen) else {
        result(FlutterError(code: "capture_failed", message: "Failed to capture screen image", details: nil))
        return
      }

      if self.saveImage(image, toPath: targetPath) {
        result(targetPath)
      } else {
        result(FlutterError(code: "save_failed", message: "Failed to save screenshot file", details: nil))
      }
    }
  }

  // MARK: - Interactive Capture

  // Gene - Oct, 27, 2026: Explicit weak self in outer DispatchQueue.main.async to eliminate Swift implicit-strong-capture warnings.
  // Old implementation:
  // private func startInteractiveCapture(targetPath: String, result: @escaping FlutterResult) {
  //   DispatchQueue.main.async {
  //     self.cleanup()
  //     self.activeResult = result
  // Gene - Nov, 08, 2026: Added initialMode and onRecordCapture callback to startInteractiveCapture so users can initiate Whole Screen or Area screen recording directly from the overlay.
  // Old implementation:
  // private func startInteractiveCapture(targetPath: String, result: @escaping FlutterResult) {
  //   DispatchQueue.main.async { [weak self] in
  private func startInteractiveCapture(targetPath: String, initialMode: String = "capture", result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.cleanup()
      self.activeResult = result

      let screens = NSScreen.screens
      if screens.isEmpty {
        self.finishWithResult(nil)
        return
      }

      // Pre-capture display images for each screen before showing overlays
      var screenImages: [NSScreen: CGImage] = [:]
      for screen in screens {
        if let img = self.captureScreenImage(for: screen) {
          screenImages[screen] = img
        }
      }

      // Create overlay window for each screen
      for screen in screens {
        let image = screenImages[screen]
        let overlayWindow = CaptureOverlayWindow(
          screen: screen,
          screenImage: image,
          initialMode: initialMode,
          onCapture: { [weak self] capturedImage in
            guard let self = self else { return }
            if let capturedImage = capturedImage, self.saveImage(capturedImage, toPath: targetPath) {
              self.finishWithResult(targetPath)
            } else {
              self.finishWithResult(nil)
            }
          },
          onPanoramicCapture: { [weak self] selRect in
            guard let self = self else { return }
            let screenFrame = screen.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
            let quartzX = screenFrame.origin.x + selRect.origin.x
            let quartzY = primaryHeight - (screenFrame.origin.y + selRect.origin.y + selRect.height)
            let quartzW = selRect.width
            let quartzH = selRect.height
            let resultString = String(format: "scrolling:%.1f:%.1f:%.1f:%.1f", quartzX, quartzY, quartzW, quartzH)
            self.finishWithResult(resultString)
            NSApp.windows.first?.orderOut(nil)
          },
          onRecordCapture: { [weak self] selRect in
            guard let self = self else { return }
            let screenFrame = screen.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
            let quartzX = screenFrame.origin.x + selRect.origin.x
            let quartzY = primaryHeight - (screenFrame.origin.y + selRect.origin.y + selRect.height)
            let quartzW = selRect.width
            let quartzH = selRect.height
            let resultString = String(format: "record:%.1f:%.1f:%.1f:%.1f", quartzX, quartzY, quartzW, quartzH)
            self.finishWithResult(resultString)
          },
          onCancel: { [weak self] in
            self?.finishWithResult(nil)
          }
        )
        self.activeWindows.append(overlayWindow)
        overlayWindow.orderFrontRegardless()
      }

      // Ensure first overlay window is key window to receive events
      // Deliberately no `NSApp.activate`. Activating a regular app brings its
      // main window's Space forward, which is the desktop — so it would switch
      // the user away from the full-screen app they meant to capture. The
      // non-activating panel takes key on its own, which is all the cancel
      // keys need.
      self.activeWindows.first?.makeKey()

      // Escape cancels; every other key is passed through so the overlay can
      // act on it. These used to cancel on *any* key press, which was fine
      // when a capture ended the instant the mouse came up — but the selection
      // is now adjustable and waits for a confirm, so Return has to survive
      // the trip to `CaptureOverlayView.keyDown`, and a stray keystroke must
      // not throw away a selection the user is still positioning.
      let escapeKeyCode: UInt16 = 53
      self.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        if event.keyCode == escapeKeyCode {
          self?.finishWithResult(nil)
          return nil
        }
        return event
      }

      // The global monitor only sees keys aimed at *other* apps, where there is
      // no selection to protect — but it still only cancels on Escape, so a
      // user typing elsewhere does not silently kill the overlay.
      self.globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        if event.keyCode == escapeKeyCode {
          self?.finishWithResult(nil)
        }
      }
    }
  }

  private func finishWithResult(_ value: Any?) {
    DispatchQueue.main.async {
      let res = self.activeResult
      self.activeResult = nil
      self.cleanup()
      res?(value)
    }
  }

  private func cleanup() {
    if let local = localKeyMonitor {
      NSEvent.removeMonitor(local)
      localKeyMonitor = nil
    }
    if let global = globalKeyMonitor {
      NSEvent.removeMonitor(global)
      globalKeyMonitor = nil
    }
    for window in activeWindows {
      window.orderOut(nil)
    }
    activeWindows.removeAll()
  }

  // MARK: - Screen Capture Helper

  private func captureScreenImage(for screen: NSScreen) -> CGImage? {
    if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      let displayID = CGDirectDisplayID(screenNumber.uint32Value)
      if let image = CGDisplayCreateImage(displayID) {
        return image
      }
    }

    // Fallback: window list capture for screen bounds
    let screenFrame = screen.frame
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
    let cgRect = CGRect(
      x: screenFrame.origin.x,
      y: primaryHeight - screenFrame.origin.y - screenFrame.height,
      width: screenFrame.width,
      height: screenFrame.height
    )
    return CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
  }

  // MARK: - Save PNG Helper

  // Gene - Oct, 27, 2026: Added showScrollingHud, updateScrollingHud, and closeScrollingHud for native floating HUD and viewport outline.
  private func showScrollingHud(for rect: CGRect) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.closeScrollingHudInternal()

      let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
      let appKitY = primaryHeight - (rect.origin.y + rect.height)
      let guideFrame = NSRect(x: rect.origin.x, y: appKitY, width: rect.width, height: rect.height)

      let guideWin = ScrollingGuideWindow(contentRect: guideFrame)
      self.scrollingGuideWindow = guideWin
      guideWin.orderFrontRegardless()

      let hudW: CGFloat = 310
      let hudH: CGFloat = 38
      var hudY = guideFrame.minY - hudH - 10
      if hudY < 20 {
        hudY = min(guideFrame.maxY + 10, primaryHeight - hudH - 20)
      }
      let screenWidth = NSScreen.screens.first?.frame.width ?? 1920
      let hudX = max(10, min(guideFrame.midX - hudW / 2, screenWidth - hudW - 10))
      let hudFrame = NSRect(x: hudX, y: hudY, width: hudW, height: hudH)

      let hudWin = ScrollingHudWindow(
        contentRect: hudFrame,
        onDone: { [weak self] in
          self?.finishScrollingSession()
        },
        onCancel: { [weak self] in
          self?.cancelScrollingSession()
        }
      )
      self.scrollingHudWindow = hudWin
      hudWin.orderFrontRegardless()

      let escapeKeyCode: UInt16 = 53
      let returnKeyCode: UInt16 = 36
      let numpadEnterKeyCode: UInt16 = 76
      self.scrollingKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        if event.keyCode == escapeKeyCode {
          self?.cancelScrollingSession()
        } else if event.keyCode == returnKeyCode || event.keyCode == numpadEnterKeyCode {
          self?.finishScrollingSession()
        }
      }
      self.scrollingLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        if event.keyCode == escapeKeyCode {
          self?.cancelScrollingSession()
          return nil
        } else if event.keyCode == returnKeyCode || event.keyCode == numpadEnterKeyCode {
          self?.finishScrollingSession()
          return nil
        }
        return event
      }
    }
  }

  private func finishScrollingSession() {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onScrollingDone", arguments: nil)
    }
  }

  private func cancelScrollingSession() {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onScrollingCancel", arguments: nil)
    }
  }

  private func updateScrollingHud(height: Int, frameCount: Int) {
    DispatchQueue.main.async { [weak self] in
      if let hudView = self?.scrollingHudWindow?.contentView as? ScrollingHudView {
        hudView.update(height: height, frameCount: frameCount)
      }
    }
  }

  private func closeScrollingHudInternal() {
    if let local = scrollingLocalKeyMonitor {
      NSEvent.removeMonitor(local)
      scrollingLocalKeyMonitor = nil
    }
    if let global = scrollingKeyMonitor {
      NSEvent.removeMonitor(global)
      scrollingKeyMonitor = nil
    }
    scrollingGuideWindow?.orderOut(nil)
    scrollingGuideWindow = nil
    scrollingHudWindow?.orderOut(nil)
    scrollingHudWindow = nil
  }

  private func closeScrollingHud() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.closeScrollingHudInternal()

      // Restore and activate SnipSnap's main window now that scrolling capture is complete
      if let mainWin = NSApp.windows.first {
        mainWin.makeKeyAndOrderFront(nil)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  // MARK: - Native Screen & Area Recording (AVAssetWriter H.264 MP4)

  // Gene - Nov, 08, 2026: Added startNativeScreenRecording, stopNativeScreenRecording, updateRecordingHudState, extractFrameFromVideo, and trimVideoFile.
  private func startNativeScreenRecording(
    targetPath: String,
    thumbnailPath: String,
    fullScreen: Bool,
    rect: CGRect,
    fps: Int,
    recordAudio: Bool,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.recordingSession != nil {
        result(FlutterError(code: "already_recording", message: "Screen recording is already active", details: nil))
        return
      }

      let primaryScreen = NSScreen.main ?? NSScreen.screens.first
      let scale = primaryScreen?.backingScaleFactor ?? 2.0
      let screenFrame = primaryScreen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

      let pointRect: CGRect
      if fullScreen || rect.width < 10 || rect.height < 10 {
        pointRect = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
      } else {
        // Incoming rect from captureInteractive is in Retina pixel coordinates
        pointRect = CGRect(
          x: rect.origin.x / scale,
          y: rect.origin.y / scale,
          width: rect.width / scale,
          height: rect.height / scale
        )
      }

      let session = MacScreenRecordingSession(
        targetPath: targetPath,
        thumbnailPath: thumbnailPath,
        pointRect: pointRect,
        scale: scale,
        fps: max(15, min(60, fps)),
        recordAudio: recordAudio,
        onTick: { [weak self] elapsedMs, isPaused in
          DispatchQueue.main.async {
            if let hudView = self?.recordingHudWindow?.contentView as? RecordingHudView {
              hudView.update(elapsedMs: elapsedMs, isPaused: isPaused)
            }
          }
        }
      )

      guard session.start() else {
        result(FlutterError(code: "record_start_failed", message: "Failed to initialize AVAssetWriter session", details: nil))
        return
      }

      self.recordingSession = session
      self.showRecordingHud(for: pointRect, fullScreen: fullScreen)
      result(true)
    }
  }

  private func showRecordingHud(for pointRect: CGRect, fullScreen: Bool) {
    closeRecordingHudInternal()

    let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
    let screenWidth = NSScreen.screens.first?.frame.width ?? 1920.0
    let appKitY = primaryHeight - (pointRect.origin.y + pointRect.height)
    let guideFrame = NSRect(x: pointRect.origin.x, y: appKitY, width: pointRect.width, height: pointRect.height)

    if !fullScreen {
      let guideWin = ScrollingGuideWindow(contentRect: guideFrame)
      guideWin.sharingType = .none
      self.recordingGuideWindow = guideWin
      guideWin.orderFrontRegardless()
    }

    let hudW: CGFloat = 320
    let hudH: CGFloat = 40
    var hudY: CGFloat
    let hudX: CGFloat
    if fullScreen {
      hudX = max(16, screenWidth - hudW - 24)
      hudY = 28
    } else {
      hudY = guideFrame.minY - hudH - 10
      if hudY < 20 {
        hudY = min(guideFrame.maxY + 10, primaryHeight - hudH - 20)
      }
      hudX = max(10, min(guideFrame.midX - hudW / 2, screenWidth - hudW - 10))
    }

    let hudWin = RecordingHudWindow(
      contentRect: NSRect(x: hudX, y: hudY, width: hudW, height: hudH),
      onTogglePause: { [weak self] in
        guard let self = self, let session = self.recordingSession else { return }
        if session.isPaused {
          session.resume()
        } else {
          session.pause()
        }
        self.updateRecordingHudState()
        self.channel?.invokeMethod("onRecordingStateChanged", arguments: ["isPaused": session.isPaused])
      },
      onStop: { [weak self] in
        guard let self = self else { return }
        self.stopNativeScreenRecording(cancel: false) { info in
          self.channel?.invokeMethod("onRecordingStopped", arguments: info)
        }
      },
      onCancel: { [weak self] in
        guard let self = self else { return }
        self.stopNativeScreenRecording(cancel: true) { _ in
          self.channel?.invokeMethod("onRecordingCancelled", arguments: nil)
        }
      }
    )
    hudWin.sharingType = .none
    self.recordingHudWindow = hudWin
    hudWin.orderFrontRegardless()
  }

  private func updateRecordingHudState() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let session = self.recordingSession else { return }
      if let hudView = self.recordingHudWindow?.contentView as? RecordingHudView {
        hudView.update(elapsedMs: session.currentElapsedMs(), isPaused: session.isPaused)
      }
    }
  }

  private func closeRecordingHudInternal() {
    recordingGuideWindow?.orderOut(nil)
    recordingGuideWindow = nil
    recordingHudWindow?.orderOut(nil)
    recordingHudWindow = nil
  }

  private func stopNativeScreenRecording(cancel: Bool, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.closeRecordingHudInternal()
      guard let session = self.recordingSession else {
        result(nil)
        return
      }
      self.recordingSession = nil
      session.stop(cancel: cancel) { info in
        DispatchQueue.main.async {
          if let mainWin = NSApp.windows.first {
            mainWin.makeKeyAndOrderFront(nil)
          }
          NSApp.activate(ignoringOtherApps: true)
          result(info)
        }
      }
    }
  }

  private func extractFrameFromVideo(
    videoPath: String,
    timestampMs: Int64,
    targetPath: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = CMTime(value: 50, timescale: 1000)
      generator.requestedTimeToleranceAfter = CMTime(value: 50, timescale: 1000)
      let time = CMTime(value: max(0, timestampMs), timescale: 1000)
      do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let ok = self.saveImage(cgImage, toPath: targetPath)
        DispatchQueue.main.async {
          result(ok ? targetPath : nil)
        }
      } catch {
        DispatchQueue.main.async {
          result(nil)
        }
      }
    }
  }

  private func trimVideoFile(
    videoPath: String,
    startMs: Int64,
    endMs: Int64,
    targetPath: String,
    result: @escaping FlutterResult
  ) {
    let inputURL = URL(fileURLWithPath: videoPath)
    let outputURL = URL(fileURLWithPath: targetPath)
    try? FileManager.default.removeItem(at: outputURL)

    let asset = AVURLAsset(url: inputURL)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      result(nil)
      return
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    let startTime = CMTime(value: max(0, startMs), timescale: 1000)
    let endTime = CMTime(value: max(startMs + 100, endMs), timescale: 1000)
    exportSession.timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)

    exportSession.exportAsynchronously {
      DispatchQueue.main.async {
        if exportSession.status == .completed {
          result(targetPath)
        } else {
          result(nil)
        }
      }
    }
  }

  private func saveImage(_ image: CGImage, toPath path: String) -> Bool {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      return false
    }
    let url = URL(fileURLWithPath: path)
    do {
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }
}

// MARK: - Capture Overlay Window

/// A non-activating panel, not a window — and that distinction is the whole
/// fix for capture over a full-screen app.
///
/// A full-screen app owns its own Space. When a regular `NSWindow` is ordered
/// front while that Space is active, the window server places it on *its own
/// app's* Space instead, so the overlay was never on screen at all: every
/// level from `.screenSaver` to the shielding level, with and without
/// activation, landed on the desktop behind Chrome or Android Studio. Measured
/// directly — seven `NSWindow` variants, all off the active Space, none
/// receiving a click. An `NSPanel` with `.nonactivatingPanel` is what the
/// screenshot tools that do work over full-screen apps use, and every variant
/// of it passed the same test: on screen, on the active Space, key, click
/// delivered. Nothing else about the configuration mattered.
private class CaptureOverlayWindow: NSPanel {
  // Gene - Oct, 27, 2026: Added onPanoramicCapture parameter to CaptureOverlayWindow.
  // Old implementation:
  // init(
  //   screen: NSScreen,
  //   screenImage: CGImage?,
  //   onCapture: @escaping (CGImage?) -> Void,
  //   onCancel: @escaping () -> Void
  // ) {
  //   super.init(
  //     contentRect: screen.frame,
  //     styleMask: [.borderless, .nonactivatingPanel],
  //     backing: .buffered,
  //     defer: false
  //   )
  //
  //   self.isOpaque = false
  //   self.backgroundColor = .clear
  //   self.level = .screenSaver
  //   self.hasShadow = false
  //   self.ignoresMouseEvents = false
  //   self.acceptsMouseMovedEvents = true
  //   self.hidesOnDeactivate = false
  //   self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
  //
  //   let view = CaptureOverlayView(
  //     frame: NSRect(origin: .zero, size: screen.frame.size),
  //     screenImage: screenImage,
  //     scaleFactor: screen.backingScaleFactor,
  //     onCapture: onCapture,
  //     onCancel: onCancel
  //   )
  //   self.contentView = view
  // }
  // Gene - Nov, 08, 2026: Added initialMode and onRecordCapture parameters to CaptureOverlayWindow.
  init(
    screen: NSScreen,
    screenImage: CGImage?,
    initialMode: String = "capture",
    onCapture: @escaping (CGImage?) -> Void,
    onPanoramicCapture: ((NSRect) -> Void)? = nil,
    onRecordCapture: ((NSRect) -> Void)? = nil,
    onCancel: @escaping () -> Void
  ) {
    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .screenSaver
    self.hasShadow = false
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = true
    // Not `isFloatingPanel`: that convenience silently resets `level` to
    // `.floating`, undoing the line above.
    // A panel hides itself when its app deactivates by default. This one must
    // outlive that: the app is *not* activated to show it, precisely so the
    // user's full-screen Space stays where it is.
    self.hidesOnDeactivate = false
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let view = CaptureOverlayView(
      frame: NSRect(origin: .zero, size: screen.frame.size),
      screenImage: screenImage,
      scaleFactor: screen.backingScaleFactor,
      initialMode: initialMode,
      onCapture: onCapture,
      onPanoramicCapture: onPanoramicCapture,
      onRecordCapture: onRecordCapture,
      onCancel: onCancel
    )
    self.contentView = view
  }

  // Key but never main: key is what routes the cancel keys here, and a
  // non-activating panel can take it without the app becoming active. Main
  // would drag the rest of the app — and its Space — along with it.
  override var canBecomeKey: Bool {
    return true
  }

  override var canBecomeMain: Bool {
    return false
  }
}

// MARK: - Capture Overlay View

/// Which part of a settled selection a press landed on.
private enum SelectionGrip {
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
  case body
}

/// What the overlay is currently doing.
private enum OverlayMode {
  /// Nothing selected yet — drag to draw one.
  case idle
  /// Rubber-banding a new selection.
  case drawing
  /// A selection exists and is waiting to be confirmed. Nothing has been
  /// captured yet, and this is the state the overlay sits in indefinitely.
  case adjusting
  /// Sliding the whole selection.
  case moving
  /// Dragging one grip.
  case resizing(SelectionGrip)
}

/// Full-screen capture overlay.
///
/// The capture used to fire on mouse-up, which meant the region you got was
/// whatever you happened to release on: no chance to nudge an edge, and no way
/// back except taking the shot again. Releasing now *settles* the selection
/// instead — it stays on screen with grips on every edge and corner, a Capture
/// button beside it, and nothing is grabbed until that button (or Return) is
/// pressed.
private class CaptureOverlayView: NSView {
  private let screenImage: CGImage?
  private let scaleFactor: CGFloat
  // Gene - Nov, 08, 2026: Added initialMode and onRecordCapture to support unified Capture + Record overlay.
  private let initialMode: String
  private let onCapture: (CGImage?) -> Void
  // Gene - Oct, 27, 2026: Added onPanoramicCapture callback.
  private let onPanoramicCapture: ((NSRect) -> Void)?
  private let onRecordCapture: ((NSRect) -> Void)?
  private let onCancel: () -> Void

  private var mode: OverlayMode = .idle

  /// The live selection, in view coordinates. Present from the first drag
  /// onward; `mode` says whether it is being drawn, adjusted or moved.
  private var selection: NSRect?

  /// Pointer position and selection geometry when the current drag began, so
  /// moves and resizes are computed as deltas rather than accumulating error.
  private var dragOrigin: NSPoint = .zero
  private var selectionAtDragStart: NSRect = .zero

  /// Where the Capture button was last drawn, for hit testing. Recomputed on
  /// every draw because it tracks the selection around the screen.
  private var captureButtonRect: NSRect = .zero
  private var captureButtonHot = false

  // Gene - Oct, 27, 2026: Added panoramicButtonRect and hot tracking.
  private var panoramicButtonRect: NSRect = .zero
  private var panoramicButtonHot = false

  // Gene - Nov, 08, 2026: Added recordButtonRect and hot tracking for the Record button in the overlay.
  private var recordButtonRect: NSRect = .zero
  private var recordButtonHot = false

  /// Where the cancel control was last drawn. Escape and right-click already
  /// cancel, but neither announces itself — this is the visible way out.
  private var cancelButtonRect: NSRect = .zero
  private var cancelButtonHot = false

  private let gripSize: CGFloat = 10
  private let minSelectionSide: CGFloat = 8

  // MARK: - Palette
  //
  // Coffee, not the stock system blue. The backdrop wash is warm rather than
  // neutral black, which reads as a tint over the desktop instead of a grey
  // veil — and because the selection itself is knocked clear, the region being
  // captured still shows its true colours.

  /// Roasted brown: selection outline, grip strokes, Capture button fill.
  private let coffee = NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 1.0)
  /// Crema: the lighter warm tone the button lifts to on hover.
  private let crema = NSColor(red: 0.784, green: 0.635, blue: 0.478, alpha: 1.0)
  /// Crimson record accent for the Record pill button.
  private let crimson = NSColor(red: 0.76, green: 0.18, blue: 0.18, alpha: 1.0)
  /// Warm espresso wash over everything outside the selection.
  private let backdrop = NSColor(red: 0.13, green: 0.09, blue: 0.06, alpha: 0.42)
  /// Near-black bean for the dimension badge.
  private let bean = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.88)

  private var hasSettled = false

  // Gene - Nov, 08, 2026: Updated CaptureOverlayView initializer to accept initialMode and onRecordCapture.
  init(
    frame: NSRect,
    screenImage: CGImage?,
    scaleFactor: CGFloat,
    initialMode: String = "capture",
    onCapture: @escaping (CGImage?) -> Void,
    onPanoramicCapture: ((NSRect) -> Void)? = nil,
    onRecordCapture: ((NSRect) -> Void)? = nil,
    onCancel: @escaping () -> Void
  ) {
    self.screenImage = screenImage
    self.scaleFactor = scaleFactor
    self.initialMode = initialMode
    self.onCapture = onCapture
    self.onPanoramicCapture = onPanoramicCapture
    self.onRecordCapture = onRecordCapture
    self.onCancel = onCancel
    super.init(frame: frame)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool {
    return true
  }

  /// Act on the very first click, rather than swallowing it to activate.
  ///
  /// AppKit's default is to consume the click that brings an inactive app
  /// forward. A capture triggered by its global hotkey is *always* that case —
  /// the user is in some other app — so the press that started the selection
  /// never reached `mouseDown`. Clicking captured nothing (the unpaired
  /// mouse-up cancels) and dragging drew no region, which is to say the
  /// shortcut only worked when SnipSnap already happened to be frontmost.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return true
  }

  // MARK: - Tracking

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseMoved, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
    )
  }

  // Gene - Oct, 27, 2026: Updated mouseMoved and resetCursorRects to track panoramicButtonRect.
  // Old implementation:
  // override func mouseMoved(with event: NSEvent) {
  //   let point = convert(event.locationInWindow, from: nil)
  //   let captureHot = !captureButtonRect.isEmpty && captureButtonRect.contains(point)
  //   let cancelHot = !cancelButtonRect.isEmpty && cancelButtonRect.contains(point)
  //   if captureHot != captureButtonHot || cancelHot != cancelButtonHot {
  //     captureButtonHot = captureHot
  //     cancelButtonHot = cancelHot
  //     needsDisplay = true
  //   }
  // }
  //
  // override func resetCursorRects() {
  //   addCursorRect(bounds, cursor: .crosshair)
  //
  //   guard case .adjusting = mode, let sel = selection else { return }
  //   addCursorRect(sel, cursor: .openHand)
  //   for (grip, rect) in gripRects(for: sel) {
  //     addCursorRect(rect, cursor: cursor(for: grip))
  //   }
  //   if !captureButtonRect.isEmpty {
  //     addCursorRect(captureButtonRect, cursor: .pointingHand)
  //   }
  //   if !cancelButtonRect.isEmpty {
  //     addCursorRect(cancelButtonRect, cursor: .pointingHand)
  //   }
  // }
  // Gene - Oct, 30, 2026: Switched off panoramicButtonHot tracking and cursor rect for beta testing.
  // Old implementation:
  // override func mouseMoved(with event: NSEvent) {
  //   let point = convert(event.locationInWindow, from: nil)
  //   let captureHot = !captureButtonRect.isEmpty && captureButtonRect.contains(point)
  //   let panoramicHot = !panoramicButtonRect.isEmpty && panoramicButtonRect.contains(point)
  //   let cancelHot = !cancelButtonRect.isEmpty && cancelButtonRect.contains(point)
  //   if captureHot != captureButtonHot || panoramicHot != panoramicButtonHot || cancelHot != cancelButtonHot {
  //     captureButtonHot = captureHot
  //     panoramicButtonHot = panoramicHot
  //     cancelButtonHot = cancelHot
  //     needsDisplay = true
  //   }
  // }
  //
  // override func resetCursorRects() {
  //   addCursorRect(bounds, cursor: .crosshair)
  //
  //   guard case .adjusting = mode, let sel = selection else { return }
  //   addCursorRect(sel, cursor: .openHand)
  //   for (grip, rect) in gripRects(for: sel) {
  //     addCursorRect(rect, cursor: cursor(for: grip))
  //   }
  //   if !captureButtonRect.isEmpty {
  //     addCursorRect(captureButtonRect, cursor: .pointingHand)
  //   }
  //   if !panoramicButtonRect.isEmpty {
  //     addCursorRect(panoramicButtonRect, cursor: .pointingHand)
  //   }
  //   if !cancelButtonRect.isEmpty {
  //     addCursorRect(cancelButtonRect, cursor: .pointingHand)
  //   }
  // }
  // Gene - Nov, 08, 2026: Track hover and cursor rects for recordButtonRect alongside captureButtonRect and cancelButtonRect.
  // Old implementation:
  // override func mouseMoved(with event: NSEvent) {
  //   let point = convert(event.locationInWindow, from: nil)
  //   let captureHot = !captureButtonRect.isEmpty && captureButtonRect.contains(point)
  //   let cancelHot = !cancelButtonRect.isEmpty && cancelButtonRect.contains(point)
  //   if captureHot != captureButtonHot || cancelHot != cancelButtonHot {
  //     captureButtonHot = captureHot
  //     cancelButtonHot = cancelHot
  //     needsDisplay = true
  //   }
  // }
  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let captureHot = !captureButtonRect.isEmpty && captureButtonRect.contains(point)
    let recordHot = !recordButtonRect.isEmpty && recordButtonRect.contains(point)
    let cancelHot = !cancelButtonRect.isEmpty && cancelButtonRect.contains(point)
    if captureHot != captureButtonHot || recordHot != recordButtonHot || cancelHot != cancelButtonHot {
      captureButtonHot = captureHot
      recordButtonHot = recordHot
      cancelButtonHot = cancelHot
      needsDisplay = true
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)

    guard case .adjusting = mode, let sel = selection else { return }
    addCursorRect(sel, cursor: .openHand)
    for (grip, rect) in gripRects(for: sel) {
      addCursorRect(rect, cursor: cursor(for: grip))
    }
    if !captureButtonRect.isEmpty {
      addCursorRect(captureButtonRect, cursor: .pointingHand)
    }
    if !recordButtonRect.isEmpty {
      addCursorRect(recordButtonRect, cursor: .pointingHand)
    }
    if !cancelButtonRect.isEmpty {
      addCursorRect(cancelButtonRect, cursor: .pointingHand)
    }
  }

  private func cursor(for grip: SelectionGrip) -> NSCursor {
    switch grip {
    case .left, .right: return .resizeLeftRight
    case .top, .bottom: return .resizeUpDown
    default: return .crosshair
    }
  }

  private func refreshChrome() {
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  // MARK: - Geometry

  private func gripRects(for sel: NSRect) -> [(SelectionGrip, NSRect)] {
    let h = gripSize
    func box(_ cx: CGFloat, _ cy: CGFloat) -> NSRect {
      NSRect(x: cx - h / 2, y: cy - h / 2, width: h, height: h)
    }
    return [
      (.bottomLeft, box(sel.minX, sel.minY)),
      (.bottom, box(sel.midX, sel.minY)),
      (.bottomRight, box(sel.maxX, sel.minY)),
      (.right, box(sel.maxX, sel.midY)),
      (.topRight, box(sel.maxX, sel.maxY)),
      (.top, box(sel.midX, sel.maxY)),
      (.topLeft, box(sel.minX, sel.maxY)),
      (.left, box(sel.minX, sel.midY)),
    ]
  }

  /// Grips first, then the body — a corner grip overlaps the body and the user
  /// aiming at it means to resize.
  private func grip(at point: NSPoint, in sel: NSRect) -> SelectionGrip? {
    for (grip, rect) in gripRects(for: sel) where rect.insetBy(dx: -3, dy: -3).contains(point) {
      return grip
    }
    return sel.contains(point) ? .body : nil
  }

  private func resized(_ rect: NSRect, grip: SelectionGrip, by delta: NSSize) -> NSRect {
    var minX = rect.minX, maxX = rect.maxX
    var minY = rect.minY, maxY = rect.maxY

    switch grip {
    case .left, .topLeft, .bottomLeft: minX += delta.width
    case .right, .topRight, .bottomRight: maxX += delta.width
    default: break
    }
    switch grip {
    case .bottom, .bottomLeft, .bottomRight: minY += delta.height
    case .top, .topLeft, .topRight: maxY += delta.height
    default: break
    }

    // Normalised so dragging an edge past its opposite flips rather than
    // collapsing to nothing.
    let r = NSRect(
      x: min(minX, maxX),
      y: min(minY, maxY),
      width: abs(maxX - minX),
      height: abs(maxY - minY)
    )
    return clamped(r)
  }

  private func clamped(_ rect: NSRect) -> NSRect {
    var r = rect.intersection(bounds)
    if r.isNull { r = .zero }
    return r
  }

  private func moved(_ rect: NSRect, by delta: NSSize) -> NSRect {
    var r = rect.offsetBy(dx: delta.width, dy: delta.height)
    if r.minX < bounds.minX { r.origin.x = bounds.minX }
    if r.minY < bounds.minY { r.origin.y = bounds.minY }
    if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
    if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
    return r
  }

  private func isUsable(_ rect: NSRect) -> Bool {
    rect.width >= minSelectionSide && rect.height >= minSelectionSide
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    dragOrigin = point

    if case .adjusting = mode, let sel = selection {
      if !cancelButtonRect.isEmpty && cancelButtonRect.contains(point) {
        settleCancelled()
        return
      }
      if !captureButtonRect.isEmpty && captureButtonRect.contains(point) {
        captureCurrentSelection()
        return
      }
      // Gene - Nov, 08, 2026: Handle click on Record button in interactive overlay.
      if !recordButtonRect.isEmpty && recordButtonRect.contains(point) {
        startRecordSelection()
        return
      }
      // Gene - Oct, 30, 2026: Switched off panoramic capture button handling in overlay for beta testing.
      // Old implementation:
      // // Gene - Oct, 27, 2026: Check click on panoramicButtonRect to trigger panoramic capture.
      // if !panoramicButtonRect.isEmpty && panoramicButtonRect.contains(point) {
      //   startPanoramicCapture()
      //   return
      // }
      if let grip = grip(at: point, in: sel) {
        selectionAtDragStart = sel
        mode = (grip == .body) ? .moving : .resizing(grip)
        refreshChrome()
        return
      }
      // Fell through: the press was outside the selection, which starts a
      // fresh one rather than capturing.
    }

    selection = NSRect(origin: point, size: .zero)
    mode = .drawing
    refreshChrome()
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let delta = NSSize(width: point.x - dragOrigin.x, height: point.y - dragOrigin.y)

    switch mode {
    case .drawing:
      selection = clamped(normalizedRect(from: dragOrigin, to: point))
    case .moving:
      selection = moved(selectionAtDragStart, by: delta)
    case .resizing(let grip):
      selection = resized(selectionAtDragStart, grip: grip, by: delta)
    case .idle, .adjusting:
      return
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    switch mode {
    case .drawing:
      guard let sel = selection else {
        settleCancelled()
        return
      }
      // A click with no meaningful drag still means "the whole screen", the
      // shortcut this overlay has always had. It is the one path that captures
      // without a confirm, and only from `idle` — once a selection exists, a
      // click outside it starts a new one instead (see `mouseDown`), so a
      // stray click can no longer grab the whole desktop by accident.
      // Gene - Nov, 08, 2026: When initialMode is "record", a single click without drag starts recording the whole screen; otherwise it captures the whole screen.
      // Old implementation:
      // if !isUsable(sel) {
      //   selection = nil
      //   mode = .idle
      //   settle(with: screenImage)
      //   return
      // }
      if !isUsable(sel) {
        selection = nil
        mode = .idle
        if initialMode == "record" {
          settleRecord(with: bounds)
        } else {
          settle(with: screenImage)
        }
        return
      }
      mode = .adjusting
      refreshChrome()

    case .moving, .resizing:
      if let sel = selection, isUsable(sel) {
        mode = .adjusting
      } else {
        selection = nil
        mode = .idle
      }
      refreshChrome()

    case .idle, .adjusting:
      // An unpaired mouse-up with nothing in flight. Before the selection was
      // adjustable this had to cancel, because the Flutter side was awaiting a
      // result and nothing else resolved it — but now the overlay legitimately
      // sits idle waiting for input, so cancelling here would kill it on the
      // first stray click.
      break
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    settleCancelled()
  }

  override func keyDown(with event: NSEvent) {
    let escape: UInt16 = 53
    let returnKey: UInt16 = 36
    let keypadEnter: UInt16 = 76
    let space: UInt16 = 49

    switch event.keyCode {
    case escape:
      settleCancelled()
    case returnKey, keypadEnter, space:
      // Gene - Nov, 08, 2026: Confirm selection as Record if initialMode == "record", otherwise Capture.
      // Old implementation:
      // captureCurrentSelection()
      if initialMode == "record" {
        startRecordSelection()
      } else {
        captureCurrentSelection()
      }
    default:
      break
    }
  }

  // MARK: - Settling

  private func captureCurrentSelection() {
    guard let sel = selection, isUsable(sel) else { return }
    settle(with: croppedImage(for: sel) ?? screenImage)
  }

  // Gene - Nov, 08, 2026: Added startRecordSelection and settleRecord for initiating area/screen recording from the overlay.
  private func startRecordSelection() {
    guard let sel = selection, isUsable(sel) else { return }
    settleRecord(with: sel)
  }

  private func settleRecord(with rect: NSRect) {
    guard !hasSettled else { return }
    hasSettled = true
    mode = .idle
    onRecordCapture?(rect)
  }

  // Gene - Oct, 27, 2026: Added startPanoramicCapture to settle with selected rect for panoramic capture.
  private func startPanoramicCapture() {
    guard let sel = selection, isUsable(sel) else { return }
    settlePanoramic(with: sel)
  }

  private func settlePanoramic(with rect: NSRect) {
    guard !hasSettled else { return }
    hasSettled = true
    mode = .idle
    onPanoramicCapture?(rect)
  }

  /// Crops the pre-captured screen bitmap to [rect], which is in view
  /// coordinates: bottom-left origin, points not pixels.
  private func croppedImage(for rect: NSRect) -> CGImage? {
    guard let screenImage = screenImage else { return nil }

    let imgWidth = CGFloat(screenImage.width)
    let imgHeight = CGFloat(screenImage.height)
    let scaleX = imgWidth / bounds.width
    let scaleY = imgHeight / bounds.height

    // In NSView, (0, 0) is bottom-left. In CGImage, (0, 0) is top-left.
    let cropX = rect.minX * scaleX
    let cropY = (bounds.height - rect.maxY) * scaleY
    let cropWidth = rect.width * scaleX
    let cropHeight = rect.height * scaleY

    let cropRect = CGRect(
      x: max(0, cropX),
      y: max(0, cropY),
      width: min(imgWidth - cropX, cropWidth),
      height: min(imgHeight - cropY, cropHeight)
    )
    guard cropRect.width > 0 && cropRect.height > 0 else { return nil }
    return screenImage.cropping(to: cropRect)
  }

  /// Hands back a captured image, once.
  private func settle(with image: CGImage?) {
    guard !hasSettled else { return }
    hasSettled = true
    mode = .idle
    onCapture(image)
  }

  /// Cancels the capture, once.
  private func settleCancelled() {
    guard !hasSettled else { return }
    hasSettled = true
    mode = .idle
    onCancel()
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    backdrop.setFill()
    dirtyRect.fill()

    let showChrome: Bool
    switch mode {
    case .idle: showChrome = false
    default: showChrome = true
    }
    guard showChrome, let selRect = selection, selRect.width > 0, selRect.height > 0 else {
      captureButtonRect = .zero
      cancelButtonRect = .zero
      return
    }

    // Knock out selection area to reveal the bright desktop underneath
    NSGraphicsContext.current?.compositingOperation = .clear
    NSColor.clear.setFill()
    selRect.fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    let strokePath = NSBezierPath(rect: selRect)
    strokePath.lineWidth = 1.5
    NSColor.white.setStroke()
    strokePath.stroke()

    let accent = coffee
    if selRect.width > 3 && selRect.height > 3 {
      let innerPath = NSBezierPath(rect: selRect.insetBy(dx: 1, dy: 1))
      innerPath.lineWidth = 1.0
      accent.withAlphaComponent(0.9).setStroke()
      innerPath.stroke()
    }

    drawDimensionBadge(for: selRect)

    // Grips and the Capture button only once the selection has settled —
    // during the initial drag they would just chase the cursor.
    var settled = false
    if case .adjusting = mode { settled = true }
    if case .moving = mode { settled = true }
    if case .resizing = mode { settled = true }

    if settled {
      drawGrips(for: selRect, accent: accent)
      drawCaptureButton(for: selRect, accent: accent)
    } else {
      captureButtonRect = .zero
      panoramicButtonRect = .zero
      cancelButtonRect = .zero
    }
  }

  private func drawDimensionBadge(for selRect: NSRect) {
    guard selRect.width > 40 && selRect.height > 25 else { return }

    let pixelW = Int(selRect.width * scaleFactor)
    let pixelH = Int(selRect.height * scaleFactor)
    let text = "\(pixelW) × \(pixelH) px"

    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white
    ]
    let attrString = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrString.size()

    let padH: CGFloat = 7
    let padV: CGFloat = 3
    let badgeW = textSize.width + padH * 2
    let badgeH = textSize.height + padV * 2

    var badgeY = selRect.maxY + 6
    if badgeY + badgeH > bounds.height - 4 {
      badgeY = selRect.maxY - badgeH - 6
    }
    var badgeX = selRect.minX
    if badgeX + badgeW > bounds.width - 4 {
      badgeX = bounds.width - badgeW - 4
    }

    let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
    bean.setFill()
    NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
    attrString.draw(at: NSPoint(x: badgeX + padH, y: badgeY + padV))
  }

  private func drawGrips(for selRect: NSRect, accent: NSColor) {
    for (_, rect) in gripRects(for: selRect) {
      let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
      NSColor.white.setFill()
      path.fill()
      accent.setStroke()
      path.lineWidth = 1.5
      path.stroke()
    }
  }

  /// The Capture button: a pill just outside the selection, flipped to
  /// whichever side has room so it never sits off screen or over the region
  /// being captured.
  // Gene - Oct, 27, 2026: Added Panoramic capture button beside the Capture button in the interactive overlay.
  // Old implementation:
  // private func drawCaptureButton(for selRect: NSRect, accent: NSColor) {
  //   let label = "Capture"
  //   let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
  //   let attrs: [NSAttributedString.Key: Any] = [
  //     .font: font,
  //     .foregroundColor: NSColor.white
  //   ]
  //   let attrString = NSAttributedString(string: label, attributes: attrs)
  //   let textSize = attrString.size()
  //
  //   let iconW: CGFloat = 15
  //   let gap: CGFloat = 6
  //   let padH: CGFloat = 11
  //   let padV: CGFloat = 6
  //   let pillW = padH * 2 + iconW + gap + textSize.width
  //   let buttonH = max(textSize.height + padV * 2, 24)
  //   let margin: CGFloat = 8
  //   // Capture and cancel are placed as one block, so the edge-flipping below
  //   // can never leave the X off screen while Capture stays visible.
  //   let controlGap: CGFloat = 7
  //   let buttonW = pillW + controlGap + buttonH
  //
  //   // Below the selection by default, above it when that would run off the
  //   // bottom, and pulled inside when the selection reaches both edges.
  //   var y = selRect.minY - buttonH - margin
  //   if y < 4 {
  //     y = selRect.maxY + margin
  //   }
  //   if y + buttonH > bounds.height - 4 {
  //     y = max(4, selRect.minY + margin)
  //   }
  //   var x = selRect.maxX - buttonW
  //   if x < 4 { x = 4 }
  //   if x + buttonW > bounds.width - 4 { x = bounds.width - buttonW - 4 }
  //
  //   let block = NSRect(x: x, y: y, width: buttonW, height: buttonH)
  //   let rect = NSRect(x: block.minX, y: block.minY, width: pillW, height: buttonH)
  //   captureButtonRect = rect
  //   cancelButtonRect = NSRect(
  //     x: block.maxX - buttonH,
  //     y: block.minY,
  //     width: buttonH,
  //     height: buttonH
  //   )
  //
  //   let path = NSBezierPath(roundedRect: rect, xRadius: buttonH / 2, yRadius: buttonH / 2)
  //   (captureButtonHot ? accent.blended(withFraction: 0.35, of: crema) ?? accent : accent).setFill()
  //   path.fill()
  //   NSColor(white: 1.0, alpha: 0.35).setStroke()
  //   path.lineWidth = 1
  //   path.stroke()
  //
  //   drawCameraGlyph(
  //     in: NSRect(x: rect.minX + padH, y: rect.midY - 5.5, width: iconW, height: 11)
  //   )
  //   attrString.draw(
  //     at: NSPoint(x: rect.minX + padH + iconW + gap, y: rect.midY - textSize.height / 2)
  //   )
  //
  //   drawCancelButton(in: cancelButtonRect, accent: accent)
  // }
  private func drawCaptureButton(for selRect: NSRect, accent: NSColor) {
    let label = "Capture"
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white
    ]
    let attrString = NSAttributedString(string: label, attributes: attrs)
    let textSize = attrString.size()

    let iconW: CGFloat = 15
    let gap: CGFloat = 6
    let padH: CGFloat = 11
    let padV: CGFloat = 6
    let pillW = padH * 2 + iconW + gap + textSize.width
    let buttonH = max(textSize.height + padV * 2, 24)
    let margin: CGFloat = 8
    let controlGap: CGFloat = 7

    // Gene - Oct, 30, 2026: Switched off Panoramic button from selection overlay for beta testing.
    // Old implementation:
    // // Panoramic button metrics
    // let panoLabel = "Panoramic"
    // let panoAttrString = NSAttributedString(string: panoLabel, attributes: attrs)
    // let panoTextSize = panoAttrString.size()
    // let panoPillW = padH * 2 + iconW + gap + panoTextSize.width
    //
    // // Total width: [Capture] + [Panoramic] + [Cancel (X)]
    // let buttonW = pillW + controlGap + panoPillW + controlGap + buttonH
    //
    // // Below the selection by default, above it when that would run off the
    // // bottom, and pulled inside when the selection reaches both edges.
    // var y = selRect.minY - buttonH - margin
    // if y < 4 {
    //   y = selRect.maxY + margin
    // }
    // if y + buttonH > bounds.height - 4 {
    //   y = max(4, selRect.minY + margin)
    // }
    // var x = selRect.maxX - buttonW
    // if x < 4 { x = 4 }
    // if x + buttonW > bounds.width - 4 { x = bounds.width - buttonW - 4 }
    //
    // let block = NSRect(x: x, y: y, width: buttonW, height: buttonH)
    // let captureRect = NSRect(x: block.minX, y: block.minY, width: pillW, height: buttonH)
    // captureButtonRect = captureRect
    //
    // let panoRect = NSRect(x: block.minX + pillW + controlGap, y: block.minY, width: panoPillW, height: buttonH)
    // panoramicButtonRect = panoRect
    //
    // cancelButtonRect = NSRect(
    //   x: block.maxX - buttonH,
    //   y: block.minY,
    //   width: buttonH,
    //   height: buttonH
    // )
    //
    // // 1. Draw Capture button
    // let capturePath = NSBezierPath(roundedRect: captureRect, xRadius: buttonH / 2, yRadius: buttonH / 2)
    // (captureButtonHot ? accent.blended(withFraction: 0.35, of: crema) ?? accent : accent).setFill()
    // capturePath.fill()
    // NSColor(white: 1.0, alpha: 0.35).setStroke()
    // capturePath.lineWidth = 1
    // capturePath.stroke()
    //
    // drawCameraGlyph(
    //   in: NSRect(x: captureRect.minX + padH, y: captureRect.midY - 5.5, width: iconW, height: 11)
    // )
    // attrString.draw(
    //   at: NSPoint(x: captureRect.minX + padH + iconW + gap, y: captureRect.midY - textSize.height / 2)
    // )
    //
    // // 2. Draw Panoramic button beside Capture
    // let panoPath = NSBezierPath(roundedRect: panoRect, xRadius: buttonH / 2, yRadius: buttonH / 2)
    // (panoramicButtonHot ? accent.blended(withFraction: 0.35, of: crema) ?? accent : accent).setFill()
    // panoPath.fill()
    // NSColor(white: 1.0, alpha: 0.35).setStroke()
    // panoPath.lineWidth = 1
    // panoPath.stroke()
    //
    // drawPanoramicGlyph(
    //   in: NSRect(x: panoRect.minX + padH, y: panoRect.midY - 5.5, width: iconW, height: 11)
    // )
    // panoAttrString.draw(
    //   at: NSPoint(x: panoRect.minX + padH + iconW + gap, y: panoRect.midY - panoTextSize.height / 2)
    // )
    //
    // // 3. Draw Cancel (X) button
    // drawCancelButton(in: cancelButtonRect, accent: accent)

    // Gene - Nov, 08, 2026: Placed [Capture] + [Record] + [Cancel (X)] as one unified control block.
    // Old implementation:
    // // Capture and cancel are placed as one block: [Capture] + [Cancel (X)]
    // let buttonW = pillW + controlGap + buttonH
    let recLabel = "Record"
    let recAttrString = NSAttributedString(string: recLabel, attributes: attrs)
    let recTextSize = recAttrString.size()
    let recPillW = padH * 2 + iconW + gap + recTextSize.width

    let buttonW = pillW + controlGap + recPillW + controlGap + buttonH

    // Below the selection by default, above it when that would run off the
    // bottom, and pulled inside when the selection reaches both edges.
    var y = selRect.minY - buttonH - margin
    if y < 4 {
      y = selRect.maxY + margin
    }
    if y + buttonH > bounds.height - 4 {
      y = max(4, selRect.minY + margin)
    }
    var x = selRect.maxX - buttonW
    if x < 4 { x = 4 }
    if x + buttonW > bounds.width - 4 { x = bounds.width - buttonW - 4 }

    let block = NSRect(x: x, y: y, width: buttonW, height: buttonH)
    let captureRect = NSRect(x: block.minX, y: block.minY, width: pillW, height: buttonH)
    captureButtonRect = captureRect
    panoramicButtonRect = .zero

    let recRect = NSRect(x: block.minX + pillW + controlGap, y: block.minY, width: recPillW, height: buttonH)
    recordButtonRect = recRect

    cancelButtonRect = NSRect(
      x: block.maxX - buttonH,
      y: block.minY,
      width: buttonH,
      height: buttonH
    )

    // 1. Draw Capture button
    let capturePath = NSBezierPath(roundedRect: captureRect, xRadius: buttonH / 2, yRadius: buttonH / 2)
    (captureButtonHot ? accent.blended(withFraction: 0.35, of: crema) ?? accent : accent).setFill()
    capturePath.fill()
    NSColor(white: 1.0, alpha: 0.35).setStroke()
    capturePath.lineWidth = 1
    capturePath.stroke()

    drawCameraGlyph(
      in: NSRect(x: captureRect.minX + padH, y: captureRect.midY - 5.5, width: iconW, height: 11)
    )
    attrString.draw(
      at: NSPoint(x: captureRect.minX + padH + iconW + gap, y: captureRect.midY - textSize.height / 2)
    )

    // 2. Draw Record button beside Capture
    let recPath = NSBezierPath(roundedRect: recRect, xRadius: buttonH / 2, yRadius: buttonH / 2)
    (recordButtonHot ? crimson.blended(withFraction: 0.25, of: NSColor.white) ?? crimson : crimson).setFill()
    recPath.fill()
    NSColor(white: 1.0, alpha: 0.35).setStroke()
    recPath.lineWidth = 1
    recPath.stroke()

    let dotR: CGFloat = 9.0
    let dotRect = NSRect(x: recRect.minX + padH + (iconW - dotR) / 2, y: recRect.midY - dotR / 2, width: dotR, height: dotR)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    recAttrString.draw(
      at: NSPoint(x: recRect.minX + padH + iconW + gap, y: recRect.midY - recTextSize.height / 2)
    )

    // 3. Draw Cancel (X) button
    drawCancelButton(in: cancelButtonRect, accent: accent)
  }

  // Gene - Oct, 27, 2026: Glyph for Panoramic / Scrolling capture button.
  private func drawPanoramicGlyph(in rect: NSRect) {
    NSColor.white.setStroke()
    let path = NSBezierPath()
    let midX = rect.midX
    let midY = rect.midY
    let arrowW: CGFloat = 3.5
    let arrowH: CGFloat = 3.0

    // Up arrow
    path.move(to: NSPoint(x: midX - arrowW, y: midY + 1))
    path.line(to: NSPoint(x: midX, y: midY + 1 + arrowH))
    path.line(to: NSPoint(x: midX + arrowW, y: midY + 1))

    // Down arrow
    path.move(to: NSPoint(x: midX - arrowW, y: midY - 1))
    path.line(to: NSPoint(x: midX, y: midY - 1 - arrowH))
    path.line(to: NSPoint(x: midX + arrowW, y: midY - 1))

    path.lineWidth = 1.4
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
  }

  /// The way out, drawn quieter than Capture: this is the escape hatch, not
  /// the thing to reach for.
  private func drawCancelButton(in rect: NSRect, accent: NSColor) {
    let path = NSBezierPath(ovalIn: rect)
    (cancelButtonHot ? accent : bean).setFill()
    path.fill()
    NSColor(white: 1.0, alpha: 0.35).setStroke()
    path.lineWidth = 1
    path.stroke()

    let inset = rect.width * 0.32
    let box = rect.insetBy(dx: inset, dy: inset)
    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: box.minX, y: box.minY))
    cross.line(to: NSPoint(x: box.maxX, y: box.maxY))
    cross.move(to: NSPoint(x: box.minX, y: box.maxY))
    cross.line(to: NSPoint(x: box.maxX, y: box.minY))
    cross.lineWidth = 1.8
    cross.lineCapStyle = .round
    NSColor.white.setStroke()
    cross.stroke()
  }

  /// A small camera outline, drawn rather than pulled from SF Symbols so the
  /// button renders identically regardless of symbol availability or weight.
  private func drawCameraGlyph(in rect: NSRect) {
    NSColor.white.setStroke()

    let body = NSBezierPath(
      roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 2),
      xRadius: 2,
      yRadius: 2
    )
    body.lineWidth = 1.4
    body.stroke()

    let bumpW = rect.width * 0.34
    let bump = NSBezierPath(
      roundedRect: NSRect(
        x: rect.midX - bumpW / 2,
        y: rect.maxY - 3,
        width: bumpW,
        height: 3
      ),
      xRadius: 1,
      yRadius: 1
    )
    bump.lineWidth = 1.4
    bump.stroke()

    let lensD = rect.height * 0.46
    let lens = NSBezierPath(
      ovalIn: NSRect(
        x: rect.midX - lensD / 2,
        y: rect.midY - lensD / 2 - 1,
        width: lensD,
        height: lensD
      )
    )
    lens.lineWidth = 1.4
    lens.stroke()
  }

  /// Button geometry, for the behaviour harness in
  /// `tool/capture_overlay_harness`. Both are computed during `draw`, so a
  /// caller has to render the view before reading them.
  var captureButtonRectForTesting: NSRect { captureButtonRect }
  var cancelButtonRectForTesting: NSRect { cancelButtonRect }

  private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
    let x = min(p1.x, p2.x)
    let y = min(p1.y, p2.y)
    let w = abs(p1.x - p2.x)
    let h = abs(p1.y - p2.y)
    return NSRect(x: x, y: y, width: w, height: h)
  }
}

// MARK: - Native Floating Scrolling Capture HUD & Guide Frame

// Gene - Oct, 27, 2026: Native floating HUD and viewport outline classes for panoramic scrolling capture.

private class ScrollingGuideWindow: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .floating
    self.hasShadow = false
    self.ignoresMouseEvents = true
    self.hidesOnDeactivate = false
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let view = ScrollingGuideView(frame: NSRect(origin: .zero, size: contentRect.size))
    self.contentView = view
  }

  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

private class ScrollingGuideView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
    path.lineWidth = 2.0
    NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 0.9).setStroke()
    path.stroke()

    let outerPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    outerPath.lineWidth = 1.0
    NSColor.white.withAlphaComponent(0.6).setStroke()
    outerPath.stroke()
  }
}

private class ScrollingHudWindow: NSPanel {
  init(
    contentRect: NSRect,
    onDone: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .floating
    self.hasShadow = true
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = true
    self.hidesOnDeactivate = false
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let view = ScrollingHudView(
      frame: NSRect(origin: .zero, size: contentRect.size),
      onDone: onDone,
      onCancel: onCancel
    )
    self.contentView = view
  }

  override var canBecomeKey: Bool { return true }
  override var canBecomeMain: Bool { return false }
}

private class ScrollingHudView: NSView {
  private let onDone: () -> Void
  private let onCancel: () -> Void

  private var height: Int = 0
  private var frameCount: Int = 1
  private var doneHot = false
  private var cancelHot = false

  private var doneRect: NSRect = .zero
  private var cancelRect: NSRect = .zero

  private let bean = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.94)
  private let coffee = NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 1.0)
  private let crema = NSColor(red: 0.784, green: 0.635, blue: 0.478, alpha: 1.0)

  init(frame: NSRect, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
    self.onDone = onDone
    self.onCancel = onCancel
    super.init(frame: frame)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(height: Int, frameCount: Int) {
    self.height = height
    self.frameCount = frameCount
    self.needsDisplay = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseMoved, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
    )
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let dHot = !doneRect.isEmpty && doneRect.contains(point)
    let cHot = !cancelRect.isEmpty && cancelRect.contains(point)
    if dHot != doneHot || cHot != cancelHot {
      doneHot = dHot
      cancelHot = cHot
      needsDisplay = true
    }
  }

  override func resetCursorRects() {
    if !doneRect.isEmpty {
      addCursorRect(doneRect, cursor: .pointingHand)
    }
    if !cancelRect.isEmpty {
      addCursorRect(cancelRect, cursor: .pointingHand)
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !doneRect.isEmpty && doneRect.contains(point) {
      onDone()
      return
    }
    if !cancelRect.isEmpty && cancelRect.contains(point) {
      onCancel()
      return
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Pill container background
    let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
    bean.setFill()
    bgPath.fill()
    NSColor(white: 1.0, alpha: 0.25).setStroke()
    bgPath.lineWidth = 1.0
    bgPath.stroke()

    let midY = bounds.midY

    // 1. Red recording dot
    let dotD: CGFloat = 8
    let dotRect = NSRect(x: 14, y: midY - dotD / 2, width: dotD, height: dotD)
    let dotPath = NSBezierPath(ovalIn: dotRect)
    NSColor(red: 0.95, green: 0.26, blue: 0.21, alpha: 1.0).setFill()
    dotPath.fill()

    // 2. Height text
    let heightStr = "\(height) px"
    let heightAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
      .foregroundColor: NSColor.white
    ]
    let heightAttrStr = NSAttributedString(string: heightStr, attributes: heightAttrs)
    let heightSize = heightAttrStr.size()
    heightAttrStr.draw(at: NSPoint(x: 28, y: midY - heightSize.height / 2))

    // 3. Frames text
    let framesStr = "(\(frameCount) \(frameCount == 1 ? "frame" : "frames"))"
    let framesAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor(white: 1.0, alpha: 0.65)
    ]
    let framesAttrStr = NSAttributedString(string: framesStr, attributes: framesAttrs)
    let framesSize = framesAttrStr.size()
    let framesX = 28 + heightSize.width + 5
    framesAttrStr.draw(at: NSPoint(x: framesX, y: midY - framesSize.height / 2))

    // 4. Cancel (X) button at right
    let cancelD: CGFloat = 24
    let cancelX = bounds.maxX - cancelD - 7
    cancelRect = NSRect(x: cancelX, y: midY - cancelD / 2, width: cancelD, height: cancelD)
    let cancelPath = NSBezierPath(ovalIn: cancelRect)
    (cancelHot ? coffee : NSColor(white: 1.0, alpha: 0.15)).setFill()
    cancelPath.fill()
    NSColor(white: 1.0, alpha: 0.3).setStroke()
    cancelPath.lineWidth = 1.0
    cancelPath.stroke()

    // Draw X
    let inset = cancelD * 0.32
    let xBox = cancelRect.insetBy(dx: inset, dy: inset)
    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: xBox.minX, y: xBox.minY))
    cross.line(to: NSPoint(x: xBox.maxX, y: xBox.maxY))
    cross.move(to: NSPoint(x: xBox.minX, y: xBox.maxY))
    cross.line(to: NSPoint(x: xBox.maxX, y: xBox.minY))
    cross.lineWidth = 1.6
    cross.lineCapStyle = .round
    NSColor.white.setStroke()
    cross.stroke()

    // 5. Done button
    let doneH: CGFloat = 26
    let doneW: CGFloat = 72
    let doneX = cancelX - doneW - 6
    doneRect = NSRect(x: doneX, y: midY - doneH / 2, width: doneW, height: doneH)
    let donePath = NSBezierPath(roundedRect: doneRect, xRadius: doneH / 2, yRadius: doneH / 2)
    (doneHot ? coffee.blended(withFraction: 0.35, of: crema) ?? coffee : coffee).setFill()
    donePath.fill()
    NSColor(white: 1.0, alpha: 0.35).setStroke()
    donePath.lineWidth = 1.0
    donePath.stroke()

    // Checkmark icon + "Done"
    let checkmark = NSBezierPath()
    let checkX = doneRect.minX + 9
    checkmark.move(to: NSPoint(x: checkX, y: midY))
    checkmark.line(to: NSPoint(x: checkX + 3.5, y: midY - 3.5))
    checkmark.line(to: NSPoint(x: checkX + 9, y: midY + 4))
    checkmark.lineWidth = 1.6
    checkmark.lineCapStyle = .round
    checkmark.lineJoinStyle = .round
    NSColor.white.setStroke()
    checkmark.stroke()

    let doneLabel = "Done"
    let doneAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
      .foregroundColor: NSColor.white
    ]
    let doneAttrStr = NSAttributedString(string: doneLabel, attributes: doneAttrs)
    let doneSize = doneAttrStr.size()
    doneAttrStr.draw(at: NSPoint(x: checkX + 13, y: midY - doneSize.height / 2))
  }
}

// MARK: - Native Screen Recording Session & HUD (AVAssetWriter H.264 MP4)

// Gene - Nov, 08, 2026: Added MacScreenRecordingSession, RecordingHudWindow, and RecordingHudView for whole-screen and area H.264 MP4 recording.
private final class MacScreenRecordingSession {
  let targetPath: String
  let thumbnailPath: String
  let pointRect: CGRect
  let scale: CGFloat
  let fps: Int
  let recordAudio: Bool
  let onTick: (Int, Bool) -> Void

  private let writerQueue = DispatchQueue(label: "com.snipsnap.screenrecorder.writer", qos: .userInteractive)
  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var timer: DispatchSourceTimer?

  private(set) var isPaused: Bool = false
  private var isStopped: Bool = false
  private var startTimestampNs: UInt64 = 0
  private var pauseStartNs: UInt64 = 0
  private var totalPausedNs: UInt64 = 0
  private var frameIndex: Int64 = 0
  private var wroteThumbnail: Bool = false
  private(set) var pixelWidth: Int = 0
  private(set) var pixelHeight: Int = 0

  init(
    targetPath: String,
    thumbnailPath: String,
    pointRect: CGRect,
    scale: CGFloat,
    fps: Int,
    recordAudio: Bool,
    onTick: @escaping (Int, Bool) -> Void
  ) {
    self.targetPath = targetPath
    self.thumbnailPath = thumbnailPath
    self.pointRect = pointRect
    self.scale = scale
    self.fps = fps
    self.recordAudio = recordAudio
    self.onTick = onTick
    let rawW = max(64, Int((pointRect.width * scale).rounded()))
    let rawH = max(64, Int((pointRect.height * scale).rounded()))
    self.pixelWidth = rawW & ~1
    self.pixelHeight = rawH & ~1
  }

  func start() -> Bool {
    let url = URL(fileURLWithPath: targetPath)
    try? FileManager.default.removeItem(at: url)

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
      return false
    }

    let bitrate = max(2_500_000, pixelWidth * pixelHeight * 4)
    let compressionProps: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoMaxKeyFrameIntervalKey: fps * 2,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
    ]
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: pixelWidth,
      AVVideoHeightKey: pixelHeight,
      AVVideoCompressionPropertiesKey: compressionProps
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = true

    let sourceBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: pixelWidth,
      kCVPixelBufferHeightKey as String: pixelHeight,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: sourceBufferAttributes
    )

    guard writer.canAdd(input) else {
      return false
    }
    writer.add(input)

    guard writer.startWriting() else {
      return false
    }
    writer.startSession(atSourceTime: .zero)

    self.assetWriter = writer
    self.videoInput = input
    self.pixelBufferAdaptor = adaptor
    self.startTimestampNs = DispatchTime.now().uptimeNanoseconds

    let timerSource = DispatchSource.makeTimerSource(queue: writerQueue)
    let intervalNs = UInt64(1_000_000_000 / max(15, fps))
    timerSource.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .milliseconds(2))
    timerSource.setEventHandler { [weak self] in
      self?.captureTick()
    }
    self.timer = timerSource
    timerSource.resume()
    return true
  }

  func pause() {
    writerQueue.async { [weak self] in
      guard let self = self, !self.isPaused, !self.isStopped else { return }
      self.isPaused = true
      self.pauseStartNs = DispatchTime.now().uptimeNanoseconds
      self.onTick(self.currentElapsedMs(), true)
    }
  }

  func resume() {
    writerQueue.async { [weak self] in
      guard let self = self, self.isPaused, !self.isStopped else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      if now > self.pauseStartNs {
        self.totalPausedNs += (now - self.pauseStartNs)
      }
      self.isPaused = false
      self.onTick(self.currentElapsedMs(), false)
    }
  }

  func currentElapsedMs() -> Int {
    let now = DispatchTime.now().uptimeNanoseconds
    let effectiveNow = isPaused ? pauseStartNs : now
    guard effectiveNow > startTimestampNs + totalPausedNs else { return 0 }
    return Int((effectiveNow - startTimestampNs - totalPausedNs) / 1_000_000)
  }

  private func captureTick() {
    guard !isStopped else { return }
    let elapsed = currentElapsedMs()
    onTick(elapsed, isPaused)
    if isPaused { return }

    guard
      let input = videoInput,
      let adaptor = pixelBufferAdaptor,
      input.isReadyForMoreMediaData,
      let pool = adaptor.pixelBufferPool
    else {
      return
    }

    guard let cgImage = CGWindowListCreateImage(
      pointRect,
      .optionOnScreenOnly,
      kCGNullWindowID,
      .bestResolution
    ) else {
      return
    }

    if !wroteThumbnail && !thumbnailPath.isEmpty {
      wroteThumbnail = true
      let rep = NSBitmapImageRep(cgImage: cgImage)
      if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: thumbnailPath), options: .atomic)
      }
    }

    var pixelBufferOut: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
    guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
      return
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    if let context = CGContext(
      data: baseAddress,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) {
      context.interpolationQuality = .low
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      let presentationTime = CMTime(value: Int64(elapsed), timescale: 1000)
      adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
      frameIndex += 1
    }
  }

  func stop(cancel: Bool, completion: @escaping ([String: Any]?) -> Void) {
    writerQueue.async { [weak self] in
      guard let self = self else {
        completion(nil)
        return
      }
      if self.isStopped {
        completion(nil)
        return
      }
      self.isStopped = true
      let finalDurationMs = max(100, self.currentElapsedMs())

      self.timer?.cancel()
      self.timer = nil

      guard let writer = self.assetWriter, let input = self.videoInput else {
        completion(nil)
        return
      }

      if cancel {
        writer.cancelWriting()
        try? FileManager.default.removeItem(atPath: self.targetPath)
        if !self.thumbnailPath.isEmpty {
          try? FileManager.default.removeItem(atPath: self.thumbnailPath)
        }
        completion(nil)
        return
      }

      input.markAsFinished()
      writer.finishWriting {
        let info: [String: Any] = [
          "filePath": self.targetPath,
          "thumbnailPath": self.thumbnailPath,
          "durationMs": finalDurationMs,
          "width": self.pixelWidth,
          "height": self.pixelHeight,
          "hasAudio": self.recordAudio
        ]
        completion(info)
      }
    }
  }
}

private class RecordingHudWindow: NSPanel {
  init(
    contentRect: NSRect,
    onTogglePause: @escaping () -> Void,
    onStop: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .floating
    self.hasShadow = true
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = true
    self.hidesOnDeactivate = false
    self.sharingType = .none
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let view = RecordingHudView(
      frame: NSRect(origin: .zero, size: contentRect.size),
      onTogglePause: onTogglePause,
      onStop: onStop,
      onCancel: onCancel
    )
    self.contentView = view
  }

  override var canBecomeKey: Bool { return true }
  override var canBecomeMain: Bool { return false }
}

private class RecordingHudView: NSView {
  private let onTogglePause: () -> Void
  private let onStop: () -> Void
  private let onCancel: () -> Void

  private var elapsedMs: Int = 0
  private var isPaused: Bool = false
  private var pauseHot: Bool = false
  private var stopHot: Bool = false
  private var cancelHot: Bool = false

  private var pauseRect: NSRect = .zero
  private var stopRect: NSRect = .zero
  private var cancelRect: NSRect = .zero

  private let bean = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.94)
  private let coffee = NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 1.0)
  private let recordRed = NSColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 1.0)

  init(
    frame: NSRect,
    onTogglePause: @escaping () -> Void,
    onStop: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onTogglePause = onTogglePause
    self.onStop = onStop
    self.onCancel = onCancel
    super.init(frame: frame)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(elapsedMs: Int, isPaused: Bool) {
    self.elapsedMs = elapsedMs
    self.isPaused = isPaused
    self.needsDisplay = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.activeAlways, .mouseMoved, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
    )
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let pHot = !pauseRect.isEmpty && pauseRect.contains(point)
    let sHot = !stopRect.isEmpty && stopRect.contains(point)
    let cHot = !cancelRect.isEmpty && cancelRect.contains(point)
    if pHot != pauseHot || sHot != stopHot || cHot != cancelHot {
      pauseHot = pHot
      stopHot = sHot
      cancelHot = cHot
      needsDisplay = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !pauseRect.isEmpty && pauseRect.contains(point) {
      onTogglePause()
      return
    }
    if !stopRect.isEmpty && stopRect.contains(point) {
      onStop()
      return
    }
    if !cancelRect.isEmpty && cancelRect.contains(point) {
      onCancel()
      return
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
    bean.setFill()
    bgPath.fill()
    NSColor(white: 1.0, alpha: 0.25).setStroke()
    bgPath.lineWidth = 1.0
    bgPath.stroke()

    let midY = bounds.midY

    // 1. Recording status dot
    let dotD: CGFloat = 9
    let dotRect = NSRect(x: 14, y: midY - dotD / 2, width: dotD, height: dotD)
    let dotPath = NSBezierPath(ovalIn: dotRect)
    (isPaused ? NSColor.systemOrange : recordRed).setFill()
    dotPath.fill()

    // 2. Formatted MM:SS timer
    let totalSecs = max(0, elapsedMs / 1000)
    let mins = totalSecs / 60
    let secs = totalSecs % 60
    let timeStr = String(format: "%02d:%02d", mins, secs) + (isPaused ? " (Paused)" : "")
    let timeAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold),
      .foregroundColor: NSColor.white
    ]
    let timeAttrStr = NSAttributedString(string: timeStr, attributes: timeAttrs)
    let timeSize = timeAttrStr.size()
    timeAttrStr.draw(at: NSPoint(x: 28, y: midY - timeSize.height / 2))

    // 3. Cancel (X) button at right
    let cancelD: CGFloat = 24
    let cancelX = bounds.maxX - cancelD - 8
    cancelRect = NSRect(x: cancelX, y: midY - cancelD / 2, width: cancelD, height: cancelD)
    let cancelPath = NSBezierPath(ovalIn: cancelRect)
    (cancelHot ? coffee : NSColor(white: 1.0, alpha: 0.15)).setFill()
    cancelPath.fill()
    let inset = cancelD * 0.32
    let xBox = cancelRect.insetBy(dx: inset, dy: inset)
    let cross = NSBezierPath()
    cross.move(to: NSPoint(x: xBox.minX, y: xBox.minY))
    cross.line(to: NSPoint(x: xBox.maxX, y: xBox.maxY))
    cross.move(to: NSPoint(x: xBox.minX, y: xBox.maxY))
    cross.line(to: NSPoint(x: xBox.maxX, y: xBox.minY))
    cross.lineWidth = 1.6
    cross.lineCapStyle = .round
    NSColor.white.setStroke()
    cross.stroke()

    // 4. Stop button
    let btnH: CGFloat = 26
    let stopW: CGFloat = 62
    let stopX = cancelX - stopW - 6
    stopRect = NSRect(x: stopX, y: midY - btnH / 2, width: stopW, height: btnH)
    let stopPath = NSBezierPath(roundedRect: stopRect, xRadius: btnH / 2, yRadius: btnH / 2)
    (stopHot ? recordRed.blended(withFraction: 0.25, of: .white) ?? recordRed : recordRed).setFill()
    stopPath.fill()
    let stopAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
      .foregroundColor: NSColor.white
    ]
    let stopStr = NSAttributedString(string: "■ Stop", attributes: stopAttrs)
    let stopSize = stopStr.size()
    stopStr.draw(at: NSPoint(x: stopRect.midX - stopSize.width / 2, y: midY - stopSize.height / 2))

    // 5. Pause / Resume button
    let pauseW: CGFloat = 68
    let pauseX = stopX - pauseW - 6
    pauseRect = NSRect(x: pauseX, y: midY - btnH / 2, width: pauseW, height: btnH)
    let pausePath = NSBezierPath(roundedRect: pauseRect, xRadius: btnH / 2, yRadius: btnH / 2)
    (pauseHot ? coffee : NSColor(white: 1.0, alpha: 0.16)).setFill()
    pausePath.fill()
    let pauseLabel = isPaused ? "▶ Resume" : "❚❚ Pause"
    let pauseStr = NSAttributedString(string: pauseLabel, attributes: stopAttrs)
    let pauseSize = pauseStr.size()
    pauseStr.draw(at: NSPoint(x: pauseRect.midX - pauseSize.width / 2, y: midY - pauseSize.height / 2))
  }
}

