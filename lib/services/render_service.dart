import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/annotation.dart';
import '../utils/canvas_projection.dart';
import '../views/components/annotation_renderer.dart';

/// Flattens a capture plus its vector annotations into a PNG at the source
/// image's **native** resolution.
///
/// Annotations arrive in **image pixels**. They are mapped back into the
/// editor's canvas coordinates and replayed through the same `BoxFit.contain`
/// transform the on-screen `Image` widget uses, so the exported file is
/// pixel-for-pixel what the editor was showing — one painting path, not two.
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
  /// [annotations] are in image pixels. [canvasSize] must be the size of the
  /// live editor canvas: it defines the projection the annotations are mapped
  /// back through, and a degenerate one therefore throws a [StateError] rather
  /// than writing a file whose markup is silently misplaced or missing.
  /// Returns null when the image cannot be read.
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

      // An empty rect means the editor canvas was never laid out. Rendering
      // through it would place nothing correctly, so fail loudly instead of
      // returning a file that looks saved but has lost its markup.
      if (imageRect.isEmpty && annotations.isNotEmpty) {
        throw StateError(
          'Cannot flatten ${annotations.length} annotation(s): the editor canvas '
          'has no size (canvasSize=$canvasSize). The capture was not exported.',
        );
      }
      if (imageRect.isEmpty && !hasFraming) {
        return await File(imagePath).readAsBytes();
      }

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
      // replayed verbatim through the shared renderer. The stored annotations
      // are in image pixels, so they are mapped down into that space first —
      // the exact inverse of the transform applied to the canvas, which is what
      // makes the export identical to what the editor draws.
      //
      // Guaranteed non-empty here whenever there is anything to map: the check
      // above already threw. A framing-only export can still reach this point
      // with an empty rect, hence the guard on the annotation list.
      if (annotations.isNotEmpty) {
        final projection = CanvasProjection(
          imageSize: imageSize,
          canvasSize: canvasSize,
        );
        final scale = projection.scale;
        canvas.save();
        canvas.scale(scale);
        canvas.translate(-imageRect.left, -imageRect.top);
        canvas.clipRect(imageRect);
        AnnotationRenderer.paintAll(
          canvas,
          annotations.map((a) => a.mappedToCanvasSpace(projection)).toList(),
          baseImage: baseImage,
          imageRect: imageRect,
          pixelScale: scale,
        );
        canvas.restore();
      }

      canvas.restore();

      final picture = recorder.endRecording();
      // `finally`, not a trailing call: a very large framed export can throw
      // out of `toImage`, and the Picture's native handle would leak with it.
      final ui.Image rendered;
      try {
        rendered = await picture.toImage(outWidth, outHeight);
      } finally {
        picture.dispose();
      }

      try {
        final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally {
        rendered.dispose();
      }
    } on StateError {
      // The invalid-canvas failure above is the whole point of this method's
      // contract — it must not be folded into the silent null that means
      // "the image could not be rendered".
      rethrow;
    } catch (e) {
      debugPrint('SnipSnap render error: $e');
      return null;
    } finally {
      baseImage.dispose();
    }
  }
}
