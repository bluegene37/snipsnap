import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../native/rust_image_core.dart';
import '../render_service.dart';
import 'channel_ocr_engine.dart';
import 'ocr_engine.dart';
import 'unavailable_ocr_engine.dart';

/// Runs OCR over a capture, cropping to a region when asked and caching
/// full-image results per capture revision.
class OcrService {
  /// Regions below this many pixels on a side are almost always accidental
  /// click-drags and are not worth a round trip.
  static const double minRegionSide = 8.0;

  final OcrEngine engine;
  final Map<String, OcrResult> _cache = {};
  OcrAvailability? _availability;

  OcrService({OcrEngine? engine}) : engine = engine ?? _engineForPlatform();

  static OcrEngine _engineForPlatform() {
    if (Platform.isMacOS || Platform.isWindows) return const ChannelOcrEngine();
    return const UnavailableOcrEngine(
      'Text extraction needs an OCR engine from the operating system, which '
      'Linux does not provide. Available on macOS and Windows.',
    );
  }

  Future<OcrAvailability> availability() async =>
      _availability ??= await engine.availability();

  /// Clears the memoised availability so the next [availability] call
  /// re-probes the engine.
  ///
  /// Availability is normally cached for the service's lifetime on the
  /// assumption it doesn't change mid-session. That assumption doesn't hold
  /// while the native OCR channel implementations are rolling out: a caller
  /// that holds a long-lived [OcrService] and calls [availability] before
  /// the platform plugin registers would otherwise pin "unavailable"
  /// forever, even after the channel comes up. This is the recovery path.
  void resetAvailability() => _availability = null;

  void invalidate(String cacheKey) => _cache.remove(cacheKey);

  void clearCache() => _cache.clear();

  /// Recognises text in [imagePath], optionally limited to [regionPx] in
  /// native image pixels.
  ///
  /// Full-image results are cached under [cacheKey] — callers pass a key that
  /// changes when the bitmap changes. Region results are never cached, since
  /// the region differs on every call.
  Future<OcrResult> recognizeCapture({
    required String imagePath,
    required String cacheKey,
    Rect? regionPx,
  }) async {
    final availability = await this.availability();
    if (!availability.available) return OcrResult.empty;

    if (regionPx != null &&
        (regionPx.width < minRegionSide || regionPx.height < minRegionSide)) {
      return OcrResult.empty;
    }

    if (regionPx == null) {
      final cached = _cache[cacheKey];
      if (cached != null) return cached;
    }

    try {
      final file = File(imagePath);
      if (!await file.exists()) return OcrResult.empty;
      final sourceBytes = await file.readAsBytes();

      if (regionPx == null) {
        final result = await engine.recognize(sourceBytes);
        _cache[cacheKey] = result;
        return result;
      }

      // Gene - Nov, 20, 2026: Fast native Skia decode + Rust FFI cropRgba path avoiding slow pure-Dart PNG decode/re-encode on large captures.
      // Old implementation:
      // final decoded = await compute(img.decodeImage, sourceBytes);
      // if (decoded == null) return OcrResult.empty;
      // final x = regionPx.left.round().clamp(0, decoded.width);
      // ...
      // final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      // final result = await engine.recognize(
      //   Uint8List.fromList(await compute(img.encodePng, cropped)),
      // );
      if (RustImageCore.isAvailable) {
        final uiImg = await RenderService.decodeImageBytes(sourceBytes);
        if (uiImg != null) {
          try {
            final fullW = uiImg.width;
            final fullH = uiImg.height;
            final x = regionPx.left.round().clamp(0, fullW);
            final y = regionPx.top.round().clamp(0, fullH);
            final right = regionPx.right.round().clamp(0, fullW);
            final bottom = regionPx.bottom.round().clamp(0, fullH);
            final w = right - x;
            final h = bottom - y;
            if (w < minRegionSide || h < minRegionSide) return OcrResult.empty;

            final rawData = await uiImg.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            if (rawData != null) {
              final croppedRgba = RustImageCore.cropRgba(
                src: rawData.buffer.asUint8List(),
                srcWidth: fullW,
                srcHeight: fullH,
                cropX: x,
                cropY: y,
                cropWidth: w,
                cropHeight: h,
              );
              if (croppedRgba != null) {
                final completer = Completer<ui.Image>();
                ui.decodeImageFromPixels(
                  croppedRgba,
                  w,
                  h,
                  ui.PixelFormat.rgba8888,
                  completer.complete,
                );
                final croppedImg = await completer.future;
                try {
                  final croppedPng = await croppedImg.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  if (croppedPng != null) {
                    final result = await engine.recognize(
                      croppedPng.buffer.asUint8List(),
                    );
                    final fullImageSize = Size(
                      fullW.toDouble(),
                      fullH.toDouble(),
                    );
                    return _offset(
                      result,
                      Offset(x.toDouble(), y.toDouble()),
                      fullImageSize,
                    );
                  }
                } finally {
                  croppedImg.dispose();
                }
              }
            }
          } finally {
            uiImg.dispose();
          }
        }
      }

      final decoded = await compute(img.decodeImage, sourceBytes);
      if (decoded == null) return OcrResult.empty;

      // Intersect the requested region with the image bounds: clamp the
      // origin up to 0/left/top, clamp the far edge down to the image's
      // right/bottom, then derive width/height from the clamped edges. A
      // region that hangs off an edge (or off the origin entirely) crops to
      // exactly its true overlap with the image, never to a substitute
      // region of the same nominal size.
      final x = regionPx.left.round().clamp(0, decoded.width);
      final y = regionPx.top.round().clamp(0, decoded.height);
      final right = regionPx.right.round().clamp(0, decoded.width);
      final bottom = regionPx.bottom.round().clamp(0, decoded.height);
      final w = right - x;
      final h = bottom - y;

      if (w < minRegionSide || h < minRegionSide) return OcrResult.empty;

      final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      final result = await engine.recognize(
        Uint8List.fromList(await compute(img.encodePng, cropped)),
      );
      final fullImageSize = Size(
        decoded.width.toDouble(),
        decoded.height.toDouble(),
      );
      return _offset(result, Offset(x.toDouble(), y.toDouble()), fullImageSize);
    } catch (e) {
      debugPrint('SnipSnap OCR service error: $e');
      return OcrResult.empty;
    }
  }

  /// Shifts a region result back into full-image coordinates and replaces
  /// its `imageSize` — which the engine reported as the crop's dimensions —
  /// with the full decoded image's size, so every field on the returned
  /// result agrees it describes full-image space.
  static OcrResult _offset(OcrResult result, Offset delta, Size imageSize) {
    return OcrResult(
      imageSize: imageSize,
      lines: result.lines
          .map(
            (l) => OcrLine(
              text: l.text,
              boundsPx: l.boundsPx.shift(delta),
              confidence: l.confidence,
              words: l.words
                  .map(
                    (w) => OcrWord(
                      text: w.text,
                      boundsPx: w.boundsPx.shift(delta),
                      confidence: w.confidence,
                    ),
                  )
                  .toList(),
            ),
          )
          .toList(),
    );
  }
}
