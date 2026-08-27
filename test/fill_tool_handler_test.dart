import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/tools/fill_tool.dart';
import 'package:snipsnap/tools/tool_handler.dart';
import 'package:snipsnap/utils/constants.dart';

/// Minimal delegate: records what the fill handler did.
class _RecordingDelegate implements ToolDelegate {
  _RecordingDelegate({required this.hit});

  final Annotation? hit;

  Annotation? updatedAnnotation;
  Offset? canvasFillPos;
  String? selectedId;

  @override
  Annotation? hitTestAnnotation(Offset pos) => hit;

  @override
  Color get activeColor => const Color(0xFF10B981);

  @override
  void updateAnnotation(String id, Annotation updated) {
    updatedAnnotation = updated;
  }

  @override
  void onPerformCanvasFill(Offset pos) {
    canvasFillPos = pos;
  }

  @override
  void onSelectedAnnotationIdChanged(String? id) {
    selectedId = id;
  }

  // Everything below is unused by FillToolHandler.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TapUpDetails _tap() => TapUpDetails(kind: PointerDeviceKind.mouse);

Annotation _annotation(CanvasTool tool) => Annotation(
  id: 'a1',
  tool: tool,
  color: const Color(0xFFEF4444),
  startPoint: const Offset(10, 10),
  endPoint: const Offset(90, 90),
);

void main() {
  test('tapping a closed shape fills that shape', () {
    final delegate = _RecordingDelegate(hit: _annotation(CanvasTool.shape));
    FillToolHandler(delegate).onTapUp(_tap(), const Offset(50, 50));

    expect(delegate.updatedAnnotation, isNotNull);
    expect(delegate.updatedAnnotation!.fill, isTrue);
    expect(delegate.updatedAnnotation!.fillColor, const Color(0xFF10B981));
    expect(delegate.canvasFillPos, isNull);
    expect(delegate.selectedId, 'a1');
  });

  for (final tool in [
    CanvasTool.line,
    CanvasTool.arrow,
    CanvasTool.pen,
    CanvasTool.highlight,
    CanvasTool.blur,
    CanvasTool.ruler,
    CanvasTool.text,
    CanvasTool.stepMarker,
  ]) {
    test('tapping over a $tool annotation flood-fills the bitmap instead', () {
      // A stroke/box annotation has no meaningful bucket fill — the click must
      // fall through to the canvas flood fill rather than silently doing
      // nothing visible.
      final delegate = _RecordingDelegate(hit: _annotation(tool));
      FillToolHandler(delegate).onTapUp(_tap(), const Offset(50, 50));

      expect(delegate.updatedAnnotation, isNull);
      expect(delegate.canvasFillPos, const Offset(50, 50));
    });
  }

  test('tapping empty canvas flood-fills the bitmap', () {
    final delegate = _RecordingDelegate(hit: null);
    FillToolHandler(delegate).onTapUp(_tap(), const Offset(30, 40));

    expect(delegate.updatedAnnotation, isNull);
    expect(delegate.canvasFillPos, const Offset(30, 40));
  });
}
