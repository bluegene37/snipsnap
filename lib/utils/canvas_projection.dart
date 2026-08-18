import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/annotation.dart';
import '../services/render_service.dart';

/// Converts between canvas (viewport) coordinates and native image pixels.
///
/// Annotations are stored in image pixels so they stay attached to the pixels
/// they mark, independent of window size. Painting and hit-testing still work
/// in canvas coordinates, so this is the single boundary between the two.
///
/// Scalar dimensions (stroke width, font size, corner radius, blur sigma) are
/// scaled alongside points — a 3px stroke drawn on a downscaled 4K screenshot
/// is 12 image pixels, and storing it unscaled would change every stroke
/// weight on export.
@immutable
class CanvasProjection {
  final Size imageSize;
  final Size canvasSize;
  final Rect imageRect;

  const CanvasProjection._(this.imageSize, this.canvasSize, this.imageRect);

  factory CanvasProjection({
    required Size imageSize,
    required Size canvasSize,
  }) {
    final rect = RenderService.imageRectInCanvas(
      imageSize: imageSize,
      canvasSize: canvasSize,
    );
    return CanvasProjection._(imageSize, canvasSize, rect);
  }

  /// False when either size is degenerate. Callers must not persist or export
  /// through an invalid projection — it cannot place anything correctly.
  bool get isValid =>
      !imageSize.isEmpty && !canvasSize.isEmpty && !imageRect.isEmpty;

  /// Image pixels per canvas pixel.
  double get scale => isValid ? imageSize.width / imageRect.width : 1.0;

  Offset toImage(Offset canvasPoint) {
    if (!isValid) return canvasPoint;
    return Offset(
      (canvasPoint.dx - imageRect.left) * scale,
      (canvasPoint.dy - imageRect.top) * scale,
    );
  }

  Offset toCanvas(Offset imagePoint) {
    if (!isValid) return imagePoint;
    return Offset(
      imageRect.left + imagePoint.dx / scale,
      imageRect.top + imagePoint.dy / scale,
    );
  }

  Rect toImageRect(Rect canvasRect) =>
      Rect.fromPoints(toImage(canvasRect.topLeft), toImage(canvasRect.bottomRight));

  Rect toCanvasRect(Rect imagePixelRect) =>
      Rect.fromPoints(toCanvas(imagePixelRect.topLeft), toCanvas(imagePixelRect.bottomRight));

  double toImageLength(double canvasLength) => canvasLength * scale;

  double toCanvasLength(double imageLength) => imageLength / scale;

  @override
  bool operator ==(Object other) =>
      other is CanvasProjection &&
      other.imageSize == imageSize &&
      other.canvasSize == canvasSize;

  @override
  int get hashCode => Object.hash(imageSize, canvasSize);
}

/// Which coordinate system a persisted annotation's numbers are in.
///
/// Rows written before schema v4 are [viewport] — canvas coordinates whose
/// originating viewport was never recorded. They are converted once on load
/// and rewritten as [imagePixels].
enum CoordSpace { viewport, imagePixels }

/// Parses a persisted [CoordSpace] name. Unknown and missing values fall back
/// to [CoordSpace.viewport] so pre-v4 rows are handled correctly by default.
CoordSpace coordSpaceByName(String? name) {
  for (final s in CoordSpace.values) {
    if (s.name == name) return s;
  }
  return CoordSpace.viewport;
}

/// Converts pre-v4 annotations from viewport coordinates into image pixels,
/// and reports whether the conversion actually ran.
///
/// The viewport that produced these numbers was never recorded, so the current
/// canvas is used as the best available estimate. This is exact when the window
/// is the size it was at draw time and approximate otherwise — the same
/// accuracy the rows already had, with the drift frozen instead of recurring on
/// every later resize.
///
/// `converted` is false, and `annotations` is the input returned untouched,
/// when the projection is degenerate. Callers MUST branch on `converted`
/// before clearing any "needs conversion" flag or persisting the result: a
/// `false` here means nothing was actually converted, so the caller must
/// leave the pending-conversion state as-is and let a later attempt (with a
/// laid-out canvas) retry, rather than permanently mislabeling still-viewport
/// data as image pixels.
({List<Annotation> annotations, bool converted}) convertLegacyAnnotationsChecked({
  required List<Annotation> annotations,
  required Size imageSize,
  required Size canvasSize,
}) {
  final projection =
      CanvasProjection(imageSize: imageSize, canvasSize: canvasSize);
  if (!projection.isValid) {
    return (annotations: annotations, converted: false);
  }
  return (
    annotations: annotations.map((a) => a.mappedToImageSpace(projection)).toList(),
    converted: true,
  );
}

/// Convenience wrapper over [convertLegacyAnnotationsChecked] for callers
/// that don't need to know whether the conversion actually ran (i.e. that
/// have no "needs conversion" flag to guard). Most callers should prefer the
/// checked version — see its doc comment for why.
List<Annotation> convertLegacyAnnotations({
  required List<Annotation> annotations,
  required Size imageSize,
  required Size canvasSize,
}) {
  return convertLegacyAnnotationsChecked(
    annotations: annotations,
    imageSize: imageSize,
    canvasSize: canvasSize,
  ).annotations;
}
