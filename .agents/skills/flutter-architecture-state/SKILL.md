---
name: flutter-architecture-state
description: >-
  Architectural patterns and state management strategies for Flutter applications.
  Use when designing state flow, structuring presentation/domain/data layers, managing BuildContext across async gaps, or handling state lifecycle.
---

# Flutter Architecture & State Management

This skill provides architectural standards, state management guidelines, and context lifecycle rules for Flutter development.

---

## 1. Clean Layered Architecture

Structure Flutter applications with a strict separation of concerns across three core layers:

```
lib/
├── models/          # Domain entities, value objects, immutable data classes
├── services/        # Data sources, database clients, platform channels, API clients
├── tools/           # Domain strategies, tool handlers, algorithms
├── utils/           # Helper functions, geometry math, theme scopes
└── views/           # UI components, screen scaffolds, dialogs, painters
    ├── components/  # Reusable widgets, toolbars, overlays
    └── dialogs/     # Modal flows, settings sheets
```

### Layer Rules
- **Models / Domain**: Pure Dart data classes. Must NOT import `dart:io`, `package:flutter/material.dart`, or UI widgets.
- **Services / Data**: Encapsulate persistence (e.g. Drift SQLite, SharedPreferences) and native I/O. Expose clean typed streams or `Future` APIs to views.
- **Views / Presentation**: Consume state and render widgets or CustomPainters. Keep business logic and database queries out of `Widget.build()` and `CustomPainter.paint()`.

---

## 2. Safe State Management

### 2.1 Async Gaps and `BuildContext` Safety
Always protect `BuildContext` lookups after `await` calls:

```dart
// ✅ Correct: Verify mounted status before using BuildContext
Future<void> _handleSave() async {
  final file = await StorageService.pickDestination();
  if (file == null) return;

  await _database.saveItem(file);

  if (!mounted) return; // Guard for State<T>
  // Or in Flutter 3.7+: if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Saved successfully')),
  );
}
```

### 2.2 Model Immutability & List Updates
When modifying collections or object state in `setState`, always produce new references so listeners and custom painters detect changes:

```dart
// ❌ BAD: Mutating list in-place prevents Painter repaint checks
_annotations.add(newAnnotation);
setState(() {});

// ✅ GOOD: Create a new list copy
setState(() {
  _annotations = [..._annotations, newAnnotation];
});
```

---

## 3. Widget Lifecycle Best Practices

| Lifecycle Hook | Purpose | Rule |
| :--- | :--- | :--- |
| `initState()` | One-time initialization, stream subscriptions, controller creation. | Never use inherited widgets (e.g. `Theme.of(context)`) here. |
| `didChangeDependencies()` | Reacting to inherited widget changes (Theme, MediaQuery, Locale). | Safe to read InheritedWidgets; avoid heavy computations. |
| `didUpdateWidget()` | Reacting to parent widget property changes. | Compare `oldWidget.property != widget.property` before updating state. |
| `dispose()` | Teardown of controllers, timers, native resources, focus nodes. | Always call `super.dispose()` last. Cancel all subscriptions. |

---

## 4. State Management Selection

- **Ephemeral / Local UI State** (`ValueNotifier`, `ChangeNotifier`, `StatefulWidget`): Best for animation controllers, focus management, active tool selection, and slider drag values.
- **Repository / Feature State** (Drift Streams, Service Singletons): Best for persistent records, screenshot history, settings cache, and global hotkeys.
