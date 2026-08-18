import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/ocr/ocr_engine.dart';
import 'package:snipsnap/services/ocr/ocr_service.dart';

class FakeOcrEngine implements OcrEngine {
  int recognizeCalls = 0;
  Uint8List? lastBytes;
  OcrAvailability availabilityResult =
      const OcrAvailability(available: true, languages: ['en-US']);

  @override
  Future<OcrAvailability> availability() async => availabilityResult;

  @override
  Future<OcrResult> recognize(Uint8List pngBytes) async {
    recognizeCalls++;
    lastBytes = pngBytes;
    final decoded = img.decodeImage(pngBytes)!;
    return OcrResult(
      imageSize: Size(decoded.width.toDouble(), decoded.height.toDouble()),
      lines: const [
        OcrLine(
          text: 'sample',
          boundsPx: Rect.fromLTWH(0, 0, 10, 10),
          confidence: 1.0,
        ),
      ],
    );
  }
}

Future<String> _writePng(Directory dir, int w, int h) async {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  final path = '${dir.path}/src.png';
  await File(path).writeAsBytes(img.encodePng(image));
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeOcrEngine engine;
  late OcrService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snipsnap_ocr_test');
    engine = FakeOcrEngine();
    service = OcrService(engine: engine);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('recognizes the whole image when no region is given', () async {
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(result.imageSize, const Size(400, 200));
    expect(engine.recognizeCalls, 1);
  });

  test('crops to the region before calling the engine', () async {
    final path = await _writePng(tempDir, 400, 200);
    await service.recognizeCapture(
      imagePath: path,
      cacheKey: 'k',
      regionPx: const Rect.fromLTWH(100, 50, 120, 60),
    );
    final decoded = img.decodeImage(engine.lastBytes!)!;
    expect(decoded.width, 120);
    expect(decoded.height, 60);
  });

  test('offsets region results back into full-image coordinates', () async {
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(
      imagePath: path,
      cacheKey: 'k',
      regionPx: const Rect.fromLTWH(100, 50, 120, 60),
    );
    // The fake reports a line at (0,0) inside the crop; it must come back at
    // (100,50) in full-image space.
    expect(result.lines.single.boundsPx.left, 100);
    expect(result.lines.single.boundsPx.top, 50);
  });

  test('caches by key and re-runs after invalidation', () async {
    final path = await _writePng(tempDir, 400, 200);
    await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(engine.recognizeCalls, 1);

    service.invalidate('k');
    await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(engine.recognizeCalls, 2);
  });

  test('does not cache region results', () async {
    final path = await _writePng(tempDir, 400, 200);
    const region = Rect.fromLTWH(0, 0, 50, 50);
    await service.recognizeCapture(imagePath: path, cacheKey: 'k', regionPx: region);
    await service.recognizeCapture(imagePath: path, cacheKey: 'k', regionPx: region);
    expect(engine.recognizeCalls, 2);
  });

  test('returns empty for a region smaller than the minimum', () async {
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(
      imagePath: path,
      cacheKey: 'k',
      regionPx: const Rect.fromLTWH(0, 0, 4, 4),
    );
    expect(result.isEmpty, isTrue);
    expect(engine.recognizeCalls, 0);
  });

  test('returns empty when the engine is unavailable', () async {
    engine.availabilityResult = const OcrAvailability.unavailable('no engine');
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(result.isEmpty, isTrue);
    expect(engine.recognizeCalls, 0);
  });
}
