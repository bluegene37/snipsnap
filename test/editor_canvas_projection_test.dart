import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

/// Returns the body of a 2-space-indented method in [source], from its
/// signature up to the line that closes it.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'could not find `$signature` in the source');
  final end = source.indexOf('\n  }', start);
  expect(end, isNot(-1), reason: 'could not find the end of `$signature`');
  return source.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Conversion machinery (CanvasProjection + Annotation.mappedTo*Space).
  //
  // Honest label: this group also passes at the parent commit. It exercises
  // Tasks 2 and 3 only. It guards the mapping itself, not Task 6's wiring.
  // ---------------------------------------------------------------------------

  group('conversion machinery', () {
    test('an annotation keeps its image position across viewport sizes', () {
      // Stored in image pixels: a line across the middle of a 1600x900 image.
      final stored = Annotation(
        id: 'a',
        tool: CanvasTool.line,
        color: const Color(0xFF000000),
        strokeWidth: 8.0,
        startPoint: const Offset(800, 450),
        endPoint: const Offset(1200, 450),
      );

      const imageSize = Size(1600, 900);
      Offset canvasStartFor(Size canvas) {
        final p = CanvasProjection(imageSize: imageSize, canvasSize: canvas);
        return p.toImage(stored.mappedToCanvasSpace(p).startPoint!);
      }

      // Whatever the window size, converting to canvas and back lands on the
      // same image pixel. This is the drift regression.
      for (final canvas in const [
        Size(800, 600),
        Size(1600, 900),
        Size(400, 1000),
      ]) {
        final round = canvasStartFor(canvas);
        expect(round.dx, closeTo(800, 1e-6), reason: 'canvas=$canvas');
        expect(round.dy, closeTo(450, 1e-6), reason: 'canvas=$canvas');
      }
    });

    test('a letterboxed projection is not a bare scale', () {
      // 800x400 inside a 400x260 canvas: contain scales by 0.5 and centres the
      // 400x200 result at y=30. An implementation that scales but forgets the
      // letterbox offset passes the dx assertion and fails the dy one.
      final projection = CanvasProjection(
        imageSize: const Size(800, 400),
        canvasSize: const Size(400, 260),
      );
      expect(projection.scale, closeTo(2.0, 1e-9));
      expect(projection.imageRect.top, closeTo(30.0, 1e-9));
      expect(projection.toImage(const Offset(100, 80)).dx, closeTo(200, 1e-9));
      expect(projection.toImage(const Offset(100, 80)).dy, closeTo(100, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // Task 6's boundary wiring.
  //
  // These are source-level invariants, not runtime assertions, and that is a
  // deliberate fallback rather than a preference. A `testWidgets` pump of
  // EditorCanvas is impossible in this environment: any widget tree containing
  // `Image.file` hangs `flutter_tester` indefinitely, which EditorCanvas builds
  // unconditionally whenever `imagePath != null`. The hang reproduces with a
  // bare `Image.file` outside EditorCanvas entirely, reproduces at the parent
  // commit, and is not fixed by `tester.runAsync`, by seeding the image cache,
  // or by `Picture.toImageSync`. See the Task 6 report for the full bisection.
  //
  // What these do buy: every regression actually found while implementing Task 6
  // was a call site that bypassed the conversion — `_duplicateSelectedAnnotation`
  // emitting unconverted, and `_commitInlineText` reading image space and
  // double-converting. Both are exactly what these assertions catch, and both
  // would ship silently otherwise.
  // ---------------------------------------------------------------------------

  group('EditorCanvas boundary wiring', () {
    late String source;

    setUpAll(() {
      source = File('lib/views/editor_canvas.dart').readAsStringSync();
    });

    test('every onAnnotationAdded call goes through _emitAnnotation', () {
      const call = 'widget.onAnnotationAdded(';
      final occurrences = call.allMatches(source).length;
      expect(
        occurrences,
        1,
        reason: 'Annotations must reach the parent only via _emitAnnotation, '
            'which converts canvas -> image pixels. Found $occurrences raw '
            'call sites; a new one bypasses the conversion and stores canvas '
            'coordinates that will drift on the next resize.',
      );
      expect(
        _bodyOf(source, 'void _emitAnnotation('),
        contains(call),
        reason: 'the single onAnnotationAdded call must be the one inside '
            '_emitAnnotation',
      );
    });

    test('_emitAnnotation converts canvas -> image pixels', () {
      expect(
        _bodyOf(source, 'void _emitAnnotation('),
        contains('mappedToImageSpace'),
        reason: 'without this every newly drawn annotation is stored in canvas '
            'coordinates',
      );
    });

    test('_replaceAnnotation converts canvas -> image pixels', () {
      expect(
        _bodyOf(source, 'void _replaceAnnotation('),
        contains('mappedToImageSpace'),
        reason: 'without this every drag, resize, rotate and nudge writes back '
            'canvas coordinates',
      );
    });

    test('_canvasAnnotationsFor converts image pixels -> canvas', () {
      expect(
        _bodyOf(source, 'List<Annotation> _canvasAnnotationsFor('),
        contains('mappedToCanvasSpace'),
        reason: 'painting and hit-testing need canvas coordinates',
      );
    });

    test('the painter is fed the canvas-space view, never the raw list', () {
      expect(
        source,
        isNot(contains('annotations: widget.annotations')),
        reason: '_AnnotationPainter and AnnotationRenderer work in canvas '
            'space; handing them the image-space list paints every annotation '
            'at the wrong place and weight',
      );
      expect(source, contains('_canvasAnnotationsFor('));
    });

    test('the selection and hit-test reads use the canvas-space view', () {
      expect(
        _bodyOf(source, 'Annotation? get _selectedAnnotation {'),
        contains('_canvasAnnotations'),
      );
      // Public since Task 9: `ToolDelegate` declares `hitTestAnnotation`, and
      // `_EditorCanvasState` satisfies the interface with this same method. The
      // invariant is unchanged — whatever the name, the body must read the
      // canvas-space view, because that is the space every caller probes in.
      expect(
        _bodyOf(source, 'Annotation? hitTestAnnotation('),
        contains('_canvasAnnotations'),
      );
    });

    // -------------------------------------------------------------------------
    // Task 9's ToolDelegate boundary.
    //
    // The handlers in lib/tools/ work entirely in canvas space and never
    // convert. That is only safe while every delegate member either reads the
    // canvas-space view or converts on the way out, which is what these pin.
    // -------------------------------------------------------------------------

    test('the delegate exposes annotations in canvas space', () {
      expect(
        source,
        contains('List<Annotation> get annotations => _canvasAnnotations;'),
        reason: 'handing widget.annotations (image pixels) to a handler places '
            'every gesture against the wrong geometry',
      );
    });

    test('_onPanEnd clears the in-flight preview after the hand-off', () {
      // Ghost-preview regression. Handlers null `_currentAnnotation` themselves,
      // but only the handler for the tool active *at mouse-up* runs, and the
      // canvas's own single-letter tool shortcuts fire mid-drag. Land on text,
      // fill, colorPicker, stepMarker or select and that handler's `onPanEnd`
      // is an empty body, so the half-drawn shape paints forever — unlistable,
      // unselectable, undeletable. The canvas has to clear it itself.
      final body = _bodyOf(source, 'void _onPanEnd(');
      final handOff = body.indexOf('_toolHandler.onPanEnd(');
      expect(handOff, isNot(-1), reason: '_onPanEnd must delegate to the handler');
      final cleared = body.indexOf('_currentAnnotation = null', handOff);
      expect(
        cleared,
        isNot(-1),
        reason: 'the canvas must clear _currentAnnotation after delegating, '
            'instead of trusting whichever handler happens to answer at '
            'mouse-up to have a non-empty onPanEnd',
      );
    });

    // -------------------------------------------------------------------------
    // Task 14's OCR boundary.
    //
    // `OcrToolHandler` hands over canvas-space rects; `OcrService.regionPx` is
    // native image pixels. `onExtractText` on the canvas is the only place the
    // two meet, and a missing conversion there would crop an arbitrary and
    // plausible-looking rectangle of the bitmap — wrong text, no error.
    // -------------------------------------------------------------------------

    test('onExtractText converts the region canvas -> image pixels', () {
      final body = _bodyOf(source, 'void onExtractText(');
      expect(
        body,
        contains('toImageRect('),
        reason: 'the handler works in canvas space and OcrService crops in '
            'image pixels; without this the wrong region is read',
      );
      expect(
        body,
        contains('if (!p.isValid) return;'),
        reason: 'an invalid projection cannot place the region; requesting '
            'anyway would pass raw canvas numbers off as image pixels',
      );
      expect(
        'widget.onExtractText?.call('.allMatches(source).length,
        1,
        reason: 'the extraction request must leave the canvas from exactly one '
            'place, the one that converts',
      );
    });

    test('a null region survives as null rather than becoming a rect', () {
      // Null means "the whole capture", which is also the only cacheable
      // request. Substituting a rect here would silently disable the cache and
      // clip the full-image read to the viewport.
      expect(
        _bodyOf(source, 'void onExtractText('),
        contains('canvasRegion == null ? null :'),
      );
    });

    // -------------------------------------------------------------------------
    // Degenerate-projection writes.
    //
    // These three used to read `p.isValid ? mapped : unmapped`, i.e. on an
    // invalid projection they wrote RAW CANVAS COORDINATES into image-pixel
    // storage, where the save layer then stamped them `coordSpace: imagePixels`
    // — permanently, silently, and with no discriminator left to recover them.
    //
    // `_projection` is invalid whenever `_baseImage` is null, and `build()` puts
    // the live GestureDetector on screen as soon as `_fileExists` is true: for a
    // few frames before the decode lands, and forever if the decode fails on a
    // corrupt or unsupported file. Refusing matches every other boundary on this
    // branch (`Annotation.withCanvasSpaceScalars`, `onExtractText`,
    // `_insertExtractedText`), which all decline rather than guess.
    // -------------------------------------------------------------------------

    for (final signature in const [
      'void _replaceAnnotation(',
      'void _emitAnnotation(',
      'void pushAnnotationsState(',
    ]) {
      test('$signature refuses a degenerate projection instead of writing '
          'canvas coordinates', () {
        final body = _bodyOf(source, signature);
        expect(
          body,
          contains('if (!_canPlaceWrite(p)) return;'),
          reason: 'an invalid projection cannot place this write; storing it '
              'anyway passes canvas numbers off as image pixels',
        );
        expect(
          body,
          isNot(contains('p.isValid ?')),
          reason: 'the ternary fallback IS the bug — it writes the unmapped '
              'canvas-space value when the projection is invalid',
        );
      });
    }

    test('a refused write is reported to the parent, and throttled', () {
      expect(
        _bodyOf(source, 'bool _canPlaceWrite('),
        contains('_reportUnplaceableEdit()'),
        reason: 'a stroke that silently fails to persist is its own bug; the '
            'refusal has to be audible',
      );
      final report = _bodyOf(source, 'void _reportUnplaceableEdit(');
      expect(report, contains('widget.onEditUnplaceable?.call()'));
      expect(
        report,
        contains('Duration(seconds:'),
        reason: 'a drag fires _replaceAnnotation on every pointer move, so an '
            'unthrottled report would replace the toast hundreds of times a '
            'second',
      );
    });

    test('delegate writes route through the converting helpers', () {
      expect(
        _bodyOf(source, 'void onAnnotationAdded('),
        contains('_emitAnnotation('),
        reason: 'a handler emits canvas space; the parent stores image pixels',
      );
      expect(
        _bodyOf(source, 'void updateAnnotation('),
        contains('_replaceAnnotation('),
        reason: 'same conversion, for edits to an existing annotation',
      );
      expect(
        _bodyOf(source, 'void pushAnnotationsState('),
        contains('mappedToImageSpace'),
        reason: 'the list a handler pushes is canvas space and has to be '
            'converted before it reaches the parent',
      );
    });
  });
}
