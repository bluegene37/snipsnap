import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Waits for `EditorCanvas`'s base bitmap to finish decoding.
///
/// The decode is real asynchronous work — `File.readAsBytes` plus a `compute`
/// isolate — so it only advances in real time, inside `runAsync`. A fixed sleep
/// is a race, and a loaded CI machine loses it: until `_baseImage` lands, the
/// canvas falls back to an `_imageRect` covering the whole viewport, so every
/// image <-> canvas projection is wrong and a tap aimed at an annotation hits
/// nothing. The test then reads an untouched annotation back and fails on a
/// value that looks like a broken clamp rather than a missed grab.
///
/// The canvas paints its bitmap through a single unconditional [RawImage] whose
/// `image` is null until the decode lands, which is the signal polled here.
///
/// Pass [expected] when switching captures: the canvas deliberately keeps the
/// outgoing bitmap on screen until the incoming one is ready, so "some image is
/// present" is already true and only its size tells the two apart.
///
/// Call from inside a `tester.runAsync` callback, after `pumpWidget`.
Future<void> settleBaseImage(
  WidgetTester tester, {
  Size? expected,
  Duration timeout = const Duration(seconds: 15),
}) async {
  bool isTarget(RawImage widget) {
    final image = widget.image;
    if (image == null) return false;
    if (expected == null) return true;
    return image.width == expected.width && image.height == expected.height;
  }

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump();
    final decoded = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .any(isTarget);
    if (decoded) {
      // One more frame so layout settles against the decoded size before the
      // caller projects anything onto it.
      await tester.pump();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('EditorCanvas did not decode its base image within $timeout');
}
