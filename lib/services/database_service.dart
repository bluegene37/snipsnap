import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import '../database/app_database.dart';
import '../models/annotation.dart';
import '../models/app_shortcut.dart';
import '../models/capture_item.dart';
import '../utils/canvas_projection.dart';
import '../utils/constants.dart';

class DatabaseService {
  static AppDatabase _db = AppDatabase();

  static AppDatabase get db => _db;

  /// Swaps in an in-memory database for tests. Assigning here never reads
  /// [_db], so the lazy on-disk initialiser above is not triggered and no real
  /// library file is opened.
  @visibleForTesting
  static set db(AppDatabase value) => _db = value;

  /// Load all captures from Drift SQLite local DB
  static Future<List<CaptureItem>> loadCapturesFromDb() async {
    final rows = await db.getAllCaptures();
    final items = <CaptureItem>[];

    for (final row in rows) {
      final annRows = await db.getAnnotationsForCapture(row.id);
      final parsed = _annotationsFor(annRows);

      items.add(
        CaptureItem(
          id: row.id,
          filePath: row.filePath,
          title: row.title,
          createdAt: row.createdAt,
          width: row.width,
          height: row.height,
          annotations: parsed.annotations,
          annotationsNeedConversion: parsed.needsConversion,
        ),
      );
    }
    return items;
  }

  /// Annotations for one capture, paired with whether any of them still hold
  /// pre-v4 viewport coordinates and need converting.
  static ({List<Annotation> annotations, bool needsConversion}) _annotationsFor(
    List<DbAnnotation> rows,
  ) {
    final converted = rows.map(convertAnnotationFromDb).toList();
    return (
      annotations: converted.map((r) => r.annotation).toList(),
      needsConversion: converted.any((r) => r.space == CoordSpace.viewport),
    );
  }

  /// Whether [item]'s annotation rows may be rewritten right now.
  ///
  /// This is the coordinate-space invariant, enforced at the only place every
  /// annotation write passes through rather than at each call site.
  ///
  /// [_convertAnnotationToCompanion] unconditionally stamps
  /// `coordSpace = imagePixels` on every row it writes. That stamp is the sole
  /// discriminator telling a pre-v4 row (still holding viewport coordinates)
  /// from a converted one. A capture whose [CaptureItem.annotationsNeedConversion]
  /// is true is still carrying viewport numbers, so writing it would stamp
  /// `imagePixels` over data that is not in image pixels — destroying the only
  /// evidence that a conversion is still owed. On the next launch the rows read
  /// back as already-converted and are never fixed: markup renders, exports and
  /// flattens at the wrong scale permanently.
  ///
  /// Refusing costs nothing. An unconverted capture's rows are already correct
  /// on disk, and every path that could have modified them is itself gated on
  /// the same flag, so there is never an unsaved edit to lose. The conversion
  /// (`_convertActiveCaptureAnnotations` in main_screen) clears the flag before
  /// it persists, so the rewrite that *does* need to happen is not blocked.
  static bool canPersistAnnotations(CaptureItem item) =>
      !item.annotationsNeedConversion;

  /// Save single capture item (and its annotations) to Drift SQLite DB.
  ///
  /// Every annotation write in the app funnels through here — the singular
  /// `saveCaptureItem` path and the plural `saveHistory` /
  /// [saveAllCapturesToDb] path alike — so this is where the coordinate-space
  /// guard lives. Placing it here rather than at the call sites means no
  /// present or future caller can bypass it.
  static Future<void> saveCaptureToDb(CaptureItem item) async {
    await db.insertOrUpdateCapture(
      CapturesCompanion(
        id: Value(item.id),
        filePath: Value(item.filePath),
        title: Value(item.title),
        createdAt: Value(item.createdAt),
        width: Value(item.width),
        height: Value(item.height),
      ),
    );

    // The capture row above is coordinate-space-free metadata (path, title,
    // recovered pixel dimensions) and is always safe to refresh — recovered
    // dimensions in particular are what a later conversion needs. Only the
    // annotation rows carry the stamp, so only they are withheld.
    if (!canPersistAnnotations(item)) return;

    // The list order *is* the layer order, so persist the index alongside.
    final companions = [
      for (var i = 0; i < item.annotations.length; i++)
        _convertAnnotationToCompanion(item.id, item.annotations[i], i),
    ];
    await db.saveAnnotationsForCapture(item.id, companions);
  }

  /// Save list of captures to Drift SQLite DB.
  ///
  /// This is the path that rewrites the *whole* library, and only the active
  /// capture is ever converted — so on a real upgrade nearly every item here
  /// still needs conversion. Each one is filtered individually by
  /// [saveCaptureToDb]'s guard; nothing extra is needed at this level, but the
  /// per-item filtering is the load-bearing part of this call, not an
  /// incidental detail.
  static Future<void> saveAllCapturesToDb(List<CaptureItem> items) async {
    for (final item in items) {
      await saveCaptureToDb(item);
    }
  }

  /// Delete capture from Drift SQLite DB
  static Future<void> deleteCaptureFromDb(String id) async {
    await db.deleteCaptureItem(id);
  }

  /// Load custom shortcuts from Drift SQLite DB
  static Future<Map<AppShortcutAction, CustomShortcut>>
  loadShortcutsFromDb() async {
    final rows = await db.getAllShortcuts();
    final map = <AppShortcutAction, CustomShortcut>{};

    for (final row in rows) {
      final action = AppShortcutAction.values.firstWhere(
        (a) => a.name == row.action,
        orElse: () => AppShortcutAction.interactiveSnip,
      );
      map[action] = CustomShortcut(
        action: action,
        keyId: row.keyId,
        keyLabel: row.keyLabel,
        meta: row.meta,
        ctrl: row.ctrl,
        shift: row.shift,
        alt: row.alt,
      );
    }
    return map;
  }

  /// Save shortcuts to Drift SQLite DB
  static Future<void> saveShortcutsToDb(
    Map<AppShortcutAction, CustomShortcut> shortcuts,
  ) async {
    final companions = shortcuts.values
        .map(
          (s) => ShortcutsCompanion(
            action: Value(s.action.name),
            keyId: Value(s.keyId),
            keyLabel: Value(s.keyLabel),
            meta: Value(s.meta),
            ctrl: Value(s.ctrl),
            shift: Value(s.shift),
            alt: Value(s.alt),
          ),
        )
        .toList();
    await db.saveAllShortcuts(companions);
  }

  /// Save app setting to Drift SQLite DB
  static Future<void> setSetting(String key, String value) async {
    await db.setSetting(key, value);
  }

  /// Get app setting from Drift SQLite DB
  static Future<String?> getSetting(String key) async {
    return await db.getSetting(key);
  }

  /// Tool names written by older builds, before the separate rectangle and
  /// oval tools were merged into the multi-shape [CanvasTool.shape].
  static const Map<String, ShapeKind> _legacyShapeTools = {
    'rectangle': ShapeKind.rectangle,
    'oval': ShapeKind.ellipse,
  };

  // Annotation conversion helpers
  /// An annotation as stored, together with the coordinate space its numbers
  /// are in. Callers must convert [CoordSpace.viewport] rows before use.
  static ({Annotation annotation, CoordSpace space}) convertAnnotationFromDb(
    DbAnnotation a,
  ) {
    final legacyShape = _legacyShapeTools[a.tool];
    final tool = legacyShape != null
        ? CanvasTool.shape
        : CanvasTool.values.firstWhere(
            (t) => t.name == a.tool,
            orElse: () => CanvasTool.pen,
          );

    List<Offset> points = [];
    if (a.pointsJson != null && a.pointsJson!.isNotEmpty) {
      try {
        final list = jsonDecode(a.pointsJson!) as List<dynamic>;
        points = list
            .map(
              (p) => Offset(
                (p['x'] as num).toDouble(),
                (p['y'] as num).toDouble(),
              ),
            )
            .toList();
      } catch (e) {
        debugPrint('SnipSnap DB error: $e');
      }
    }

    var annotation = Annotation(
      id: a.id,
      tool: tool,
      color: Color(a.color),
      strokeWidth: a.strokeWidth,
      fontSize: a.fontSize,
      fill: a.isFilled,
      text: a.textContent,
      stepNumber: a.stepNumber != 0 ? a.stepNumber : null,
      points: points,
      startPoint: a.startX != null && a.startY != null
          ? Offset(a.startX!, a.startY!)
          : null,
      endPoint: a.endX != null && a.endY != null
          ? Offset(a.endX!, a.endY!)
          : null,
      opacity: a.opacity ?? 1.0,
    );

    // v3+ rows carry every extra property in one blob.
    if (a.propsJson != null && a.propsJson!.isNotEmpty) {
      try {
        annotation = annotation.withPropsJson(
          jsonDecode(a.propsJson!) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('SnipSnap DB error: $e');
      }
    } else if (a.rectJson != null && a.rectJson!.isNotEmpty) {
      // Legacy (schema <= 2) layout: rect, background colour and rotation were
      // packed into rectJson.
      try {
        final map = jsonDecode(a.rectJson!) as Map<String, dynamic>;
        annotation = annotation.copyWith(
          rect: map.containsKey('l')
              ? Rect.fromLTRB(
                  (map['l'] as num).toDouble(),
                  (map['t'] as num).toDouble(),
                  (map['r'] as num).toDouble(),
                  (map['b'] as num).toDouble(),
                )
              : null,
          backgroundColor: map.containsKey('bgColor')
              ? Color(map['bgColor'] as int)
              : null,
          rotation: (map['rot'] as num?)?.toDouble(),
        );
      } catch (e) {
        debugPrint('SnipSnap DB error: $e');
      }
    }

    // Applied last: the old tool name is the authoritative record of which
    // shape the user drew, and must win over any default in propsJson.
    if (legacyShape != null) {
      annotation = annotation.copyWith(shapeKind: legacyShape);
    }

    return (annotation: annotation, space: coordSpaceByName(a.coordSpace));
  }

  static AnnotationsCompanion _convertAnnotationToCompanion(
    String captureId,
    Annotation a,
    int zIndex,
  ) {
    return AnnotationsCompanion(
      id: Value(a.id),
      captureId: Value(captureId),
      tool: Value(a.tool.name),
      color: Value(a.color.toARGB32()),
      strokeWidth: Value(a.strokeWidth),
      fontSize: Value(a.fontSize),
      isFilled: Value(a.fill),
      textContent: Value(a.text),
      stepNumber: Value(a.stepNumber ?? 0),
      pointsJson: Value(
        a.points.isEmpty
            ? null
            : jsonEncode(a.points.map((p) => {'x': p.dx, 'y': p.dy}).toList()),
      ),
      propsJson: Value(jsonEncode(a.toPropsJson())),
      createdAt: Value(DateTime.now()),
      startX: Value(a.startPoint?.dx),
      startY: Value(a.startPoint?.dy),
      endX: Value(a.endPoint?.dx),
      endY: Value(a.endPoint?.dy),
      opacity: Value(a.opacity),
      zIndex: Value(zIndex),
      coordSpace: Value(CoordSpace.imagePixels.name),
    );
  }
}
