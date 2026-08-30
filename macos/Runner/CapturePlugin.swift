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
        // `orderFrontRegardless`, not `makeKeyAndOrderFront`: the latter is
        // ignored while another app is active, which for a capture launched
        // from the global hotkey is always. Showing the window first also
        // means it is already up if activation moves Spaces underneath it.
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
  init(
    screen: NSScreen,
    screenImage: CGImage?,
    onCapture: @escaping (CGImage?) -> Void,
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
      onCapture: onCapture,
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
  private let onCapture: (CGImage?) -> Void
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

  private let gripSize: CGFloat = 10
  private let minSelectionSide: CGFloat = 8

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

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let hot = !captureButtonRect.isEmpty && captureButtonRect.contains(point)
    if hot != captureButtonHot {
      captureButtonHot = hot
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
      if !captureButtonRect.isEmpty && captureButtonRect.contains(point) {
        captureCurrentSelection()
        return
      }
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
      if !isUsable(sel) {
        selection = nil
        mode = .idle
        settle(with: screenImage)
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
      captureCurrentSelection()
    default:
      break
    }
  }

  // MARK: - Settling

  private func captureCurrentSelection() {
    guard let sel = selection, isUsable(sel) else { return }
    settle(with: croppedImage(for: sel) ?? screenImage)
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

    NSColor(white: 0.0, alpha: 0.35).setFill()
    dirtyRect.fill()

    let showChrome: Bool
    switch mode {
    case .idle: showChrome = false
    default: showChrome = true
    }
    guard showChrome, let selRect = selection, selRect.width > 0, selRect.height > 0 else {
      captureButtonRect = .zero
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

    let accent = NSColor(red: 0.15, green: 0.55, blue: 1.0, alpha: 1.0)
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
    NSColor(white: 0.1, alpha: 0.85).setFill()
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
    let buttonW = padH * 2 + iconW + gap + textSize.width
    let buttonH = max(textSize.height + padV * 2, 24)
    let margin: CGFloat = 8

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

    let rect = NSRect(x: x, y: y, width: buttonW, height: buttonH)
    captureButtonRect = rect

    let path = NSBezierPath(roundedRect: rect, xRadius: buttonH / 2, yRadius: buttonH / 2)
    (captureButtonHot ? accent.blended(withFraction: 0.18, of: .white) ?? accent : accent).setFill()
    path.fill()
    NSColor(white: 1.0, alpha: 0.35).setStroke()
    path.lineWidth = 1
    path.stroke()

    drawCameraGlyph(
      in: NSRect(x: rect.minX + padH, y: rect.midY - 5.5, width: iconW, height: 11)
    )
    attrString.draw(
      at: NSPoint(x: rect.minX + padH + iconW + gap, y: rect.midY - textSize.height / 2)
    )
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

  private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
    let x = min(p1.x, p2.x)
    let y = min(p1.y, p2.y)
    let w = abs(p1.x - p2.x)
    let h = abs(p1.y - p2.y)
    return NSRect(x: x, y: y, width: w, height: h)
  }
}
