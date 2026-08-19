import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/tools/ocr_tool.dart';
import 'package:snipsnap/tools/tool_handler.dart';
import 'package:snipsnap/utils/constants.dart';

import 'tool_handlers_test.dart' show MockToolDelegate;

DragStartDetails _dragStart(Offset p) =>
    DragStartDetails(localPosition: p, globalPosition: p);
DragUpdateDetails _dragUpdate(Offset p) =>
    DragUpdateDetails(globalPosition: p, localPosition: p);
DragEndDetails _dragEnd() => DragEndDetails();
TapUpDetails _tapUp(Offset p) =>
    TapUpDetails(kind: PointerDeviceKind.mouse, localPosition: p);

/// Returns the body of a 2-space-indented member in [source].
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'could not find `$signature` in the source');
  final end = source.indexOf('\n  }', start);
  expect(end, isNot(-1), reason: 'could not find the end of `$signature`');
  return source.substring(start, end);
}

void main() {
  test('handlerFor returns the OCR handler', () {
    expect(
      handlerFor(CanvasTool.ocr, MockToolDelegate()),
      isA<OcrToolHandler>(),
    );
  });

  test('a drag requests extraction for that region', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
    handler.onPanUpdate(_dragUpdate(const Offset(120, 90)), const Offset(120, 90));
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions, hasLength(1));
    expect(delegate.extractTextRegions.single, const Rect.fromLTRB(10, 10, 120, 90));
  });

  test('a drag up and to the left still yields a normalised region', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(200, 160)), const Offset(200, 160));
    handler.onPanUpdate(_dragUpdate(const Offset(40, 20)), const Offset(40, 20));
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions.single, const Rect.fromLTRB(40, 20, 200, 160));
  });

  test('a tap with no drag requests whole-image extraction', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onTapUp(_tapUp(const Offset(40, 40)), const Offset(40, 40));

    expect(delegate.extractTextRegions, hasLength(1));
    expect(delegate.extractTextRegions.single, isNull);
  });

  test('a negligible drag is treated as a tap', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
    handler.onPanUpdate(_dragUpdate(const Offset(12, 11)), const Offset(12, 11));
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions.single, isNull);
  });

  test('a drag that is wide but paper-thin is treated as a tap', () {
    // Either axis below the threshold is unusable: OcrService rejects the crop
    // outright, so the handler must not present it as a region.
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
    handler.onPanUpdate(_dragUpdate(const Offset(400, 13)), const Offset(400, 13));
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions.single, isNull);
  });

  test('a pan end with no pan start asks for nothing at all', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions, isEmpty);
  });

  test('the handler does not retain the previous region across gestures', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
    handler.onPanUpdate(_dragUpdate(const Offset(120, 90)), const Offset(120, 90));
    handler.onPanEnd(_dragEnd());
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions, hasLength(1));
  });

  // ---------------------------------------------------------------------------
  // MainScreen wiring, as source-level invariants.
  //
  // The runtime path cannot be pumped: it lives inside `MainScreen`, whose tree
  // reaches `EditorCanvas` and therefore `Image.file`, which hangs
  // flutter_tester indefinitely (see editor_canvas_projection_test.dart). What
  // is pinned here is the part that fails silently rather than loudly — a cache
  // key that stops tracking the bitmap hands back yesterday's text with no
  // error anywhere.
  // ---------------------------------------------------------------------------

  group('MainScreen OCR wiring', () {
    late String source;

    setUpAll(() {
      source = File('lib/views/main_screen.dart').readAsStringSync();
    });

    test('the cache key tracks the bitmap, not just the capture', () {
      final body = _bodyOf(source, 'String _ocrCacheKeyFor(');
      expect(
        body,
        contains(r'$_imageRevision'),
        reason: 'OcrService caches full-image results under whatever key it is '
            'given and cannot see the bitmap change. _imageRevision is bumped '
            'by crop, flatten, flood fill and undo/redo — without it, OCR '
            'after a crop returns the pre-crop text.',
      );
      expect(body, contains(r'${capture.id}'));
      expect(
        body,
        contains(r'${capture.filePath}'),
        reason: 'the key should name the bytes actually read',
      );
    });

    test('the only cacheKey passed is the derived one', () {
      expect(
        _bodyOf(source, 'Future<void> _handleExtractText('),
        contains('cacheKey: _ocrCacheKeyFor(capture)'),
      );
      expect('cacheKey:'.allMatches(source).length, 1);
    });

    test('availability is probed so unavailable is not shown as empty', () {
      final body = _bodyOf(source, 'Future<void> _handleExtractText(');
      final probe = body.indexOf('_ocrService.availability()');
      final call = body.indexOf('_ocrService.recognizeCapture(');
      expect(probe, isNot(-1),
          reason: 'an unavailable engine and a blank region both return '
              'OcrResult.empty; only availability() separates them');
      expect(call, isNot(-1));
      expect(probe, lessThan(call));
      expect(body, contains('_ocrUnavailableReason = availability.reason'));
    });

    test('switching captures drops the cache and closes the panel', () {
      expect(_bodyOf(source, 'void _resetOcr('), contains('clearCache()'));
      // The gallery's selection callback is where the active capture actually
      // changes.
      final selection = source.indexOf('onSelectItem: (item) {');
      expect(selection, isNot(-1));
      final reset = source.indexOf('_resetOcr();', selection);
      final assigned = source.indexOf('_activeCapture = item;', selection);
      expect(reset, isNot(-1));
      expect(reset, lessThan(assigned),
          reason: 'stale results must not survive the switch');
    });

    test('the canvas callback is wired to the handler', () {
      expect(source, contains('onExtractText: _handleExtractText'));
      final canvas = File('lib/views/editor_canvas.dart').readAsStringSync();
      expect(canvas, contains('widget.onExtractText?.call('));
    });
  });
}
