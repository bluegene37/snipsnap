// Gene - Nov, 20, 2026: Native macOS ScreenCaptureKit + Rust snipsnap_core panoramic scrolling capture engine and floating HUD.
import ApplicationServices
import Cocoa
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScrollingCaptureAxis: Int32 {
  case auto = 0
  case vertical = 1
  case horizontal = 2
}

struct ScrollingCompletionPayload {
  let path: String
  let width: Int
  let height: Int
  let frameCount: Int
  let axis: Int32
  let truncated: Bool
}

struct ScrollingProgressPayload {
  let width: Int
  let height: Int
  let frameCount: Int
  let axis: Int32
  let statusCode: Int32
  let isPaused: Bool
  let isAutoScrolling: Bool
  let warningMessage: String?
}

final class ScrollingCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private static let syntheticScrollMagic: Int64 = 0x534E4950 // "SNIP"

  private let quartzRect: CGRect
  private let targetPath: String
  private let maxDimension: Int32
  private let axisMode: Int32
  private let excludedMainWindowNumbers: [Int]

  private let onProgress: (ScrollingProgressPayload) -> Void
  private let onCompleted: (ScrollingCompletionPayload) -> Void
  private let onCancel: () -> Void
  private let onError: (String) -> Void

  private let stateLock = NSLock()
  private let stitchQueue = DispatchQueue(label: "com.snipsnap.scrolling.stitch", qos: .userInitiated)
  private let encodeQueue = DispatchQueue(label: "com.snipsnap.scrolling.encode", qos: .userInitiated)

  private var stitcher: OpaquePointer?
  private var scStream: SCStream?
  private var borderPanel: ScrollingRegionBorderPanel?
  private var hudPanel: ScrollingLiveHudPanel?

  private var autoScrollTimer: DispatchSourceTimer?
  private var keyGlobalMonitor: Any?
  private var keyLocalMonitor: Any?
  private var wheelGlobalMonitor: Any?

  private var isPaused: Bool = false
  private var isAutoScrolling: Bool = false
  private var isStopping: Bool = false
  private var hasFinishedOrCancelled: Bool = false
  private var hasMovedContent: Bool = false

  private var currentAxis: Int32 = Int32(SNIPSNAP_AXIS_VERTICAL.rawValue)
  private var latestWidth: Int = 0
  private var latestHeight: Int = 0
  private var latestFrameCount: Int = 0
  private var latestStatusCode: Int32 = Int32(SNIPSNAP_STITCH_OK.rawValue)
  private var warningBanner: String?
  private var lastHudUpdateNs: UInt64 = 0

  private var displayID: CGDirectDisplayID = CGMainDisplayID()
  private var screenFrameQuartz: CGRect = .zero
  private var sourceRectLocal: CGRect = .zero
  private var backingScale: CGFloat = 1.0
  private var pixelWidth: Int = 0
  private var pixelHeight: Int = 0

  init(
    quartzRect: CGRect,
    targetPath: String,
    maxDimension: Int = 16000,
    axisMode: Int = 0,
    excludedWindowNumbers: [Int] = [],
    onProgress: @escaping (ScrollingProgressPayload) -> Void,
    onCompleted: @escaping (ScrollingCompletionPayload) -> Void,
    onCancel: @escaping () -> Void,
    onError: @escaping (String) -> Void
  ) {
    self.quartzRect = quartzRect
    self.targetPath = targetPath
    self.maxDimension = Int32(max(1024, min(maxDimension, 24000)))
    self.axisMode = Int32(axisMode)
    self.excludedMainWindowNumbers = excludedWindowNumbers
    self.onProgress = onProgress
    self.onCompleted = onCompleted
    self.onCancel = onCancel
    self.onError = onError
    super.init()
  }

  deinit {
    cleanupSyncResourcesOnAnyThread()
  }

  func start(completion: @escaping (Bool) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        completion(false)
        return
      }
      self.resolveDisplayAndCreateOverlays()
      self.stitchQueue.async {
        let handle = snipsnap_stitcher_create(
          Int32(self.pixelWidth),
          Int32(self.pixelHeight),
          self.maxDimension,
          self.axisMode
        )
        guard let handle = handle else {
          DispatchQueue.main.async {
            self.teardownUiAndMonitors()
            completion(false)
          }
          return
        }
        self.stateLock.lock()
        self.stitcher = handle
        self.latestWidth = self.pixelWidth
        self.latestHeight = self.pixelHeight
        self.stateLock.unlock()

        self.startScreenCaptureStream { started in
          if !started {
            DispatchQueue.main.async {
              self.teardownUiAndMonitors()
            }
            self.freeStitcherSafely()
          }
          completion(started)
        }
      }
    }
  }

  func setAutoScroll(_ enabled: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.stateLock.lock()
      let stopping = self.isStopping || self.hasFinishedOrCancelled
      self.stateLock.unlock()
      if stopping { return }

      if !enabled {
        self.stopAutoScrollTimer()
        self.stateLock.lock()
        self.isAutoScrolling = false
        self.stateLock.unlock()
        self.refreshHudFromCurrentState()
        return
      }

      if !AXIsProcessTrusted() {
        self.stopAutoScrollTimer()
        self.stateLock.lock()
        self.isAutoScrolling = false
        self.warningBanner = "Enable Accessibility for Auto-Scroll (manual scroll works)"
        self.stateLock.unlock()
        self.refreshHudFromCurrentState()
        return
      }

      self.stateLock.lock()
      self.isPaused = false
      self.isAutoScrolling = true
      self.warningBanner = nil
      self.stateLock.unlock()

      self.startAutoScrollTimer()
      self.refreshHudFromCurrentState()
    }
  }

  func pause() {
    stateLock.lock()
    if isStopping || hasFinishedOrCancelled {
      stateLock.unlock()
      return
    }
    isPaused = true
    let wasAuto = isAutoScrolling
    isAutoScrolling = false
    stateLock.unlock()

    if wasAuto {
      DispatchQueue.main.async { [weak self] in
        self?.stopAutoScrollTimer()
      }
    }
    refreshHudFromCurrentState()
  }

  func resume() {
    stateLock.lock()
    if isStopping || hasFinishedOrCancelled {
      stateLock.unlock()
      return
    }
    isPaused = false
    warningBanner = nil
    stateLock.unlock()
    refreshHudFromCurrentState()
  }

  func finish() {
    stateLock.lock()
    if hasFinishedOrCancelled || isStopping {
      stateLock.unlock()
      return
    }
    isStopping = true
    isAutoScrolling = false
    stateLock.unlock()

    DispatchQueue.main.async { [weak self] in
      self?.teardownUiAndMonitors()
    }

    let activeStream: SCStream?
    stateLock.lock()
    activeStream = scStream
    scStream = nil
    stateLock.unlock()

    let finalizeWork = { [weak self] in
      guard let self = self else { return }
      self.stitchQueue.async {
        self.assembleAndSavePng()
      }
    }

    if let stream = activeStream {
      stream.stopCapture { _ in
        finalizeWork()
      }
    } else {
      finalizeWork()
    }
  }

  func cancel() {
    stateLock.lock()
    if hasFinishedOrCancelled {
      stateLock.unlock()
      return
    }
    hasFinishedOrCancelled = true
    isStopping = true
    isAutoScrolling = false
    let activeStream = scStream
    scStream = nil
    stateLock.unlock()

    DispatchQueue.main.async { [weak self] in
      self?.teardownUiAndMonitors()
    }

    let completeCancel = { [weak self] in
      guard let self = self else { return }
      self.freeStitcherSafely()
      DispatchQueue.main.async {
        self.onCancel()
      }
    }

    if let stream = activeStream {
      stream.stopCapture { _ in
        completeCancel()
      }
    } else {
      completeCancel()
    }
  }

  // MARK: - Display Resolution & Overlays

  private func resolveDisplayAndCreateOverlays() {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
    let appKitY = primaryHeight - (quartzRect.origin.y + quartzRect.height)
    let targetAppKitRect = NSRect(
      x: quartzRect.origin.x,
      y: appKitY,
      width: quartzRect.width,
      height: quartzRect.height
    )

    var chosenScreen = NSScreen.screens.first
    var bestArea: CGFloat = -1
    for screen in NSScreen.screens {
      let overlap = screen.frame.intersection(targetAppKitRect)
      let area = overlap.isNull ? 0 : (overlap.width * overlap.height)
      if area > bestArea {
        bestArea = area
        chosenScreen = screen
      }
    }

    let screen = chosenScreen ?? NSScreen.main
    let sFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    self.backingScale = max(1.0, screen?.backingScaleFactor ?? 1.0)
    if let screenNum = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      self.displayID = CGDirectDisplayID(screenNum.uint32Value)
    } else {
      self.displayID = CGMainDisplayID()
    }

    self.screenFrameQuartz = CGRect(
      x: sFrame.origin.x,
      y: primaryHeight - (sFrame.origin.y + sFrame.height),
      width: sFrame.width,
      height: sFrame.height
    )

    let localX = max(0, quartzRect.origin.x - screenFrameQuartz.origin.x)
    let localY = max(0, quartzRect.origin.y - screenFrameQuartz.origin.y)
    let cropW = max(24, min(screenFrameQuartz.width - localX, quartzRect.width))
    let cropH = max(24, min(screenFrameQuartz.height - localY, quartzRect.height))
    self.sourceRectLocal = CGRect(x: localX, y: localY, width: cropW, height: cropH)
    self.pixelWidth = max(24, Int((cropW * backingScale).rounded()))
    self.pixelHeight = max(24, Int((cropH * backingScale).rounded()))

    // Border sits 4pt outside the captured region so it stays clear of pixels.
    let guideRect = targetAppKitRect.insetBy(dx: -4, dy: -4)
    let guide = ScrollingRegionBorderPanel(contentRect: guideRect)
    self.borderPanel = guide
    guide.orderFrontRegardless()

    let visible = screen?.visibleFrame ?? sFrame
    let hudW: CGFloat = 368
    let hudH: CGFloat = 152
    var hudY = targetAppKitRect.minY - hudH - 12
    if hudY < visible.minY + 8 {
      let aboveY = targetAppKitRect.maxY + 12
      if aboveY + hudH <= visible.maxY - 8 {
        hudY = aboveY
      } else {
        hudY = max(visible.minY + 14, min(targetAppKitRect.minY + 14, visible.maxY - hudH - 14))
      }
    }
    let hudX = max(
      visible.minX + 10,
      min(targetAppKitRect.midX - hudW / 2, visible.maxX - hudW - 10)
    )
    let hudFrame = NSRect(x: hudX, y: hudY, width: hudW, height: hudH)

    let hud = ScrollingLiveHudPanel(
      contentRect: hudFrame,
      onToggleAutoScroll: { [weak self] in
        guard let self = self else { return }
        self.stateLock.lock()
        let next = !self.isAutoScrolling
        self.stateLock.unlock()
        self.setAutoScroll(next)
      },
      onTogglePause: { [weak self] in
        guard let self = self else { return }
        self.stateLock.lock()
        let paused = self.isPaused
        self.stateLock.unlock()
        if paused {
          self.resume()
        } else {
          self.pause()
        }
      },
      onDone: { [weak self] in
        self?.finish()
      },
      onCancel: { [weak self] in
        self?.cancel()
      }
    )
    self.hudPanel = hud
    hud.orderFrontRegardless()
    hud.hudView.update(
      width: pixelWidth,
      height: pixelHeight,
      frameCount: 0,
      axis: currentAxis,
      statusCode: Int32(SNIPSNAP_STITCH_OK.rawValue),
      isPaused: false,
      isAutoScrolling: false,
      warning: nil,
      previewImage: nil
    )

    installMonitors()
  }

  private func installMonitors() {
    let escapeKeyCode: UInt16 = 53
    let returnKeyCode: UInt16 = 36
    let numpadEnterKeyCode: UInt16 = 76

    keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      if event.keyCode == escapeKeyCode {
        self?.cancel()
      } else if event.keyCode == returnKeyCode || event.keyCode == numpadEnterKeyCode {
        self?.finish()
      }
    }

    keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      if event.keyCode == escapeKeyCode {
        self?.cancel()
        return nil
      } else if event.keyCode == returnKeyCode || event.keyCode == numpadEnterKeyCode {
        self?.finish()
        return nil
      }
      return event
    }

    wheelGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
      guard let self = self else { return }
      let tag = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
      if tag == Self.syntheticScrollMagic {
        return
      }
      self.stateLock.lock()
      let currentlyAuto = self.isAutoScrolling
      self.stateLock.unlock()
      if currentlyAuto {
        self.setAutoScroll(false)
        self.stateLock.lock()
        self.warningBanner = "Manual scroll detected — Auto-Scroll paused"
        self.stateLock.unlock()
        self.refreshHudFromCurrentState()
      }
    }
  }

  private func startAutoScrollTimer() {
    stopAutoScrollTimer()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
    timer.schedule(deadline: .now() + .milliseconds(45), repeating: .milliseconds(55))
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      self.stateLock.lock()
      let active = self.isAutoScrolling && !self.isPaused && !self.isStopping && !self.hasFinishedOrCancelled
      let axis = self.currentAxis
      self.stateLock.unlock()
      guard active else { return }

      let center = CGPoint(
        x: self.screenFrameQuartz.origin.x + self.sourceRectLocal.midX,
        y: self.screenFrameQuartz.origin.y + self.sourceRectLocal.midY
      )
      let source = CGEventSource(stateID: .hidSystemState)
      source?.userData = Self.syntheticScrollMagic

      let scrollEvent: CGEvent?
      if axis == Int32(SNIPSNAP_AXIS_HORIZONTAL.rawValue) {
        let step = Int32(max(12, min(32, Int(self.sourceRectLocal.width * 0.14))))
        scrollEvent = CGEvent(
          scrollWheelEvent2Source: source,
          units: .pixel,
          wheelCount: 2,
          wheel1: 0,
          wheel2: -step,
          wheel3: 0
        )
      } else {
        let step = Int32(max(12, min(32, Int(self.sourceRectLocal.height * 0.14))))
        scrollEvent = CGEvent(
          scrollWheelEvent2Source: source,
          units: .pixel,
          wheelCount: 1,
          wheel1: -step,
          wheel2: 0,
          wheel3: 0
        )
      }
      if let ev = scrollEvent {
        ev.location = center
        ev.setIntegerValueField(.eventSourceUserData, value: Self.syntheticScrollMagic)
        ev.post(tap: .cghidEventTap)
      }
    }
    autoScrollTimer = timer
    timer.resume()
  }

  private func stopAutoScrollTimer() {
    autoScrollTimer?.cancel()
    autoScrollTimer = nil
  }

  private func teardownUiAndMonitors() {
    stopAutoScrollTimer()
    if let local = keyLocalMonitor {
      NSEvent.removeMonitor(local)
      keyLocalMonitor = nil
    }
    if let global = keyGlobalMonitor {
      NSEvent.removeMonitor(global)
      keyGlobalMonitor = nil
    }
    if let wheel = wheelGlobalMonitor {
      NSEvent.removeMonitor(wheel)
      wheelGlobalMonitor = nil
    }
    borderPanel?.orderOut(nil)
    borderPanel = nil
    hudPanel?.orderOut(nil)
    hudPanel = nil
  }

  private func cleanupSyncResourcesOnAnyThread() {
    stopAutoScrollTimer()
    freeStitcherSafely()
  }

  private func freeStitcherSafely() {
    stitchQueue.sync {
      self.stateLock.lock()
      let handle = self.stitcher
      self.stitcher = nil
      self.stateLock.unlock()
      if let handle = handle {
        snipsnap_stitcher_free(handle)
      }
    }
  }

  // MARK: - ScreenCaptureKit Stream

  private func startScreenCaptureStream(completion: @escaping (Bool) -> Void) {
    let borderNum = borderPanel?.windowNumber ?? 0
    let hudNum = hudPanel?.windowNumber ?? 0
    var excludedNums = Set(excludedMainWindowNumbers)
    if borderNum > 0 { excludedNums.insert(borderNum) }
    if hudNum > 0 { excludedNums.insert(hudNum) }

    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, err in
      guard let self = self, err == nil, let scContent = content else {
        completion(false)
        return
      }
      guard let matchedDisplay = scContent.displays.first(where: { $0.displayID == self.displayID })
        ?? scContent.displays.first
      else {
        completion(false)
        return
      }

      let myPid = ProcessInfo.processInfo.processIdentifier
      let excludedWindows = scContent.windows.filter { win in
        // Gene - Nov, 20, 2026: Use SCRunningApplication.processID (pid_t) on macOS ScreenCaptureKit.
        // excludedNums.contains(Int(win.windowID)) || win.owningApplication?.processIdentifier == myPid
        excludedNums.contains(Int(win.windowID)) || win.owningApplication?.processID == myPid
      }
      let filter = SCContentFilter(display: matchedDisplay, excludingWindows: excludedWindows)

      let config = SCStreamConfiguration()
      config.width = self.pixelWidth
      config.height = self.pixelHeight
      config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
      config.pixelFormat = kCVPixelFormatType_32BGRA
      config.showsCursor = false
      config.capturesAudio = false
      config.queueDepth = 3
      config.sourceRect = self.sourceRectLocal

      let stream = SCStream(filter: filter, configuration: config, delegate: self)
      do {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.stitchQueue)
      } catch {
        completion(false)
        return
      }

      stream.startCapture { startErr in
        if let startErr = startErr {
          DispatchQueue.main.async {
            self.onError("Scrolling stream failed to start: \(startErr.localizedDescription)")
          }
          completion(false)
          return
        }
        self.stateLock.lock()
        if self.isStopping || self.hasFinishedOrCancelled {
          self.stateLock.unlock()
          stream.stopCapture { _ in }
          completion(false)
          return
        }
        self.scStream = stream
        self.stateLock.unlock()
        completion(true)
      }
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
       let rawStatus = attachments.first?[.status] as? Int,
       let frameStatus = SCFrameStatus(rawValue: rawStatus),
       frameStatus != .complete
    {
      return
    }

    stateLock.lock()
    let skip = isPaused || isStopping || hasFinishedOrCancelled
    let handle = stitcher
    let autoActive = isAutoScrolling
    stateLock.unlock()
    guard !skip, let handle = handle, let pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    CVPixelBufferLockBaseAddress(pixBuf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixBuf, .readOnly) }

    guard let baseAddr = CVPixelBufferGetBaseAddress(pixBuf) else { return }
    let w = Int32(CVPixelBufferGetWidth(pixBuf))
    let h = Int32(CVPixelBufferGetHeight(pixBuf))
    let stride = Int32(CVPixelBufferGetBytesPerRow(pixBuf))
    let typedPtr = baseAddr.assumingMemoryBound(to: UInt8.self)

    let pushRes = snipsnap_stitcher_push_bgra(handle, typedPtr, w, h, stride)
    let statusInt = Int(pushRes.status)

    var shouldStopAuto = false
    var shouldAutoFinish = false
    var computedWarning: String?

    if statusInt == Int(SNIPSNAP_STITCH_OK.rawValue) && pushRes.frame_count > 1 && abs(pushRes.delta) > 0 {
      stateLock.lock()
      hasMovedContent = true
      stateLock.unlock()
    }

    if statusInt == Int(SNIPSNAP_STITCH_TRACKING_LOST.rawValue) {
      computedWarning = "Tracking lost — scroll slower or keep overlap visible"
    } else if statusInt == Int(SNIPSNAP_STITCH_MAX_LIMIT_REACHED.rawValue) {
      computedWarning = "Max dimension (\(maxDimension) px) reached — click Done"
      if autoActive {
        shouldStopAuto = true
        shouldAutoFinish = true
      } else {
        shouldStopAuto = true
      }
    } else if autoActive {
      stateLock.lock()
      let moved = hasMovedContent
      stateLock.unlock()
      if (moved && pushRes.identical_streak >= 4) || (!moved && pushRes.identical_streak >= 16) {
        shouldStopAuto = true
        shouldAutoFinish = moved
        if !moved {
          computedWarning = "End of scrollable area reached or window not scrollable"
        }
      }
    }

    stateLock.lock()
    latestWidth = Int(pushRes.total_width)
    latestHeight = Int(pushRes.total_height)
    latestFrameCount = Int(pushRes.frame_count)
    currentAxis = pushRes.active_axis
    latestStatusCode = pushRes.status
    if let cw = computedWarning {
      warningBanner = cw
    } else if statusInt == Int(SNIPSNAP_STITCH_OK.rawValue) && pushRes.delta != 0 {
      warningBanner = nil
    }
    let nowNs = DispatchTime.now().uptimeNanoseconds
    let shouldPushPreview = (nowNs - lastHudUpdateNs) >= 95_000_000 ||
      statusInt == Int(SNIPSNAP_STITCH_TRACKING_LOST.rawValue) ||
      statusInt == Int(SNIPSNAP_STITCH_MAX_LIMIT_REACHED.rawValue)
    if shouldPushPreview {
      lastHudUpdateNs = nowNs
    }
    stateLock.unlock()

    if shouldStopAuto {
      setAutoScroll(false)
    }
    if shouldAutoFinish {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
        self?.finish()
      }
      return
    }

    if shouldPushPreview {
      let previewImage = buildPreviewImage(handle: handle)
      refreshHudFromCurrentState(previewImage: previewImage)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    stateLock.lock()
    let expected = isStopping || hasFinishedOrCancelled
    stateLock.unlock()
    if expected { return }
    DispatchQueue.main.async { [weak self] in
      self?.onError("Scrolling stream interrupted: \(error.localizedDescription)")
      self?.cancel()
    }
  }

  private func buildPreviewImage(handle: OpaquePointer) -> NSImage? {
    var previewBuf = SnipSnapImageBuffer(data: nil, width: 0, height: 0, stride: 0, len: 0)
    guard snipsnap_stitcher_get_preview_bgra(handle, 176, 112, &previewBuf) else {
      return nil
    }
    defer { snipsnap_buffer_free(&previewBuf) }
    guard let rawPtr = previewBuf.data, previewBuf.len > 0, previewBuf.width > 0, previewBuf.height > 0 else {
      return nil
    }

    let copiedData = Data(bytes: rawPtr, count: previewBuf.len)
    guard let provider = CGDataProvider(data: copiedData as CFData) else {
      return nil
    }
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard let cgImg = CGImage(
      width: Int(previewBuf.width),
      height: Int(previewBuf.height),
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: Int(previewBuf.stride),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    ) else {
      return nil
    }
    return NSImage(cgImage: cgImg, size: NSSize(width: Int(previewBuf.width), height: Int(previewBuf.height)))
  }

  private func refreshHudFromCurrentState(previewImage: NSImage? = nil) {
    stateLock.lock()
    let w = latestWidth
    let h = latestHeight
    let frames = latestFrameCount
    let axis = currentAxis
    let status = latestStatusCode
    let paused = isPaused
    let auto = isAutoScrolling
    let warn = warningBanner
    stateLock.unlock()

    let payload = ScrollingProgressPayload(
      width: w,
      height: h,
      frameCount: frames,
      axis: axis,
      statusCode: status,
      isPaused: paused,
      isAutoScrolling: auto,
      warningMessage: warn
    )

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.hudPanel?.hudView.update(
        width: w,
        height: h,
        frameCount: frames,
        axis: axis,
        statusCode: status,
        isPaused: paused,
        isAutoScrolling: auto,
        warning: warn,
        previewImage: previewImage
      )
      self.onProgress(payload)
    }
  }

  // MARK: - Single-Pass Assembly & ImageIO PNG Encode

  private func assembleAndSavePng() {
    stateLock.lock()
    let handle = stitcher
    stitcher = nil
    let finalAxis = currentAxis
    let finalFrames = latestFrameCount
    let truncated = Int(latestStatusCode) == Int(SNIPSNAP_STITCH_MAX_LIMIT_REACHED.rawValue)
    stateLock.unlock()

    guard let handle = handle else {
      DispatchQueue.main.async {
        self.onError("Scrolling capture session has no stitched image handle.")
      }
      return
    }

    var fullBuf = SnipSnapImageBuffer(data: nil, width: 0, height: 0, stride: 0, len: 0)
    let assembled = snipsnap_stitcher_assemble_bgra(handle, &fullBuf)
    snipsnap_stitcher_free(handle)

    guard assembled, let dataPtr = fullBuf.data, fullBuf.len > 0, fullBuf.width > 0, fullBuf.height > 0 else {
      snipsnap_buffer_free(&fullBuf)
      DispatchQueue.main.async {
        self.onError("Failed to assemble scrolling capture image.")
      }
      return
    }

    let outWidth = Int(fullBuf.width)
    let outHeight = Int(fullBuf.height)
    let outStride = Int(fullBuf.stride)
    let outLen = fullBuf.len
    let outPath = targetPath

    encodeQueue.async { [weak self] in
      guard let self = self else {
        var tmp = fullBuf
        snipsnap_buffer_free(&tmp)
        return
      }

      let boxedBuf = UnsafeMutablePointer<SnipSnapImageBuffer>.allocate(capacity: 1)
      boxedBuf.initialize(to: fullBuf)

      guard let provider = CGDataProvider(
        dataInfo: boxedBuf,
        data: dataPtr,
        size: outLen,
        releaseData: { info, _, _ in
          guard let info = info else { return }
          let ptr = info.assumingMemoryBound(to: SnipSnapImageBuffer.self)
          snipsnap_buffer_free(ptr)
          ptr.deinitialize(count: 1)
          ptr.deallocate()
        }
      ) else {
        snipsnap_buffer_free(boxedBuf)
        boxedBuf.deinitialize(count: 1)
        boxedBuf.deallocate()
        DispatchQueue.main.async {
          self.onError("Failed to create CGDataProvider for scrolling capture PNG.")
        }
        return
      }

      let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
      var writeOk = false
      autoreleasepool {
        if let cgImage = CGImage(
          width: outWidth,
          height: outHeight,
          bitsPerComponent: 8,
          bitsPerPixel: 32,
          bytesPerRow: outStride,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
          provider: provider,
          decode: nil,
          shouldInterpolate: false,
          intent: .defaultIntent
        ) {
          let url = URL(fileURLWithPath: outPath)
          try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          if let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            writeOk = CGImageDestinationFinalize(dest)
          }
        }
      }

      self.stateLock.lock()
      self.hasFinishedOrCancelled = true
      self.stateLock.unlock()

      DispatchQueue.main.async {
        if writeOk {
          self.onCompleted(
            ScrollingCompletionPayload(
              path: outPath,
              width: outWidth,
              height: outHeight,
              frameCount: finalFrames,
              axis: finalAxis,
              truncated: truncated
            )
          )
        } else {
          self.onError("Failed to encode scrolling PNG to disk.")
        }
      }
    }
  }
}

// MARK: - Overlay Windows

private final class ScrollingRegionBorderPanel: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    level = .floating
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    contentView = ScrollingRegionBorderView(frame: NSRect(origin: .zero, size: contentRect.size))
    setFrame(contentRect, display: true)
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    return frameRect
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class ScrollingRegionBorderView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let outerPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
    outerPath.lineWidth = 1.5
    NSColor.white.withAlphaComponent(0.7).setStroke()
    outerPath.stroke()

    let innerPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.0, dy: 2.0), xRadius: 4, yRadius: 4)
    innerPath.lineWidth = 2.0
    NSColor(red: 0.784, green: 0.635, blue: 0.478, alpha: 0.95).setStroke()
    innerPath.stroke()
  }
}

private final class ScrollingLiveHudPanel: NSPanel {
  let hudView: ScrollingLiveHudView

  init(
    contentRect: NSRect,
    onToggleAutoScroll: @escaping () -> Void,
    onTogglePause: @escaping () -> Void,
    onDone: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.hudView = ScrollingLiveHudView(
      frame: NSRect(origin: .zero, size: contentRect.size),
      onToggleAutoScroll: onToggleAutoScroll,
      onTogglePause: onTogglePause,
      onDone: onDone,
      onCancel: onCancel
    )
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    level = .floating
    hasShadow = true
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    contentView = hudView
    setFrame(contentRect, display: true)
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    return frameRect
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class HudPillButton: NSButton {
  var fillNormal: NSColor
  var fillHover: NSColor
  private var isHovered: Bool = false
  private var trackingArea: NSTrackingArea?

  init(
    title: String,
    fillNormal: NSColor,
    fillHover: NSColor,
    textColor: NSColor = .white,
    target: AnyObject?,
    action: Selector?
  ) {
    self.fillNormal = fillNormal
    self.fillHover = fillHover
    super.init(frame: .zero)
    self.title = title
    self.isBordered = false
    self.wantsLayer = true
    self.target = target
    self.action = action
    self.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    self.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: textColor,
      ]
    )
    layer?.cornerRadius = 8
    layer?.borderWidth = 1.0
    layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
    updateColors()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setTitleAndStyle(_ title: String, normal: NSColor, hover: NSColor, textColor: NSColor = .white) {
    self.fillNormal = normal
    self.fillHover = hover
    self.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: textColor,
      ]
    )
    updateColors()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingArea {
      removeTrackingArea(existing)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateColors()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateColors()
  }

  private func updateColors() {
    layer?.backgroundColor = (isHovered ? fillHover : fillNormal).cgColor
  }
}

private final class ScrollingLiveHudView: NSView {
  private let onToggleAutoScroll: () -> Void
  private let onTogglePause: () -> Void
  private let onDone: () -> Void
  private let onCancel: () -> Void

  private let statusDot = NSView()
  private let dimsLabel = NSTextField(labelWithString: "0 × 0 px")
  private let framesLabel = NSTextField(labelWithString: "0 frames")
  private let axisChip = NSTextField(labelWithString: "Auto")
  private let messageLabel = NSTextField(wrappingLabelWithString: "Scroll manually or click Auto-Scroll")
  private let previewContainer = NSView()
  private let previewImageView = NSImageView()
  private let previewPlaceholder = NSTextField(labelWithString: "Preview")

  private lazy var autoBtn = HudPillButton(
    title: "Auto-Scroll",
    fillNormal: NSColor(white: 1.0, alpha: 0.12),
    fillHover: NSColor(white: 1.0, alpha: 0.22),
    target: self,
    action: #selector(handleAuto)
  )
  private lazy var pauseBtn = HudPillButton(
    title: "Pause",
    fillNormal: NSColor(white: 1.0, alpha: 0.12),
    fillHover: NSColor(white: 1.0, alpha: 0.22),
    target: self,
    action: #selector(handlePause)
  )
  private lazy var doneBtn = HudPillButton(
    title: "Done ↵",
    fillNormal: NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 1.0),
    fillHover: NSColor(red: 0.56, green: 0.40, blue: 0.29, alpha: 1.0),
    target: self,
    action: #selector(handleDone)
  )
  private lazy var cancelBtn = HudPillButton(
    title: "Cancel",
    fillNormal: NSColor(white: 1.0, alpha: 0.10),
    fillHover: NSColor(red: 0.72, green: 0.22, blue: 0.20, alpha: 0.9),
    target: self,
    action: #selector(handleCancel)
  )

  init(
    frame: NSRect,
    onToggleAutoScroll: @escaping () -> Void,
    onTogglePause: @escaping () -> Void,
    onDone: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onToggleAutoScroll = onToggleAutoScroll
    self.onTogglePause = onTogglePause
    self.onDone = onDone
    self.onCancel = onCancel
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor(red: 0.11, green: 0.075, blue: 0.05, alpha: 0.96).cgColor
    layer?.cornerRadius = 14
    layer?.borderWidth = 1.0
    layer?.borderColor = NSColor(white: 1.0, alpha: 0.22).cgColor
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupSubviews() {
    statusDot.wantsLayer = true
    statusDot.layer?.cornerRadius = 4.5
    statusDot.layer?.backgroundColor = NSColor(red: 0.95, green: 0.26, blue: 0.21, alpha: 1.0).cgColor

    dimsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
    dimsLabel.textColor = .white

    framesLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    framesLabel.textColor = NSColor(white: 1.0, alpha: 0.68)

    axisChip.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    axisChip.textColor = NSColor(red: 0.87, green: 0.74, blue: 0.59, alpha: 1.0)
    axisChip.alignment = .right

    previewContainer.wantsLayer = true
    previewContainer.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.35).cgColor
    previewContainer.layer?.cornerRadius = 7
    previewContainer.layer?.borderWidth = 1.0
    previewContainer.layer?.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor

    previewImageView.imageScaling = .scaleProportionallyUpOrDown
    previewImageView.imageAlignment = .alignCenter

    previewPlaceholder.font = NSFont.systemFont(ofSize: 10, weight: .medium)
    previewPlaceholder.textColor = NSColor(white: 1.0, alpha: 0.45)
    previewPlaceholder.alignment = .center

    messageLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
    messageLabel.textColor = NSColor(white: 1.0, alpha: 0.86)
    messageLabel.maximumNumberOfLines = 3
    messageLabel.lineBreakMode = .byWordWrapping

    previewContainer.addSubview(previewPlaceholder)
    previewContainer.addSubview(previewImageView)

    for v in [
      statusDot, dimsLabel, framesLabel, axisChip,
      previewContainer, messageLabel,
      autoBtn, pauseBtn, doneBtn, cancelBtn,
    ] {
      addSubview(v)
    }

    layoutControls()
  }

  override func layout() {
    super.layout()
    layoutControls()
  }

  private func layoutControls() {
    let w = bounds.width
    let h = bounds.height

    statusDot.frame = NSRect(x: 14, y: h - 24, width: 9, height: 9)
    dimsLabel.frame = NSRect(x: 29, y: h - 28, width: 130, height: 18)
    framesLabel.frame = NSRect(x: 162, y: h - 27, width: 92, height: 16)
    axisChip.frame = NSRect(x: w - 92, y: h - 27, width: 78, height: 16)

    previewContainer.frame = NSRect(x: 14, y: 48, width: 92, height: 64)
    previewImageView.frame = previewContainer.bounds.insetBy(dx: 3, dy: 3)
    previewPlaceholder.frame = NSRect(x: 4, y: 24, width: 84, height: 16)

    messageLabel.frame = NSRect(x: 116, y: 50, width: w - 130, height: 60)

    let btnY: CGFloat = 12
    let btnH: CGFloat = 28
    let gap: CGFloat = 7
    autoBtn.frame = NSRect(x: 14, y: btnY, width: 92, height: btnH)
    pauseBtn.frame = NSRect(x: 14 + 92 + gap, y: btnY, width: 72, height: btnH)
    doneBtn.frame = NSRect(x: 14 + 92 + 72 + gap * 2, y: btnY, width: 82, height: btnH)
    cancelBtn.frame = NSRect(x: w - 14 - 72, y: btnY, width: 72, height: btnH)
  }

  func update(
    width: Int,
    height: Int,
    frameCount: Int,
    axis: Int32,
    statusCode: Int32,
    isPaused: Bool,
    isAutoScrolling: Bool,
    warning: String?,
    previewImage: NSImage?
  ) {
    dimsLabel.stringValue = "\(width) × \(height) px"
    framesLabel.stringValue = "\(frameCount) \(frameCount == 1 ? "frame" : "frames")"

    if axis == Int32(SNIPSNAP_AXIS_HORIZONTAL.rawValue) {
      axisChip.stringValue = "Horizontal"
    } else if axis == Int32(SNIPSNAP_AXIS_VERTICAL.rawValue) {
      axisChip.stringValue = "Vertical"
    } else {
      axisChip.stringValue = "Auto"
    }

    if let img = previewImage {
      previewImageView.image = img
      previewPlaceholder.isHidden = true
    }

    if isPaused {
      statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
      pauseBtn.setTitleAndStyle(
        "Resume",
        normal: NSColor(red: 0.435, green: 0.306, blue: 0.216, alpha: 0.9),
        hover: NSColor(red: 0.56, green: 0.40, blue: 0.29, alpha: 1.0)
      )
    } else {
      statusDot.layer?.backgroundColor = NSColor(red: 0.95, green: 0.26, blue: 0.21, alpha: 1.0).cgColor
      pauseBtn.setTitleAndStyle(
        "Pause",
        normal: NSColor(white: 1.0, alpha: 0.12),
        hover: NSColor(white: 1.0, alpha: 0.22)
      )
    }

    if isAutoScrolling {
      autoBtn.setTitleAndStyle(
        "Auto On",
        normal: NSColor(red: 0.22, green: 0.54, blue: 0.36, alpha: 0.95),
        hover: NSColor(red: 0.28, green: 0.64, blue: 0.42, alpha: 1.0)
      )
    } else {
      autoBtn.setTitleAndStyle(
        "Auto-Scroll",
        normal: NSColor(white: 1.0, alpha: 0.12),
        hover: NSColor(white: 1.0, alpha: 0.22)
      )
    }

    if let warn = warning, !warn.isEmpty {
      messageLabel.textColor = NSColor(red: 0.98, green: 0.78, blue: 0.42, alpha: 1.0)
      messageLabel.stringValue = warn
    } else if isPaused {
      messageLabel.textColor = NSColor(white: 1.0, alpha: 0.85)
      messageLabel.stringValue = "Paused — scroll elsewhere safely or click Resume / Done"
    } else if isAutoScrolling {
      messageLabel.textColor = NSColor(red: 0.68, green: 0.92, blue: 0.76, alpha: 1.0)
      messageLabel.stringValue = "Auto-scrolling… scroll manually anytime to pause"
    } else if statusCode == Int32(SNIPSNAP_STITCH_TRACKING_LOST.rawValue) {
      messageLabel.textColor = NSColor(red: 0.98, green: 0.78, blue: 0.42, alpha: 1.0)
      messageLabel.stringValue = "Slow down slightly so overlapping content stays visible"
    } else {
      messageLabel.textColor = NSColor(white: 1.0, alpha: 0.86)
      messageLabel.stringValue = frameCount <= 1
        ? "Ready — scroll the area or click Auto-Scroll"
        : "Capturing stitch… press Enter when done"
    }
  }

  @objc private func handleAuto() { onToggleAutoScroll() }
  @objc private func handlePause() { onTogglePause() }
  @objc private func handleDone() { onDone() }
  @objc private func handleCancel() { onCancel() }
}
