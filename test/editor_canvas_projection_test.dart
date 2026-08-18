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
