import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/user_manual_data.dart';
import 'package:snipsnap/views/dialogs/user_manual_dialog.dart';

Widget _buildTestDialog({
  String? initialTopicId,
  VoidCallback? onOpenShortcuts,
  bool isDarkMode = true,
}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(
      isDarkMode ? SnipThemeMode.dark : SnipThemeMode.light,
    ),
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => UserManualDialog.show(
                context,
                initialTopicId: initialTopicId,
                onOpenShortcuts: onOpenShortcuts,
              ),
              child: const Text('Open Manual'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders UserManualDialog with all default topics and header', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildTestDialog());
    await tester.tap(find.text('Open Manual'));
    await tester.pumpAndSettle();

    // Verify header title
    expect(find.text('SnipSnap User Manual & Knowledge Base'), findsOneWidget);

    // Verify topics exist in sidebar
    for (final topic in UserManualData.topics) {
      expect(find.byKey(ValueKey('topic_${topic.id}')), findsOneWidget);
    }

    // Verify default active topic content
    expect(find.text('Welcome to SnipSnap'), findsOneWidget);
  });

  testWidgets('switches content when selecting a different topic', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildTestDialog());
    await tester.tap(find.text('Open Manual'));
    await tester.pumpAndSettle();

    // Tap on Annotation & Drawing Tools topic
    await tester.tap(find.byKey(const ValueKey('topic_annotation_tools')));
    await tester.pumpAndSettle();

    // Verify first annotation section appears
    expect(find.text('Vector Arrows & Lines'), findsOneWidget);
  });

  testWidgets('filters topics and sections in real-time when searching', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildTestDialog());
    await tester.tap(find.text('Open Manual'));
    await tester.pumpAndSettle();

    // Enter search query
    await tester.enterText(find.byType(TextField), 'redaction');
    await tester.pumpAndSettle();

    // Topic list should only have Annotation & Drawing Tools
    expect(find.byKey(const ValueKey('topic_annotation_tools')), findsOneWidget);
    expect(find.byKey(const ValueKey('topic_screen_pinning')), findsNothing);

    // Clear search
    await tester.tap(find.byIcon(Icons.clear_rounded));
    await tester.pumpAndSettle();

    // All topics should reappear
    expect(find.byKey(const ValueKey('topic_screen_pinning')), findsOneWidget);
  });

  testWidgets('displays empty state when search finds no match', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildTestDialog());
    await tester.tap(find.text('Open Manual'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'xyznonexistentterm');
    await tester.pumpAndSettle();

    expect(find.text('No matching guides found'), findsOneWidget);
    expect(find.text('No matching topics'), findsOneWidget);
  });

  testWidgets('initialTopicId opens directly to specified topic', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildTestDialog(initialTopicId: 'ocr_text'));
    await tester.tap(find.text('Open Manual'));
    await tester.pumpAndSettle();

    expect(find.text('OCR Text Recognition'), findsAtLeastNWidgets(1));
    expect(find.text('Extracting Text with the OCR Tool'), findsOneWidget);
  });

  testWidgets('onOpenShortcuts callback is invoked and dialog closes', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    bool shortcutsOpened = false;
    await tester.pumpWidget(_buildTestDialog(
      onOpenShortcuts: () {
        shortcutsOpened = true;
      },
    ));
    await tester.tap(find.text('Open Manual'));
    await tester.pumpAndSettle();

    expect(find.text('Keyboard Shortcuts…'), findsOneWidget);
    await tester.tap(find.text('Keyboard Shortcuts…'));
    await tester.pumpAndSettle();

    expect(shortcutsOpened, isTrue);
    expect(find.text('SnipSnap User Manual & Knowledge Base'), findsNothing);
  });
}
