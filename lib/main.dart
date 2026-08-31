import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'services/sandbox_migration.dart';
import 'views/main_screen.dart';

/// [MainScreen] is handed to [runApp] directly, and **must stay that way**:
/// it builds its own `SnipThemeScope` wrapping the app's one and only
/// [MaterialApp] (see `main_screen.dart`'s `build`).
///
/// There used to be a second, outer `MaterialApp` here. It looked harmless —
/// the inner one overrode its theme for everything on screen — but it broke
/// every modal dialog in the app:
///
/// * `showDialog` defaults to `useRootNavigator: true`, so dialog routes were
///   pushed onto the **outer** app's navigator, which sat *above*
///   `SnipThemeScope`.
/// * `SnipThemeScope` is an `InheritedWidget`, not an `InheritedTheme`, so
///   `showDialog`'s `InheritedTheme.capture` did not carry it across the
///   route boundary either.
/// * Every converted dialog calls `SnipTheme.of(context)` in its own `build`,
///   so About, Keyboard Shortcuts and Save As all threw on open — an assert
///   in debug, a `TypeError` in release — taking out the primary export path.
/// * Anything that *did* survive (the style picker's colour-picker dialogs
///   capture the theme before `showDialog`) still resolved `Theme.of` from
///   the outer `ThemeData(brightness: dark, useMaterial3: true)`, i.e. the
///   stock M3 baseline **purple** — the last violet-tinted surface in an app
///   whose whole point is that it has no violet left.
///
/// Deleting that outer app is necessary but **not sufficient**, and this is
/// the part worth remembering: with it gone, `_MainScreenState.context` — the
/// context the three `showDialog` call sites used to pass — has no Navigator
/// and no `MaterialLocalizations` above it at all, because it sits above the
/// MaterialApp its own `build()` mounts. `showDialog` then asserts
/// `No MaterialLocalizations found` instead. So `main_screen.dart` also holds
/// a `navigatorKey` on that MaterialApp and passes the navigator's own
/// context to `showDialog`; see `_navigatorKey`'s doc comment there.
///
/// `test/dialog_route_theme_test.dart` pins every arm of this: it opens the
/// real dialogs through the real tree shape, and it reproduces the two-app
/// shape *and* the above-the-app-context shape to prove each one breaks them
/// on its own. `test/snip_theme_wiring_test.dart` additionally guards that
/// this file constructs no `MaterialApp`.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything touches the database or SharedPreferences: pulls user
  // data out of the old App Sandbox container on the first unsandboxed run.
  await SandboxMigration.runIfNeeded();
  try {
    await hotKeyManager.unregisterAll();
  } catch (e) {
    debugPrint('hotKeyManager init notice: $e');
  }
  runApp(const MainScreen());
}
