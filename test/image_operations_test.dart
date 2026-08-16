import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/utils/image_operations.dart';

void main() {
  group('ImageOperations.floodFill', () {
    test('fills connected solid color region', () {
      final image = img.Image(width: 10, height: 10);
      // Fill image with white
      for (int y = 0; y < 10; y++) {
        for (int x = 0; x < 10; x++) {
          image.setPixelRgba(x, y, 255, 255, 255, 255);
        }
      }
      // Add a red 4x4 square in the middle
      for (int y = 3; y < 7; y++) {
        for (int x = 3; x < 7; x++) {
          image.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }

      // Flood fill the red square with blue
      final changed = ImageOperations.floodFill(
        image: image,
        startX: 4,
        startY: 4,
        fillColor: const Color(0xFF0000FF),
        tolerancePercent: 5.0,
      );

      expect(changed, isTrue);

      // Check the square is now blue
      for (int y = 3; y < 7; y++) {
        for (int x = 3; x < 7; x++) {
          final p = image.getPixel(x, y);
          expect(p.r, 0);
          expect(p.g, 0);
          expect(p.b, 255);
          expect(p.a, 255);
        }
      }

      // Check outside remains white
      final outside = image.getPixel(0, 0);
      expect(outside.r, 255);
      expect(outside.g, 255);
      expect(outside.b, 255);
    });

    test('fills transparent region with color', () {
      final image = img.Image(width: 8, height: 8, numChannels: 4);
      // Default new img.Image with 4 channels is all transparent (0, 0, 0, 0)
      final changed = ImageOperations.floodFill(
        image: image,
        startX: 0,
        startY: 0,
        fillColor: const Color(0xFFFF8800),
        tolerancePercent: 15.0,
      );

      expect(changed, isTrue);
      final p = image.getPixel(3, 3);
      expect(p.r, 255);
      expect(p.g, 136);
      expect(p.b, 0);
      expect(p.a, 255);
    });

    test('global fill replaces non-contiguous areas of matching color', () {
      final image = img.Image(width: 10, height: 10);
      // Two separate red pixels
      image.setPixelRgba(1, 1, 255, 0, 0, 255);
      image.setPixelRgba(8, 8, 255, 0, 0, 255);

      final changed = ImageOperations.floodFill(
        image: image,
        startX: 1,
        startY: 1,
        fillColor: const Color(0xFF00FF00),
        tolerancePercent: 5.0,
        isGlobal: true,
      );

      expect(changed, isTrue);

      final p1 = image.getPixel(1, 1);
      expect(p1.r, 0);
      expect(p1.g, 255);
      expect(p1.b, 0);

      final p2 = image.getPixel(8, 8);
      expect(p2.r, 0);
      expect(p2.g, 255);
      expect(p2.b, 0);
    });
  });

  group('ImageOperations.cutRegion', () {
    test('extracts sub-image and erases source area to transparent', () {
      final image = img.Image(width: 20, height: 20, numChannels: 4);
      for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 20; x++) {
          image.setPixelRgba(x, y, 200, 100, 50, 255);
        }
      }

      final cut = ImageOperations.cutRegion(
        image: image,
        x: 5,
        y: 5,
        width: 10,
        height: 10,
      );

      expect(cut, isNotNull);
      expect(cut!.width, 10);
      expect(cut.height, 10);

      // Verify cut region has the original colors
      final cutPixel = cut.getPixel(0, 0);
      expect(cutPixel.r, 200);
      expect(cutPixel.g, 100);
      expect(cutPixel.b, 50);
      expect(cutPixel.a, 255);

      // Verify the hole left in source image is transparent
      for (int y = 5; y < 15; y++) {
        for (int x = 5; x < 15; x++) {
          final p = image.getPixel(x, y);
          expect(p.a, 0);
        }
      }

      // Verify areas outside the hole remain intact
      final untouched = image.getPixel(0, 0);
      expect(untouched.a, 255);
      expect(untouched.r, 200);
    });
  });

  group('ImageOperations.pasteRegion', () {
    test('composites sub-image onto destination image', () {
      final base = img.Image(width: 20, height: 20);
      final sub = img.Image(width: 5, height: 5);
      for (int y = 0; y < 5; y++) {
        for (int x = 0; x < 5; x++) {
          sub.setPixelRgba(x, y, 255, 0, 0, 255);
        }
      }

      ImageOperations.pasteRegion(
        destinationImage: base,
        subImage: sub,
        dstX: 10,
        dstY: 10,
        dstWidth: 5,
        dstHeight: 5,
      );

      final p = base.getPixel(12, 12);
      expect(p.r, 255);
      expect(p.g, 0);
      expect(p.b, 0);
      expect(p.a, 255);
    });
  });

  group('ImageOperations.expandOrCropCanvas', () {
    test('inward crop reduces dimensions correctly', () {
      final image = img.Image(width: 100, height: 100);
      image.setPixelRgba(25, 25, 123, 234, 56, 255);

      final cropped = ImageOperations.expandOrCropCanvas(
        sourceImage: image,
        targetLeft: 20,
        targetTop: 20,
        targetWidth: 50,
        targetHeight: 50,
      );

      expect(cropped.width, 50);
      expect(cropped.height, 50);
      final p = cropped.getPixel(5, 5); // (25-20, 25-20)
      expect(p.r, 123);
      expect(p.g, 234);
      expect(p.b, 56);
      expect(p.a, 255);
    });

    test('outward expansion adds transparent space without stretching image', () {
      final image = img.Image(width: 40, height: 40);
      for (int y = 0; y < 40; y++) {
        for (int x = 0; x < 40; x++) {
          image.setPixelRgba(x, y, 10, 20, 30, 255);
        }
      }

      // Expand outward by 10px on all sides: targetLeft = -10, targetTop = -10, targetW = 60, targetH = 60
      final expanded = ImageOperations.expandOrCropCanvas(
        sourceImage: image,
        targetLeft: -10,
        targetTop: -10,
        targetWidth: 60,
        targetHeight: 60,
      );

      expect(expanded.width, 60);
      expect(expanded.height, 60);

      // Expanded margins should be transparent
      final borderPixel = expanded.getPixel(2, 2);
      expect(borderPixel.a, 0);

      // Original image content shifted to (10, 10)
      final centerPixel = expanded.getPixel(15, 15);
      expect(centerPixel.r, 10);
      expect(centerPixel.g, 20);
      expect(centerPixel.b, 30);
      expect(centerPixel.a, 255);
    });
  });
}
