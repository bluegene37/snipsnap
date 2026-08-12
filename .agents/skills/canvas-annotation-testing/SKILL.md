---
name: canvas-annotation-testing
description: >-
  Guidelines and strategies for testing Flutter CustomPainter canvas drawing, gesture interactions, shape hit-testing,
  and undo/redo state history in Snipsnap. Use when writing widget or unit tests for canvas components.
---

# Canvas & Annotation Testing Strategy

This skill provides patterns for writing reliable unit and widget tests for Snipsnap canvas rendering, user gesture handling, selection handles, and undo/redo state serialization.

---

## 1. Unit Testing Annotation Models & Hit Testing

Test vector shape bounds and hit-testing functions independently of the Flutter render tree:

```dart
void main() {
  group('ArrowAnnotation Hit Testing', () {
    test('detects click near arrow line path', () {
      final arrow = ArrowAnnotation(
        id: '1',
        start: const Offset(10, 10),
        end: const Offset(100, 100),
        color: Colors.red,
      );

      // Hit point directly on the line
      expect(arrow.containsPoint(const Offset(55, 55), threshold: 8.0), isTrue);

      // Hit point far from the line
      expect(arrow.containsPoint(const Offset(200, 200), threshold: 8.0), isFalse);
    });
  });
}
```

---

## 2. Widget Testing Canvas Drag Gestures

Use `WidgetTester` to simulate drag gestures for creating and resizing annotations:

```dart
testWidgets('Creates rectangle annotation on drag', (WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EditorCanvas(
          activeTool: ToolType.rectangle,
        ),
      ),
    ),
  );

  final canvasFinder = find.byType(EditorCanvas);
  expect(canvasFinder, findsOneWidget);

  // Drag from (100, 100) to (300, 200)
  final TestGesture gesture = await tester.startGesture(const Offset(100, 100));
  await gesture.moveBy(const Offset(200, 100));
  await gesture.up();
  await tester.pumpAndSettle();

  // Verify shape count or state updated
});
```

---

## 3. Testing Golden Image Output (Painter Visual Regression)

Golden tests verify `CustomPainter` output visually:

```dart
testWidgets('Matches golden image for framing background', (WidgetTester tester) async {
  await tester.pumpWidget(
    RepaintBoundary(
      child: CustomPaint(
        size: const Size(400, 300),
        painter: FramedExportPainter(
          backgroundColor: Colors.blueAccent,
          padding: 20,
        ),
      ),
    ),
  );

  await expectLater(
    find.byType(RepaintBoundary),
    matchesGoldenFile('goldens/framed_export_blue.png'),
  );
});
```

---

## 4. Undo / Redo Stack State Testing

Verify state integrity across rapid undo/redo cycles:

```dart
test('Undo/Redo restores exact annotation list', () {
  final history = CanvasHistoryManager();
  
  history.addShape(arrow1);
  history.addShape(rect2);
  expect(history.shapes.length, equals(2));

  history.undo();
  expect(history.shapes.length, equals(1));
  expect(history.shapes.first.id, equals(arrow1.id));

  history.redo();
  expect(history.shapes.length, equals(2));
});
```
