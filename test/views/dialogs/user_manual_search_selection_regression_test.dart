// Regression: ISSUE-001 — searching the manual desynced the sidebar highlight
// from the content pane. The pane renders `_activeTopic`, which falls back to
// the first match when the selected topic is filtered out; the sidebar marks a
// row selected by `_selectedTopicId`, which still pointed at the filtered-out
// topic. So a reader saw a topic on screen with no row highlighted, and
// clearing the search silently threw away whatever they had landed on and
// jumped back to the old topic.
// Found by /qa on 2026-08-30
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-08-30.md

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/user_manual_data.dart';
import 'package:snipsnap/views/dialogs/user_manual_dialog.dart';

Widget _harness({String? initialTopicId}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  UserManualDialog.show(context, initialTopicId: initialTopicId),
              child: const Text('Open Manual'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A sidebar row paints [SnipTheme.selectedFill] when selected and
/// [Colors.transparent] when not, so a non-transparent fill is the highlight.
bool _rowIsHighlighted(WidgetTester tester, String topicId) {
  // The row's own Container comes first; the badge pill is nested inside it.
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(ValueKey('topic_$topicId')),
          matching: find.byType(Container),
        )
        .first,
  );
  final decoration = container.decoration as BoxDecoration;
  return decoration.color != null && decoration.color != Colors.transparent;
}

/// The topic the content pane is actually rendering.
String _visibleTopicId(WidgetTester tester) {
  final listView = tester.widget<ListView>(find.byType(ListView));
  final key = listView.key as ValueKey<String>;
  return key.value.replaceFirst('content_list_', '');
}

Future<void> _openManual(WidgetTester tester, {String? initialTopicId}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_harness(initialTopicId: initialTopicId));
  await tester.tap(find.text('Open Manual'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a search that filters out the selection highlights the topic it shows',
    (tester) async {
      await _openManual(tester, initialTopicId: 'annotation_tools');
      expect(_visibleTopicId(tester), 'annotation_tools');
      expect(_rowIsHighlighted(tester, 'annotation_tools'), isTrue);

      // "ocr" does not match the annotation topic, so the pane falls back.
      await tester.enterText(find.byType(TextField), 'ocr');
      await tester.pumpAndSettle();

      final shown = _visibleTopicId(tester);
      expect(shown, isNot('annotation_tools'),
          reason: 'the selected topic was filtered out of the results');

      // The bug: the pane showed `shown` while no sidebar row was highlighted.
      expect(_rowIsHighlighted(tester, shown), isTrue,
          reason: 'the topic on screen must be the one marked selected');

      for (final topic in UserManualData.topics) {
        if (topic.id == shown) continue;
        if (find.byKey(ValueKey('topic_${topic.id}')).evaluate().isEmpty) {
          continue; // filtered out of the sidebar entirely
        }
        expect(_rowIsHighlighted(tester, topic.id), isFalse,
            reason: 'only the visible topic may be highlighted');
      }
    },
  );

  testWidgets('clearing the search keeps the topic the reader landed on',
      (tester) async {
    await _openManual(tester, initialTopicId: 'annotation_tools');

    await tester.enterText(find.byType(TextField), 'ocr');
    await tester.pumpAndSettle();
    final landedOn = _visibleTopicId(tester);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // The bug: this snapped back to 'annotation_tools'.
    expect(_visibleTopicId(tester), landedOn,
        reason: 'clearing the search must not discard the reader\'s position');
    expect(_rowIsHighlighted(tester, landedOn), isTrue);
  });

  testWidgets('a search matching nothing leaves the selection untouched',
      (tester) async {
    await _openManual(tester, initialTopicId: 'annotation_tools');

    await tester.enterText(find.byType(TextField), 'zzzznomatch');
    await tester.pumpAndSettle();
    expect(find.text('No matching guides found'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(_visibleTopicId(tester), 'annotation_tools',
        reason: 'an empty result set must not clobber the selection');
  });
}
