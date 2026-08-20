import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/models/tool_properties.dart';
import 'package:snipsnap/tools/ocr_tool.dart';
import 'package:snipsnap/tools/tool_handler.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
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

  // ---------------------------------------------------------------------------
  // Insert-as-text and the *scalar* half of the coordinate contract.
  //
  // The rect half (region -> image pixels) is pinned in
  // editor_canvas_projection_test.dart. This is the other half, and it bit:
  // `ToolProperties.fontSize` is what the toolbar slider shows, i.e. canvas
  // units, while the annotation it is written into is image space. Store it
  // raw and `mappedToCanvasSpace` divides it by the projection scale at paint
  // time — and it is on disk that way.
  // ---------------------------------------------------------------------------

  group('insert as text', () {
    // A 3024x1890 Retina capture in a 1200x750 canvas: 2.52 image px per
    // canvas px, no letterbox.
    final projection = CanvasProjection(
      imageSize: const Size(3024, 1890),
      canvasSize: const Size(1200, 750),
    );

    Annotation inserted({required bool converted}) {
      final style = ToolProperties.createDefaults()[CanvasTool.text]!;
      final base = Annotation(
        id: 'ocr-1',
        tool: CanvasTool.text,
        color: style.activeColor,
        text: 'hello',
        startPoint: const Offset(40, 40),
      );
      return converted
          ? base.withCanvasSpaceScalars(projection, fontSize: style.fontSize)
          : base.copyWith(fontSize: style.fontSize);
    }

    test('the stored font size is image pixels, not slider units', () {
      final style = ToolProperties.createDefaults()[CanvasTool.text]!;
      expect(style.fontSize, 18.0);
      expect(projection.scale, closeTo(2.52, 1e-9));

      expect(inserted(converted: true).fontSize, closeTo(18.0 * 2.52, 1e-9));
    });

    test('it paints back at the size the toolbar promised', () {
      // The regression, stated as the user sees it: what lands on screen.
      final good = inserted(converted: true).mappedToCanvasSpace(projection);
      expect(good.fontSize, closeTo(18.0, 1e-9));

      // And what the unconverted version would have rendered at: ~7px, which
      // is the near-illegible caption this guards against.
      final bad = inserted(converted: false).mappedToCanvasSpace(projection);
      expect(bad.fontSize, closeTo(18.0 / 2.52, 1e-9));
      expect(bad.fontSize, lessThan(8.0));
    });

    test('an unconverted insert is measurably wrong, not a rounding nit', () {
      expect(
        inserted(converted: false).fontSize,
        isNot(closeTo(inserted(converted: true).fontSize, 1.0)),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // EditorCanvas invariants raised in review. Source-level for the usual
  // reason: `Image.file` hangs flutter_tester, so the canvas cannot be pumped.
  // ---------------------------------------------------------------------------

  group('EditorCanvas bitmap and gesture state', () {
    late String canvas;

    setUpAll(() {
      canvas = File('lib/views/editor_canvas.dart').readAsStringSync();
    });

    test('every in-place bitmap rewrite notifies the parent', () {
      // The floating-selection paths rewrite the capture file at the same path
      // and the same pixel size, so `onImageSizeResolved` early-returns and the
      // parent never learns the bytes changed. A whole-image OCR run after a
      // cut then hits a byte-identical cache key and serves the PRE-EDIT text,
      // with no error and no way for the user to tell.
      expect(canvas, contains('final VoidCallback? onImageBytesChanged;'));
      for (final method in const [
        'Future<void> _extractFloatingSelection() async {',
        'Future<void> _commitFloatingSelection() async {',
      ]) {
        final start = canvas.indexOf(method);
        expect(start, isNot(-1), reason: 'could not find `$method`');
        final end = canvas.indexOf('\n  }', start);
        expect(
          canvas.substring(start, end),
          // Guarded form: the flag that suppresses the redundant reload is
          // only set when the callback actually exists and will fire.
          contains('widget.onImageBytesChanged!.call()'),
          reason: '$method rewrites the bitmap and must say so',
        );
      }
      // Delete reaches the bitmap through _extractFloatingSelection, so it is
      // covered by the same notification rather than a second one.
      final del = canvas.indexOf('Future<void> _deleteFloatingSelection() async {');
      expect(del, isNot(-1));
      expect(
        canvas.substring(del, canvas.indexOf('\n  }', del)),
        contains('_extractFloatingSelection()'),
      );
    });

    test('a tool change clears the canvas-owned drag flags', () {
      // `_isDraggingSelection` and `_isDraggingCrop` do not self-heal at the
      // next `_onPanStart` the way the annotation-drag flags do. Grab a
      // floating-selection handle, press a tool shortcut mid-drag, release:
      // the flag stays set and the next drag rebuilds `_floatingSelectionRect`
      // from a stale origin, conjuring a phantom selection box.
      final start = canvas.indexOf('if (oldWidget.activeTool != widget.activeTool) {');
      expect(start, isNot(-1));
      final end = canvas.indexOf('_selectedAnnotationId = null;', start);
      expect(end, isNot(-1));
      final block = canvas.substring(start, end);
      expect(block, contains('_isDraggingSelection = false;'));
      expect(block, contains('_selectionGestureOriginRect = null;'));
      expect(block, contains('_isDraggingCrop = false;'));
      expect(block, contains('_cropOrigin = null;'));
    });
  });

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

    test('the inserted annotation converts its canvas-unit scalars', () {
      final body = _bodyOf(source, 'void _insertExtractedText(');
      expect(
        body,
        contains('withCanvasSpaceScalars('),
        reason: 'ToolProperties values are canvas units and the annotation is '
            'image space; storing fontSize raw renders the inserted text at '
            'a fraction of its size on any downscaled capture',
      );
      expect(body, contains('fontSize: style.fontSize'));
      expect(body, contains('strokeWidth: style.strokeWidth'));
      expect(
        body,
        contains('if (projection == null || !projection.isValid)'),
        reason: 'withCanvasSpaceScalars silently returns the annotation '
            'untouched on a degenerate projection, which would look like a '
            'successful insert at the model default size',
      );
      // The conversion must not be bypassed by a raw scalar on the constructor.
      final ctor = body.substring(body.indexOf('Annotation('));
      expect(
        ctor.substring(0, ctor.indexOf('withCanvasSpaceScalars')),
        isNot(contains('fontSize:')),
      );
    });

    test('the revision counter and the OCR reset cannot drift apart', () {
      // The cache key stops matching only because _imageRevision moved, and
      // the open panel stops showing pre-edit text only because _resetOcr ran.
      // A call site that does one and forgets the other is the bug.
      expect(_bodyOf(source, 'void _bumpImageRevision('), contains('_resetOcr()'));
      expect(
        '_imageRevision++'.allMatches(source).length,
        1,
        reason: 'the only bare increment must be the one inside '
            '_bumpImageRevision; every other site goes through it',
      );
      expect(source, contains('onImageBytesChanged: () {'));
    });
  });
}
