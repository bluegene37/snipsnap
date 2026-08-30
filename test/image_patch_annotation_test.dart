// Covers the two pure seams of the cut-and-move object model: the annotation
// that carries the cut pixels, and the decode step the renderer depends on.
//
// The gesture flow itself (marquee -> cut -> drop) is not covered here: it runs
// through fire-and-forget async and `compute` isolates that never settle under
// flutter_tester, the same reason `small_selection_grab_test.dart` drives the
// crop rect rather than the floating selection.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/constants.dart';

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(10, 200, 30));
  return Uint8List.fromList(img.encodePng(image));
}

Annotation _patch(String id, Uint8List? bytes) => Annotation(
  id: id,
  tool: CanvasTool.imagePatch,
  color: const Color(0x00000000),
  startPoint: const Offset(10, 20),
  endPoint: const Offset(110, 70),
  patchBytes: bytes,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Annotation.patchBytes', () {
    test('survives an unrelated copyWith', () {
      // Every move, resize and rotate goes through copyWith. Dropping the
      // pixels on any of them would blank the patch the moment it is touched.
      final bytes = _png(4, 4);
      final moved = _patch('a', bytes).copyWith(
        startPoint: const Offset(50, 60),
        endPoint: const Offset(150, 110),
      );

      expect(moved.patchBytes, same(bytes));
      expect(moved.startPoint, const Offset(50, 60));
    });

    test('can be cleared explicitly', () {
      expect(
        _patch('a', _png(4, 4)).copyWith(patchBytes: null).patchBytes,
        isNull,
      );
    });

    test('equality tracks the bytes by reference, not by content', () {
      // `==` runs on every rebuild to decide whether to repaint, so it must not
      // walk a whole PNG. A new cut always allocates a new list, which makes
      // the reference a sound stand-in.
      final bytes = _png(4, 4);
      expect(_patch('a', bytes) == _patch('a', bytes), isTrue);

      final sameContentDifferentList = Uint8List.fromList(bytes);
      expect(
        _patch('a', bytes) == _patch('a', sameContentDifferentList),
        isFalse,
      );
      expect(_patch('a', bytes) == _patch('a', null), isFalse);
    });

    test('hashCode agrees with == on identical bytes', () {
      final bytes = _png(4, 4);
      expect(_patch('a', bytes).hashCode, _patch('a', bytes).hashCode);
    });
  });

  group('RenderService.decodePatchImages', () {
    test('decodes patches and ignores everything else', () async {
      final images = await RenderService.decodePatchImages([
        _patch('patch-1', _png(12, 8)),
        Annotation(
          id: 'arrow-1',
          tool: CanvasTool.arrow,
          color: const Color(0xFF000000),
          startPoint: Offset.zero,
          endPoint: const Offset(10, 10),
        ),
      ]);

      addTearDown(() {
        for (final image in images.values) {
          image.dispose();
        }
      });

      expect(images.keys, ['patch-1']);
      expect(images['patch-1']!.width, 12);
      expect(images['patch-1']!.height, 8);
    });

    test('skips a patch with no bytes rather than throwing', () async {
      // A row written before the pixels landed, or a corrupt one. The renderer
      // draws nothing for a missing entry, which beats a black rectangle.
      final images = await RenderService.decodePatchImages([
        _patch('empty', null),
      ]);
      expect(images, isEmpty);
    });

    test('survives bytes that are not an image', () async {
      final images = await RenderService.decodePatchImages([
        _patch('junk', Uint8List.fromList([1, 2, 3, 4, 5])),
      ]);
      expect(images, isEmpty);
    });
  });

  test('decodeImageBytes round-trips a PNG', () async {
    final ui.Image? image = await RenderService.decodeImageBytes(_png(7, 3));
    addTearDown(() => image?.dispose());
    expect(image, isNotNull);
    expect(image!.width, 7);
    expect(image.height, 3);
  });
}
