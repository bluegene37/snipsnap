// Gene - Oct, 27, 2026: Core Template-Matching Image Stitcher for panoramic scrolling capture.
import 'dart:math' as math;
import 'package:image/image.dart' as img;

class StitchResult {
  final int shiftY;
  final int cumulativeHeight;
  final bool isDuplicate;
  final bool isMatchValid;
  final double confidence;

  const StitchResult({
    required this.shiftY,
    required this.cumulativeHeight,
    required this.isDuplicate,
    required this.isMatchValid,
    required this.confidence,
  });
}

class ImageStitcher {
  final int scrollbarIgnoreMargin;
  final double maxMatchError;
  final int maxCumulativeHeight;

  ImageStitcher({
    this.scrollbarIgnoreMargin = 20,
    this.maxMatchError = 35.0,
    this.maxCumulativeHeight = 35000,
  });

  /// Stitches [newFrame] into [composite], growing [composite] downward if new content is detected.
  StitchResult stitchFrame({
    required img.Image composite,
    required img.Image newFrame,
  }) {
    if (composite.height >= maxCumulativeHeight) {
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: composite.height,
        isDuplicate: true,
        isMatchValid: false,
        confidence: 0.0,
      );
    }

    final shift = findVerticalShift(
      base: composite,
      next: newFrame,
      ignoreRightMargin: scrollbarIgnoreMargin,
      maxError: maxMatchError,
    );

    if (shift == 0) {
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: composite.height,
        isDuplicate: true,
        isMatchValid: true,
        confidence: 1.0,
      );
    }

    if (shift < 0) {
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: composite.height,
        isDuplicate: false,
        isMatchValid: false,
        confidence: 0.0,
      );
    }

    // Append only the newly revealed rows [newFrame.height - shift .. newFrame.height]
    final rowsToAdd = shift;
    final startYInNewFrame = newFrame.height - rowsToAdd;
    final oldHeight = composite.height;
    final newHeight = oldHeight + rowsToAdd;

    // Expand composite canvas
    final expanded = img.Image(
      width: composite.width,
      height: newHeight,
      format: composite.format,
      numChannels: composite.numChannels,
      withPalette: composite.hasPalette,
      palette: composite.palette,
    );

    // Copy existing composite
    for (var y = 0; y < oldHeight; y++) {
      for (var x = 0; x < composite.width; x++) {
        expanded.setPixel(x, y, composite.getPixel(x, y));
      }
    }

    // Append new rows
    for (var row = 0; row < rowsToAdd; row++) {
      final srcY = startYInNewFrame + row;
      final dstY = oldHeight + row;
      for (var x = 0; x < composite.width; x++) {
        expanded.setPixel(x, dstY, newFrame.getPixel(x, srcY));
      }
    }

    // Mutate composite buffer in place
    composite.data = expanded.data;

    return StitchResult(
      shiftY: shift,
      cumulativeHeight: newHeight,
      isDuplicate: false,
      isMatchValid: true,
      confidence: 1.0,
    );
  }

  /// Calculates vertical displacement by comparing the bottom strip of [base]
  /// with [next] using Sum of Absolute Differences (SAD).
  static int findVerticalShift({
    required img.Image base,
    required img.Image next,
    required int ignoreRightMargin,
    required double maxError,
  }) {
    final width = base.width;
    final effectiveWidth = math.max(1, width - ignoreRightMargin);
    final frameH = next.height;
    final sampleH = math.min(frameH ~/ 3, 80);

    if (sampleH < 4 || effectiveWidth < 4) return 0;

    // Check for identical duplicate first
    var isDuplicate = true;
    for (var y = 0; y < sampleH && isDuplicate; y += 2) {
      final baseY = base.height - sampleH + y;
      final nextY = frameH - sampleH + y;
      for (var x = 0; x < effectiveWidth; x += 4) {
        final p1 = base.getPixel(x, baseY);
        final p2 = next.getPixel(x, nextY);
        final diff =
            (p1.r - p2.r).abs() + (p1.g - p2.g).abs() + (p1.b - p2.b).abs();
        if (diff > 15) {
          isDuplicate = false;
          break;
        }
      }
    }
    if (isDuplicate) return 0;

    // Search for the template [base.height - sampleH .. base.height] inside [next]
    int bestShift = -1;
    double lowestAvgError = double.infinity;

    // Scan vertical shifts from 1px up to (frameH - sampleH)
    final maxShift = frameH - sampleH;
    for (var shift = 1; shift <= maxShift; shift++) {
      final nextMatchY = frameH - shift - sampleH;
      if (nextMatchY < 0) break;

      double totalError = 0.0;
      int sampledPixels = 0;

      for (var sy = 0; sy < sampleH; sy += 2) {
        final baseY = base.height - sampleH + sy;
        final candidateY = nextMatchY + sy;
        for (var sx = 0; sx < effectiveWidth; sx += 4) {
          final pBase = base.getPixel(sx, baseY);
          final pNext = next.getPixel(sx, candidateY);
          final diff =
              (pBase.r - pNext.r).abs() +
              (pBase.g - pNext.g).abs() +
              (pBase.b - pNext.b).abs();
          totalError += diff / 3.0;
          sampledPixels++;
        }
      }

      final avgError = totalError / (sampledPixels == 0 ? 1 : sampledPixels);
      if (avgError < lowestAvgError) {
        lowestAvgError = avgError;
        bestShift = shift;
      }
    }

    if (bestShift > 0 && lowestAvgError <= maxError) {
      return bestShift;
    }

    return -1; // No confident match found
  }
}

// Gene - Nov, 20, 2026: O(N) strip accumulator for Dart scrolling fallback (keeps only tail slices until final assembly instead of reallocating full canvas every frame).
class StitchStripSession {
  final ImageStitcher stitcher;
  final List<img.Image> _strips = [];
  img.Image? _tailFrame;
  int _cumulativeHeight = 0;

  StitchStripSession({ImageStitcher? stitcher})
    : stitcher = stitcher ?? ImageStitcher();

  int get cumulativeHeight => _cumulativeHeight;
  int get width => _tailFrame?.width ?? 0;
  img.Image? get tailFrame => _tailFrame;

  StitchResult pushFrame(img.Image newFrame) {
    if (_tailFrame == null) {
      _strips.add(newFrame);
      _tailFrame = newFrame;
      _cumulativeHeight = newFrame.height;
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: _cumulativeHeight,
        isDuplicate: false,
        isMatchValid: true,
        confidence: 1.0,
      );
    }

    if (_cumulativeHeight >= stitcher.maxCumulativeHeight) {
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: _cumulativeHeight,
        isDuplicate: true,
        isMatchValid: false,
        confidence: 0.0,
      );
    }

    final shift = ImageStitcher.findVerticalShift(
      base: _tailFrame!,
      next: newFrame,
      ignoreRightMargin: stitcher.scrollbarIgnoreMargin,
      maxError: stitcher.maxMatchError,
    );

    if (shift == 0) {
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: _cumulativeHeight,
        isDuplicate: true,
        isMatchValid: true,
        confidence: 1.0,
      );
    }
    if (shift < 0) {
      return StitchResult(
        shiftY: 0,
        cumulativeHeight: _cumulativeHeight,
        isDuplicate: false,
        isMatchValid: false,
        confidence: 0.0,
      );
    }

    appendShiftSlice(frame: newFrame, shiftY: shift);
    return StitchResult(
      shiftY: shift,
      cumulativeHeight: _cumulativeHeight,
      isDuplicate: false,
      isMatchValid: true,
      confidence: 1.0,
    );
  }

  void appendShiftSlice({required img.Image frame, required int shiftY}) {
    if (_tailFrame == null) {
      pushFrame(frame);
      return;
    }
    final available = stitcher.maxCumulativeHeight - _cumulativeHeight;
    final actualShift = math.min(shiftY, available);
    if (actualShift <= 0) return;
    _strips.add(
      img.copyCrop(
        frame,
        x: 0,
        y: frame.height - actualShift,
        width: frame.width,
        height: actualShift,
      ),
    );
    _tailFrame = frame;
    _cumulativeHeight += actualShift;
  }

  img.Image? assemble() {
    if (_strips.isEmpty) return null;
    if (_strips.length == 1) return _strips.first;
    final first = _strips.first;
    final out = img.Image(width: first.width, height: _cumulativeHeight);
    var dstY = 0;
    for (final strip in _strips) {
      img.compositeImage(out, strip, dstX: 0, dstY: dstY);
      dstY += strip.height;
    }
    return out;
  }

  void clear() {
    _strips.clear();
    _tailFrame = null;
    _cumulativeHeight = 0;
  }
}
