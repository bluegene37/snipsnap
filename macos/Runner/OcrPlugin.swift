import AppKit
import FlutterMacOS
import Vision

/// Bridges `snipsnap/ocr` to Vision's text recogniser.
///
/// Vision reports normalised boxes with a bottom-left origin; everything here
/// is converted to top-left-origin pixels so Dart only ever sees one
/// convention.
class OcrPlugin: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "snipsnap/ocr",
      binaryMessenger: registrar.messenger
    )
    let instance = OcrPlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability":
      result(availability())
    case "recognize":
      guard
        let args = call.arguments as? [String: Any],
        let data = args["png"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "png bytes missing", details: nil))
        return
      }
      recognize(data.data, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The newest text-recognition revision this Mac supports. Revision 3 needs
  /// macOS 13; the deployment target is 12.0, so revision 2 is the fallback.
  private static var preferredRevision: Int {
    if #available(macOS 13.0, *) {
      return VNRecognizeTextRequestRevision3
    }
    return VNRecognizeTextRequestRevision2
  }

  /// The single place a text request is configured. `availability` and
  /// `recognize` both go through it, so what we advertise can never drift from
  /// what we actually attempt.
  private static func configure(_ request: VNRecognizeTextRequest) {
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.revision = Self.preferredRevision
    if #available(macOS 13.0, *) {
      // Revision 3 can pick the language per image. Without this, Vision
      // silently defaults to `["en_US"]` only.
      request.automaticallyDetectsLanguage = true
    }
  }

  /// The languages `recognize` will actually attempt — *not* everything the
  /// revision is capable of. The two differ on macOS 12; see below.
  private func advertisedLanguages() -> [String] {
    let request = VNRecognizeTextRequest()
    Self.configure(request)

    if #available(macOS 13.0, *) {
      // Auto-detection is on, so any supported language is genuinely on offer.
      // (The class-level query is deprecated as of macOS 12; ask the configured
      // instance instead.)
      return (try? request.supportedRecognitionLanguages()) ?? []
    }

    // macOS 12 / revision 2 has no `automaticallyDetectsLanguage`, so the
    // request runs against a fixed, priority-ordered list — Vision's default,
    // `["en_US"]`. We report exactly that list rather than the wider set the
    // revision could support, because the alternative is worse: widening
    // `recognitionLanguages` to every supported language would degrade accuracy
    // on every capture, including the overwhelmingly common English one, to
    // serve a case nothing can request yet (no caller reads
    // `OcrAvailability.languages`, and there is no language picker). Narrow and
    // honest is also the reversible choice — when a picker exists it can pass a
    // language through and both sides widen together.
    return request.recognitionLanguages
  }

  private func availability() -> [String: Any] {
    let languages = advertisedLanguages()
    if languages.isEmpty {
      return [
        "available": false,
        "reason": "Vision reported no recognition languages on this Mac.",
        "languages": [String](),
      ]
    }
    return ["available": true, "languages": languages]
  }

  private func recognize(_ data: Data, result: @escaping FlutterResult) {
    // Vision is slow enough to stutter the UI, so every step after this point
    // — decode included — runs off the platform thread. `sink` guarantees the
    // reply is delivered exactly once, on the main thread.
    let sink = ResultSink(result)

    DispatchQueue.global(qos: .userInitiated).async {
      guard
        let image = NSImage(data: data),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else {
        sink.send(FlutterError(code: "decode_failed", message: "Could not decode PNG", details: nil))
        return
      }

      let width = CGFloat(cgImage.width)
      let height = CGFloat(cgImage.height)

      let request = VNRecognizeTextRequest { request, error in
        if let error = error {
          sink.send(
            FlutterError(code: "recognize_failed", message: error.localizedDescription, details: nil)
          )
          return
        }

        // No text in the image is a normal outcome, not a failure: `results`
        // is nil or empty and Dart receives an empty `lines` list.
        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        var lines: [[String: Any]] = []

        for observation in observations {
          guard let candidate = observation.topCandidates(1).first else { continue }

          var words: [[String: Any]] = []
          // Per-word boxes come from ranges inside the candidate's string.
          for range in candidate.string.wordRanges {
            guard let box = try? candidate.boundingBox(for: range) else { continue }
            words.append(
              Self.rectPayload(
                text: String(candidate.string[range]),
                box: box.boundingBox,
                width: width,
                height: height,
                confidence: Double(candidate.confidence)
              )
            )
          }

          var line = Self.rectPayload(
            text: candidate.string,
            box: observation.boundingBox,
            width: width,
            height: height,
            confidence: Double(candidate.confidence)
          )
          line["words"] = words
          lines.append(line)
        }

        sink.send([
          "width": Int(width),
          "height": Int(height),
          "lines": lines,
        ])
      }

      Self.configure(request)

      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

      // Defence in depth against a hang. Every reply above happens either in
      // the completion handler or in the `catch`; if Vision ever returned
      // without doing either, nothing would answer the channel and the Dart
      // Future would never complete — there is no timeout anywhere in the Dart
      // path, so the OCR panel would spin forever with no recovery. The sink is
      // already drained on every normal path, which makes this a no-op there.
      defer {
        sink.send(
          FlutterError(
            code: "recognize_failed",
            message: "Vision finished without returning a result.",
            details: nil
          )
        )
      }

      do {
        try handler.perform([request])
      } catch {
        sink.send(
          FlutterError(code: "recognize_failed", message: error.localizedDescription, details: nil)
        )
      }
    }
  }

  /// Converts a Vision normalised, bottom-left-origin box into a top-left
  /// origin pixel rect.
  ///
  /// Vision's `minY`/`maxY` grow upwards from the bottom edge, so the top of
  /// the box measured from the top edge is `1 - maxY`. Width and height are
  /// orientation-independent fractions and only need scaling.
  private static func rectPayload(
    text: String,
    box: CGRect,
    width: CGFloat,
    height: CGFloat,
    confidence: Double
  ) -> [String: Any] {
    let x = box.minX * width
    let w = box.width * width
    let h = box.height * height
    let y = (1.0 - box.maxY) * height
    return [
      "text": text,
      "x": Double(x),
      "y": Double(y),
      "w": Double(w),
      "h": Double(h),
      "confidence": confidence,
    ]
  }
}

/// Delivers a `FlutterResult` exactly once, always on the main thread.
///
/// The once-only guarantee is the point. `VNImageRequestHandler.perform`
/// invokes the completion handler *synchronously*, so a request that both
/// reports an error to the handler and makes `perform` throw would otherwise
/// call `FlutterResult` twice — which is not allowed.
///
/// The main-thread hop is merely tidiness, not a correctness requirement:
/// `FlutterChannels.h` documents the reply callback as invocable from any
/// thread. It is kept so replies reach Dart from one predictable queue.
private final class ResultSink {
  private let lock = NSLock()
  private var result: FlutterResult?

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  func send(_ value: Any?) {
    lock.lock()
    let pending = result
    result = nil
    lock.unlock()

    guard let pending = pending else { return }
    if Thread.isMainThread {
      pending(value)
    } else {
      DispatchQueue.main.async { pending(value) }
    }
  }
}

private extension String {
  /// Ranges of each whitespace-separated word, used for per-word boxes.
  var wordRanges: [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start: String.Index? = nil
    for index in indices {
      let isSpace = self[index].isWhitespace
      if !isSpace && start == nil {
        start = index
      } else if isSpace, let s = start {
        ranges.append(s..<index)
        start = nil
      }
    }
    if let s = start { ranges.append(s..<endIndex) }
    return ranges
  }
}
