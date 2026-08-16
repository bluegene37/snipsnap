import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/annotation.dart';
import '../views/components/annotation_renderer.dart';

/// Flattens a capture plus its vector annotations into a PNG at the source
/// image's **native** resolution.
///
/// The editor stores annotation geometry in canvas (viewport) coordinates, so
/// this maps those coordinates through the same `BoxFit.contain` transform the
/// on-screen `Image` widget uses, then scales everything up to native pixels.
/// Rendering offscreen also guarantees no editor chrome — selection handles,
/// crop dimming, HUD badges — ever reaches an exported file.
class RenderService {
  const RenderService._();

  /// Rectangle occupied by the image inside a [canvasSize] viewport when drawn
  /// with `BoxFit.contain`.
  static Rect imageRectInCanvas({
    required Size imageSize,
    required Size canvasSize,
  }) {
    if (imageSize.isEmpty || canvasSize.isEmpty) return Rect.zero;
    final fitted = applyBoxFit(BoxFit.contain, imageSize, canvasSize);
    final dest = fitted.destination;
    return Rect.fromLTWH(
      (canvasSize.width - dest.width) / 2.0,
      (canvasSize.height - dest.height) / 2.0,
      dest.width,
      dest.height,
    );
  }

  /// Decodes [imagePath] into a `ui.Image`. Callers own the result and must
  /// call `dispose()` on it.
  static Future<ui.Image?> decodeImageFile(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      debugPrint('SnipSnap decode error: $e');
      return null;
    }
  }

  /// Renders [imagePath] with [annotations] burned in, at native resolution,
  /// with optional social canvas framing, padding, rounded corners, drop shadow, and gradient.
  ///
  /// [canvasSize] must be the size of the editor canvas the annotations were
  /// drawn against. Returns null when the image cannot be read.
  static Future<Uint8List?> renderFlattenedPng({
    required String imagePath,
    required List<Annotation> annotations,
    required Size canvasSize,
    double framingPadding = 0.0,
    double cornerRadius = 0.0,
    double shadowBlur = 0.0,
    Gradient? framingGradient,
  }) async {
    final baseImage = await decodeImageFile(imagePath);
    if (baseImage == null) return null;

    try {
      final imageSize = Size(baseImage.width.toDouble(), baseImage.height.toDouble());
      final hasFraming = framingPadding > 0 || cornerRadius > 0 || shadowBlur > 0 || framingGradient != null;

      if (annotations.isEmpty && !hasFraming) {
        // Nothing to composite — hand back the original bytes untouched so a
        // plain save is always lossless.
        return await File(imagePath).readAsBytes();
      }

      final imageRect = imageRectInCanvas(imageSize: imageSize, canvasSize: canvasSize);
      if (imageRect.isEmpty && !hasFraming) {
        return await File(imagePath).readAsBytes();
      }

      final scale = imageRect.isEmpty ? 1.0 : imageSize.width / imageRect.width;

      final pad = framingPadding;
      final outWidth = (baseImage.width + pad * 2).round();
      final outHeight = (baseImage.height + pad * 2).round();
      final outRect = Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble());
      final innerImageRect = Rect.fromLTWH(pad, pad, imageSize.width, imageSize.height);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, outRect);

      if (hasFraming && framingGradient != null) {
        final bgPaint = Paint()..shader = framingGradient.createShader(outRect);
        canvas.drawRect(outRect, bgPaint);
      } else if (hasFraming && pad > 0) {
        canvas.drawRect(outRect, Paint()..color = const Color(0xFF18181B));
      }

      if (hasFraming && shadowBlur > 0) {
        final shadowRRect = RRect.fromRectAndRadius(innerImageRect, Radius.circular(cornerRadius));
        final shadowPaint = Paint()
          ..color = const Color(0x66000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadowBlur);
        canvas.drawRRect(shadowRRect.shift(Offset(0, shadowBlur * 0.3)), shadowPaint);
      }

      canvas.save();
      if (cornerRadius > 0) {
        canvas.clipRRect(RRect.fromRectAndRadius(innerImageRect, Radius.circular(cornerRadius)));
      }
      canvas.translate(pad, pad);

      canvas.drawImage(baseImage, Offset.zero, Paint()..filterQuality = FilterQuality.high);

      // Switch into canvas (viewport) coordinates so annotation geometry can be
      // replayed verbatim through the shared renderer.
      if (!imageRect.isEmpty) {
        canvas.save();
        canvas.scale(scale);
        canvas.translate(-imageRect.left, -imageRect.top);
        canvas.clipRect(imageRect);
        AnnotationRenderer.paintAll(
          canvas,
          annotations,
          baseImage: baseImage,
          imageRect: imageRect,
        );
        canvas.restore();
      }

      canvas.restore();

      final picture = recorder.endRecording();
      final rendered = await picture.toImage(outWidth, outHeight);
      picture.dispose();

      try {
        final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally {
        rendered.dispose();
      }
    } catch (e) {
      debugPrint('SnipSnap render error: $e');
      return null;
    } finally {
      baseImage.dispose();
    }
  }
}
