// Gene - Oct, 27, 2026: NativeScrollService interface and PlatformNativeScrollService implementation for viewport frame grabbing and scroll simulation.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class NativeScrollService {
  Future<Uint8List?> captureRectBytes(
    Rect rect, {
    double devicePixelRatio = 1.0,
  });
  Future<void> simulateScrollWheel({
    required int deltaY,
    required Offset position,
  });
}

class PlatformNativeScrollService implements NativeScrollService {
  final MethodChannel _channel;

  PlatformNativeScrollService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('snipsnap/capture');

  @override
  Future<Uint8List?> captureRectBytes(
    Rect rect, {
    double devicePixelRatio = 1.0,
  }) async {
    final x = rect.left * devicePixelRatio;
    final y = rect.top * devicePixelRatio;
    final w = rect.width * devicePixelRatio;
    final h = rect.height * devicePixelRatio;

    try {
      final bytes = await _channel.invokeMethod<Uint8List>('captureRect', {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      });
      return bytes;
    } catch (e) {
      debugPrint('captureRect error: $e');
      return null;
    }
  }

  @override
  Future<void> simulateScrollWheel({
    required int deltaY,
    required Offset position,
  }) async {
    try {
      await _channel.invokeMethod('simulateScroll', {
        'deltaY': deltaY,
        'x': position.dx,
        'y': position.dy,
      });
    } catch (e) {
      debugPrint('simulateScroll error: $e');
    }
  }
}
