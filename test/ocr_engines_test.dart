// Gene - Nov, 14, 2026: Added unit and MethodChannel tests for ChannelOcrEngine and UnavailableOcrEngine.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/ocr/channel_ocr_engine.dart';
import 'package:snipsnap/services/ocr/unavailable_ocr_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ocrChannel = MethodChannel('snipsnap/ocr');

  void setOcrMock(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ocrChannel, handler);
  }

  tearDown(() {
    setOcrMock(null);
  });

  group('ChannelOcrEngine.availability', () {
    const engine = ChannelOcrEngine();

    test('parses available status and language list from channel map', () async {
      final calls = <MethodCall>[];
      setOcrMock((MethodCall call) async {
        calls.add(call);
        return <Object?, Object?>{
          'available': true,
          'languages': <Object?>['en-US', 'zh-Hans'],
        };
      });

      final status = await engine.availability();

      expect(calls.map((c) => c.method), <String>['availability']);
      expect(status.available, isTrue);
      expect(status.reason, isNull);
      expect(status.languages, <String>['en-US', 'zh-Hans']);
    });

    test('parses unavailable status, reason, and defaults missing fields', () async {
      setOcrMock(
        (MethodCall call) async => <Object?, Object?>{
          'available': false,
          'reason': 'No language pack',
        },
      );

      final withReason = await engine.availability();
      expect(withReason.available, isFalse);
      expect(withReason.reason, 'No language pack');
      expect(withReason.languages, isEmpty);

      setOcrMock((MethodCall call) async => <Object?, Object?>{});

      final emptyMap = await engine.availability();
      expect(emptyMap.available, isFalse);
      expect(emptyMap.reason, isNull);
      expect(emptyMap.languages, isEmpty);
    });

    test('returns unavailable when channel returns null', () async {
      setOcrMock((MethodCall call) async => null);

      final status = await engine.availability();

      expect(status.available, isFalse);
      expect(status.reason, 'No response from the OCR engine.');
      expect(status.languages, isEmpty);
    });

    test('returns platform unavailable message on MissingPluginException', () async {
      setOcrMock(null);

      final status = await engine.availability();

      expect(status.available, isFalse);
      expect(status.reason, 'Text extraction is not available on this platform.');
    });

    test('returns descriptive error reason when channel throws PlatformException', () async {
      setOcrMock((MethodCall call) async {
        throw PlatformException(code: 'OCR_DOWN', message: 'vision failed');
      });

      final status = await engine.availability();

      expect(status.available, isFalse);
      expect(status.reason, startsWith('Could not reach the OCR engine:'));
      expect(status.reason, contains('vision failed'));
    });
  });

  group('ChannelOcrEngine.recognize', () {
    const engine = ChannelOcrEngine();
    final pngBytes = Uint8List.fromList(<int>[137, 80, 78, 71, 1, 2, 3]);

    test('sends png bytes and parses lines and nested word boxes', () async {
      final calls = <MethodCall>[];
      setOcrMock((MethodCall call) async {
        calls.add(call);
        return <Object?, Object?>{
          'width': 640,
          'height': 320,
          'lines': <Object?>[
            <Object?, Object?>{
              'text': 'Hello world',
              'x': 12.5,
              'y': 20.0,
              'w': 140.0,
              'h': 24.0,
              'confidence': 0.98,
              'words': <Object?>[
                <Object?, Object?>{
                  'text': 'Hello',
                  'x': 12.5,
                  'y': 20.0,
                  'w': 60.0,
                  'h': 24.0,
                  'confidence': 0.99,
                },
                <Object?, Object?>{
                  'text': 'world',
                  'x': 80.5,
                  'y': 20.0,
                  'w': 72.0,
                  'h': 24.0,
                  'confidence': 0.97,
                },
              ],
            },
          ],
        };
      });

      final result = await engine.recognize(pngBytes);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'recognize');
      expect((calls.single.arguments as Map<Object?, Object?>)['png'], pngBytes);
      expect(result.imageSize, const Size(640, 320));
      expect(result.plainText, 'Hello world');
      expect(result.lines, hasLength(1));

      final line = result.lines.single;
      expect(line.boundsPx, const Rect.fromLTWH(12.5, 20.0, 140.0, 24.0));
      expect(line.confidence, 0.98);
      expect(line.words, hasLength(2));
      expect(line.words.first.text, 'Hello');
      expect(
        line.words.first.boundsPx,
        const Rect.fromLTWH(12.5, 20.0, 60.0, 24.0),
      );
      expect(line.words.first.confidence, 0.99);
      expect(line.words.last.text, 'world');
    });

    test('returns OcrResult.empty when channel returns null', () async {
      setOcrMock((MethodCall call) async => null);

      final result = await engine.recognize(pngBytes);

      expect(result.isEmpty, isTrue);
      expect(result.imageSize, Size.zero);
    });

    test('returns OcrResult.empty on MissingPluginException and PlatformException', () async {
      setOcrMock(null);
      expect((await engine.recognize(pngBytes)).isEmpty, isTrue);

      setOcrMock((MethodCall call) async {
        throw PlatformException(code: 'ERR', message: 'decode failed');
      });
      expect((await engine.recognize(pngBytes)).isEmpty, isTrue);
    });
  });

  group('UnavailableOcrEngine', () {
    test('reports configured unavailable reason and returns empty result', () async {
      const engine = UnavailableOcrEngine(
        'OCR is not supported in this build.',
      );

      final status = await engine.availability();
      expect(status.available, isFalse);
      expect(status.reason, 'OCR is not supported in this build.');
      expect(status.languages, isEmpty);

      final result = await engine.recognize(Uint8List.fromList(<int>[1, 2, 3]));
      expect(result.isEmpty, isTrue);
      expect(result.imageSize, Size.zero);
    });
  });
}
