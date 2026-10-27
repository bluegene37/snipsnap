// Gene - Oct, 27, 2026: Unit tests for ImageStitcher (Task 1: Panoramic scrolling capture core stitcher).
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/scrolling/image_stitcher.dart';

void main() {
  group('ImageStitcher', () {
    late ImageStitcher stitcher;

    setUp(() {
      stitcher = ImageStitcher(scrollbarIgnoreMargin: 10, maxMatchError: 30.0);
    });

    img.Image createPatternImage(int width, int height, {int offsetY = 0}) {
      final image = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        final globalY = y + offsetY;
        final color = img.ColorRgb8(
          (globalY * 7) % 256,
          (globalY * 13) % 256,
          (globalY * 17) % 256,
        );
        for (var x = 0; x < width; x++) {
          image.setPixel(x, y, color);
        }
      }
      return image;
    }

    test('detects exact vertical scroll shift and appends new rows', () {
      final frame1 = createPatternImage(200, 100, offsetY: 0);
      final frame2 = createPatternImage(
        200,
        100,
        offsetY: 40,
      ); // Scrolled down by 40px

      final composite = img.Image.from(frame1);
      final result = stitcher.stitchFrame(
        composite: composite,
        newFrame: frame2,
      );

      expect(result.isMatchValid, isTrue);
      expect(result.isDuplicate, isFalse);
      expect(result.shiftY, 40);
      expect(result.cumulativeHeight, 140);
      expect(composite.height, 140);
    });

    test('identifies stationary / duplicate frame without expanding', () {
      final frame1 = createPatternImage(200, 100, offsetY: 0);
      final frame2 = createPatternImage(
        200,
        100,
        offsetY: 0,
      ); // Exact same content

      final composite = img.Image.from(frame1);
      final result = stitcher.stitchFrame(
        composite: composite,
        newFrame: frame2,
      );

      expect(result.isDuplicate, isTrue);
      expect(result.shiftY, 0);
      expect(composite.height, 100);
    });

    test('ignores noise in right-hand scrollbar margin', () {
      final frame1 = createPatternImage(200, 100, offsetY: 0);
      final frame2 = createPatternImage(200, 100, offsetY: 30);

      // Add a moving white scrollbar thumb in the rightmost 10px of frame 2
      for (var y = 20; y < 60; y++) {
        for (var x = 192; x < 200; x++) {
          frame2.setPixel(x, y, img.ColorRgb8(255, 255, 255));
        }
      }

      final composite = img.Image.from(frame1);
      final result = stitcher.stitchFrame(
        composite: composite,
        newFrame: frame2,
      );

      expect(result.isMatchValid, isTrue);
      expect(result.shiftY, 30);
      expect(result.cumulativeHeight, 130);
    });

    test('flags invalid match when content is completely unaligned', () {
      final frame1 = createPatternImage(200, 100, offsetY: 0);
      final frame2 = img.Image(width: 200, height: 100); // blank black
      img.fill(frame2, color: img.ColorRgb8(0, 0, 0));

      final composite = img.Image.from(frame1);
      final result = stitcher.stitchFrame(
        composite: composite,
        newFrame: frame2,
      );

      expect(result.isMatchValid, isFalse);
      expect(composite.height, 100);
    });

    test('aborts stitch when composite height reaches maxCumulativeHeight', () {
      final cappedStitcher = ImageStitcher(
        scrollbarIgnoreMargin: 10,
        maxMatchError: 30.0,
        maxCumulativeHeight: 100,
      );
      final frame1 = createPatternImage(200, 100, offsetY: 0);
      final frame2 = createPatternImage(200, 100, offsetY: 40);

      final composite = img.Image.from(frame1);
      final result = cappedStitcher.stitchFrame(
        composite: composite,
        newFrame: frame2,
      );

      expect(result.isMatchValid, isFalse);
      expect(result.isDuplicate, isTrue);
      expect(result.shiftY, 0);
      expect(composite.height, 100);
    });

    test(
      'returns zero shift for tiny frames where sample height is too small',
      () {
        final tiny1 = img.Image(width: 2, height: 2);
        final tiny2 = img.Image(width: 2, height: 2);

        final shift = ImageStitcher.findVerticalShift(
          base: tiny1,
          next: tiny2,
          ignoreRightMargin: 0,
          maxError: 30.0,
        );

        expect(shift, 0);
      },
    );
  });
}
