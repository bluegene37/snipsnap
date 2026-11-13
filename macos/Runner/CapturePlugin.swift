import AppKit
// Gene - Nov, 08, 2026: Added AVFoundation and CoreMedia imports for native H.264 MP4 screen & area recording, frame extraction, and video trimming.
// Gene - Nov, 13, 2026: Added ScreenCaptureKit, ImageIO, and UniformTypeIdentifiers for 60fps system-audio screen recording and GIF export.
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import FlutterMacOS
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// Gene - Nov, 13, 2026: Shared configuration passed into/out of the Snagit interactive pre-recording overlay.
struct OverlayRecordOptions {
  var fps: Int = 60
  var recordMic: Bool = false
  var micDeviceId: String? = nil
  var recordSystemAudio: Bool = true
  var recordCursor: Bool = true
  var highlightClicks: Bool = true
  var isFullScreen: Bool = false
}

/// Native macOS Screen Capture Plugin.
/// Provides interactive screen capture overlay where:
/// - Clicking once (without drag) captures the whole screen.
/// - Clicking and dragging captures the selected rectangular area.
/// - Pressing any key escapes and cancels capture (no screenshot taken).
class CapturePlugin: NSObject {
  // Gene - Oct, 27, 2026: Retain FlutterMethodChannel reference and scrolling HUD windows on CapturePlugin instance.
  // Gene - Nov, 13, 2026: Retain FlutterTextureRegistry, sharedInstance guard for window hiding, countdown/click-highlight windows, menu-bar status item, and video players.
  private static weak var sharedInstance: CapturePlugin?

  static var isCaptureOrRecordingActive: Bool {
    guard let inst = sharedInstance else { return false }
    return !inst.activeWindows.isEmpty ||
      inst.countdownWindow != nil ||
      inst.recordingSession != nil ||
      inst.isMainWindowHiddenForCapture
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "snipsnap/capture",
      binaryMessenger: registrar.messenger
    )
    let instance = CapturePlugin()
    instance.channel = channel
    instance.textureRegistry = registrar.textures
    sharedInstance = instance
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private var channel: FlutterMethodChannel?
  private var textureRegistry: FlutterTextureRegistry?
  private var activeWindows: [CaptureOverlayWindow] = []
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var activeResult: FlutterResult?

  private var scrollingGuideWindow: NSPanel?
  private var scrollingHudWindow: NSPanel?
  private var scrollingKeyMonitor: Any?
  private var scrollingLocalKeyMonitor: Any?

  // Gene - Nov, 08, 2026: Added screen recording session state and floating recording HUD windows.
  // Gene - Nov, 13, 2026: Added main-window hide guard, 3-2-1 countdown window, click-highlight window, menu-bar stop item, and native FlutterTexture video players.
  private var isMainWindowHiddenForCapture: Bool = false
  private var countdownWindow: CountdownOverlayWindow?
  private var countdownTimer: DispatchSourceTimer?
  private var countdownEscapeLocalMonitor: Any?
  private var countdownEscapeGlobalMonitor: Any?
  private var clickHighlightWindow: ClickHighlightOverlayWindow?
  private var recordingGuideWindow: NSPanel?
  private var recordingHudWindow: NSPanel?
  private var recordingStatusItem: NSStatusItem?
  private var recordingSession: MacScreenRecordingSession?
  private var videoPlayers: [Int64: MacVideoTexturePlayer] = [:]

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "captureInteractive":
      // Gene - Nov, 08, 2026: Support optional initialMode ("capture" or "record") in captureInteractive.
      // Gene - Nov, 13, 2026: Pass Snagit initial recording options (fps, mic, micDeviceId, systemAudio, cursor, clicks) into overlay.
      guard
        let args = call.arguments as? [String: Any],
        let targetPath = args["targetPath"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
        return
      }
      let initialMode = (args["initialMode"] as? String) ?? "capture"
      let initialOptions = OverlayRecordOptions(
        fps: (args["initialFps"] as? NSNumber)?.intValue ?? (args["initialFps"] as? Int) ?? 60,
        recordMic: (args["initialRecordMic"] as? Bool) ?? false,
        micDeviceId: args["initialMicDeviceId"] as? String,
        recordSystemAudio: (args["initialRecordSystemAudio"] as? Bool) ?? true,
        recordCursor: (args["initialRecordCursor"] as? Bool) ?? true,
        highlightClicks: (args["initialHighlightClicks"] as? Bool) ?? true,
        isFullScreen: false
      )
      startInteractiveCapture(
        targetPath: targetPath,
        initialMode: initialMode,
        initialRecordOptions: initialOptions,
        result: result
      )

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

    // Gene - Nov, 13, 2026: Added main-window visibility, audio device enumeration, microphone permission/mute, extended SCStream recording params, cutVideo, exportVideoAsGif, and FlutterTexture video player handlers.
    // Old implementation:
    // case "startScreenRecording":
    //   guard
    //     let args = call.arguments as? [String: Any],
    //     let targetPath = args["targetPath"] as? String
    //   else {
    //     result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
    //     return
    //   }
    //   let thumbnailPath = (args["thumbnailPath"] as? String) ?? ""
    //   let fullScreen = (args["fullScreen"] as? Bool) ?? false
    //   let xVal = (args["x"] as? NSNumber)?.doubleValue ?? (args["x"] as? Double) ?? 0.0
    //   let yVal = (args["y"] as? NSNumber)?.doubleValue ?? (args["y"] as? Double) ?? 0.0
    //   let wVal = (args["width"] as? NSNumber)?.doubleValue ?? (args["width"] as? Double) ?? 0.0
    //   let hVal = (args["height"] as? NSNumber)?.doubleValue ?? (args["height"] as? Double) ?? 0.0
    //   let fps = (args["fps"] as? NSNumber)?.intValue ?? (args["fps"] as? Int) ?? 30
    //   let recordAudio = (args["recordAudio"] as? Bool) ?? false
    //
    //   startNativeScreenRecording(
    //     targetPath: targetPath,
    //     thumbnailPath: thumbnailPath,
    //     fullScreen: fullScreen,
    //     rect: CGRect(x: xVal, y: yVal, width: wVal, height: hVal),
    //     fps: fps,
    //     recordAudio: recordAudio,
    //     result: result
    //   )
    case "setMainWindowVisible":
      let visible = ((call.arguments as? [String: Any])?["visible"] as? Bool) ?? true
      DispatchQueue.main.async { [weak self] in
        guard let self = self else {
          result(nil)
          return
        }
        let mainWin = NSApp.windows.first(where: { !($0 is NSPanel) }) ?? NSApp.windows.first
        if visible {
          self.isMainWindowHiddenForCapture = false
          mainWin?.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        } else {
          self.isMainWindowHiddenForCapture = true
          mainWin?.orderOut(nil)
        }
        result(nil)
      }

    case "listAudioInputDevices":
      let devices = CapturePlugin.enumerateAudioInputDevices()
      result(devices)

    case "microphoneAuthorized":
      result(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)

    case "requestMicrophoneAccess":
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }

    case "setRecordingMicrophoneMuted":
      let muted = ((call.arguments as? [String: Any])?["muted"] as? Bool) ?? false
      recordingSession?.setMicrophoneMuted(muted)
      updateRecordingHudState()
      result(true)

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
      let fps = (args["fps"] as? NSNumber)?.intValue ?? (args["fps"] as? Int) ?? 60
      let recordAudio = (args["recordAudio"] as? Bool) ?? false
      let micDeviceId = args["microphoneDeviceId"] as? String
      let recordSystemAudio = (args["recordSystemAudio"] as? Bool) ?? true
      let recordCursor = (args["recordCursor"] as? Bool) ?? true
      let highlightClicks = (args["highlightClicks"] as? Bool) ?? true
      let countdownSeconds = (args["countdownSeconds"] as? NSNumber)?.intValue ?? (args["countdownSeconds"] as? Int) ?? 0

      startNativeScreenRecording(
        targetPath: targetPath,
        thumbnailPath: thumbnailPath,
        fullScreen: fullScreen,
        rect: CGRect(x: xVal, y: yVal, width: wVal, height: hVal),
        fps: fps,
        recordAudio: recordAudio,
        microphoneDeviceId: micDeviceId,
        recordSystemAudio: recordSystemAudio,
        recordCursor: recordCursor,
        highlightClicks: highlightClicks,
        countdownSeconds: countdownSeconds,
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

    case "cutVideo":
      guard
        let args = call.arguments as? [String: Any],
        let videoPath = args["videoPath"] as? String,
        let targetPath = args["targetPath"] as? String
      else {
        result(nil)
        return
      }
      let cutStartMs = (args["cutStartMs"] as? NSNumber)?.int64Value ?? (args["cutStartMs"] as? Int64) ?? 0
      let cutEndMs = (args["cutEndMs"] as? NSNumber)?.int64Value ?? (args["cutEndMs"] as? Int64) ?? 0
      cutVideoFile(videoPath: videoPath, cutStartMs: cutStartMs, cutEndMs: cutEndMs, targetPath: targetPath, result: result)

    case "exportVideoAsGif":
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
      let gifFps = (args["fps"] as? NSNumber)?.intValue ?? (args["fps"] as? Int) ?? 15
      let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue ?? (args["maxWidth"] as? Int) ?? 0
      exportVideoAsGif(videoPath: videoPath, targetPath: targetPath, startMs: startMs, endMs: endMs, fps: gifFps, maxWidth: maxWidth, result: result)

    case "createVideoPlayer":
      guard
        let args = call.arguments as? [String: Any],
        let videoPath = args["videoPath"] as? String
      else {
        result(nil)
        return
      }
      createNativeVideoPlayer(videoPath: videoPath, result: result)

    case "playVideo":
      if let tid = ((call.arguments as? [String: Any])?["textureId"] as? NSNumber)?.int64Value {
        videoPlayers[tid]?.play()
      }
      result(nil)

    case "pauseVideo":
      if let tid = ((call.arguments as? [String: Any])?["textureId"] as? NSNumber)?.int64Value {
        videoPlayers[tid]?.pause()
      }
      result(nil)

    case "seekVideo":
      if
        let args = call.arguments as? [String: Any],
        let tid = (args["textureId"] as? NSNumber)?.int64Value
      {
        let posMs = (args["positionMs"] as? NSNumber)?.int64Value ?? 0
        videoPlayers[tid]?.seek(toMs: posMs)
      }
      result(nil)

    case "setVideoVolume":
      if
        let args = call.arguments as? [String: Any],
        let tid = (args["textureId"] as? NSNumber)?.int64Value
      {
        let vol = (args["volume"] as? NSNumber)?.floatValue ?? 1.0
        videoPlayers[tid]?.setVolume(vol)
      }
      result(nil)

    case "setVideoMuted":
      if
        let args = call.arguments as? [String: Any],
        let tid = (args["textureId"] as? NSNumber)?.int64Value
      {
        let muted = (args["muted"] as? Bool) ?? false
        videoPlayers[tid]?.setMuted(muted)
      }
      result(nil)

    case "setVideoSpeed":
      if
        let args = call.arguments as? [String: Any],
        let tid = (args["textureId"] as? NSNumber)?.int64Value
      {
        let spd = (args["speed"] as? NSNumber)?.floatValue ?? 1.0
        videoPlayers[tid]?.setSpeed(spd)
      }
      result(nil)

    case "disposeVideoPlayer":
      if let tid = ((call.arguments as? [String: Any])?["textureId"] as? NSNumber)?.int64Value {
        if let player = videoPlayers.removeValue(forKey: tid) {
          player.dispose()
        }
      }
      result(nil)

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
  // Gene - Nov, 08, 2026: Added initialMode and onRecordCapture callback to startInteractiveCapture so users can initiate Whole Screen or Area screen recording directly from the overlay.
  // Gene - Nov, 13, 2026: Pass OverlayRecordOptions to CaptureOverlayWindow and return extended record: string with fps, audio toggles, cursor, click highlights, fullscreen flag, and URI-encoded mic ID.
  // Old implementation:
  // private func startInteractiveCapture(targetPath: String, initialMode: String = "capture", result: @escaping FlutterResult) {
  //   DispatchQueue.main.async { [weak self] in
  //     guard let self = self else { return }
  //     ...
  //     let overlayWindow = CaptureOverlayWindow(
  //       screen: screen,
  //       screenImage: image,
  //       initialMode: initialMode,
  //       ...
  //       onRecordCapture: { [weak self] selRect in
  //         let resultString = String(format: "record:%.1f:%.1f:%.1f:%.1f", quartzX, quartzY, quartzW, quartzH)
  //         self.finishWithResult(resultString)
  //       },
  //     )
  //   }
  // }
  private func startInteractiveCapture(
    targetPath: String,
    initialMode: String = "capture",
    initialRecordOptions: OverlayRecordOptions = OverlayRecordOptions(),
    result: @escaping FlutterResult
  ) {
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
      for screenItem in screens {
        if let img = self.captureScreenImage(for: screenItem) {
          screenImages[screenItem] = img
        }
      }

      // Create overlay window for each screen
      for screenItem in screens {
        let image = screenImages[screenItem]
        let overlayWindow = CaptureOverlayWindow(
          screen: screenItem,
          screenImage: image,
          initialMode: initialMode,
          initialRecordOptions: initialRecordOptions,
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
            let screenFrame = screenItem.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
            let quartzX = screenFrame.origin.x + selRect.origin.x
            let quartzY = primaryHeight - (screenFrame.origin.y + selRect.origin.y + selRect.height)
            let quartzW = selRect.width
            let quartzH = selRect.height
            let resultString = String(format: "scrolling:%.1f:%.1f:%.1f:%.1f", quartzX, quartzY, quartzW, quartzH)
            self.finishWithResult(resultString)
            NSApp.windows.first(where: { !($0 is NSPanel) })?.orderOut(nil)
          },
          onRecordCapture: { [weak self] selRect, opts in
            guard let self = self else { return }
            let screenFrame = screenItem.frame
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
            let quartzX = screenFrame.origin.x + selRect.origin.x
            let quartzY = primaryHeight - (screenFrame.origin.y + selRect.origin.y + selRect.height)
            let quartzW = selRect.width
            let quartzH = selRect.height
            let encodedMic = (opts.micDeviceId ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let resultString = String(
              format: "record:%.1f:%.1f:%.1f:%.1f:%d:%d:%d:%d:%d:%d:%@",
              quartzX,
              quartzY,
              quartzW,
              quartzH,
              opts.fps,
              opts.recordMic ? 1 : 0,
              opts.recordSystemAudio ? 1 : 0,
              opts.recordCursor ? 1 : 0,
              opts.highlightClicks ? 1 : 0,
              opts.isFullScreen ? 1 : 0,
              encodedMic
            )
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
      window.stopOverlayResources()
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
  // Gene - Nov, 13, 2026: Upgraded to ScreenCaptureKit (SCStream + system audio + mic mixer), fixed Retina coordinate double-division, added 3-2-1 countdown, click highlight overlay, menu-bar stop item, zero-tolerance frame extraction, cutVideoFile, exportVideoAsGif, and FlutterTexture video player.
  /*
  // Old implementation (Nov, 08, 2026):
  private func startNativeScreenRecording(
    targetPath: String,
    thumbnailPath: String,
    fullScreen: Bool,
    rect: CGRect,
    fps: Int,
    recordAudio: Bool,
    result: @escaping FlutterResult
  ) {
    ...
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
    ...
      generator.requestedTimeToleranceBefore = CMTime(value: 50, timescale: 1000)
      generator.requestedTimeToleranceAfter = CMTime(value: 50, timescale: 1000)
  }
  */

  static func enumerateAudioInputDevices() -> [[String: Any]] {
    let deviceTypes: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) {
      deviceTypes = [.microphone, .external]
    } else {
      deviceTypes = [.builtInMicrophone, .externalUnknown]
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes,
      mediaType: .audio,
      position: .unspecified
    )
    let defaultUID = AVCaptureDevice.default(for: .audio)?.uniqueID
    var list: [[String: Any]] = []
    for dev in discovery.devices {
      list.append([
        "id": dev.uniqueID,
        "name": dev.localizedName,
        "isDefault": (dev.uniqueID == defaultUID)
      ])
    }
    return list
  }

  private func screenForQuartzPoint(_ quartzPt: CGPoint) -> NSScreen {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
    let appKitPt = NSPoint(x: quartzPt.x, y: primaryHeight - quartzPt.y)
    for scr in NSScreen.screens {
      if scr.frame.contains(appKitPt) {
        return scr
      }
    }
    return NSScreen.main ?? NSScreen.screens.first!
  }

  private func quartzRect(for screenItem: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screenItem.frame.height
    let f = screenItem.frame
    return CGRect(
      x: f.origin.x,
      y: primaryHeight - (f.origin.y + f.height),
      width: f.width,
      height: f.height
    )
  }

  private func startNativeScreenRecording(
    targetPath: String,
    thumbnailPath: String,
    fullScreen: Bool,
    rect: CGRect,
    fps: Int,
    recordAudio: Bool,
    microphoneDeviceId: String?,
    recordSystemAudio: Bool,
    recordCursor: Bool,
    highlightClicks: Bool,
    countdownSeconds: Int,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.recordingSession != nil || self.countdownWindow != nil {
        result(FlutterError(code: "already_recording", message: "Screen recording is already active", details: nil))
        return
      }

      let probePoint = (rect.width >= 10 && rect.height >= 10)
        ? CGPoint(x: rect.midX, y: rect.midY)
        : CGPoint.zero
      let targetScreen = self.screenForQuartzPoint(probePoint)
      let scale = targetScreen.backingScaleFactor
      let screenQuartz = self.quartzRect(for: targetScreen)

      let pointRect: CGRect
      if fullScreen || rect.width < 10 || rect.height < 10 {
        pointRect = screenQuartz
      } else {
        // rect from captureInteractive / Dart is already in Quartz points
        pointRect = rect
      }

      let displayNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      let displayID = CGDirectDisplayID(displayNumber?.uint32Value ?? CGMainDisplayID())

      let session = MacScreenRecordingSession(
        targetPath: targetPath,
        thumbnailPath: thumbnailPath,
        displayID: displayID,
        screenQuartzFrame: screenQuartz,
        pointRect: pointRect,
        scale: scale,
        fps: max(15, min(60, fps)),
        recordAudio: recordAudio,
        microphoneDeviceId: microphoneDeviceId,
        recordSystemAudio: recordSystemAudio,
        recordCursor: recordCursor,
        onTick: { [weak self] elapsedMs, isPaused in
          DispatchQueue.main.async {
            guard let strongSelf = self else { return }
            if let hudView = strongSelf.recordingHudWindow?.contentView as? RecordingHudView {
              hudView.update(
                elapsedMs: elapsedMs,
                isPaused: isPaused,
                isMicEnabled: strongSelf.recordingSession?.recordAudio ?? false,
                isMicMuted: strongSelf.recordingSession?.isMicrophoneMuted ?? false
              )
            }
            strongSelf.updateMenuBarStatusItem(elapsedMs: elapsedMs, isPaused: isPaused)
          }
        },
        onStreamError: { [weak self] _ in
          DispatchQueue.main.async {
            guard let strongSelf = self else { return }
            strongSelf.stopNativeScreenRecording(cancel: false) { info in
              strongSelf.channel?.invokeMethod("onRecordingStopped", arguments: info)
            }
          }
        }
      )

      let launchSession: (@escaping (Bool) -> Void) -> Void = { [weak self] done in
        guard let strongSelf = self else {
          done(false)
          return
        }
        strongSelf.recordingSession = session
        var excludeWinNumbers: [Int] = []
        for win in NSApp.windows where win.sharingType == .none && win.windowNumber > 0 {
          excludeWinNumbers.append(win.windowNumber)
        }
        session.prepareAndStart(excludingWindowNumbers: excludeWinNumbers) { startedOk in
          DispatchQueue.main.async { [weak self] in
            guard let innerSelf = self else {
              done(false)
              return
            }
            if !startedOk {
              innerSelf.recordingSession = nil
              innerSelf.closeRecordingHudInternal()
              done(false)
              return
            }
            if recordCursor && highlightClicks {
              let hlWin = ClickHighlightOverlayWindow(screen: targetScreen)
              innerSelf.clickHighlightWindow = hlWin
              hlWin.orderFrontRegardless()
            }
            innerSelf.showRecordingHud(
              for: pointRect,
              screenItem: targetScreen,
              fullScreen: fullScreen || (rect.width < 10 || rect.height < 10)
            )
            innerSelf.installMenuBarStatusItem()
            done(true)
          }
        }
      }

      if countdownSeconds > 0 {
        self.beginCountdown(
          seconds: countdownSeconds,
          on: targetScreen,
          selectionQuartzRect: pointRect,
          fullScreen: fullScreen || (rect.width < 10 || rect.height < 10),
          onFinished: {
            launchSession { startedOk in
              if !startedOk {
                self.channel?.invokeMethod("onRecordingCancelled", arguments: nil)
                self.restoreMainWindowIfHidden()
              }
            }
          },
          onCancelled: {
            self.channel?.invokeMethod("onRecordingCancelled", arguments: nil)
            self.restoreMainWindowIfHidden()
          }
        )
        result(true)
      } else {
        launchSession { startedOk in
          result(startedOk)
        }
      }
    }
  }

  private func beginCountdown(
    seconds: Int,
    on targetScreen: NSScreen,
    selectionQuartzRect: CGRect,
    fullScreen: Bool,
    onFinished: @escaping () -> Void,
    onCancelled: @escaping () -> Void
  ) {
    cancelCountdownInternal()
    let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
    let appKitY = primaryHeight - (selectionQuartzRect.origin.y + selectionQuartzRect.height)
    let centerX = selectionQuartzRect.origin.x + selectionQuartzRect.width / 2.0
    let centerY = appKitY + selectionQuartzRect.height / 2.0
    let pillSize = NSSize(width: 170, height: 150)
    let panelRect = NSRect(
      x: centerX - pillSize.width / 2.0,
      y: centerY - pillSize.height / 2.0,
      width: pillSize.width,
      height: pillSize.height
    )

    if !fullScreen {
      let guideFrame = NSRect(
        x: selectionQuartzRect.origin.x,
        y: appKitY,
        width: selectionQuartzRect.width,
        height: selectionQuartzRect.height
      )
      let guideWin = ScrollingGuideWindow(contentRect: guideFrame)
      guideWin.sharingType = .none
      self.recordingGuideWindow = guideWin
      guideWin.orderFrontRegardless()
    }

    let cWin = CountdownOverlayWindow(contentRect: panelRect, initialValue: seconds)
    self.countdownWindow = cWin
    cWin.orderFrontRegardless()

    var remaining = seconds
    let escapeCode: UInt16 = 53
    self.countdownEscapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
      if ev.keyCode == escapeCode {
        self?.cancelCountdownInternal()
        onCancelled()
        return nil
      }
      return ev
    }
    self.countdownEscapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
      if ev.keyCode == escapeCode {
        self?.cancelCountdownInternal()
        onCancelled()
      }
    }

    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
    t.setEventHandler { [weak self] in
      guard let strongSelf = self else { return }
      remaining -= 1
      if remaining <= 0 {
        strongSelf.cancelCountdownInternal()
        onFinished()
      } else {
        strongSelf.countdownWindow?.updateValue(remaining)
      }
    }
    self.countdownTimer = t
    t.resume()
  }

  private func cancelCountdownInternal() {
    countdownTimer?.cancel()
    countdownTimer = nil
    if let m = countdownEscapeLocalMonitor {
      NSEvent.removeMonitor(m)
      countdownEscapeLocalMonitor = nil
    }
    if let m = countdownEscapeGlobalMonitor {
      NSEvent.removeMonitor(m)
      countdownEscapeGlobalMonitor = nil
    }
    countdownWindow?.orderOut(nil)
    countdownWindow = nil
  }

  private func restoreMainWindowIfHidden() {
    isMainWindowHiddenForCapture = false
    let mainWin = NSApp.windows.first(where: { !($0 is NSPanel) }) ?? NSApp.windows.first
    mainWin?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func installMenuBarStatusItem() {
    removeMenuBarStatusItem()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.title = "● 00:00"
      button.target = self
      button.action = #selector(handleMenuBarStopClicked)
      button.toolTip = "SnipSnap Recording — Click to Stop"
    }
    recordingStatusItem = item
  }

  private func updateMenuBarStatusItem(elapsedMs: Int, isPaused: Bool) {
    guard let button = recordingStatusItem?.button else { return }
    let secsTotal = max(0, elapsedMs / 1000)
    let prefix = isPaused ? "❚❚" : "●"
    button.title = String(format: "%@ %02d:%02d", prefix, secsTotal / 60, secsTotal % 60)
  }

  private func removeMenuBarStatusItem() {
    if let item = recordingStatusItem {
      NSStatusBar.system.removeStatusItem(item)
      recordingStatusItem = nil
    }
  }

  @objc private func handleMenuBarStopClicked() {
    stopNativeScreenRecording(cancel: false) { [weak self] info in
      self?.channel?.invokeMethod("onRecordingStopped", arguments: info)
    }
  }

  private func showRecordingHud(for pointRect: CGRect, screenItem: NSScreen, fullScreen: Bool) {
    closeRecordingHudInternal()

    let primaryHeight = NSScreen.screens.first?.frame.height ?? screenItem.frame.height
    let screenFrame = screenItem.frame
    let appKitY = primaryHeight - (pointRect.origin.y + pointRect.height)
    let guideFrame = NSRect(x: pointRect.origin.x, y: appKitY, width: pointRect.width, height: pointRect.height)

    if !fullScreen {
      let guideWin = ScrollingGuideWindow(contentRect: guideFrame)
      guideWin.sharingType = .none
      self.recordingGuideWindow = guideWin
      guideWin.orderFrontRegardless()
    }

    let hudW: CGFloat = 410
    let hudH: CGFloat = 42
    var hudY: CGFloat
    let hudX: CGFloat
    if fullScreen {
      hudX = max(screenFrame.minX + 16, screenFrame.maxX - hudW - 24)
      hudY = screenFrame.minY + 28
    } else {
      hudY = guideFrame.minY - hudH - 10
      if hudY < screenFrame.minY + 12 {
        hudY = min(guideFrame.maxY + 10, screenFrame.maxY - hudH - 12)
      }
      hudX = max(screenFrame.minX + 10, min(guideFrame.midX - hudW / 2, screenFrame.maxX - hudW - 10))
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
      onRestart: { [weak self] in
        guard let self = self else { return }
        self.stopNativeScreenRecording(cancel: true, restoreWindow: false) { _ in
          self.channel?.invokeMethod("onRecordingRestartRequested", arguments: nil)
        }
      },
      onToggleMicMute: { [weak self] in
        guard let self = self, let session = self.recordingSession else { return }
        let nextMuted = !session.isMicrophoneMuted
        session.setMicrophoneMuted(nextMuted)
        self.updateRecordingHudState()
        self.channel?.invokeMethod("onRecordingMicMutedChanged", arguments: ["isMuted": nextMuted])
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
    self.updateRecordingHudState()
  }

  private func updateRecordingHudState() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let session = self.recordingSession else { return }
      if let hudView = self.recordingHudWindow?.contentView as? RecordingHudView {
        hudView.update(
          elapsedMs: session.currentElapsedMs(),
          isPaused: session.isPaused,
          isMicEnabled: session.recordAudio,
          isMicMuted: session.isMicrophoneMuted
        )
      }
      self.updateMenuBarStatusItem(elapsedMs: session.currentElapsedMs(), isPaused: session.isPaused)
    }
  }

  private func closeRecordingHudInternal() {
    cancelCountdownInternal()
    clickHighlightWindow?.stopMonitoring()
    clickHighlightWindow?.orderOut(nil)
    clickHighlightWindow = nil
    recordingGuideWindow?.orderOut(nil)
    recordingGuideWindow = nil
    recordingHudWindow?.orderOut(nil)
    recordingHudWindow = nil
    removeMenuBarStatusItem()
  }

  private func stopNativeScreenRecording(
    cancel: Bool,
    restoreWindow: Bool = true,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.closeRecordingHudInternal()
      guard let session = self.recordingSession else {
        if restoreWindow {
          self.restoreMainWindowIfHidden()
        }
        result(nil)
        return
      }
      self.recordingSession = nil
      session.stop(cancel: cancel) { info in
        DispatchQueue.main.async {
          if restoreWindow {
            self.restoreMainWindowIfHidden()
          }
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
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
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
    try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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

  private func cutVideoFile(
    videoPath: String,
    cutStartMs: Int64,
    cutEndMs: Int64,
    targetPath: String,
    result: @escaping FlutterResult
  ) {
    let inputURL = URL(fileURLWithPath: videoPath)
    let outputURL = URL(fileURLWithPath: targetPath)
    try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: outputURL)

    let asset = AVURLAsset(url: inputURL)
    let totalDuration = asset.duration
    let totalMs = Int64((CMTimeGetSeconds(totalDuration) * 1000.0).rounded())
    let clampedStart = max(Int64(0), min(cutStartMs, totalMs))
    let clampedEnd = max(clampedStart, min(cutEndMs, totalMs))

    let composition = AVMutableComposition()
    guard let videoTrack = asset.tracks(withMediaType: .video).first,
          let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      result(nil)
      return
    }
    compVideo.preferredTransform = videoTrack.preferredTransform

    let compAudio = asset.tracks(withMediaType: .audio).first.flatMap { _ in
      composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    }

    var cursorTime = CMTime.zero
    if clampedStart > 20 {
      let headRange = CMTimeRange(start: .zero, duration: CMTime(value: clampedStart, timescale: 1000))
      try? compVideo.insertTimeRange(headRange, of: videoTrack, at: cursorTime)
      if let srcAudio = asset.tracks(withMediaType: .audio).first, let dstAudio = compAudio {
        try? dstAudio.insertTimeRange(headRange, of: srcAudio, at: cursorTime)
      }
      cursorTime = CMTimeAdd(cursorTime, headRange.duration)
    }

    if totalMs - clampedEnd > 20 {
      let tailStart = CMTime(value: clampedEnd, timescale: 1000)
      let tailRange = CMTimeRange(start: tailStart, duration: CMTimeSubtract(totalDuration, tailStart))
      try? compVideo.insertTimeRange(tailRange, of: videoTrack, at: cursorTime)
      if let srcAudio = asset.tracks(withMediaType: .audio).first, let dstAudio = compAudio {
        try? dstAudio.insertTimeRange(tailRange, of: srcAudio, at: cursorTime)
      }
      cursorTime = CMTimeAdd(cursorTime, tailRange.duration)
    }

    let outDurationMs = Int((CMTimeGetSeconds(cursorTime) * 1000.0).rounded())
    guard outDurationMs >= 100,
          let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else {
      result(nil)
      return
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.exportAsynchronously {
      DispatchQueue.main.async {
        if exportSession.status == .completed {
          result(["filePath": targetPath, "durationMs": outDurationMs])
        } else {
          result(nil)
        }
      }
    }
  }

  private func exportVideoAsGif(
    videoPath: String,
    targetPath: String,
    startMs: Int64,
    endMs: Int64,
    fps: Int,
    maxWidth: Int,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let inputURL = URL(fileURLWithPath: videoPath)
      let outputURL = URL(fileURLWithPath: targetPath)
      try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: outputURL)

      let asset = AVURLAsset(url: inputURL)
      let durationTotalMs = Int64((CMTimeGetSeconds(asset.duration) * 1000.0).rounded())
      let effectiveStart = max(Int64(0), startMs)
      let effectiveEnd = min(durationTotalMs, endMs > effectiveStart ? endMs : durationTotalMs)
      let spanMs = max(Int64(100), effectiveEnd - effectiveStart)
      let clampedFps = max(5, min(25, fps))
      let stepMs = max(Int64(40), Int64(1000 / clampedFps))
      let frameCount = min(300, max(1, Int(spanMs / stepMs) + 1))

      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = CMTime(value: stepMs / 2, timescale: 1000)
      generator.requestedTimeToleranceAfter = CMTime(value: stepMs / 2, timescale: 1000)
      if maxWidth > 0 {
        generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: CGFloat(maxWidth))
      } else {
        generator.maximumSize = CGSize(width: 1280, height: 1280)
      }

      guard let dest = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.gif.identifier as CFString,
        frameCount,
        nil
      ) else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      let fileProps: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
          kCGImagePropertyGIFLoopCount as String: 0
        ]
      ]
      CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

      let delaySeconds = Double(stepMs) / 1000.0
      let frameProps: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
          kCGImagePropertyGIFDelayTime as String: delaySeconds,
          kCGImagePropertyGIFUnclampedDelayTime as String: delaySeconds
        ]
      ]

      var added = 0
      for idx in 0..<frameCount {
        let ts = min(effectiveEnd, effectiveStart + Int64(idx) * stepMs)
        let cm = CMTime(value: ts, timescale: 1000)
        if let frameImg = try? generator.copyCGImage(at: cm, actualTime: nil) {
          CGImageDestinationAddImage(dest, frameImg, frameProps as CFDictionary)
          added += 1
        }
      }

      let finalized = added > 0 && CGImageDestinationFinalize(dest)
      DispatchQueue.main.async {
        result(finalized ? targetPath : nil)
      }
    }
  }

  private func createNativeVideoPlayer(videoPath: String, result: @escaping FlutterResult) {
    guard let registry = textureRegistry else {
      result(nil)
      return
    }
    let player = MacVideoTexturePlayer(
      videoPath: videoPath,
      registry: registry,
      onProgress: { [weak self] tid, posMs, playing in
        DispatchQueue.main.async {
          self?.channel?.invokeMethod("onVideoPlayerProgress", arguments: [
            "textureId": tid,
            "positionMs": posMs,
            "isPlaying": playing
          ])
        }
      },
      onCompleted: { [weak self] tid in
        DispatchQueue.main.async {
          self?.channel?.invokeMethod("onVideoPlayerCompleted", arguments: [
            "textureId": tid
          ])
        }
      }
    )
    player.prepare { [weak self] info in
      DispatchQueue.main.async {
        guard let strongSelf = self, let readyInfo = info else {
          player.dispose()
          result(nil)
          return
        }
        strongSelf.videoPlayers[player.textureId] = player
        result(readyInfo)
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
  // Gene - Nov, 13, 2026: Added initialRecordOptions, updated onRecordCapture to pass OverlayRecordOptions, and added stopOverlayResources().
  /*
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
  */
  init(
    screen: NSScreen,
    screenImage: CGImage?,
    initialMode: String = "capture",
    initialRecordOptions: OverlayRecordOptions = OverlayRecordOptions(),
    onCapture: @escaping (CGImage?) -> Void,
    onPanoramicCapture: ((NSRect) -> Void)? = nil,
    onRecordCapture: ((NSRect, OverlayRecordOptions) -> Void)? = nil,
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
      initialRecordOptions: initialRecordOptions,
      onCapture: onCapture,
      onPanoramicCapture: onPanoramicCapture,
      onRecordCapture: onRecordCapture,
      onCancel: onCancel
    )
    self.contentView = view
  }

  func stopOverlayResources() {
    (contentView as? CaptureOverlayView)?.stopMicMonitor()
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

// Gene - Nov, 13, 2026: Live RMS microphone meter feed for the Snagit pre-recording toolbar.
private final class OverlayMicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "com.snipsnap.overlay.micmeter", qos: .utility)
  private let onLevel: (CGFloat) -> Void
  private var lastEmitNs: UInt64 = 0
  private var isStopped = false

  init?(deviceId: String?, onLevel: @escaping (CGFloat) -> Void) {
    self.onLevel = onLevel
    super.init()

    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    guard status == .authorized else { return nil }

    let device: AVCaptureDevice?
    if let devId = deviceId, !devId.isEmpty {
      device = AVCaptureDevice(uniqueID: devId) ?? AVCaptureDevice.default(for: .audio)
    } else {
      device = AVCaptureDevice.default(for: .audio)
    }
    guard let audioDev = device,
          let input = try? AVCaptureDeviceInput(device: audioDev),
          session.canAddInput(input)
    else {
      return nil
    }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else { return nil }
    session.addOutput(output)

    queue.async { [weak self] in
      self?.session.startRunning()
    }
  }

  func stop() {
    isStopped = true
    let capSession = session
    queue.async {
      if capSession.isRunning {
        capSession.stopRunning()
      }
    }
  }

  deinit {
    stop()
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !isStopped else { return }
    let nowNs = DispatchTime.now().uptimeNanoseconds
    if nowNs - lastEmitNs < 66_000_000 { return } // ~15Hz
    lastEmitNs = nowNs

    guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuffer),
          let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
    else {
      return
    }

    var totalLen: Int = 0
    var dataPtr: UnsafeMutablePointer<Int8>?
    let res = CMBlockBufferGetDataPointer(blockBuf, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr)
    guard res == noErr, let rawPtr = dataPtr, totalLen > 0 else { return }

    var sumSq: Double = 0
    var sampleCount = 0
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    if isFloat && asbd.mBitsPerChannel == 32 {
      let count = totalLen / MemoryLayout<Float>.size
      let step = max(1, count / 128)
      rawPtr.withMemoryRebound(to: Float.self, capacity: count) { fBuf in
        var idx = 0
        while idx < count {
          let v = Double(fBuf[idx])
          sumSq += v * v
          sampleCount += 1
          idx += step
        }
      }
    } else if asbd.mBitsPerChannel == 16 {
      let count = totalLen / MemoryLayout<Int16>.size
      let step = max(1, count / 128)
      rawPtr.withMemoryRebound(to: Int16.self, capacity: count) { iBuf in
        var idx = 0
        while idx < count {
          let v = Double(iBuf[idx]) / 32768.0
          sumSq += v * v
          sampleCount += 1
          idx += step
        }
      }
    }

    guard sampleCount > 0 else { return }
    let rms = sqrt(sumSq / Double(sampleCount))
    let normalized = CGFloat(min(1.0, max(0.0, rms * 5.0)))
    DispatchQueue.main.async { [weak self] in
      guard let strongSelf = self, !strongSelf.isStopped else { return }
      strongSelf.onLevel(normalized)
    }
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
  // Gene - Nov, 13, 2026: Added OverlayRecordOptions state, Snagit pre-recording toolbar hit rects, and live mic level meter.
  private let initialMode: String
  private let onCapture: (CGImage?) -> Void
  // Gene - Oct, 27, 2026: Added onPanoramicCapture callback.
  private let onPanoramicCapture: ((NSRect) -> Void)?
  private let onRecordCapture: ((NSRect, OverlayRecordOptions) -> Void)?
  private let onCancel: () -> Void

  private var recordOptions: OverlayRecordOptions
  private var micLevel: CGFloat = 0.0
  private var micMonitor: OverlayMicLevelMonitor?

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

  // Gene - Nov, 13, 2026: Pre-recording Snagit toolbar & quick-preset rects and hover tracking.
  private var idleFullRect: NSRect = .zero
  private var idle1080Rect: NSRect = .zero
  private var idle720Rect: NSRect = .zero
  private var idleCancelRect: NSRect = .zero
  private var tbPresetFullRect: NSRect = .zero
  private var tbPreset1080Rect: NSRect = .zero
  private var tbPreset720Rect: NSRect = .zero
  private var tbFpsRect: NSRect = .zero
  private var tbMicRect: NSRect = .zero
  private var tbMicChevronRect: NSRect = .zero
  private var tbSysAudioRect: NSRect = .zero
  private var tbCursorRect: NSRect = .zero
  private var tbImageRect: NSRect = .zero
  private var hotChipKey: String = ""

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
  private let bean = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.92)

  private var hasSettled = false

  // Gene - Nov, 08, 2026: Updated CaptureOverlayView initializer to accept initialMode and onRecordCapture.
  // Gene - Nov, 13, 2026: Accept OverlayRecordOptions and initialize mic level monitor when recordMic is active.
  /*
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
  */
  init(
    frame: NSRect,
    screenImage: CGImage?,
    scaleFactor: CGFloat,
    initialMode: String = "capture",
    initialRecordOptions: OverlayRecordOptions = OverlayRecordOptions(),
    onCapture: @escaping (CGImage?) -> Void,
    onPanoramicCapture: ((NSRect) -> Void)? = nil,
    onRecordCapture: ((NSRect, OverlayRecordOptions) -> Void)? = nil,
    onCancel: @escaping () -> Void
  ) {
    self.screenImage = screenImage
    self.scaleFactor = scaleFactor
    self.initialMode = initialMode
    self.recordOptions = initialRecordOptions
    self.onCapture = onCapture
    self.onPanoramicCapture = onPanoramicCapture
    self.onRecordCapture = onRecordCapture
    self.onCancel = onCancel
    super.init(frame: frame)
    self.wantsLayer = true
    if initialMode == "record" && initialRecordOptions.recordMic {
      refreshMicMonitor()
    }
  }

  deinit {
    stopMicMonitor()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func stopMicMonitor() {
    micMonitor?.stop()
    micMonitor = nil
    micLevel = 0.0
  }

  private func refreshMicMonitor() {
    stopMicMonitor()
    guard initialMode == "record" && recordOptions.recordMic else {
      needsDisplay = true
      return
    }
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        DispatchQueue.main.async {
          guard let strongSelf = self else { return }
          if granted && strongSelf.recordOptions.recordMic {
            strongSelf.startMicMonitorInternal()
          } else if !granted {
            strongSelf.recordOptions.recordMic = false
            strongSelf.needsDisplay = true
          }
        }
      }
    } else if status == .authorized {
      startMicMonitorInternal()
    }
  }

  private func startMicMonitorInternal() {
    micMonitor = OverlayMicLevelMonitor(deviceId: recordOptions.micDeviceId) { [weak self] lvl in
      guard let strongSelf = self else { return }
      strongSelf.micLevel = lvl
      strongSelf.needsDisplay = true
    }
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
  // Gene - Nov, 13, 2026: Track hover and cursor rects for all Snagit preset & pre-recording toolbar controls.
  /*
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
  */
  override func mouseMoved(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    let captureHot = !captureButtonRect.isEmpty && captureButtonRect.contains(pt)
    let recordHot = !recordButtonRect.isEmpty && recordButtonRect.contains(pt)
    let cancelHot = (!cancelButtonRect.isEmpty && cancelButtonRect.contains(pt)) ||
      (!idleCancelRect.isEmpty && idleCancelRect.contains(pt))
    let chipPairs: [(String, NSRect)] = [
      ("idleFull", idleFullRect),
      ("idle1080", idle1080Rect),
      ("idle720", idle720Rect),
      ("idleCancel", idleCancelRect),
      ("tbFull", tbPresetFullRect),
      ("tb1080", tbPreset1080Rect),
      ("tb720", tbPreset720Rect),
      ("tbFps", tbFpsRect),
      ("tbMic", tbMicRect),
      ("tbMicChev", tbMicChevronRect),
      ("tbSys", tbSysAudioRect),
      ("tbCursor", tbCursorRect),
      ("tbImage", tbImageRect),
    ]
    var nextChip = ""
    for (keyName, rectBox) in chipPairs {
      if !rectBox.isEmpty && rectBox.contains(pt) {
        nextChip = keyName
        break
      }
    }
    if captureHot != captureButtonHot ||
      recordHot != recordButtonHot ||
      cancelHot != cancelButtonHot ||
      nextChip != hotChipKey
    {
      captureButtonHot = captureHot
      recordButtonHot = recordHot
      cancelButtonHot = cancelHot
      hotChipKey = nextChip
      needsDisplay = true
    }
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)

    for rectBox in [idleFullRect, idle1080Rect, idle720Rect, idleCancelRect] where !rectBox.isEmpty {
      addCursorRect(rectBox, cursor: .pointingHand)
    }

    guard case .adjusting = mode, let sel = selection else { return }
    addCursorRect(sel, cursor: .openHand)
    for (gItem, gRect) in gripRects(for: sel) {
      addCursorRect(gRect, cursor: cursor(for: gItem))
    }
    let toolbarRects = [
      captureButtonRect, recordButtonRect, cancelButtonRect,
      tbPresetFullRect, tbPreset1080Rect, tbPreset720Rect,
      tbFpsRect, tbMicRect, tbMicChevronRect, tbSysAudioRect, tbCursorRect, tbImageRect
    ]
    for btnRect in toolbarRects where !btnRect.isEmpty {
      addCursorRect(btnRect, cursor: .pointingHand)
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

  // Gene - Nov, 13, 2026: Handle Snagit quick presets and pre-recording toolbar controls in mouseDown, mouseUp, and settle handlers.
  /*
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
      if !recordButtonRect.isEmpty && recordButtonRect.contains(point) {
        startRecordSelection()
        return
      }
      if let grip = grip(at: point, in: sel) {
        selectionAtDragStart = sel
        mode = (grip == .body) ? .moving : .resizing(grip)
        refreshChrome()
        return
      }
    }

    selection = NSRect(origin: point, size: .zero)
    mode = .drawing
    refreshChrome()
  }
  */
  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    dragOrigin = pt

    if case .idle = mode, initialMode == "record" {
      if !idleCancelRect.isEmpty && idleCancelRect.contains(pt) {
        settleCancelled()
        return
      }
      if !idleFullRect.isEmpty && idleFullRect.contains(pt) {
        applyPresetSelection(pixelW: 0, pixelH: 0, full: true)
        return
      }
      if !idle1080Rect.isEmpty && idle1080Rect.contains(pt) {
        applyPresetSelection(pixelW: 1920, pixelH: 1080, full: false)
        return
      }
      if !idle720Rect.isEmpty && idle720Rect.contains(pt) {
        applyPresetSelection(pixelW: 1280, pixelH: 720, full: false)
        return
      }
    }

    if case .adjusting = mode, let sel = selection {
      if !cancelButtonRect.isEmpty && cancelButtonRect.contains(pt) {
        settleCancelled()
        return
      }
      if !captureButtonRect.isEmpty && captureButtonRect.contains(pt) {
        captureCurrentSelection()
        return
      }
      if !recordButtonRect.isEmpty && recordButtonRect.contains(pt) {
        startRecordSelection()
        return
      }
      if initialMode == "record" {
        if !tbPresetFullRect.isEmpty && tbPresetFullRect.contains(pt) {
          applyPresetSelection(pixelW: 0, pixelH: 0, full: true)
          return
        }
        if !tbPreset1080Rect.isEmpty && tbPreset1080Rect.contains(pt) {
          applyPresetSelection(pixelW: 1920, pixelH: 1080, full: false)
          return
        }
        if !tbPreset720Rect.isEmpty && tbPreset720Rect.contains(pt) {
          applyPresetSelection(pixelW: 1280, pixelH: 720, full: false)
          return
        }
        if !tbFpsRect.isEmpty && tbFpsRect.contains(pt) {
          recordOptions.fps = (recordOptions.fps == 60) ? 30 : 60
          needsDisplay = true
          return
        }
        if !tbMicChevronRect.isEmpty && tbMicChevronRect.contains(pt) {
          showMicPickerMenu(anchorRect: tbMicChevronRect)
          return
        }
        if !tbMicRect.isEmpty && tbMicRect.contains(pt) {
          recordOptions.recordMic = !recordOptions.recordMic
          refreshMicMonitor()
          needsDisplay = true
          return
        }
        if !tbSysAudioRect.isEmpty && tbSysAudioRect.contains(pt) {
          recordOptions.recordSystemAudio = !recordOptions.recordSystemAudio
          needsDisplay = true
          return
        }
        if !tbCursorRect.isEmpty && tbCursorRect.contains(pt) {
          let nextVal = !(recordOptions.recordCursor && recordOptions.highlightClicks)
          recordOptions.recordCursor = nextVal
          recordOptions.highlightClicks = nextVal
          needsDisplay = true
          return
        }
        if !tbImageRect.isEmpty && tbImageRect.contains(pt) {
          captureCurrentSelection()
          return
        }
      }
      if let gHit = grip(at: pt, in: sel) {
        selectionAtDragStart = sel
        mode = (gHit == .body) ? .moving : .resizing(gHit)
        refreshChrome()
        return
      }
    }

    selection = NSRect(origin: pt, size: .zero)
    mode = .drawing
    refreshChrome()
  }

  private func applyPresetSelection(pixelW: Int, pixelH: Int, full: Bool) {
    if full {
      selection = bounds
      recordOptions.isFullScreen = true
    } else {
      let denom = max(CGFloat(1.0), scaleFactor)
      let ptW = min(bounds.width - 16, max(120, CGFloat(pixelW) / denom))
      let ptH = min(bounds.height - 16, max(120, CGFloat(pixelH) / denom))
      let originX = max(bounds.minX, (bounds.width - ptW) / 2.0)
      let originY = max(bounds.minY, (bounds.height - ptH) / 2.0)
      selection = NSRect(x: originX, y: originY, width: ptW, height: ptH)
      recordOptions.isFullScreen = false
    }
    mode = .adjusting
    refreshChrome()
  }

  private func showMicPickerMenu(anchorRect: NSRect) {
    let devices = CapturePlugin.enumerateAudioInputDevices()
    let menu = NSMenu(title: "Microphones")
    if devices.isEmpty {
      let emptyItem = NSMenuItem(title: "No audio input devices", action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      menu.addItem(emptyItem)
    } else {
      for dev in devices {
        let devId = (dev["id"] as? String) ?? ""
        let devName = (dev["name"] as? String) ?? "Microphone"
        let isDef = (dev["isDefault"] as? Bool) ?? false
        let title = isDef ? "\(devName) (Default)" : devName
        let item = NSMenuItem(title: title, action: #selector(handleMicMenuSelection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = devId
        let isSelected = (recordOptions.micDeviceId == devId) || (recordOptions.micDeviceId == nil && isDef)
        item.state = isSelected ? .on : .off
        menu.addItem(item)
      }
    }
    menu.popUp(positioning: nil, at: NSPoint(x: anchorRect.minX, y: anchorRect.maxY + 4), in: self)
  }

  @objc private func handleMicMenuSelection(_ sender: NSMenuItem) {
    guard let chosenId = sender.representedObject as? String, !chosenId.isEmpty else { return }
    recordOptions.micDeviceId = chosenId
    recordOptions.recordMic = true
    refreshMicMonitor()
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    let delta = NSSize(width: pt.x - dragOrigin.x, height: pt.y - dragOrigin.y)

    switch mode {
    case .drawing:
      selection = clamped(normalizedRect(from: dragOrigin, to: pt))
    case .moving:
      selection = moved(selectionAtDragStart, by: delta)
    case .resizing(let gMode):
      selection = resized(selectionAtDragStart, grip: gMode, by: delta)
    case .idle, .adjusting:
      return
    }
    if let selNow = selection {
      recordOptions.isFullScreen = (abs(selNow.width - bounds.width) < 2 && abs(selNow.height - bounds.height) < 2)
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
      // Gene - Nov, 13, 2026: In record mode, a click without drag opens full-screen Snagit pre-recording toolbar instead of starting unconfirmed.
      /*
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
      */
      if !isUsable(sel) {
        if initialMode == "record" {
          selection = bounds
          recordOptions.isFullScreen = true
          mode = .adjusting
          refreshChrome()
        } else {
          selection = nil
          mode = .idle
          settle(with: screenImage)
        }
        return
      }
      recordOptions.isFullScreen = (abs(sel.width - bounds.width) < 2 && abs(sel.height - bounds.height) < 2)
      mode = .adjusting
      refreshChrome()

    case .moving, .resizing:
      if let sel = selection, isUsable(sel) {
        recordOptions.isFullScreen = (abs(sel.width - bounds.width) < 2 && abs(sel.height - bounds.height) < 2)
        mode = .adjusting
      } else {
        selection = nil
        mode = .idle
      }
      refreshChrome()

    case .idle, .adjusting:
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
    stopMicMonitor()
    mode = .idle
    recordOptions.isFullScreen = recordOptions.isFullScreen ||
      (abs(rect.width - bounds.width) < 2 && abs(rect.height - bounds.height) < 2)
    onRecordCapture?(rect, recordOptions)
  }

  // Gene - Oct, 27, 2026: Added startPanoramicCapture to settle with selected rect for panoramic capture.
  private func startPanoramicCapture() {
    guard let sel = selection, isUsable(sel) else { return }
    settlePanoramic(with: sel)
  }

  private func settlePanoramic(with rect: NSRect) {
    guard !hasSettled else { return }
    hasSettled = true
    stopMicMonitor()
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
    stopMicMonitor()
    mode = .idle
    onCapture(image)
  }

  /// Cancels the capture, once.
  private func settleCancelled() {
    guard !hasSettled else { return }
    hasSettled = true
    stopMicMonitor()
    mode = .idle
    onCancel()
  }

  // MARK: - Drawing

  // Gene - Nov, 13, 2026: Render Snagit idle quick presets and rich Pre-Recording Toolbar when initialMode == "record".
  /*
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
    ...
    if settled {
      drawGrips(for: selRect, accent: accent)
      drawCaptureButton(for: selRect, accent: accent)
    } else {
      captureButtonRect = .zero
      panoramicButtonRect = .zero
      cancelButtonRect = .zero
    }
  }
  */
  private func clearToolbarRects() {
    captureButtonRect = .zero
    panoramicButtonRect = .zero
    recordButtonRect = .zero
    cancelButtonRect = .zero
    tbPresetFullRect = .zero
    tbPreset1080Rect = .zero
    tbPreset720Rect = .zero
    tbFpsRect = .zero
    tbMicRect = .zero
    tbMicChevronRect = .zero
    tbSysAudioRect = .zero
    tbCursorRect = .zero
    tbImageRect = .zero
  }

  private func clearIdlePresetRects() {
    idleFullRect = .zero
    idle1080Rect = .zero
    idle720Rect = .zero
    idleCancelRect = .zero
  }

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
      clearToolbarRects()
      if case .idle = mode, initialMode == "record" {
        drawIdleRecordPresetsBar()
      } else {
        clearIdlePresetRects()
      }
      return
    }
    clearIdlePresetRects()

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

    var settled = false
    if case .adjusting = mode { settled = true }
    if case .moving = mode { settled = true }
    if case .resizing = mode { settled = true }

    if settled {
      drawGrips(for: selRect, accent: accent)
      if initialMode == "record" {
        drawSnagitRecordToolbar(for: selRect, accent: accent)
      } else {
        drawCaptureButton(for: selRect, accent: accent)
      }
    } else {
      clearToolbarRects()
    }
  }

  private func drawPillChip(
    rect box: NSRect,
    label: String,
    active: Bool,
    hot: Bool,
    activeColor: NSColor,
    dotColor: NSColor? = nil
  ) {
    let pill = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
    if active {
      let fill = hot ? (activeColor.blended(withFraction: 0.25, of: .white) ?? activeColor) : activeColor
      fill.setFill()
    } else {
      let base = hot ? NSColor(white: 1.0, alpha: 0.22) : NSColor(white: 1.0, alpha: 0.11)
      base.setFill()
    }
    pill.fill()
    NSColor(white: 1.0, alpha: active ? 0.42 : 0.2).setStroke()
    pill.lineWidth = 1.0
    pill.stroke()

    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white
    ]
    let attr = NSAttributedString(string: label, attributes: attrs)
    let tSize = attr.size()
    if let dCol = dotColor {
      let dotD: CGFloat = 7
      let contentW = dotD + 5 + tSize.width
      let startX = box.midX - contentW / 2
      dCol.setFill()
      NSBezierPath(ovalIn: NSRect(x: startX, y: box.midY - dotD / 2, width: dotD, height: dotD)).fill()
      attr.draw(at: NSPoint(x: startX + dotD + 5, y: box.midY - tSize.height / 2))
    } else {
      attr.draw(at: NSPoint(x: box.midX - tSize.width / 2, y: box.midY - tSize.height / 2))
    }
  }

  private func drawIdleRecordPresetsBar() {
    let barW: CGFloat = 530
    let barH: CGFloat = 44
    let barX = max(12, bounds.midX - barW / 2)
    let barY = max(24, bounds.height - barH - 64)
    let barRect = NSRect(x: barX, y: barY, width: barW, height: barH)

    let barPath = NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2)
    bean.setFill()
    barPath.fill()
    NSColor(white: 1.0, alpha: 0.25).setStroke()
    barPath.lineWidth = 1.0
    barPath.stroke()

    let prompt = "Drag region or select:"
    let pAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
      .foregroundColor: NSColor(white: 1.0, alpha: 0.85)
    ]
    let pAttr = NSAttributedString(string: prompt, attributes: pAttrs)
    let pSize = pAttr.size()
    pAttr.draw(at: NSPoint(x: barRect.minX + 14, y: barRect.midY - pSize.height / 2))

    let btnH: CGFloat = 26
    let by = barRect.midY - btnH / 2
    var cursorX = barRect.minX + 14 + pSize.width + 10

    idleFullRect = NSRect(x: cursorX, y: by, width: 90, height: btnH)
    drawPillChip(rect: idleFullRect, label: "Full Screen", active: false, hot: hotChipKey == "idleFull", activeColor: coffee)
    cursorX += 96

    idle1080Rect = NSRect(x: cursorX, y: by, width: 84, height: btnH)
    drawPillChip(rect: idle1080Rect, label: "1920×1080", active: false, hot: hotChipKey == "idle1080", activeColor: coffee)
    cursorX += 90

    idle720Rect = NSRect(x: cursorX, y: by, width: 78, height: btnH)
    drawPillChip(rect: idle720Rect, label: "1280×720", active: false, hot: hotChipKey == "idle720", activeColor: coffee)
    cursorX += 84

    idleCancelRect = NSRect(x: cursorX, y: by, width: 64, height: btnH)
    drawPillChip(rect: idleCancelRect, label: "Cancel", active: false, hot: hotChipKey == "idleCancel", activeColor: coffee)
  }

  private func drawSnagitRecordToolbar(for selRect: NSRect, accent: NSColor) {
    captureButtonRect = .zero
    panoramicButtonRect = .zero

    let barW: CGFloat = min(bounds.width - 16, 704)
    let barH: CGFloat = 44
    let presetBarH: CGFloat = 28
    let gap: CGFloat = 6
    let margin: CGFloat = 10

    var barY = selRect.minY - barH - margin
    if barY < 10 {
      barY = selRect.maxY + margin
    }
    if barY + barH > bounds.height - 10 {
      barY = max(12, selRect.minY + 14)
    }
    var barX = selRect.midX - barW / 2
    if barX < 8 { barX = 8 }
    if barX + barW > bounds.width - 8 { barX = bounds.width - barW - 8 }

    // Main Snagit pre-recording bar
    let barRect = NSRect(x: barX, y: barY, width: barW, height: barH)
    let barPath = NSBezierPath(roundedRect: barRect, xRadius: 12, yRadius: 12)
    bean.setFill()
    barPath.fill()
    NSColor(white: 1.0, alpha: 0.25).setStroke()
    barPath.lineWidth = 1.0
    barPath.stroke()

    // Upper compact preset strip above main toolbar
    let pStripW: CGFloat = 248
    var pStripY = barRect.maxY + gap
    if pStripY + presetBarH > bounds.height - 8 {
      pStripY = max(8, barRect.minY - presetBarH - gap)
    }
    let pStripX = min(bounds.width - pStripW - 8, max(8, barRect.minX))
    let pStripRect = NSRect(x: pStripX, y: pStripY, width: pStripW, height: presetBarH)
    let pStripPath = NSBezierPath(roundedRect: pStripRect, xRadius: 8, yRadius: 8)
    bean.setFill()
    pStripPath.fill()
    NSColor(white: 1.0, alpha: 0.2).setStroke()
    pStripPath.lineWidth = 1.0
    pStripPath.stroke()

    let pChipH: CGFloat = 20
    let pChipY = pStripRect.midY - pChipH / 2
    var px = pStripRect.minX + 6
    tbPresetFullRect = NSRect(x: px, y: pChipY, width: 72, height: pChipH)
    drawPillChip(rect: tbPresetFullRect, label: "Full Screen", active: recordOptions.isFullScreen, hot: hotChipKey == "tbFull", activeColor: accent)
    px += 78
    tbPreset1080Rect = NSRect(x: px, y: pChipY, width: 78, height: pChipH)
    drawPillChip(rect: tbPreset1080Rect, label: "1920×1080", active: false, hot: hotChipKey == "tb1080", activeColor: accent)
    px += 84
    tbPreset720Rect = NSRect(x: px, y: pChipY, width: 72, height: pChipH)
    drawPillChip(rect: tbPreset720Rect, label: "1280×720", active: false, hot: hotChipKey == "tb720", activeColor: accent)

    // Populate main bar controls
    let chipH: CGFloat = 28
    let cy = barRect.midY - chipH / 2
    var cx = barRect.minX + 8

    // 1. FPS toggle
    tbFpsRect = NSRect(x: cx, y: cy, width: 62, height: chipH)
    drawPillChip(rect: tbFpsRect, label: "\(recordOptions.fps) FPS", active: recordOptions.fps == 60, hot: hotChipKey == "tbFps", activeColor: accent)
    cx += 68

    // 2. Mic toggle + 5-bar live RMS meter
    tbMicRect = NSRect(x: cx, y: cy, width: 100, height: chipH)
    drawPillChip(rect: tbMicRect, label: "Mic     ", active: recordOptions.recordMic, hot: hotChipKey == "tbMic", activeColor: accent)
    // Draw 5 vertical level bars on the right half of Mic chip
    let barsStartX = tbMicRect.minX + 46
    for barIdx in 0..<5 {
      let bh: CGFloat = 4 + CGFloat(barIdx) * 2.2
      let barBox = NSRect(x: barsStartX + CGFloat(barIdx) * 6, y: cy + (chipH - bh) / 2, width: 3.5, height: bh)
      let threshold = CGFloat(barIdx + 1) * 0.18
      let lit = recordOptions.recordMic && micLevel >= threshold
      let barCol: NSColor
      if lit {
        barCol = (barIdx >= 4) ? NSColor.systemOrange : NSColor.systemGreen
      } else {
        barCol = NSColor(white: 1.0, alpha: 0.28)
      }
      barCol.setFill()
      NSBezierPath(roundedRect: barBox, xRadius: 1.5, yRadius: 1.5).fill()
    }
    cx += 102

    // 3. Mic device picker chevron
    tbMicChevronRect = NSRect(x: cx, y: cy, width: 24, height: chipH)
    drawPillChip(rect: tbMicChevronRect, label: "▾", active: false, hot: hotChipKey == "tbMicChev", activeColor: accent)
    cx += 30

    // 4. System Audio toggle
    tbSysAudioRect = NSRect(x: cx, y: cy, width: 92, height: chipH)
    drawPillChip(rect: tbSysAudioRect, label: "Sys Audio", active: recordOptions.recordSystemAudio, hot: hotChipKey == "tbSys", activeColor: accent)
    cx += 98

    // 5. Cursor + Click highlights toggle
    tbCursorRect = NSRect(x: cx, y: cy, width: 104, height: chipH)
    drawPillChip(rect: tbCursorRect, label: "Cursor+Click", active: recordOptions.recordCursor && recordOptions.highlightClicks, hot: hotChipKey == "tbCursor", activeColor: accent)
    cx += 110

    // 6. Switch to Image capture
    tbImageRect = NSRect(x: cx, y: cy, width: 66, height: chipH)
    drawPillChip(rect: tbImageRect, label: "Image", active: false, hot: hotChipKey == "tbImage", activeColor: accent)
    cx += 74

    // 7. Crimson Rec button & Cancel X pinned at right
    let cancelSide: CGFloat = 28
    cancelButtonRect = NSRect(x: barRect.maxX - cancelSide - 8, y: cy, width: cancelSide, height: cancelSide)
    drawCancelButton(in: cancelButtonRect, accent: accent)

    let recW: CGFloat = max(72, cancelButtonRect.minX - cx - 8)
    recordButtonRect = NSRect(x: cancelButtonRect.minX - recW - 6, y: cy, width: recW, height: chipH)
    drawPillChip(
      rect: recordButtonRect,
      label: "Rec",
      active: true,
      hot: recordButtonHot,
      activeColor: crimson,
      dotColor: .white
    )
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
// Gene - Nov, 13, 2026: Replaced CGWindowListCreateImage timer recorder and non-draggable HUD with ScreenCaptureKit SCStream, MacAudioMixer, CountdownOverlayWindow, ClickHighlightOverlayWindow, draggable RecordingHudWindow, and MacVideoTexturePlayer (FlutterTexture).
/*
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
*/

// MARK: - Countdown & Click Highlight Overlays (Gene - Nov, 13, 2026)

private final class CountdownOverlayWindow: NSPanel {
  private let countdownView: CountdownOverlayView

  init(contentRect: NSRect, initialValue: Int) {
    let view = CountdownOverlayView(frame: NSRect(origin: .zero, size: contentRect.size), value: initialValue)
    self.countdownView = view
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .screenSaver
    self.hasShadow = true
    self.ignoresMouseEvents = true
    self.hidesOnDeactivate = false
    self.sharingType = .none
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    self.contentView = view
  }

  func updateValue(_ val: Int) {
    countdownView.updateValue(val)
  }

  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

private final class CountdownOverlayView: NSView {
  private var value: Int
  private let bean = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.90)
  private let accent = NSColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 1.0)

  init(frame: NSRect, value: Int) {
    self.value = value
    super.init(frame: frame)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateValue(_ newValue: Int) {
    self.value = newValue
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 24, yRadius: 24)
    bean.setFill()
    bg.fill()
    accent.withAlphaComponent(0.65).setStroke()
    bg.lineWidth = 2.5
    bg.stroke()

    let numStr = "\(value)"
    let numAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold),
      .foregroundColor: NSColor.white
    ]
    let numAttr = NSAttributedString(string: numStr, attributes: numAttrs)
    let numSz = numAttr.size()
    numAttr.draw(at: NSPoint(x: bounds.midX - numSz.width / 2, y: bounds.midY - numSz.height / 2 + 10))

    let subStr = "Esc to cancel"
    let subAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor(white: 1.0, alpha: 0.72)
    ]
    let subAttr = NSAttributedString(string: subStr, attributes: subAttrs)
    let subSz = subAttr.size()
    subAttr.draw(at: NSPoint(x: bounds.midX - subSz.width / 2, y: 14))
  }
}

private final class ClickHighlightOverlayWindow: NSPanel {
  private let hlView: ClickHighlightOverlayView
  private var globalMonitor: Any?
  private var localMonitor: Any?

  init(screen: NSScreen) {
    let view = ClickHighlightOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screenOrigin: screen.frame.origin)
    self.hlView = view
    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .statusBar
    self.hasShadow = false
    self.ignoresMouseEvents = true
    self.hidesOnDeactivate = false
    self.sharingType = .readOnly
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    self.contentView = view

    self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.hlView.triggerPulse(atScreenPoint: NSEvent.mouseLocation)
    }
    self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
      self?.hlView.triggerPulse(atScreenPoint: NSEvent.mouseLocation)
      return ev
    }
  }

  func stopMonitoring() {
    if let gMon = globalMonitor {
      NSEvent.removeMonitor(gMon)
      globalMonitor = nil
    }
    if let lMon = localMonitor {
      NSEvent.removeMonitor(lMon)
      localMonitor = nil
    }
    hlView.stopTimer()
  }

  deinit {
    stopMonitoring()
  }

  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

private final class ClickHighlightOverlayView: NSView {
  private struct RingPulse {
    let center: NSPoint
    let startTime: CFTimeInterval
  }

  private let screenOrigin: NSPoint
  private var pulses: [RingPulse] = []
  private var animTimer: Timer?

  init(frame: NSRect, screenOrigin: NSPoint) {
    self.screenOrigin = screenOrigin
    super.init(frame: frame)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func stopTimer() {
    animTimer?.invalidate()
    animTimer = nil
  }

  func triggerPulse(atScreenPoint pt: NSPoint) {
    let localPt = NSPoint(x: pt.x - screenOrigin.x, y: pt.y - screenOrigin.y)
    guard bounds.contains(localPt) else { return }
    DispatchQueue.main.async { [weak self] in
      guard let strongSelf = self else { return }
      strongSelf.pulses.append(RingPulse(center: localPt, startTime: CACurrentMediaTime()))
      if strongSelf.animTimer == nil {
        strongSelf.animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
          self?.tickAnimation()
        }
      }
      strongSelf.needsDisplay = true
    }
  }

  private func tickAnimation() {
    let now = CACurrentMediaTime()
    pulses.removeAll { now - $0.startTime > 0.28 }
    if pulses.isEmpty {
      stopTimer()
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let now = CACurrentMediaTime()
    for p in pulses {
      let progress = CGFloat(min(1.0, max(0.0, (now - p.startTime) / 0.28)))
      let radius = 10.0 + progress * 24.0
      let alpha = (1.0 - progress) * 0.85
      let ringRect = NSRect(x: p.center.x - radius, y: p.center.y - radius, width: radius * 2, height: radius * 2)
      let path = NSBezierPath(ovalIn: ringRect)
      NSColor(red: 0.96, green: 0.72, blue: 0.22, alpha: alpha).setStroke()
      path.lineWidth = 3.0 * (1.0 - progress * 0.4)
      path.stroke()
    }
  }
}

// MARK: - Real-time 48kHz Stereo AAC Audio Mixer (Mic + SCStream System Audio)

private final class MacAudioMixer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let targetFormat: AVAudioFormat
  private let formatDesc: CMAudioFormatDescription
  private let mixQueue = DispatchQueue(label: "com.snipsnap.audiomixer.mix", qos: .userInitiated)
  private let lock = NSLock()

  private var sysBuffer: [Float] = []
  private var micBuffer: [Float] = []
  private var sysConverter: AVAudioConverter?
  private var sysSig: String = ""
  private var micConverter: AVAudioConverter?
  private var micSig: String = ""

  private var captureSession: AVCaptureSession?
  private var mixTimer: DispatchSourceTimer?
  private var isMicMuted: Bool = false
  private var isPaused: Bool = false
  private var isStopped: Bool = false
  private var nextAudioPts: CMTime = .zero
  private let chunkFrames = 960 // 20ms @ 48kHz

  private let audioInput: AVAssetWriterInput
  private let elapsedMsProvider: () -> Int

  init?(
    audioInput: AVAssetWriterInput,
    enableMic: Bool,
    micDeviceId: String?,
    elapsedMsProvider: @escaping () -> Int
  ) {
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true) else {
      return nil
    }
    self.targetFormat = fmt
    self.formatDesc = fmt.formatDescription
    self.audioInput = audioInput
    self.elapsedMsProvider = elapsedMsProvider
    super.init()

    if enableMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
      setupMicSession(deviceId: micDeviceId)
    }

    let timerSrc = DispatchSource.makeTimerSource(queue: mixQueue)
    timerSrc.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
    timerSrc.setEventHandler { [weak self] in
      self?.drainMixChunk()
    }
    self.mixTimer = timerSrc
    timerSrc.resume()
  }

  private func setupMicSession(deviceId: String?) {
    let session = AVCaptureSession()
    let dev: AVCaptureDevice?
    if let devId = deviceId, !devId.isEmpty {
      dev = AVCaptureDevice(uniqueID: devId) ?? AVCaptureDevice.default(for: .audio)
    } else {
      dev = AVCaptureDevice.default(for: .audio)
    }
    guard let audioDev = dev,
          let input = try? AVCaptureDeviceInput(device: audioDev),
          session.canAddInput(input)
    else { return }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: mixQueue)
    guard session.canAddOutput(output) else { return }
    session.addOutput(output)
    self.captureSession = session
    mixQueue.async { [weak self] in
      self?.captureSession?.startRunning()
    }
  }

  func setMicrophoneMuted(_ muted: Bool) {
    lock.lock()
    isMicMuted = muted
    lock.unlock()
  }

  func setPaused(_ paused: Bool) {
    lock.lock()
    isPaused = paused
    if !paused {
      let curMs = max(0, elapsedMsProvider())
      let curTime = CMTime(value: Int64(curMs), timescale: 1000)
      if curTime > nextAudioPts {
        nextAudioPts = curTime
      }
      sysBuffer.removeAll(keepingCapacity: true)
      micBuffer.removeAll(keepingCapacity: true)
    }
    lock.unlock()
  }

  func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
    guard !isStopped, !isPaused else { return }
    let converted = convertToStereo48k(sampleBuffer, converter: &sysConverter, lastSig: &sysSig)
    guard !converted.isEmpty else { return }
    lock.lock()
    sysBuffer.append(contentsOf: converted)
    let maxCap = 48_000 * 2
    if sysBuffer.count > maxCap {
      sysBuffer.removeFirst(sysBuffer.count - maxCap)
    }
    lock.unlock()
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !isStopped, !isPaused else { return }
    lock.lock()
    let mutedNow = isMicMuted
    lock.unlock()
    guard !mutedNow else { return }
    let converted = convertToStereo48k(sampleBuffer, converter: &micConverter, lastSig: &micSig)
    guard !converted.isEmpty else { return }
    lock.lock()
    micBuffer.append(contentsOf: converted)
    let maxCap = 48_000 * 2
    if micBuffer.count > maxCap {
      micBuffer.removeFirst(micBuffer.count - maxCap)
    }
    lock.unlock()
  }

  private func convertToStereo48k(
    _ sbuf: CMSampleBuffer,
    converter: inout AVAudioConverter?,
    lastSig: inout String
  ) -> [Float] {
    guard let fmtDesc = CMSampleBufferGetFormatDescription(sbuf) else { return [] }
    let nFrames = CMSampleBufferGetNumSamples(sbuf)
    guard nFrames > 0 else { return [] }
    let srcFmt = AVAudioFormat(cmAudioFormatDescription: fmtDesc)
    let asbd = srcFmt.streamDescription.pointee
    let sig = "\(asbd.mSampleRate)_\(asbd.mChannelsPerFrame)_\(asbd.mFormatFlags)_\(asbd.mBitsPerChannel)"
    if converter == nil || lastSig != sig {
      converter = AVAudioConverter(from: srcFmt, to: targetFormat)
      lastSig = sig
    }
    guard let conv = converter else { return [] }

    var retainedBlk: CMBlockBuffer?
    var ablBytesNeeded = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sbuf,
      bufferListSizeNeededOut: &ablBytesNeeded,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: &retainedBlk
    )
    guard ablBytesNeeded > 0 else { return [] }
    let rawMem = UnsafeMutableRawPointer.allocate(byteCount: ablBytesNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawMem.deallocate() }
    let ablPtr = rawMem.bindMemory(to: AudioBufferList.self, capacity: 1)
    let ablStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sbuf,
      bufferListSizeNeededOut: nil,
      bufferListOut: ablPtr,
      bufferListSize: ablBytesNeeded,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &retainedBlk
    )
    guard ablStatus == noErr,
          let srcPCM = AVAudioPCMBuffer(pcmFormat: srcFmt, bufferListNoCopy: ablPtr, deallocator: nil)
    else { return [] }

    let outCap = AVAudioFrameCount(max(128, Int(Double(nFrames) * (48_000.0 / max(8000.0, srcFmt.sampleRate))) + 32))
    guard let dstPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return [] }

    var provided = false
    var convErr: NSError?
    let convStatus = conv.convert(to: dstPCM, error: &convErr) { _, inStatus in
      if provided {
        inStatus.pointee = .noDataNow
        return nil
      }
      provided = true
      inStatus.pointee = .haveData
      return srcPCM
    }
    guard convStatus != .error,
          dstPCM.frameLength > 0,
          let fPtr = dstPCM.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
    else { return [] }

    return Array(UnsafeBufferPointer(start: fPtr, count: Int(dstPCM.frameLength) * 2))
  }

  private func drainMixChunk() {
    guard !isStopped else { return }
    let needed = chunkFrames * 2

    lock.lock()
    if isPaused {
      lock.unlock()
      return
    }
    var mixed = [Float](repeating: 0.0, count: needed)
    let sysTake = min(needed, sysBuffer.count)
    if sysTake > 0 {
      for i in 0..<sysTake {
        mixed[i] += sysBuffer[i]
      }
      sysBuffer.removeFirst(sysTake)
    }
    let micTake = min(needed, micBuffer.count)
    if micTake > 0 {
      if !isMicMuted {
        for i in 0..<micTake {
          mixed[i] += micBuffer[i]
        }
      }
      micBuffer.removeFirst(micTake)
    }
    for i in 0..<needed {
      mixed[i] = tanhf(mixed[i])
    }
    let pts = nextAudioPts
    nextAudioPts = CMTimeAdd(pts, CMTime(value: CMTimeValue(chunkFrames), timescale: 48_000))
    lock.unlock()

    guard audioInput.isReadyForMoreMediaData else { return }

    let byteLen = needed * MemoryLayout<Float>.size
    var blockOut: CMBlockBuffer?
    let blkStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteLen,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteLen,
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &blockOut
    )
    guard blkStatus == noErr, let blk = blockOut else { return }

    let copyStatus = mixed.withUnsafeBytes { rawBytes -> OSStatus in
      guard let basePtr = rawBytes.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(with: basePtr, blockBuffer: blk, offsetIntoDestination: 0, dataLength: byteLen)
    }
    guard copyStatus == noErr else { return }

    var sbOut: CMSampleBuffer?
    let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: blk,
      formatDescription: formatDesc,
      sampleCount: chunkFrames,
      presentationTimeStamp: pts,
      packetDescriptions: nil,
      sampleBufferOut: &sbOut
    )
    if sbStatus == noErr, let outSB = sbOut {
      audioInput.append(outSB)
    }
  }

  func stop() {
    isStopped = true
    mixTimer?.cancel()
    mixTimer = nil
    let capSess = captureSession
    captureSession = nil
    mixQueue.async {
      if let s = capSess, s.isRunning {
        s.stopRunning()
      }
    }
  }
}

// MARK: - ScreenCaptureKit 60fps Recorder Session

private final class MacScreenRecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
  let targetPath: String
  let thumbnailPath: String
  let displayID: CGDirectDisplayID
  let screenQuartzFrame: CGRect
  let pointRect: CGRect
  let scale: CGFloat
  let fps: Int
  let recordAudio: Bool
  let microphoneDeviceId: String?
  let recordSystemAudio: Bool
  let recordCursor: Bool
  let onTick: (Int, Bool) -> Void
  let onStreamError: (String) -> Void

  private let writerQueue = DispatchQueue(label: "com.snipsnap.screcorder.writer", qos: .userInteractive)
  private let audioSampleQueue = DispatchQueue(label: "com.snipsnap.screcorder.audio", qos: .userInitiated)
  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var audioInput: AVAssetWriterInput?
  private var scStream: SCStream?
  private var audioMixer: MacAudioMixer?
  private var tickTimer: DispatchSourceTimer?

  private(set) var isPaused: Bool = false
  private(set) var isMicrophoneMuted: Bool = false
  private var isStopped: Bool = false
  private var startTimestampNs: UInt64 = 0
  private var pauseStartNs: UInt64 = 0
  private var totalPausedNs: UInt64 = 0
  private var frameCount: Int64 = 0
  private var lastVideoPts: CMTime = CMTime(value: -1, timescale: 1000)
  private var lastFrameWallNs: UInt64 = 0
  private var lastPixelBuffer: CVPixelBuffer?
  private var wroteThumbnail: Bool = false
  private(set) var pixelWidth: Int = 0
  private(set) var pixelHeight: Int = 0

  init(
    targetPath: String,
    thumbnailPath: String,
    displayID: CGDirectDisplayID,
    screenQuartzFrame: CGRect,
    pointRect: CGRect,
    scale: CGFloat,
    fps: Int,
    recordAudio: Bool,
    microphoneDeviceId: String?,
    recordSystemAudio: Bool,
    recordCursor: Bool,
    onTick: @escaping (Int, Bool) -> Void,
    onStreamError: @escaping (String) -> Void
  ) {
    self.targetPath = targetPath
    self.thumbnailPath = thumbnailPath
    self.displayID = displayID
    self.screenQuartzFrame = screenQuartzFrame
    self.pointRect = pointRect
    self.scale = scale
    self.fps = fps
    self.recordAudio = recordAudio
    self.microphoneDeviceId = microphoneDeviceId
    self.recordSystemAudio = recordSystemAudio
    self.recordCursor = recordCursor
    self.onTick = onTick
    self.onStreamError = onStreamError
    super.init()

    let rawW = max(64, Int((pointRect.width * scale).rounded()))
    let rawH = max(64, Int((pointRect.height * scale).rounded()))
    self.pixelWidth = rawW & ~1
    self.pixelHeight = rawH & ~1
  }

  func setMicrophoneMuted(_ muted: Bool) {
    isMicrophoneMuted = muted
    audioMixer?.setMicrophoneMuted(muted)
  }

  func currentElapsedMs() -> Int {
    guard startTimestampNs > 0 else { return 0 }
    let now = DispatchTime.now().uptimeNanoseconds
    let effectiveNow = isPaused ? pauseStartNs : now
    guard effectiveNow > startTimestampNs + totalPausedNs else { return 0 }
    return Int((effectiveNow - startTimestampNs - totalPausedNs) / 1_000_000)
  }

  func pause() {
    writerQueue.async { [weak self] in
      guard let strongSelf = self, !strongSelf.isPaused, !strongSelf.isStopped else { return }
      strongSelf.isPaused = true
      strongSelf.pauseStartNs = DispatchTime.now().uptimeNanoseconds
      strongSelf.audioMixer?.setPaused(true)
      strongSelf.onTick(strongSelf.currentElapsedMs(), true)
    }
  }

  func resume() {
    writerQueue.async { [weak self] in
      guard let strongSelf = self, strongSelf.isPaused, !strongSelf.isStopped else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      if now > strongSelf.pauseStartNs {
        strongSelf.totalPausedNs += (now - strongSelf.pauseStartNs)
      }
      strongSelf.isPaused = false
      strongSelf.audioMixer?.setPaused(false)
      strongSelf.onTick(strongSelf.currentElapsedMs(), false)
    }
  }

  func prepareAndStart(excludingWindowNumbers: [Int], completion: @escaping (Bool) -> Void) {
    // Gene - Nov, 13, 2026: Use SCShareableContent.getExcludingDesktopWindows completion-handler API on macOS 13+.
    // SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, shareErr in
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, shareErr in
      guard let strongSelf = self else {
        completion(false)
        return
      }
      guard shareErr == nil, let scContent = content else {
        completion(false)
        return
      }
      guard let matchedDisplay = scContent.displays.first(where: { $0.displayID == strongSelf.displayID })
        ?? scContent.displays.first
      else {
        completion(false)
        return
      }

      let excludedSet = Set(excludingWindowNumbers)
      let excludedWindows = scContent.windows.filter { excludedSet.contains(Int($0.windowID)) }
      let filter = SCContentFilter(display: matchedDisplay, excludingWindows: excludedWindows)

      let config = SCStreamConfiguration()
      config.width = strongSelf.pixelWidth
      config.height = strongSelf.pixelHeight
      config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(15, strongSelf.fps)))
      config.pixelFormat = kCVPixelFormatType_32BGRA
      config.showsCursor = strongSelf.recordCursor
      config.capturesAudio = strongSelf.recordSystemAudio
      config.sampleRate = 48_000
      config.channelCount = 2
      config.excludesCurrentProcessAudio = true
      config.queueDepth = 5

      let localX = max(0, strongSelf.pointRect.origin.x - strongSelf.screenQuartzFrame.origin.x)
      let localY = max(0, strongSelf.pointRect.origin.y - strongSelf.screenQuartzFrame.origin.y)
      let cropW = min(strongSelf.screenQuartzFrame.width - localX, strongSelf.pointRect.width)
      let cropH = min(strongSelf.screenQuartzFrame.height - localY, strongSelf.pointRect.height)
      if cropW >= 8 && cropH >= 8 &&
        (abs(cropW - strongSelf.screenQuartzFrame.width) > 2 ||
         abs(cropH - strongSelf.screenQuartzFrame.height) > 2 ||
         localX > 1 || localY > 1)
      {
        config.sourceRect = CGRect(x: localX, y: localY, width: cropW, height: cropH)
      }

      strongSelf.writerQueue.async {
        guard strongSelf.setupWriter() else {
          completion(false)
          return
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: strongSelf)
        do {
          try stream.addStreamOutput(strongSelf, type: .screen, sampleHandlerQueue: strongSelf.writerQueue)
          if strongSelf.recordSystemAudio {
            try stream.addStreamOutput(strongSelf, type: .audio, sampleHandlerQueue: strongSelf.audioSampleQueue)
          }
        } catch {
          strongSelf.assetWriter?.cancelWriting()
          completion(false)
          return
        }

        stream.startCapture { startErr in
          if startErr != nil {
            strongSelf.writerQueue.async {
              strongSelf.audioMixer?.stop()
              strongSelf.assetWriter?.cancelWriting()
            }
            completion(false)
            return
          }
          strongSelf.writerQueue.async {
            strongSelf.scStream = stream
            strongSelf.startTimestampNs = DispatchTime.now().uptimeNanoseconds
            strongSelf.lastFrameWallNs = strongSelf.startTimestampNs
            strongSelf.startKeepAliveTimer()
            completion(true)
          }
        }
      }
    }
  }

  private func setupWriter() -> Bool {
    let url = URL(fileURLWithPath: targetPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
      return false
    }

    let bitrate = max(3_000_000, pixelWidth * pixelHeight * (fps >= 50 ? 6 : 4))
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
    let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    vInput.expectsMediaDataInRealTime = true

    let bufAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: pixelWidth,
      kCVPixelBufferHeightKey as String: pixelHeight
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: vInput,
      sourcePixelBufferAttributes: bufAttrs
    )
    guard writer.canAdd(vInput) else { return false }
    writer.add(vInput)

    var aInput: AVAssetWriterInput?
    if recordAudio || recordSystemAudio {
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 2,
        AVSampleRateKey: 48_000,
        AVEncoderBitRateKey: 192_000
      ]
      let candidateAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      candidateAudio.expectsMediaDataInRealTime = true
      if writer.canAdd(candidateAudio) {
        writer.add(candidateAudio)
        aInput = candidateAudio
      }
    }

    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)

    self.assetWriter = writer
    self.videoInput = vInput
    self.pixelBufferAdaptor = adaptor
    self.audioInput = aInput
    if let addedAudio = aInput {
      self.audioMixer = MacAudioMixer(
        audioInput: addedAudio,
        enableMic: recordAudio,
        micDeviceId: microphoneDeviceId,
        elapsedMsProvider: { [weak self] in self?.currentElapsedMs() ?? 0 }
      )
      self.audioMixer?.setMicrophoneMuted(isMicrophoneMuted)
    }
    return true
  }

  private func startKeepAliveTimer() {
    let t = DispatchSource.makeTimerSource(queue: writerQueue)
    t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200), leeway: .milliseconds(10))
    t.setEventHandler { [weak self] in
      self?.onKeepAliveTick()
    }
    self.tickTimer = t
    t.resume()
  }

  private func onKeepAliveTick() {
    guard !isStopped else { return }
    let elapsed = currentElapsedMs()
    onTick(elapsed, isPaused)
    if isPaused { return }

    let nowNs = DispatchTime.now().uptimeNanoseconds
    if nowNs - lastFrameWallNs >= 300_000_000, let cached = lastPixelBuffer {
      appendPixelBuffer(cached, atMs: elapsed)
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard !isStopped else { return }
    switch type {
    case .audio:
      if !isPaused {
        audioMixer?.appendSystemAudio(sampleBuffer)
      }
    case .screen:
      guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
         let rawStatus = attachments.first?[.status] as? Int,
         let fStatus = SCFrameStatus(rawValue: rawStatus),
         fStatus != .complete
      {
        return
      }
      guard !isPaused, let pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
      let elapsed = currentElapsedMs()
      lastFrameWallNs = DispatchTime.now().uptimeNanoseconds
      lastPixelBuffer = pixBuf

      if !wroteThumbnail && !thumbnailPath.isEmpty {
        wroteThumbnail = true
        saveThumbnailPixelBuffer(pixBuf, toPath: thumbnailPath)
      }
      appendPixelBuffer(pixBuf, atMs: elapsed)
    @unknown default:
      break
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    guard !isStopped else { return }
    onStreamError(error.localizedDescription)
  }

  private func appendPixelBuffer(_ pixBuf: CVPixelBuffer, atMs ms: Int) {
    guard let vInput = videoInput,
          let adaptor = pixelBufferAdaptor,
          vInput.isReadyForMoreMediaData
    else { return }

    var pts = CMTime(value: Int64(max(0, ms)), timescale: 1000)
    if pts <= lastVideoPts {
      pts = CMTimeAdd(lastVideoPts, CMTime(value: 1, timescale: 1000))
    }
    if adaptor.append(pixBuf, withPresentationTime: pts) {
      lastVideoPts = pts
      frameCount += 1
    }
  }

  private func synthesizeFallbackPixelBuffer() -> CVPixelBuffer? {
    guard let pool = pixelBufferAdaptor?.pixelBufferPool else { return nil }
    var outBuf: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuf) == kCVReturnSuccess,
          let buf = outBuf
    else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    if let base = CVPixelBufferGetBaseAddress(buf) {
      let bytesTotal = CVPixelBufferGetBytesPerRow(buf) * pixelHeight
      memset(base, 0, bytesTotal)
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
  }

  private func saveThumbnailPixelBuffer(_ pixBuf: CVPixelBuffer, toPath path: String) {
    let ciImg = CIImage(cvPixelBuffer: pixBuf)
    let ctx = CIContext(options: nil)
    guard let cgImg = ctx.createCGImage(ciImg, from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixBuf), height: CVPixelBufferGetHeight(pixBuf))) else {
      return
    }
    let thumbURL = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: cgImg)
    if let pngData = rep.representation(using: .png, properties: [:]) {
      try? pngData.write(to: thumbURL, options: .atomic)
    }
  }

  func stop(cancel: Bool, completion: @escaping ([String: Any]?) -> Void) {
    writerQueue.async { [weak self] in
      guard let strongSelf = self else {
        completion(nil)
        return
      }
      if strongSelf.isStopped {
        completion(nil)
        return
      }
      strongSelf.isStopped = true
      let finalDurationMs = max(120, strongSelf.currentElapsedMs())

      strongSelf.tickTimer?.cancel()
      strongSelf.tickTimer = nil
      strongSelf.audioMixer?.stop()
      strongSelf.audioMixer = nil

      let activeStream = strongSelf.scStream
      strongSelf.scStream = nil
      activeStream?.stopCapture { _ in }

      guard let writer = strongSelf.assetWriter, let vInput = strongSelf.videoInput else {
        completion(nil)
        return
      }

      if cancel {
        writer.cancelWriting()
        try? FileManager.default.removeItem(atPath: strongSelf.targetPath)
        if !strongSelf.thumbnailPath.isEmpty {
          try? FileManager.default.removeItem(atPath: strongSelf.thumbnailPath)
        }
        completion(nil)
        return
      }

      // Guarantee static-screen & ultra-short clips always have >=2 valid frames.
      if strongSelf.frameCount == 0 {
        if let fallback = strongSelf.synthesizeFallbackPixelBuffer() {
          strongSelf.appendPixelBuffer(fallback, atMs: 0)
          strongSelf.appendPixelBuffer(fallback, atMs: finalDurationMs)
        }
      } else if let cached = strongSelf.lastPixelBuffer {
        strongSelf.appendPixelBuffer(cached, atMs: finalDurationMs)
      }

      vInput.markAsFinished()
      strongSelf.audioInput?.markAsFinished()
      writer.finishWriting {
        let ok = writer.status == .completed
        if !ok {
          completion(nil)
          return
        }
        let info: [String: Any] = [
          "filePath": strongSelf.targetPath,
          "thumbnailPath": strongSelf.thumbnailPath,
          "durationMs": finalDurationMs,
          "width": strongSelf.pixelWidth,
          "height": strongSelf.pixelHeight,
          "hasAudio": (strongSelf.recordAudio || strongSelf.recordSystemAudio)
        ]
        completion(info)
      }
    }
  }
}

// MARK: - Draggable Live Recording HUD Pill

private class RecordingHudWindow: NSPanel {
  init(
    contentRect: NSRect,
    onTogglePause: @escaping () -> Void,
    onStop: @escaping () -> Void,
    onRestart: @escaping () -> Void,
    onToggleMicMute: @escaping () -> Void,
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
      onRestart: onRestart,
      onToggleMicMute: onToggleMicMute,
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
  private let onRestart: () -> Void
  private let onToggleMicMute: () -> Void
  private let onCancel: () -> Void

  private var elapsedMs: Int = 0
  private var isPaused: Bool = false
  private var isMicEnabled: Bool = false
  private var isMicMuted: Bool = false

  private var hotKey: String = ""
  private var dragMouseStart: NSPoint = .zero
  private var dragWinOrigin: NSPoint = .zero
  private var isDraggingWindow: Bool = false

  private var micRect: NSRect = .zero
  private var pauseRect: NSRect = .zero
  private var restartRect: NSRect = .zero
  private var stopRect: NSRect = .zero
  private var cancelRect: NSRect = .zero

  private let bean = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.94)
  private let coffee = NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 1.0)
  private let recordRed = NSColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 1.0)

  init(
    frame: NSRect,
    onTogglePause: @escaping () -> Void,
    onStop: @escaping () -> Void,
    onRestart: @escaping () -> Void,
    onToggleMicMute: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onTogglePause = onTogglePause
    self.onStop = onStop
    self.onRestart = onRestart
    self.onToggleMicMute = onToggleMicMute
    self.onCancel = onCancel
    super.init(frame: frame)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(elapsedMs: Int, isPaused: Bool, isMicEnabled: Bool, isMicMuted: Bool) {
    self.elapsedMs = elapsedMs
    self.isPaused = isPaused
    self.isMicEnabled = isMicEnabled
    self.isMicMuted = isMicMuted
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
    let pt = convert(event.locationInWindow, from: nil)
    var next = ""
    if !micRect.isEmpty && micRect.contains(pt) { next = "mic" }
    else if !pauseRect.isEmpty && pauseRect.contains(pt) { next = "pause" }
    else if !restartRect.isEmpty && restartRect.contains(pt) { next = "restart" }
    else if !stopRect.isEmpty && stopRect.contains(pt) { next = "stop" }
    else if !cancelRect.isEmpty && cancelRect.contains(pt) { next = "cancel" }
    if next != hotKey {
      hotKey = next
      needsDisplay = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if !micRect.isEmpty && micRect.contains(pt) { onToggleMicMute(); return }
    if !pauseRect.isEmpty && pauseRect.contains(pt) { onTogglePause(); return }
    if !restartRect.isEmpty && restartRect.contains(pt) { onRestart(); return }
    if !stopRect.isEmpty && stopRect.contains(pt) { onStop(); return }
    if !cancelRect.isEmpty && cancelRect.contains(pt) { onCancel(); return }

    isDraggingWindow = true
    dragMouseStart = NSEvent.mouseLocation
    dragWinOrigin = window?.frame.origin ?? .zero
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDraggingWindow, let win = window else { return }
    let cur = NSEvent.mouseLocation
    let nextOrigin = NSPoint(
      x: dragWinOrigin.x + (cur.x - dragMouseStart.x),
      y: dragWinOrigin.y + (cur.y - dragMouseStart.y)
    )
    win.setFrameOrigin(nextOrigin)
  }

  override func mouseUp(with event: NSEvent) {
    isDraggingWindow = false
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

    // Drag grip dots
    NSColor(white: 1.0, alpha: 0.35).setFill()
    for col in 0..<2 {
      for row in 0..<3 {
        let dotBox = NSRect(x: 11 + CGFloat(col) * 4, y: midY - 6 + CGFloat(row) * 4.5, width: 2.2, height: 2.2)
        NSBezierPath(ovalIn: dotBox).fill()
      }
    }

    // Status dot
    let dotD: CGFloat = 9
    let dotRect = NSRect(x: 24, y: midY - dotD / 2, width: dotD, height: dotD)
    (isPaused ? NSColor.systemOrange : recordRed).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    // Timer readout
    let totalSecs = max(0, elapsedMs / 1000)
    let timeStr = String(format: "%02d:%02d", totalSecs / 60, totalSecs % 60) + (isPaused ? " II" : "")
    let timeAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold),
      .foregroundColor: NSColor.white
    ]
    let timeAttr = NSAttributedString(string: timeStr, attributes: timeAttrs)
    let timeSz = timeAttr.size()
    timeAttr.draw(at: NSPoint(x: 38, y: midY - timeSz.height / 2))

    // Cancel X button at right
    let btnH: CGFloat = 26
    let cancelD: CGFloat = 24
    let cancelX = bounds.maxX - cancelD - 8
    cancelRect = NSRect(x: cancelX, y: midY - cancelD / 2, width: cancelD, height: cancelD)
    (hotKey == "cancel" ? coffee : NSColor(white: 1.0, alpha: 0.15)).setFill()
    NSBezierPath(ovalIn: cancelRect).fill()
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

    let btnAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
      .foregroundColor: NSColor.white
    ]

    // Stop button
    let stopW: CGFloat = 62
    let stopX = cancelX - stopW - 6
    stopRect = NSRect(x: stopX, y: midY - btnH / 2, width: stopW, height: btnH)
    (hotKey == "stop" ? (recordRed.blended(withFraction: 0.25, of: .white) ?? recordRed) : recordRed).setFill()
    NSBezierPath(roundedRect: stopRect, xRadius: btnH / 2, yRadius: btnH / 2).fill()
    let stopAttr = NSAttributedString(string: "■ Stop", attributes: btnAttrs)
    let stopSz = stopAttr.size()
    stopAttr.draw(at: NSPoint(x: stopRect.midX - stopSz.width / 2, y: midY - stopSz.height / 2))

    // Restart button
    let restartW: CGFloat = 64
    let restartX = stopX - restartW - 6
    restartRect = NSRect(x: restartX, y: midY - btnH / 2, width: restartW, height: btnH)
    (hotKey == "restart" ? coffee : NSColor(white: 1.0, alpha: 0.16)).setFill()
    NSBezierPath(roundedRect: restartRect, xRadius: btnH / 2, yRadius: btnH / 2).fill()
    let restartAttr = NSAttributedString(string: "↺ Redo", attributes: btnAttrs)
    let restartSz = restartAttr.size()
    restartAttr.draw(at: NSPoint(x: restartRect.midX - restartSz.width / 2, y: midY - restartSz.height / 2))

    // Pause / Resume button
    let pauseW: CGFloat = 68
    let pauseX = restartX - pauseW - 6
    pauseRect = NSRect(x: pauseX, y: midY - btnH / 2, width: pauseW, height: btnH)
    (hotKey == "pause" ? coffee : NSColor(white: 1.0, alpha: 0.16)).setFill()
    NSBezierPath(roundedRect: pauseRect, xRadius: btnH / 2, yRadius: btnH / 2).fill()
    let pauseAttr = NSAttributedString(string: isPaused ? "▶ Play" : "❚❚ Pause", attributes: btnAttrs)
    let pauseSz = pauseAttr.size()
    pauseAttr.draw(at: NSPoint(x: pauseRect.midX - pauseSz.width / 2, y: midY - pauseSz.height / 2))

    // Live Mic Mute toggle button (always shown when mic enabled)
    if isMicEnabled {
      let micW: CGFloat = 58
      let micX = pauseX - micW - 6
      micRect = NSRect(x: micX, y: midY - btnH / 2, width: micW, height: btnH)
      let micFill = isMicMuted ? NSColor.systemOrange : (hotKey == "mic" ? coffee : NSColor(white: 1.0, alpha: 0.16))
      micFill.setFill()
      NSBezierPath(roundedRect: micRect, xRadius: btnH / 2, yRadius: btnH / 2).fill()
      let micAttr = NSAttributedString(string: isMicMuted ? "Muted" : "Mic On", attributes: btnAttrs)
      let micSz = micAttr.size()
      micAttr.draw(at: NSPoint(x: micRect.midX - micSz.width / 2, y: midY - micSz.height / 2))
    } else {
      micRect = .zero
    }
  }
}

// MARK: - 60fps Native Video Player Texture (AVPlayer + AVPlayerItemVideoOutput + FlutterTexture)

private final class MacVideoTexturePlayer: NSObject, FlutterTexture {
  private let videoURL: URL
  private weak var registry: FlutterTextureRegistry?
  private let onProgress: (Int64, Int, Bool) -> Void
  private let onCompleted: (Int64) -> Void

  private(set) var textureId: Int64 = -1
  private var player: AVPlayer?
  private var playerItem: AVPlayerItem?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var endObserver: NSObjectProtocol?
  private var frameTimer: DispatchSourceTimer?
  private let pixelLock = NSLock()
  private var currentBuffer: CVPixelBuffer?
  private var lastProgressEmitNs: UInt64 = 0
  private var playbackSpeed: Float = 1.0
  private var isPlaying: Bool = false
  private var isDisposed: Bool = false
  private var totalDurationMs: Int = 0

  init(
    videoPath: String,
    registry: FlutterTextureRegistry,
    onProgress: @escaping (Int64, Int, Bool) -> Void,
    onCompleted: @escaping (Int64) -> Void
  ) {
    self.videoURL = URL(fileURLWithPath: videoPath)
    self.registry = registry
    self.onProgress = onProgress
    self.onCompleted = onCompleted
    super.init()
  }

  func prepare(completion: @escaping ([String: Any]?) -> Void) {
    let asset = AVURLAsset(url: videoURL)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
      guard let strongSelf = self, !strongSelf.isDisposed else {
        completion(nil)
        return
      }
      var loadErr: NSError?
      let status = asset.statusOfValue(forKey: "tracks", error: &loadErr)
      guard status == .loaded, let vTrack = asset.tracks(withMediaType: .video).first else {
        completion(nil)
        return
      }

      let durMs = max(0, Int((CMTimeGetSeconds(asset.duration) * 1000.0).rounded()))
      strongSelf.totalDurationMs = durMs
      let transformed = vTrack.naturalSize.applying(vTrack.preferredTransform)
      let widthPx = max(1, Int(abs(transformed.width).rounded()))
      let heightPx = max(1, Int(abs(transformed.height).rounded()))
      let hasAudioTrack = !asset.tracks(withMediaType: .audio).isEmpty

      let outputAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
      ]
      let vOut = AVPlayerItemVideoOutput(pixelBufferAttributes: outputAttrs)
      let item = AVPlayerItem(asset: asset)
      item.add(vOut)

      DispatchQueue.main.async {
        guard let reg = strongSelf.registry, !strongSelf.isDisposed else {
          completion(nil)
          return
        }
        let pl = AVPlayer(playerItem: item)
        strongSelf.videoOutput = vOut
        strongSelf.playerItem = item
        strongSelf.player = pl
        let tid = reg.register(strongSelf)
        strongSelf.textureId = tid

        strongSelf.endObserver = NotificationCenter.default.addObserver(
          forName: .AVPlayerItemDidPlayToEndTime,
          object: item,
          queue: .main
        ) { [weak self] _ in
          guard let innerSelf = self, !innerSelf.isDisposed else { return }
          innerSelf.isPlaying = false
          innerSelf.stopFrameTimer()
          innerSelf.pullCurrentFrame(forceProgress: true)
          innerSelf.onCompleted(innerSelf.textureId)
        }

        // Pull initial frame at t = 0 once item is ready
        pl.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
          DispatchQueue.main.async {
            self?.pullCurrentFrame(forceProgress: true)
          }
        }

        completion([
          "textureId": tid,
          "durationMs": durMs,
          "width": widthPx,
          "height": heightPx,
          "hasAudio": hasAudioTrack
        ])
      }
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelLock.lock()
    defer { pixelLock.unlock() }
    guard let buf = currentBuffer else { return nil }
    return Unmanaged.passRetained(buf)
  }

  func play() {
    guard !isDisposed, let pl = player else { return }
    if let cur = pl.currentItem?.currentTime(),
       totalDurationMs > 0,
       Int((CMTimeGetSeconds(cur) * 1000.0).rounded()) >= totalDurationMs - 30
    {
      pl.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    isPlaying = true
    pl.playImmediately(atRate: playbackSpeed)
    startFrameTimer()
  }

  func pause() {
    guard !isDisposed else { return }
    isPlaying = false
    player?.pause()
    stopFrameTimer()
    pullCurrentFrame(forceProgress: true)
  }

  func seek(toMs ms: Int64) {
    guard !isDisposed, let pl = player else { return }
    let clampedMs = max(Int64(0), min(Int64(max(0, totalDurationMs)), ms))
    let target = CMTime(value: clampedMs, timescale: 1000)
    pl.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        self?.pullCurrentFrame(forceProgress: true)
      }
    }
  }

  func setVolume(_ vol: Float) {
    player?.volume = max(0.0, min(1.0, vol))
  }

  func setMuted(_ muted: Bool) {
    player?.isMuted = muted
  }

  func setSpeed(_ speed: Float) {
    playbackSpeed = max(0.25, min(4.0, speed))
    if isPlaying {
      player?.rate = playbackSpeed
    }
  }

  private func startFrameTimer() {
    stopFrameTimer()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
    t.setEventHandler { [weak self] in
      self?.pullCurrentFrame(forceProgress: false)
    }
    frameTimer = t
    t.resume()
  }

  private func stopFrameTimer() {
    frameTimer?.cancel()
    frameTimer = nil
  }

  private func pullCurrentFrame(forceProgress: Bool) {
    guard !isDisposed, let pl = player, let vOut = videoOutput else { return }
    let itemTime = vOut.itemTime(forHostTime: CACurrentMediaTime())
    let checkTime = itemTime.isValid ? itemTime : pl.currentTime()
    if vOut.hasNewPixelBuffer(forItemTime: checkTime),
       let pixBuf = vOut.copyPixelBuffer(forItemTime: checkTime, itemTimeForDisplay: nil)
    {
      pixelLock.lock()
      currentBuffer = pixBuf
      pixelLock.unlock()
      if textureId >= 0 {
        registry?.textureFrameAvailable(textureId)
      }
    }

    let nowNs = DispatchTime.now().uptimeNanoseconds
    if forceProgress || nowNs - lastProgressEmitNs >= 50_000_000 {
      lastProgressEmitNs = nowNs
      let posMs = max(0, min(totalDurationMs, Int((CMTimeGetSeconds(pl.currentTime()) * 1000.0).rounded())))
      onProgress(textureId, posMs, isPlaying)
    }
  }

  func dispose() {
    guard !isDisposed else { return }
    isDisposed = true
    isPlaying = false
    stopFrameTimer()
    if let obs = endObserver {
      NotificationCenter.default.removeObserver(obs)
      endObserver = nil
    }
    player?.pause()
    player = nil
    playerItem = nil
    videoOutput = nil
    pixelLock.lock()
    currentBuffer = nil
    pixelLock.unlock()
    if textureId >= 0 {
      registry?.unregisterTexture(textureId)
      textureId = -1
    }
  }
}

