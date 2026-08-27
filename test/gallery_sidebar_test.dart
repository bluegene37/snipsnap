import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/gallery_sidebar.dart';

// GallerySidebar embeds Image.file for its thumbnails, which hangs
// flutter_tester indefinitely once the file actually exists (see
// editor_canvas_projection_test.dart's bisection and the task-5 report).
// It only reaches Image.file when File(item.filePath).existsSync() is true,
// so every item constructed here points at a path that does not exist —
// the widget takes its fileExists == false branch (a plain fallback icon,
// no Image.file call at all) and stays safely pumpable while still
// exercising the card chrome (selection, delete/reveal buttons, the
// extension badge) that this task converted.

CaptureItem _item(String id, {int width = 0, int height = 0}) => CaptureItem(
  id: id,
  filePath: '/nonexistent/$id.png',
  title: 'Capture $id',
  createdAt: DateTime(2026, 1, 1),
  width: width,
  height: height,
);

Future<void> _pump(
  WidgetTester tester, {
  required SnipThemeMode mode,
  required List<CaptureItem> items,
  CaptureItem? activeItem,
  ValueChanged<CaptureItem>? onSelectItem,
  ValueChanged<CaptureItem>? onDeleteItem,
  double zoomScale = 1.0,
  ValueChanged<double>? onZoomScaleChanged,
}) {
  return tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(mode),
      child: MaterialApp(
        home: Scaffold(
          body: GallerySidebar(
            items: items,
            activeItem: activeItem,
            onSelectItem: onSelectItem ?? (_) {},
            onDeleteItem: onDeleteItem ?? (_) {},
            onClose: () {},
            zoomScale: zoomScale,
            onZoomScaleChanged: onZoomScaleChanged,
          ),
        ),
      ),
    ),
  );
}

void _runStateTests(SnipThemeMode mode) {
  final label = mode.name;
  final t = SnipTheme.forMode(mode);

  testWidgets('[$label] empty state pumps cleanly and shows the hint text', (
    tester,
  ) async {
    await _pump(tester, mode: mode, items: const []);
    expect(
      find.text('No captures yet. Click "Snip" to start!'),
      findsOneWidget,
    );
  });

  testWidgets(
    '[$label] a populated tray pumps cleanly with no Image.file hang',
    (tester) async {
      final items = [_item('a'), _item('b'), _item('c')];
      await _pump(tester, mode: mode, items: items, activeItem: items[1]);

      expect(find.text('Capture a'), findsOneWidget);
      expect(find.text('Capture b'), findsOneWidget);
      expect(find.text('Capture c'), findsOneWidget);
      // fileExists is false for all three, so the fallback glyph renders
      // instead of Image.file.
      expect(find.byIcon(Icons.image_not_supported_rounded), findsNWidgets(3));
    },
  );

  testWidgets(
    '[$label] the selected capture uses selectedFill, not the exclusive plate',
    (tester) async {
      final items = [_item('a'), _item('b')];
      await _pump(tester, mode: mode, items: items, activeItem: items[0]);

      // Card containers are the ones carrying a BorderRadius.circular(6)
      // decoration with no border side — find both and match by fill colour.
      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration is BoxDecoration)
          .map((c) => c.decoration as BoxDecoration)
          .where((d) => d.color == t.selectedFill || d.color == t.surfaceRaised)
          .toList();

      expect(
        containers.any((d) => d.color == t.selectedFill),
        isTrue,
        reason: '$label: the selected card must use selectedFill',
      );
      expect(
        containers.any((d) => d.color == t.surfaceRaised),
        isTrue,
        reason:
            '$label: the unselected card must use surfaceRaised, not selectedFill',
      );
      // Never the app's exclusive-active plate — that stays reserved for the
      // tool sidebar's single active tool.
      expect(
        containers.any((d) => d.color == t.activeFill),
        isFalse,
        reason:
            '$label: gallery selection must never use the exclusive activeFill plate',
      );
    },
  );

  testWidgets(
    '[$label] delete routes through the danger tone, never an inline red',
    (tester) async {
      final items = [_item('a')];
      await _pump(tester, mode: mode, items: items);

      final deleteButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.delete_outline_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(
        deleteButton.color,
        t.danger,
        reason: '$label: delete icon must use SnipTheme.danger',
      );
      expect(deleteButton.color, isNot(equals(Colors.redAccent)));
    },
  );

  testWidgets('[$label] tapping a card fires onSelectItem', (tester) async {
    final items = [_item('a'), _item('b')];
    CaptureItem? selected;
    await _pump(
      tester,
      mode: mode,
      items: items,
      onSelectItem: (i) => selected = i,
    );

    await tester.tap(find.text('Capture b'));
    await tester.pump();

    expect(selected?.id, 'b');
  });

  testWidgets(
    '[$label] the extension badge uses the ink/onActive plate over the thumbnail',
    (tester) async {
      final items = [_item('a')];
      await _pump(tester, mode: mode, items: items);

      final badgeText = tester.widget<Text>(find.text('png'));
      expect(badgeText.style?.color, t.onActive, reason: '$label: badge text');

      final badgeContainer = tester.widget<Container>(
        find
            .ancestor(of: find.text('png'), matching: find.byType(Container))
            .first,
      );
      final decoration = badgeContainer.decoration as BoxDecoration;
      expect(decoration.color, t.ink, reason: '$label: badge fill');
    },
  );
}

void main() {
  for (final mode in SnipThemeMode.values) {
    _runStateTests(mode);
  }
}
