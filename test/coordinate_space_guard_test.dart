import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Returns the body of a 2-space-indented method in [source], from its
/// signature up to the line that closes it.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'could not find `$signature` in the source');
  final end = source.indexOf('\n  }', start);
  expect(end, isNot(-1), reason: 'could not find the end of `$signature`');
  return source.substring(start, end);
}

/// Returns the text between [from] and [to] in [source].
String _regionBetween(String source, String from, String to) {
  final start = source.indexOf(from);
  expect(start, isNot(-1), reason: 'could not find `$from` in the source');
  final end = source.indexOf(to, start);
  expect(end, isNot(-1), reason: 'could not find `$to` after `$from`');
  return source.substring(start, end);
}

void main() {
  // ---------------------------------------------------------------------------
  // The invariant: everything persisted is IMAGE PIXELS, top-left origin. A
  // capture whose `annotationsNeedConversion` is true still holds VIEWPORT
  // numbers, and must never be persisted or baked into a bitmap — persisting
  // stamps `coordSpace: imagePixels` on it and destroys the only discriminator
  // that could have rescued it.
  //
  // The runtime proof lives in migration_v3_to_v4_test.dart, which exercises
  // the real database through both save paths. These are the structural
  // companions: they pin *where* the guards sit, which is what makes them
  // unbypassable rather than merely present.
  // ---------------------------------------------------------------------------

  group('the write guard sits at the chokepoint, not at the call sites', () {
    late String source;

    setUpAll(() {
      source = File('lib/services/database_service.dart').readAsStringSync();
    });

    test('saveCaptureToDb refuses to rewrite annotations for an unconverted '
        'capture', () {
      final body = _bodyOf(source, 'static Future<void> saveCaptureToDb(');
      final guard = body.indexOf('if (!canPersistAnnotations(item)) return;');
      expect(guard, isNot(-1),
          reason: 'this is the single point every annotation write passes '
              'through — the singular saveCaptureItem path and the plural '
              'saveHistory path alike');
      final write = body.indexOf('saveAnnotationsForCapture(');
      expect(write, isNot(-1));
      expect(guard, lessThan(write),
          reason: 'the guard has to precede the write it guards');
    });

    test('saveAllCapturesToDb has no annotation write of its own to bypass it',
        () {
      final body = _bodyOf(source, 'static Future<void> saveAllCapturesToDb(');
      expect(body, contains('saveCaptureToDb(item)'));
      expect(
        body,
        isNot(contains('saveAnnotationsForCapture(')),
        reason: 'the whole-library path must delegate, so it inherits the '
            'guard instead of needing a duplicate one that can drift',
      );
    });

    test('the imagePixels stamp exists in exactly one place', () {
      expect(
        'CoordSpace.imagePixels.name'.allMatches(source).length,
        1,
        reason: 'the stamp is the discriminator between converted and legacy '
            'rows; a second site would be a second way to mislabel data',
      );
    });
  });

  group('main_screen guards every path that reads annotations as image pixels',
      () {
    late String source;

    setUpAll(() {
      source = File('lib/views/main_screen.dart').readAsStringSync();
    });

    // Findings 4: crop, flatten and export burn markup into the bitmap. Flatten
    // and crop rewrite the capture file, so placing viewport numbers as image
    // pixels there is not recoverable.
    for (final signature in const [
      'Future<Uint8List?> _renderAnnotatedBytes(',
      'Future<void> _handleFlattenCanvas(',
      'Future<void> _handleApplyCrop(',
    ]) {
      test('$signature refuses while a conversion is still owed', () {
        expect(
          _bodyOf(source, signature),
          contains('_blockedByPendingConversion('),
          reason: 'this path treats _annotations as image pixels and would '
              'bake still-viewport markup in at the wrong coordinates',
        );
      });
    }

    test('the refusal is user-visible, not a silent no-op', () {
      expect(
        _bodyOf(source, 'bool _blockedByPendingConversion('),
        contains('_showToast('),
        reason: 'a button that does nothing reads as broken; this branch '
            'follows the same loud-failure contract as the "editor is not '
            'ready" cases beside it',
      );
    });

    test('flatten and crop check before they touch the undo stack', () {
      for (final signature in const [
        'Future<void> _handleFlattenCanvas(',
        'Future<void> _handleApplyCrop(',
      ]) {
        final body = _bodyOf(source, signature);
        final guard = body.indexOf('_blockedByPendingConversion(');
        final undo = body.indexOf('_pushUndoState(');
        expect(undo, isNot(-1), reason: '$signature should push undo state');
        expect(guard, lessThan(undo),
            reason: 'an aborted $signature must not leave an orphan undo entry');
      }
    });

    // Finding 2: deleting the active capture promotes the next one, which is a
    // selection change and owes the same conversion onSelectItem schedules.
    test('deleting the active capture schedules the promoted one\'s conversion',
        () {
      final region = _regionBetween(
        source,
        'onDeleteItem: (item) async {',
        'onOpenLibraryLocation:',
      );
      expect(
        region,
        contains('_convertActiveCaptureAnnotations()'),
        reason: 'without this the promoted capture spends the session with '
            'viewport numbers treated as image pixels, and the save guard '
            'means nothing drawn on it is ever persisted',
      );
      expect(region, contains('annotationsNeedConversion'));
      expect(region, contains('addPostFrameCallback'),
          reason: 'the canvas has to be laid out before the projection exists, '
              'same as onSelectItem');
    });

    test('every conversion entry point posts a post-frame callback', () {
      // Load, select, delete-and-promote. A fourth entry point appearing
      // without a post-frame callback would convert against a canvas that has
      // not been laid out, get converted:false, and quietly do nothing.
      expect(
        '_convertActiveCaptureAnnotations()'.allMatches(source).length,
        4,
        reason: 'three schedulers plus the method declaration; add an entry '
            'point and this needs re-checking on purpose',
      );
    });
  });
}
