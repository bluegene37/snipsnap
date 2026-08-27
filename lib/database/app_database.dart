import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

class Captures extends Table {
  TextColumn get id => text()();
  TextColumn get filePath => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get width => integer().withDefault(const Constant(0))();
  IntColumn get height => integer().withDefault(const Constant(0))();
  TextColumn get tags => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DbAnnotation')
class Annotations extends Table {
  TextColumn get id => text()();
  TextColumn get captureId => text()();
  TextColumn get tool => text()();
  IntColumn get color => integer()();
  RealColumn get strokeWidth => real()();
  RealColumn get fontSize => real()();
  BoolColumn get isFilled => boolean().withDefault(const Constant(false))();
  TextColumn get textContent => text().nullable()();
  TextColumn get pointsJson => text().nullable()();
  TextColumn get rectJson => text().nullable()();
  IntColumn get stepNumber => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  RealColumn get startX => real().nullable()();
  RealColumn get startY => real().nullable()();
  RealColumn get endX => real().nullable()();
  RealColumn get endY => real().nullable()();
  RealColumn get opacity => real().nullable()();

  /// Every tool property without a dedicated column (corner radius, line style,
  /// blur mode & strength, shadow, arrowheads, colours, rotation). Stored as one
  /// JSON blob so adding a tool property never needs another migration.
  TextColumn get propsJson => text().nullable()();

  /// Preserves layer order (back to front) independently of insert time.
  IntColumn get zIndex => integer().withDefault(const Constant(0))();

  /// Which coordinate system [startX]/[startY]/[endX]/[endY]/[pointsJson] and
  /// the scalar dimensions are expressed in. Pre-v4 rows are 'viewport'.
  TextColumn get coordSpace => text().withDefault(const Constant('viewport'))();

  @override
  Set<Column> get primaryKey => {id};
}

class Shortcuts extends Table {
  TextColumn get action => text()();
  IntColumn get keyId => integer()();
  TextColumn get keyLabel => text()();
  BoolColumn get meta => boolean().withDefault(const Constant(false))();
  BoolColumn get ctrl => boolean().withDefault(const Constant(false))();
  BoolColumn get shift => boolean().withDefault(const Constant(false))();
  BoolColumn get alt => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {action};
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Captures, Annotations, Shortcuts, AppSettings])
class AppDatabase extends _$AppDatabase {
  /// [executor] exists for tests, which pass `NativeDatabase.memory()` so a
  /// migration can be exercised without touching the user's real library file.
  /// Production always omits it and gets the on-disk connection.
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.addColumn(annotations, annotations.startX);
          await m.addColumn(annotations, annotations.startY);
          await m.addColumn(annotations, annotations.endX);
          await m.addColumn(annotations, annotations.endY);
          await m.addColumn(annotations, annotations.opacity);
        }
        if (from < 3) {
          await m.addColumn(annotations, annotations.propsJson);
          await m.addColumn(annotations, annotations.zIndex);
        }
        if (from < 4) {
          await m.addColumn(annotations, annotations.coordSpace);
        }
      },
    );
  }

  // Captures CRUD
  Future<List<Capture>> getAllCaptures() =>
      (select(captures)..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
          .get();

  Future<void> insertOrUpdateCapture(CapturesCompanion capture) =>
      into(captures).insertOnConflictUpdate(capture);

  Future<void> deleteCaptureItem(String id) async {
    await transaction(() async {
      await (delete(annotations)..where((t) => t.captureId.equals(id))).go();
      await (delete(captures)..where((t) => t.id.equals(id))).go();
    });
  }

  // Annotations CRUD
  Future<List<DbAnnotation>> getAnnotationsForCapture(String captureId) =>
      (select(annotations)
            ..where((t) => t.captureId.equals(captureId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.zIndex),
              (t) => OrderingTerm(expression: t.createdAt),
            ]))
          .get();

  Future<void> saveAnnotationsForCapture(
    String captureId,
    List<AnnotationsCompanion> annotationList,
  ) async {
    await transaction(() async {
      await (delete(
        annotations,
      )..where((t) => t.captureId.equals(captureId))).go();
      for (final companion in annotationList) {
        await into(annotations).insert(companion);
      }
    });
  }

  // Shortcuts CRUD
  Future<List<Shortcut>> getAllShortcuts() => select(shortcuts).get();

  Future<void> saveShortcut(ShortcutsCompanion shortcut) =>
      into(shortcuts).insertOnConflictUpdate(shortcut);

  Future<void> saveAllShortcuts(List<ShortcutsCompanion> shortcutList) async {
    await transaction(() async {
      for (final companion in shortcutList) {
        await into(shortcuts).insertOnConflictUpdate(companion);
      }
    });
  }

  // Settings CRUD
  Future<String?> getSetting(String key) async {
    final row = await (select(
      appSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) =>
      into(appSettings).insertOnConflictUpdate(
        AppSettingsCompanion(key: Value(key), value: Value(value)),
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(
      p.join(dbFolder.path, 'SnipSnap', 'snipsnap_local.sqlite'),
    );
    return NativeDatabase.createInBackground(file);
  });
}
