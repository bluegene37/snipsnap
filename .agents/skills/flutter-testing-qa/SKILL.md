---
name: flutter-testing-qa
description: >-
  Comprehensive testing strategies and test automation for Flutter applications.
  Use when writing unit tests, WidgetTester tests, CustomPainter canvas tests, mocking platform channels, or setting up in-memory database tests.
---

# Flutter Testing & Quality Assurance

This skill provides testing patterns for unit tests, widget interaction tests, CustomPainter tests, and platform channel mocking.

---

## 1. Unit & Database Testing

### 1.1 In-Memory Database Tests (Drift SQLite)
```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    // Open clean in-memory database for isolated test run
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('inserts and retrieves capture item successfully', () async {
    await db.into(db.captures).insert(
      CapturesCompanion.insert(
        id: 'test-123',
        filePath: '/tmp/test.png',
        createdAt: DateTime.now(),
      ),
    );

    final items = await db.select(db.captures).get();
    expect(items.length, 1);
    expect(items.first.id, 'test-123');
  });
}
```

---

## 2. Widget & Interaction Testing

### 2.1 Widget Testing with `WidgetTester`
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/views/dialogs/about_dialog.dart';

void main() {
  testWidgets('About dialog shows version and closes when Close clicked', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AboutSnipSnapDialog(),
        ),
      ),
    );

    expect(find.text('SnipSnap'), findsOneWidget);
    expect(find.text('Version 1.0.0 (Build 1)'), findsOneWidget);

    // Tap Close button
    final closeBtn = find.widgetWithText(ElevatedButton, 'Close');
    expect(closeBtn, findsOneWidget);
    await tester.tap(closeBtn);
    await tester.pumpAndSettle();
  });
}
```

---

## 3. Mocking Platform Channels

When testing code that calls native platform APIs (`MethodChannel`, `window_manager`, `hotkey_manager`):

```dart
setUp(() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('snipsnap/screen_capture'),
    (MethodCall methodCall) async {
      if (methodCall.method == 'captureArea') {
        return {'success': true, 'path': '/fake/path.png'};
      }
      return null;
    },
  );
});
```

---

## 4. Testing Execution Commands

```bash
# Run all tests
flutter test

# Run a specific test file
flutter test test/annotation_test.dart

# Run with coverage report
flutter test --coverage
```
