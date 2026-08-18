import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// One recognised word, positioned in **native image pixels**.
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

/// One recognised line, positioned in native image pixels.
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

  static Rect _rect(Map<Object?, Object?> m) => Rect.fromLTWH(
        (m['x'] as num).toDouble(),
        (m['y'] as num).toDouble(),
        (m['w'] as num).toDouble(),
        (m['h'] as num).toDouble(),
      );

  /// Builds a result from the `snipsnap/ocr` channel payload. Natives emit
  /// top-left-origin pixel coordinates, so no flipping happens here.
  factory OcrResult.fromChannelMap(Map<Object?, Object?> map) {
    final rawLines = (map['lines'] as List?) ?? const [];
    return OcrResult(
      imageSize: Size(
        (map['width'] as num?)?.toDouble() ?? 0,
        (map['height'] as num?)?.toDouble() ?? 0,
      ),
      lines: rawLines.map((raw) {
        final l = raw as Map<Object?, Object?>;
        final rawWords = (l['words'] as List?) ?? const [];
        return OcrLine(
          text: l['text'] as String? ?? '',
          boundsPx: _rect(l),
          confidence: (l['confidence'] as num?)?.toDouble() ?? 0.0,
          words: rawWords.map((rw) {
            final w = rw as Map<Object?, Object?>;
            return OcrWord(
              text: w['text'] as String? ?? '',
              boundsPx: _rect(w),
              confidence: (w['confidence'] as num?)?.toDouble() ?? 0.0,
            );
          }).toList(),
        );
      }).toList(),
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
