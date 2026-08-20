import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/ocr/ocr_engine.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/ocr_result_panel.dart';

// `OcrResultPanel` is one of the few pieces of this feature's UI that can be
// pumped: it contains no `Image.file`, which hangs flutter_tester
// indefinitely and rules out pumping `EditorCanvas` at all (see
// editor_canvas_projection_test.dart for the bisection).

OcrResult _resultWith(List<String> lines) => OcrResult(
      imageSize: const Size(800, 600),
      lines: [
        for (final text in lines)
          OcrLine(
            text: text,
            boundsPx: const Rect.fromLTWH(10, 10, 100, 20),
            confidence: 0.9,
          ),
      ],
    );

// Wrapped in a real SnipThemeScope (matching every other converted widget's
// test harness) rather than a bare MaterialApp — OcrResultPanel now reads
// SnipTheme.of(context) in build(), which throws without a scope ancestor.
Future<void> _pump(
  WidgetTester tester, {
  required SnipThemeMode mode,
  required OcrResult result,
  bool isLoading = false,
  String? unavailableReason,
  VoidCallback? onClose,
  ValueChanged<String>? onInsertAsText,
}) {
  return tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(mode),
      child: MaterialApp(
        home: Scaffold(
          body: OcrResultPanel(
            result: result,
            isLoading: isLoading,
            unavailableReason: unavailableReason,
            isDarkMode: true,
            onClose: onClose ?? () {},
            onInsertAsText: onInsertAsText ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

/// Runs the full state-assertion suite under one [mode] — called once per
/// [SnipThemeMode] from `main()` so every assertion below is proven to hold
/// in both light and dark, not just whichever mode a bare pump happened to
/// default to.
void _runStateTests(SnipThemeMode mode) {
  final label = mode.name;

  testWidgets('[$label] shows the recognised text and both actions', (tester) async {
    await _pump(tester, mode: mode, result: _resultWith(['hello', 'world']));

    expect(find.text('hello\nworld'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Insert'), findsOneWidget);
  });

  testWidgets('[$label] an empty result reports that nothing was found', (tester) async {
    await _pump(tester, mode: mode, result: OcrResult.empty);

    expect(find.text('No text found in this area.'), findsOneWidget);
    // Nothing to copy or insert, so neither action is offered.
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Insert'), findsNothing);
  });

  testWidgets(
      '[$label] an unavailable engine shows its reason, not the empty state',
      (tester) async {
    // The regression this pins: `OcrService` returns `OcrResult.empty` both
    // when the engine is missing and when it ran and found nothing. Reporting
    // "no text found" on a Linux host would be a flat lie.
    await _pump(
      tester,
      mode: mode,
      result: OcrResult.empty,
      unavailableReason: 'Linux does not provide an OCR engine.',
    );

    expect(find.text('Linux does not provide an OCR engine.'), findsOneWidget);
    expect(find.text('No text found in this area.'), findsNothing);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Insert'), findsNothing);
  });

  testWidgets('[$label] while loading it shows a spinner and no actions',
      (tester) async {
    await _pump(tester, mode: mode, result: OcrResult.empty, isLoading: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No text found in this area.'), findsNothing);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('[$label] a stale non-empty result cannot leak actions while loading',
      (tester) async {
    await _pump(tester, mode: mode, result: _resultWith(['stale']), isLoading: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Insert'), findsNothing);
  });

  testWidgets('[$label] Insert hands back the plain text', (tester) async {
    final inserted = <String>[];
    await _pump(
      tester,
      mode: mode,
      result: _resultWith(['first', 'second']),
      onInsertAsText: inserted.add,
    );

    await tester.tap(find.text('Insert'));
    await tester.pump();

    expect(inserted, ['first\nsecond']);
  });

  testWidgets('[$label] the close button fires onClose', (tester) async {
    var closed = 0;
    await _pump(
      tester,
      mode: mode,
      result: _resultWith(['x']),
      onClose: () => closed++,
    );

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(closed, 1);
  });

  group('[$label] chrome tokens', () {
    testWidgets('panel chrome routes through SnipTheme, not a fixed hue', (tester) async {
      final t = SnipTheme.forMode(mode);
      await _pump(tester, mode: mode, result: _resultWith(['hello']));

      final container = tester.widget<Container>(
        find.ancestor(of: find.text('Extracted text'), matching: find.byType(Container)).first,
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, t.surface, reason: '$label: panel background');
      expect((decoration.border as Border).top.color, t.border, reason: '$label: panel hairline');

      final title = tester.widget<Text>(find.text('Extracted text'));
      expect(title.style?.color, t.ink, reason: '$label: title colour');
    });
  });
}

void main() {
  for (final mode in SnipThemeMode.values) {
    _runStateTests(mode);
  }
}
