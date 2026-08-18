import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

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

      final decoded = img.decodeImage(sourceBytes);
      if (decoded == null) return OcrResult.empty;

      final x = regionPx.left.round().clamp(0, decoded.width - 1);
      final y = regionPx.top.round().clamp(0, decoded.height - 1);
      final w = regionPx.width.round().clamp(1, decoded.width - x);
      final h = regionPx.height.round().clamp(1, decoded.height - y);

      final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      final result = await engine.recognize(
        Uint8List.fromList(img.encodePng(cropped)),
      );
      return _offset(result, Offset(x.toDouble(), y.toDouble()));
    } catch (e) {
      debugPrint('SnipSnap OCR service error: $e');
      return OcrResult.empty;
    }
  }

  /// Shifts a region result back into full-image coordinates.
  static OcrResult _offset(OcrResult result, Offset delta) {
    if (delta == Offset.zero) return result;
    return OcrResult(
      imageSize: result.imageSize,
      lines: result.lines
          .map((l) => OcrLine(
                text: l.text,
                boundsPx: l.boundsPx.shift(delta),
                confidence: l.confidence,
                words: l.words
                    .map((w) => OcrWord(
                          text: w.text,
                          boundsPx: w.boundsPx.shift(delta),
                          confidence: w.confidence,
                        ))
                    .toList(),
              ))
          .toList(),
    );
  }
}
