// Gene - Nov, 25, 2026: Widget tests for CaptureHistoryDialog date-grouped archive browser in light and dark modes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/capture_history_dialog.dart';

CaptureItem _item(
  String id,
  DateTime createdAt, {
  CaptureMediaType mediaType = CaptureMediaType.image,
}) => CaptureItem(
  id: id,
  filePath: mediaType == CaptureMediaType.video
      ? '/nonexistent/$id.mp4'
      : '/nonexistent/$id.png',
  title: 'Capture $id',
  createdAt: createdAt,
  mediaType: mediaType,
);

void _runTests(SnipThemeMode mode) {
  final label = mode.name;
  final now = DateTime(2026, 11, 25, 12, 0);
  final cutoff = DateTime(2026, 11, 19);

  final olderItems = [
    _item('old_1', DateTime(2026, 11, 18, 15, 0)),
    _item('old_2', DateTime(2026, 11, 18, 11, 0)),
    _item(
      'old_vid',
      DateTime(2026, 11, 10, 9, 30),
      mediaType: CaptureMediaType.video,
    ),
  ];
  final allItems = [
    _item('recent_1', DateTime(2026, 11, 25, 10, 0)),
    ...olderItems,
  ];

  Future<void> pumpDialog(
    WidgetTester tester, {
    int olderCount = 3,
    ValueChanged<CaptureItem>? onSelectItem,
    Future<void> Function(CaptureItem)? onDeleteItem,
    VoidCallback? onOpenLibraryLocation,
    ValueChanged<CaptureItem>? onRevealItemInFolder,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      SnipThemeScope(
        theme: SnipTheme.forMode(mode),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => CaptureHistoryDialog(
                        recentCutoff: cutoff,
                        olderCount: olderCount,
                        nowOverride: now,
                        onSelectItem: onSelectItem ?? (_) {},
                        onDeleteItem: onDeleteItem ?? (_) async {},
                        onOpenLibraryLocation: onOpenLibraryLocation,
                        onRevealItemInFolder: onRevealItemInFolder,
                        loadPage:
                            ({before, required limit, required offset}) async {
                              final pool = before != null
                                  ? olderItems
                                  : allItems;
                              final slice = pool
                                  .skip(offset)
                                  .take(limit)
                                  .toList();
                              return (
                                items: slice,
                                dbCount: slice.length,
                                hasMore: offset + slice.length < pool.length,
                              );
                            },
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    '[$label] renders date groups, toggles collapse, and switches Older/All and media filters',
    (tester) async {
      await pumpDialog(tester);

      expect(
        find.byKey(const ValueKey('history-dialog-group-2026-11-18')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('history-dialog-group-2026-11-10')),
        findsOneWidget,
      );
      expect(find.text('Capture old_1'), findsOneWidget);
      expect(find.text('Capture old_vid'), findsOneWidget);
      expect(find.text('Capture recent_1'), findsNothing);

      // Collapse Nov 18 date group
      await tester.tap(
        find.byKey(const ValueKey('history-dialog-group-2026-11-18')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Capture old_1'), findsNothing);
      expect(find.text('Capture old_vid'), findsOneWidget);

      // Expand back
      await tester.tap(
        find.byKey(const ValueKey('history-dialog-group-2026-11-18')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Capture old_1'), findsOneWidget);

      // Switch to All Dates
      await tester.tap(find.byKey(const ValueKey('history-scope-all')));
      await tester.pumpAndSettle();
      expect(find.text('Capture recent_1'), findsOneWidget);

      // Filter to Videos only
      await tester.tap(
        find.byKey(const ValueKey('history-dialog-filter-videos')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Capture old_vid'), findsOneWidget);
      expect(find.text('Capture old_1'), findsNothing);
    },
  );

  testWidgets(
    '[$label] handles select, reveal, open folder, and delete callbacks',
    (tester) async {
      CaptureItem? selected;
      CaptureItem? revealed;
      CaptureItem? deleted;
      var openedFolder = 0;

      await pumpDialog(
        tester,
        onSelectItem: (item) => selected = item,
        onRevealItemInFolder: (item) => revealed = item,
        onOpenLibraryLocation: () => openedFolder++,
        onDeleteItem: (item) async => deleted = item,
      );

      await tester.tap(
        find.byKey(const ValueKey('history-dialog-open-folder')),
      );
      await tester.pump();
      expect(openedFolder, 1);

      await tester.tap(
        find.byKey(const ValueKey('history-dialog-reveal-old_1')),
      );
      await tester.pump();
      expect(revealed?.id, 'old_1');

      await tester.tap(
        find.byKey(const ValueKey('history-dialog-delete-old_2')),
      );
      await tester.pumpAndSettle();
      expect(deleted?.id, 'old_2');
      expect(find.text('Capture old_2'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('history-dialog-card-old_1')));
      await tester.pumpAndSettle();
      expect(selected?.id, 'old_1');
      expect(find.byType(CaptureHistoryDialog), findsNothing);
    },
  );
}

void main() {
  for (final mode in SnipThemeMode.values) {
    _runTests(mode);
  }
}
