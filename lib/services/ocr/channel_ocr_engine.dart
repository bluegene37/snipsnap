import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ocr_engine.dart';

/// Talks to the native OCR implementations over `snipsnap/ocr`.
///
/// macOS answers with Vision, Windows with Windows.Media.Ocr. Both emit
/// top-left-origin pixel coordinates, so this class does no geometry.
class ChannelOcrEngine implements OcrEngine {
  static const MethodChannel _channel = MethodChannel('snipsnap/ocr');

  const ChannelOcrEngine();

  @override
  Future<OcrAvailability> availability() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'availability',
      );
      if (result == null) {
        return const OcrAvailability.unavailable(
          'No response from the OCR engine.',
        );
      }
      return OcrAvailability(
        available: result['available'] as bool? ?? false,
        reason: result['reason'] as String?,
        languages: ((result['languages'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
    } on MissingPluginException {
      return const OcrAvailability.unavailable(
        'Text extraction is not available on this platform.',
      );
    } catch (e) {
      debugPrint('SnipSnap OCR availability error: $e');
      return OcrAvailability.unavailable('Could not reach the OCR engine: $e');
    }
  }

  @override
  Future<OcrResult> recognize(Uint8List pngBytes) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'recognize',
        {'png': pngBytes},
      );
      if (result == null) return OcrResult.empty;
      return OcrResult.fromChannelMap(result);
    } catch (e) {
      debugPrint('SnipSnap OCR recognize error: $e');
      return OcrResult.empty;
    }
  }
}
