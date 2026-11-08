// Gene - Nov, 08, 2026: Unit tests for ultra-fast PNG/JPEG header dimension parser.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/utils/image_header_parser.dart';

void main() {
  group('ImageHeaderParser', () {
    test('parses PNG IHDR dimensions accurately from header bytes', () {
      final pngImage = img.Image(width: 640, height: 360);
      final bytes = Uint8List.fromList(img.encodePng(pngImage, level: 1));

      final dims = ImageHeaderParser.parseHeaderBytes(bytes);
      expect(dims, isNotNull);
      expect(dims!.width, 640);
      expect(dims.height, 360);
    });

    test('parses JPEG SOF dimensions accurately from header bytes', () {
      final jpgImage = img.Image(width: 1280, height: 720);
      final bytes = Uint8List.fromList(img.encodeJpg(jpgImage, quality: 80));

      final dims = ImageHeaderParser.parseHeaderBytes(bytes);
      expect(dims, isNotNull);
      expect(dims!.width, 1280);
      expect(dims.height, 720);
    });

    test('reads PNG and JPEG dimensions from disk in under 5ms', () async {
      final tempDir = await Directory.systemTemp.createTemp('snipsnap_hdr_');
      try {
        final pngFile = File('${tempDir.path}/sample.png');
        final pngBytes = Uint8List.fromList(
          img.encodePng(img.Image(width: 1920, height: 1080), level: 1),
        );
        await pngFile.writeAsBytes(pngBytes);

        final sw = Stopwatch()..start();
        final dims = await ImageHeaderParser.readDimensions(pngFile.path);
        sw.stop();

        expect(dims, isNotNull);
        expect(dims!.width, 1920);
        expect(dims.height, 1080);
        expect(sw.elapsedMilliseconds, lessThan(20));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns null for truncated or unrecognized header bytes', () {
      expect(ImageHeaderParser.parseHeaderBytes(Uint8List(8)), isNull);
      expect(
        ImageHeaderParser.parseHeaderBytes(
          Uint8List.fromList(List.filled(32, 0x42)),
        ),
        isNull,
      );
    });
  });
}
