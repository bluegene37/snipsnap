// Regression: ISSUE-003 — the tool rail scrolled with no scrollbar, so at any
// laptop-height window the last five tools (Blur, Ruler, Fill, Crop, Extract)
// sat below the fold with nothing to say the rail continued.
// Found by /qa on 2026-09-02
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-09-02.md
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/tool_sidebar.dart';

Future<void> _pumpRail(WidgetTester tester, {required double height}) async {
  await tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(SnipThemeMode.light),
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: height,
              child: ToolSidebar(
                activeTool: CanvasTool.select,
                onToolSelected: (_) {},
                shapeKind: ShapeKind.rectangle,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a rail taller than its window shows a persistent thumb', (
    tester,
  ) async {
    // 609px is what a 1360x818 default window leaves the rail — the height
    // this was found at, with Extract 200px below the fold.
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpRail(tester, height: 609);

    final scrollbar = tester.widget<Scrollbar>(
      find.ancestor(
        of: find.text('Select'),
        matching: find.byType(Scrollbar),
      ),
    );
    expect(
      scrollbar.thumbVisibility,
      isTrue,
      reason: 'the thumb is the only cue that the rail goes on',
    );

    // The tool at the very end is not on screen yet...
    final extract = find.text('Extract');
    expect(tester.getBottomLeft(extract).dy, greaterThan(609));

    // ...and the same scroll surface the thumb belongs to brings it in.
    await tester.scrollUntilVisible(
      extract,
      80,
      scrollable: find.descendant(
        of: find.byType(ToolSidebar),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(extract).dy, lessThanOrEqualTo(609));
  });

  testWidgets('a rail that fits keeps its full tool list reachable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpRail(tester, height: 1300);

    expect(find.text('Extract'), findsOneWidget);
    expect(tester.getBottomLeft(find.text('Extract')).dy, lessThan(1300));
  });
}
