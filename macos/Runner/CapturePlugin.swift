import AppKit
import CoreGraphics
import FlutterMacOS

/// Native macOS Screen Capture Plugin.
/// Provides interactive screen capture overlay where:
/// - Clicking once (without drag) captures the whole screen.
/// - Clicking and dragging captures the selected rectangular area.
/// - Pressing any key escapes and cancels capture (no screenshot taken).
class CapturePlugin: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "snipsnap/capture",
      binaryMessenger: registrar.messenger
    )
    let instance = CapturePlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private var activeWindows: [CaptureOverlayWindow] = []
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var activeResult: FlutterResult?

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "captureInteractive":
      guard
        let args = call.arguments as? [String: Any],
        let targetPath = args["targetPath"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "targetPath missing", details: nil))
        return
      }
      startInteractiveCapture(targetPath: targetPath, result: result)

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
      // Preflight first: it never prompts, so a granted app pays nothing.
      // Only request when it comes back false, which puts the system dialog at
      // the moment the user actually asked to capture.
      //
      // Without this, a missing grant is invisible: CGWindowListCreateImage
      // quietly returns desktop wallpaper with no windows in it, and
      // `screencapture` exits 0 having written a file — so every guard on the
      // Dart side passes and the user just gets a blank-looking capture.
      if CGPreflightScreenCaptureAccess() {
        result(true)
      } else {
        // Returns false on first call; the grant only takes effect after a
        // relaunch, which is why the Dart side words its message that way.
        result(CGRequestScreenCaptureAccess())
      }

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

  private func startInteractiveCapture(targetPath: String, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
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
          onCapture: { [weak self] capturedImage in
            guard let self = self else { return }
            if let capturedImage = capturedImage, self.saveImage(capturedImage, toPath: targetPath) {
              self.finishWithResult(targetPath)
            } else {
              self.finishWithResult(nil)
            }
          },
          onCancel: { [weak self] in
            self?.finishWithResult(nil)
          }
        )
        self.activeWindows.append(overlayWindow)
        overlayWindow.makeKeyAndOrderFront(nil)
      }

      // Ensure first overlay window is key window to receive events
      if let first = self.activeWindows.first {
        first.makeKey()
        NSApp.activate(ignoringOtherApps: true)
      }

      // Global and local key event monitors: ANY key press immediately cancels
      self.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        self?.finishWithResult(nil)
        return nil
      }

      self.globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
        self?.finishWithResult(nil)
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

private class CaptureOverlayWindow: NSWindow {
  init(
    screen: NSScreen,
    screenImage: CGImage?,
    onCapture: @escaping (CGImage?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    self.isOpaque = false
    self.backgroundColor = .clear
    self.level = .screenSaver
    self.hasShadow = false
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = true
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let view = CaptureOverlayView(
      frame: NSRect(origin: .zero, size: screen.frame.size),
      screenImage: screenImage,
      scaleFactor: screen.backingScaleFactor,
      onCapture: onCapture,
      onCancel: onCancel
    )
    self.contentView = view
  }

  override var canBecomeKey: Bool {
    return true
  }

  override var canBecomeMain: Bool {
    return true
  }
}

// MARK: - Capture Overlay View

private class CaptureOverlayView: NSView {
  private let screenImage: CGImage?
  private let scaleFactor: CGFloat
  private let onCapture: (CGImage?) -> Void
  private let onCancel: () -> Void

  private var startPoint: NSPoint?
  private var currentPoint: NSPoint?
  private var isDragging: Bool = false

  /// Whether this overlay has already handed back a result.
  ///
  /// The Flutter call is awaiting exactly one answer, and there is more than
  /// one way for a second one to arrive: cancelling mid-drag (a key press or a
  /// right-click) leaves the drag state intact, so the mouse-up that follows
  /// still ran the whole capture path and wrote a PNG to the target path — a
  /// screenshot the user had just cancelled, which the library scan then
  /// adopted on next launch. Teardown usually deallocates this view first, but
  /// nothing orders those two, so the latch is what actually guarantees it.
  private var hasSettled = false

  init(
    frame: NSRect,
    screenImage: CGImage?,
    scaleFactor: CGFloat,
    onCapture: @escaping (CGImage?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.screenImage = screenImage
    self.scaleFactor = scaleFactor
    self.onCapture = onCapture
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

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    startPoint = convert(event.locationInWindow, from: nil)
    currentPoint = startPoint
    isDragging = true
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDragging else { return }
    currentPoint = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  /// Hands back a captured image, once.
  private func settle(with image: CGImage?) {
    guard !hasSettled else { return }
    hasSettled = true
    isDragging = false
    onCapture(image)
  }

  /// Cancels the capture, once.
  private func settleCancelled() {
    guard !hasSettled else { return }
    hasSettled = true
    isDragging = false
    onCancel()
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging, let start = startPoint, let end = currentPoint else {
      // An unpaired mouse-up still has to settle the capture. The Flutter side
      // is awaiting this call and nothing else resolves it, so returning
      // silently left the app behind its "Waiting for screen capture..." scrim
      // with no way out but a restart.
      settleCancelled()
      return
    }

    let rect = normalizedRect(from: start, to: end)

    // Single click (drag distance < 5px): Capture whole screen!
    if rect.width < 5.0 && rect.height < 5.0 {
      settle(with: screenImage)
      return
    }

    // Dragged area: Crop to selected rectangle
    guard let screenImage = screenImage else {
      settle(with: nil)
      return
    }

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

    if cropRect.width > 0 && cropRect.height > 0,
       let cropped = screenImage.cropping(to: cropRect) {
      settle(with: cropped)
    } else {
      settle(with: screenImage)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    settleCancelled()
  }

  override func keyDown(with event: NSEvent) {
    // Any key press escapes and cancels screenshot
    settleCancelled()
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // 1. Draw dimmed backdrop
    NSColor(white: 0.0, alpha: 0.35).setFill()
    dirtyRect.fill()

    // 2. If dragging, cut out clear selection rect + draw stroke & badge
    if let start = startPoint, let end = currentPoint, isDragging {
      let selRect = normalizedRect(from: start, to: end)

      // Knock out selection area to reveal the bright desktop underneath
      NSGraphicsContext.current?.compositingOperation = .clear
      NSColor.clear.setFill()
      selRect.fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver

      // White outline
      let strokePath = NSBezierPath(rect: selRect)
      strokePath.lineWidth = 1.5
      NSColor.white.setStroke()
      strokePath.stroke()

      // Inner accent outline (vibrant blue)
      if selRect.width > 3 && selRect.height > 3 {
        let innerPath = NSBezierPath(rect: selRect.insetBy(dx: 1, dy: 1))
        innerPath.lineWidth = 1.0
        NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 0.9).setStroke()
        innerPath.stroke()
      }

      // Dimension badge (e.g. "800 × 600")
      if selRect.width > 40 && selRect.height > 25 {
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

        let badgePaddingH: CGFloat = 7
        let badgePaddingV: CGFloat = 3
        let badgeW = textSize.width + badgePaddingH * 2
        let badgeH = textSize.height + badgePaddingV * 2

        // Position badge below selection, or inside if near bottom edge
        var badgeY = selRect.minY - badgeH - 6
        if badgeY < 4 {
          badgeY = selRect.minY + 6
        }
        var badgeX = selRect.minX
        if badgeX + badgeW > bounds.width - 4 {
          badgeX = bounds.width - badgeW - 4
        }

        let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        badgePath.fill()

        attrString.draw(at: NSPoint(x: badgeX + badgePaddingH, y: badgeY + badgePaddingV))
      }
    }
  }

  private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
    let x = min(p1.x, p2.x)
    let y = min(p1.y, p2.y)
    let w = abs(p1.x - p2.x)
    let h = abs(p1.y - p2.y)
    return NSRect(x: x, y: y, width: w, height: h)
  }
}
