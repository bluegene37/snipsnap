import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Arguments for [floodFillPng]. `compute` passes exactly one argument and its
/// entry point must be top-level or static, so the parameters travel as a
/// record and the bitmap crosses the isolate boundary as encoded bytes rather
/// than as a decoded [img.Image] — a 5K capture is ~59 MB decoded and a small
/// fraction of that as PNG.
typedef FloodFillRequest = ({
  Uint8List pngBytes,
  int startX,
  int startY,
  int fillArgb,
  double tolerancePercent,
  double opacity,
  bool isGlobal,
});

/// Runs [ImageOperations.floodFill] off the UI isolate, returning the re-encoded
/// PNG, or null when nothing matched (or the bytes could not be decoded).
///
/// Top-level rather than a static method so it is a valid `compute` entry
/// point. A global fill on a 5K capture is 14.7 M pixel visits through the
/// `image` package's accessor objects; on the UI isolate that is seconds of a
/// frozen window.
Uint8List? floodFillPng(FloodFillRequest req) {
  final image = img.decodeImage(req.pngBytes);
  if (image == null) return null;
  final changed = ImageOperations.floodFill(
    image: image,
    startX: req.startX,
    startY: req.startY,
    fillColor: Color(req.fillArgb),
    tolerancePercent: req.tolerancePercent,
    opacity: req.opacity,
    isGlobal: req.isGlobal,
  );
  if (!changed) return null;
  return Uint8List.fromList(img.encodePng(image));
}

/// Clean, high-performance bitmap operations for SnipSnap (Fill, Selection, Crop/Expand).
class ImageOperations {
  const ImageOperations._();

  /// Performs a Snagit-like flood fill (contiguous) or global fill on [image].
  ///
  /// [startX], [startY]: The pixel coordinates clicked by the user.
  /// [fillColor]: The desired replacement color.
  /// [tolerancePercent]: Tolerance threshold between 0% and 100% (default 15%).
  /// [opacity]: Opacity between 0.0 and 1.0 (default 1.0).
  /// [isGlobal]: If true, replaces all matching pixels across the image.
  ///             If false, replaces only the contiguous connected region.
  static bool floodFill({
    required img.Image image,
    required int startX,
    required int startY,
    required Color fillColor,
    double tolerancePercent = 15.0,
    double opacity = 1.0,
    bool isGlobal = false,
  }) {
    if (startX < 0 ||
        startX >= image.width ||
        startY < 0 ||
        startY >= image.height) {
      return false;
    }

    final startPixel = image.getPixel(startX, startY);
    final srcR = startPixel.r.toInt();
    final srcG = startPixel.g.toInt();
    final srcB = startPixel.b.toInt();
    final srcA = startPixel.a.toInt();

    final destA = ((fillColor.a * opacity) * 255.0).round().clamp(0, 255);
    final destR = (fillColor.r * 255.0).round().clamp(0, 255);
    final destG = (fillColor.g * 255.0).round().clamp(0, 255);
    final destB = (fillColor.b * 255.0).round().clamp(0, 255);

    // If source pixel already matches target pixel exactly, avoid redundant work.
    if (srcR == destR && srcG == destG && srcB == destB && srcA == destA) {
      return false;
    }

    final toleranceNorm = (tolerancePercent / 100.0).clamp(0.0, 1.0);
    final isSourceTransparent = srcA <= 10;

    bool matches(img.Pixel p) {
      final pA = p.a.toInt();
      if (isSourceTransparent) {
        // When clicking a transparent area, match any pixel with alpha within tolerance
        return pA <= (toleranceNorm * 255.0) || (srcA == 0 && pA == 0);
      }

      // Euclidean color distance in normalized RGBA space (0.0 to 1.0)
      final dr = p.r.toDouble() - srcR.toDouble();
      final dg = p.g.toDouble() - srcG.toDouble();
      final db = p.b.toDouble() - srcB.toDouble();
      final da = pA.toDouble() - srcA.toDouble();
      final dist = math.sqrt(dr * dr + dg * dg + db * db + da * da) / 510.0;
      return dist <= toleranceNorm;
    }

    final targetColor = img.ColorRgba8(destR, destG, destB, destA);

    if (isGlobal) {
      // Global fill: replace all matching pixels across the image
      for (int y = 0; y < image.height; y++) {
        for (int x = 0; x < image.width; x++) {
          final p = image.getPixel(x, y);
          if (matches(p)) {
            image.setPixel(x, y, targetColor);
          }
        }
      }
      return true;
    }

    // Contiguous BFS Flood Fill with visited bitset
    final width = image.width;
    final height = image.height;
    final visited = Uint8List(width * height);

    // Flat queue for high performance
    final queue = Int32List(width * height);
    int head = 0;
    int tail = 0;

    final startIdx = startY * width + startX;
    visited[startIdx] = 1;
    queue[tail++] = startIdx;

    while (head < tail) {
      final currIdx = queue[head++];
      final cx = currIdx % width;
      final cy = currIdx ~/ width;

      image.setPixel(cx, cy, targetColor);

      // Check 4-connected neighbors
      // Right
      if (cx + 1 < width) {
        final nIdx = currIdx + 1;
        if (visited[nIdx] == 0 && matches(image.getPixel(cx + 1, cy))) {
          visited[nIdx] = 1;
          queue[tail++] = nIdx;
        }
      }
      // Left
      if (cx - 1 >= 0) {
        final nIdx = currIdx - 1;
        if (visited[nIdx] == 0 && matches(image.getPixel(cx - 1, cy))) {
          visited[nIdx] = 1;
          queue[tail++] = nIdx;
        }
      }
      // Down
      if (cy + 1 < height) {
        final nIdx = currIdx + width;
        if (visited[nIdx] == 0 && matches(image.getPixel(cx, cy + 1))) {
          visited[nIdx] = 1;
          queue[tail++] = nIdx;
        }
      }
      // Up
      if (cy - 1 >= 0) {
        final nIdx = currIdx - width;
        if (visited[nIdx] == 0 && matches(image.getPixel(cx, cy - 1))) {
          visited[nIdx] = 1;
          queue[tail++] = nIdx;
        }
      }
    }

    return true;
  }

  /// Extracts a rectangular region from [image] and replaces that region in [image]
  /// with transparent pixels (cut operation).
  static img.Image? cutRegion({
    required img.Image image,
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    final clampX = x.clamp(0, image.width - 1);
    final clampY = y.clamp(0, image.height - 1);
    final clampW = width.clamp(1, image.width - clampX);
    final clampH = height.clamp(1, image.height - clampY);

    if (clampW <= 0 || clampH <= 0) return null;

    // 1. Copy the cropped slice
    final extracted = img.copyCrop(
      image,
      x: clampX,
      y: clampY,
      width: clampW,
      height: clampH,
    );

    // 2. Erase the area in the source image to transparent
    final transparent = img.ColorRgba8(0, 0, 0, 0);
    for (int py = clampY; py < clampY + clampH; py++) {
      for (int px = clampX; px < clampX + clampW; px++) {
        image.setPixel(px, py, transparent);
      }
    }

    return extracted;
  }

  /// Pastes / composites [subImage] into [destinationImage] at ([dstX], [dstY]),
  /// optionally resizing it if [dstWidth] and [dstHeight] differ.
  static void pasteRegion({
    required img.Image destinationImage,
    required img.Image subImage,
    required int dstX,
    required int dstY,
    int? dstWidth,
    int? dstHeight,
  }) {
    img.Image toComposite = subImage;
    if (dstWidth != null &&
        dstHeight != null &&
        (dstWidth != subImage.width || dstHeight != subImage.height) &&
        dstWidth > 0 &&
        dstHeight > 0) {
      toComposite = img.copyResize(
        subImage,
        width: dstWidth,
        height: dstHeight,
        interpolation: img.Interpolation.linear,
      );
    }

    img.compositeImage(destinationImage, toComposite, dstX: dstX, dstY: dstY);
  }

  /// Crops or expands the canvas of [sourceImage].
  ///
  /// [targetLeft], [targetTop], [targetWidth], [targetHeight]: Target bounds
  /// in native pixel coordinates relative to original top-left.
  /// If target bounds extend outside the source image, the canvas is expanded
  /// with transparent pixels while keeping the original image at its offset.
  static img.Image expandOrCropCanvas({
    required img.Image sourceImage,
    required int targetLeft,
    required int targetTop,
    required int targetWidth,
    required int targetHeight,
  }) {
    final validW = math.max(1, targetWidth);
    final validH = math.max(1, targetHeight);

    // Pure inward crop within original bounds
    if (targetLeft >= 0 &&
        targetTop >= 0 &&
        (targetLeft + validW) <= sourceImage.width &&
        (targetTop + validH) <= sourceImage.height) {
      return img.copyCrop(
        sourceImage,
        x: targetLeft,
        y: targetTop,
        width: validW,
        height: validH,
      );
    }

    // Outward expansion or mixed expansion/crop
    final expanded = img.Image(width: validW, height: validH, numChannels: 4);
    // Initialize transparent
    final transparent = img.ColorRgba8(0, 0, 0, 0);
    img.fill(expanded, color: transparent);

    // Calculate destination offset where source image is placed
    final dstX = -targetLeft;
    final dstY = -targetTop;

    img.compositeImage(expanded, sourceImage, dstX: dstX, dstY: dstY);

    return expanded;
  }
}
