import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/header_bar.dart';

Widget _harness({
  required double width,
  bool hasCapture = true,
  bool canUndo = true,
  bool canRedo = true,
  bool canClear = true,
  bool isDarkMode = true,
  VoidCallback? onFlattenCanvas,
}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(isDarkMode ? SnipThemeMode.dark : SnipThemeMode.light),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: HeaderBar(
            onSnipInteractive: () {},
            onSnipFullScreen: () {},
            onSnipTimer: () {},
            onImportImage: () {},
            onUndo: () {},
            onRedo: () {},
            onClear: () {},
            onCopyToClipboard: () {},
            onSaveAs: () {},
            onFlattenCanvas: onFlattenCanvas,
            onToggleSidebar: () {},
            onToggleProperties: () {},
            onOpenShortcutSettings: () {},
            onToggleThemeMode: () {},
            onOpenAboutDialog: () {},
            canUndo: canUndo,
            canRedo: canRedo,
            canClear: canClear,
            hasCapture: hasCapture,
            isSidebarOpen: true,
          ),
        ),
      ),
    ),
  );
}

void main() {
  // The header must never overflow: anything pushed off the edge is a control
  // the user simply cannot reach.
  for (final width in <double>[1920, 1440, 1180, 1100, 940, 900, 800, 720]) {
    testWidgets('lays out without overflow at ${width.toInt()}px', (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(width: width));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('always shows capture, export and view controls', (tester) async {
    tester.view.physicalSize = const Size(1440, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(width: 1440));

    expect(find.text('SnipSnap'), findsOneWidget);
    expect(find.text('Snip'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Save As'), findsOneWidget);
    // Gallery toggle + properties toggle + overflow menu.
    expect(find.byIcon(Icons.photo_library_rounded), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
  });

  testWidgets('drops button labels but keeps the icons when space is tight',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(width: 1000));

    expect(find.text('Copy'), findsNothing);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disables destructive and export actions when nothing is loaded',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(
      width: 1440,
      hasCapture: false,
      canUndo: false,
      canRedo: false,
      canClear: false,
    ));

    ElevatedButton buttonWithText(String label) => tester.widget<ElevatedButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(ElevatedButton),
          ),
        );

    expect(buttonWithText('Copy').onPressed, isNull, reason: 'no image to copy');
    expect(buttonWithText('Save As').onPressed, isNull, reason: 'no image to save');
    expect(buttonWithText('Flatten').onPressed, isNull, reason: 'no annotations to flatten');

    // Clear must be disabled when there is nothing to clear — previously it
    // was always enabled.
    final clear = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline_rounded),
    );
    expect(clear.onPressed, isNull);
  });

  testWidgets('enables the edit pill only when history is available', (tester) async {
    tester.view.physicalSize = const Size(1440, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(width: 1440, canUndo: true, canRedo: false));

    IconButton button(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

    expect(button(Icons.undo_rounded).onPressed, isNotNull);
    expect(button(Icons.redo_rounded).onPressed, isNull);
  });

  testWidgets('zoom stepper appears with a capture and reports the level',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    double? requested;
    await tester.pumpWidget(SnipThemeScope(
      theme: SnipTheme.forMode(SnipThemeMode.dark),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1440,
            child: HeaderBar(
              onSnipInteractive: () {},
              onImportImage: () {},
              onUndo: () {},
              onRedo: () {},
              onClear: () {},
              onCopyToClipboard: () {},
              onSaveAs: () {},
              onToggleSidebar: () {},
              onOpenShortcutSettings: () {},
              onToggleThemeMode: () {},
              onOpenAboutDialog: () {},
              canUndo: false,
              canRedo: false,
              isSidebarOpen: true,
              hasCapture: true,
              zoomScale: 1.5,
              onZoomScaleChanged: (v) => requested = v,
            ),
          ),
        ),
      ),
    ));

    expect(find.text('150%'), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.remove_rounded));
    expect(requested, closeTo(1.25, 0.001));
  });

  for (final dark in [false, true]) {
    testWidgets('lays out without overflow in ${dark ? "dark" : "light"}',
        (tester) async {
      tester.view.physicalSize = const Size(1180, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(width: 1180, isDarkMode: dark));
      expect(tester.takeException(), isNull);
    });
  }
}
