import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// One recognised word, positioned in **native image pixels** (top-left origin).
@immutable
class OcrWord {
  final String text;
  final Rect boundsPx;
  final double confidence;

  const OcrWord({
    required this.text,
    required this.boundsPx,
    required this.confidence,
  });
}

/// One recognised line, positioned in native image pixels (top-left origin).
@immutable
class OcrLine {
  final String text;
  final Rect boundsPx;
  final double confidence;
  final List<OcrWord> words;

  const OcrLine({
    required this.text,
    required this.boundsPx,
    required this.confidence,
    this.words = const [],
  });
}

/// The full recognition result for one image.
@immutable
class OcrResult {
  final List<OcrLine> lines;
  final Size imageSize;

  const OcrResult({required this.lines, required this.imageSize});

  static const OcrResult empty = OcrResult(lines: [], imageSize: Size.zero);

  bool get isEmpty => lines.isEmpty;

  String get plainText => lines.map((l) => l.text).join('\n');

  static double _num(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;

  static String _str(Object? v) => v is String ? v : '';

  static Rect _rect(Map<Object?, Object?> m) => Rect.fromLTWH(
        _num(m['x'], 0.0),
        _num(m['y'], 0.0),
        _num(m['w'], 0.0),
        _num(m['h'], 0.0),
      );

  /// Builds a result from the `snipsnap/ocr` channel payload. Natives emit
  /// top-left-origin pixel coordinates, so no flipping happens here.
  factory OcrResult.fromChannelMap(Map<Object?, Object?> map) {
    final rawLines = map['lines'] is List ? map['lines'] as List : const [];
    final width = _num(map['width'], 0.0);
    final height = _num(map['height'], 0.0);

    return OcrResult(
      imageSize: Size(width, height),
      lines: rawLines
          .whereType<Map<Object?, Object?>>()
          .map((raw) {
            final l = raw;
            final rawWords = l['words'] is List ? l['words'] as List : const [];
            return OcrLine(
              text: _str(l['text']),
              boundsPx: _rect(l),
              confidence: _num(l['confidence'], 0.0),
              words: rawWords
                  .whereType<Map<Object?, Object?>>()
                  .map((rw) {
                    final w = rw;
                    return OcrWord(
                      text: _str(w['text']),
                      boundsPx: _rect(w),
                      confidence: _num(w['confidence'], 0.0),
                    );
                  })
                  .toList(),
            );
          })
          .toList(),
    );
  }
}

/// Whether OCR can run on this host, and why not when it cannot.
@immutable
class OcrAvailability {
  final bool available;
  final String? reason;
  final List<String> languages;

  const OcrAvailability({
    required this.available,
    this.reason,
    this.languages = const [],
  });

  const OcrAvailability.unavailable(String this.reason)
      : available = false,
        languages = const [];
}

/// Recognises text in an image. One implementation per platform.
abstract class OcrEngine {
  Future<OcrAvailability> availability();

  /// [pngBytes] is a complete PNG. Callers crop before calling, so engines
  /// never deal with regions or coordinate systems.
  Future<OcrResult> recognize(Uint8List pngBytes);
}
