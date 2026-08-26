import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/shortcut_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/about_dialog.dart';
import 'package:snipsnap/views/dialogs/save_as_dialog.dart';
import 'package:snipsnap/views/dialogs/shortcut_settings_dialog.dart';
import 'package:snipsnap/views/main_screen.dart';

/// Every modal in this app opens through `showDialog` from `MainScreen`, and
/// every converted dialog calls `SnipTheme.of(context)` in its own `build`.
/// That makes the *placement* of `SnipThemeScope` relative to the navigator
/// that hosts the route a correctness property, not a style one — and it is
/// a property no source-level check can see.
///
/// `snip_theme_wiring_test.dart` greps for the string `SnipThemeScope(` and
/// was green for the entire branch while About, Keyboard Shortcuts and Save
/// As all threw the moment they opened. This file exists so that cannot
/// happen again: it drives real `showDialog` calls through the real app
/// shell, and it reproduces each broken shape to show what the passing case
/// is actually protecting against.
///
/// `MainScreen` itself cannot be pumped — it builds an `EditorCanvas`, which
/// emits `Image.file`, which hangs `flutter_tester`. So [_AppShell] below
/// reproduces `MainScreen`'s structure exactly (`SnipThemeScope` wrapping a
/// single `MaterialApp` themed by the production [snipThemeData], dialogs
/// opened through a `navigatorKey` context) around a trivial home, and the
/// two deliberately-broken variants differ from it in exactly one way each.

/// Which context a shell hands to `showDialog`.
enum _DialogContext {
  /// The navigator's own context, from a `navigatorKey` on the MaterialApp —
  /// what `MainScreen` does. Inside the app, inside the scope.
  navigatorKey,

  /// The `State`'s own context — what `MainScreen` used to do. It sits
  /// *above* the MaterialApp this same `build()` mounts.
  stateContext,
}

/// Reproduces `MainScreen`'s tree shape with a pumpable home.
///
/// [dialogContext] selects which context reaches `showDialog`. To reproduce
/// the pre-fix `lib/main.dart`, wrap the whole shell in [_preFixOuterApp] —
/// that has to happen from *outside* the shell, because the outer app used
/// to sit above `MainScreen` (`SnipSnapApp(home: MainScreen())`), which is
/// precisely what put `MainScreen`'s own context below a navigator that was
/// above the scope. Building it inside `_AppShell.build` instead would put
/// the State's context above both apps and reproduce a different bug.
///
/// The production shape is a bare shell with `_DialogContext.navigatorKey`;
/// every other combination is a bug being pinned.
class _AppShell extends StatefulWidget {
  const _AppShell({
    required this.mode,
    required this.child,
    this.dialogContext = _DialogContext.navigatorKey,
  });

  final SnipThemeMode mode;
  final _DialogContext dialogContext;

  /// Built inside the dialog route. A real dialog, or a probe.
  final WidgetBuilder child;

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  SnipTheme get _theme => SnipTheme.forMode(widget.mode);

  void _open() {
    // Deliberately the bare `showDialog` with its default
    // `useRootNavigator: true` — overriding that would paper over exactly
    // the routing this test is here to check.
    showDialog<void>(
      context: widget.dialogContext == _DialogContext.navigatorKey
          ? _navigatorKey.currentContext!
          : context,
      builder: widget.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    final app = SnipThemeScope(
      theme: theme,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: snipThemeData(theme),
        home: Scaffold(
          body: Center(
            child: TextButton(onPressed: _open, child: const Text('open')),
          ),
        ),
      ),
    );
    return app;
  }
}

/// Pumps [shell], taps "open", and returns whatever went wrong — a thrown
/// error, or the exception the framework captured while building the route —
/// or `null` if the dialog opened cleanly.
///
/// `tester.takeException()` alone is not enough here: a `showDialog` whose
/// *context* is bad throws synchronously out of the tap, whereas one whose
/// *route* cannot build reports through the framework instead. Both are
/// "the dialog did not open", and this collapses them.
Future<Object?> _openDialog(WidgetTester tester, Widget shell) async {
  await tester.pumpWidget(shell);
  Object? error;
  try {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  } catch (e) {
    error = e;
  }
  // The dialogs embed Image.asset logos and lay out under the Ahem font;
  // both produce benign exceptions the existing per-dialog tests already
  // drain. Only take the exception when nothing was thrown outright, and
  // let the caller decide whether it is the failure it was looking for.
  return error ?? tester.takeException();
}

void main() {
  for (final mode in SnipThemeMode.values) {
    final label = mode.name;
    final t = SnipTheme.forMode(mode);

    // ---------------------------------------------------------------
    // The real tree shape: every dialog opens and renders.
    // ---------------------------------------------------------------

    testWidgets('[$label] About opens through showDialog and renders', (tester) async {
      await _openDialog(
        tester,
        _AppShell(mode: mode, child: (_) => const AboutSnipSnapDialog()),
      );

      expect(find.byType(AboutSnipSnapDialog), findsOneWidget);
      expect(find.text('snipsnap'), findsOneWidget);
      // Proof it resolved the scope rather than merely mounting: this colour
      // can only have come from SnipTheme.of inside the route.
      expect(tester.widget<Dialog>(find.byType(Dialog)).backgroundColor, t.surface);
    });

    testWidgets('[$label] Keyboard Shortcuts opens through showDialog and renders',
        (tester) async {
      await _openDialog(
        tester,
        _AppShell(
          mode: mode,
          child: (_) => ShortcutSettingsDialog(
            initialShortcuts: ShortcutService.getDefaultShortcuts(),
            onShortcutsSaved: (_) {},
          ),
        ),
      );

      // Rendered content, not `findsOneWidget` on the dialog type: a widget
      // whose build() threw still leaves its own element in the tree, so
      // byType would pass against the very crash this file exists to catch.
      // (Verified — that assertion was the one arm of this file that stayed
      // green when the whole shell was flipped to the pre-fix shape.)
      expect(find.byType(ShortcutSettingsDialog), findsOneWidget);
      expect(find.text('Keyboard Shortcuts'), findsOneWidget);
      expect(find.text('Save Shortcuts'), findsOneWidget);
    });

    testWidgets('[$label] Save As opens through showDialog and renders', (tester) async {
      await _openDialog(
        tester,
        _AppShell(
          mode: mode,
          child: (_) => SaveAsDialog(initialName: 'shot', onConfirm: (_) {}),
        ),
      );

      expect(find.byType(SaveAsDialog), findsOneWidget);
      expect(tester.widget<AlertDialog>(find.byType(AlertDialog)).backgroundColor, t.surface);
    });

    // ---------------------------------------------------------------
    // The secondary consequence of the same nesting: stock Material
    // chrome inside a dialog route resolving the wrong ThemeData.
    // ---------------------------------------------------------------

    testWidgets('[$label] Material chrome inside a dialog route resolves the snip theme, '
        'not a stock M3 baseline', (tester) async {
      late ColorScheme scheme;
      await _openDialog(
        tester,
        _AppShell(
          mode: mode,
          child: (ctx) {
            scheme = Theme.of(ctx).colorScheme;
            return const AlertDialog(content: Text('probe'));
          },
        ),
      );

      expect(find.text('probe'), findsOneWidget);
      // style_picker.dart's two colour-picker dialogs capture SnipTheme
      // before showDialog, so they survived the crash — but their
      // AlertDialogs and the third-party ColorPicker inside them read
      // Theme.of, which used to reach the outer stock M3 app and come back
      // baseline purple. That was the one violet surface left in the app.
      expect(scheme.primary, t.ink, reason: '$label: dialog-route primary');
      expect(scheme.surface, t.surface, reason: '$label: dialog-route surface');
      // Monochrome, to the same <0.04 channel spread
      // `main_screen_color_scheme_test.dart` uses — the palette's two paper
      // tones are a hair warm on purpose (see SnipTheme.dark's doc comment),
      // so an exact R==G==B check would be wrong, not stricter.
      for (final entry in <String, Color>{
        'primary': scheme.primary,
        'secondary': scheme.secondary,
        'surface': scheme.surface,
        'surfaceContainerHigh': scheme.surfaceContainerHigh,
        'outline': scheme.outline,
      }.entries) {
        expect(
          _isNeutral(entry.value),
          isTrue,
          reason: '$label: ${entry.key} carries chroma inside a dialog route '
              '(${entry.value}) — a stock M3 scheme leaked in',
        );
      }
    });
  }

  // ---------------------------------------------------------------
  // The two broken shapes, pinned. Each differs from the passing shell
  // above in exactly one way, so between them they show that BOTH halves
  // of the fix are load-bearing.
  // ---------------------------------------------------------------

  group('the shapes this guards against', () {
    testWidgets('a second MaterialApp above SnipThemeScope breaks every dialog '
        '(the pre-fix lib/main.dart)', (tester) async {
      final error = await _openDialog(
        tester,
        _preFixOuterApp(
          const _AppShell(
            mode: SnipThemeMode.dark,
            dialogContext: _DialogContext.stateContext,
            child: _aboutBuilder,
          ),
        ),
      );

      // showDialog defaults to useRootNavigator: true, so the route lands on
      // the OUTER navigator — above the scope. And SnipThemeScope is an
      // InheritedWidget, not an InheritedTheme, so InheritedTheme.capture
      // does not carry it across the route either.
      expect(find.text('snipsnap'), findsNothing);
      expect(error, isNotNull);
      expect('$error', contains('No SnipThemeScope found in the widget tree'));
    });

    testWidgets('deleting the outer MaterialApp is not enough on its own — the '
        "State's own context still has no Navigator above it", (tester) async {
      final error = await _openDialog(
        tester,
        const _AppShell(
          mode: SnipThemeMode.dark,
          dialogContext: _DialogContext.stateContext,
          child: _aboutBuilder,
        ),
      );

      // MainScreen's State context sits above the MaterialApp its own build()
      // mounts, so once nothing else supplies a root app there is no
      // Navigator and no MaterialLocalizations to be found. Hence the
      // navigatorKey in main_screen.dart: the fix is two halves, not one.
      expect(find.text('snipsnap'), findsNothing);
      expect(error, isNotNull);
      expect('$error', contains('No MaterialLocalizations found'));
    });

    testWidgets('the navigatorKey alone does not save it either, because '
        'useRootNavigator still resolves past it to the outer app', (tester) async {
      final error = await _openDialog(
        tester,
        _preFixOuterApp(
          const _AppShell(mode: SnipThemeMode.dark, child: _aboutBuilder),
        ),
      );

      expect(find.text('snipsnap'), findsNothing);
      expect(error, isNotNull);
      expect('$error', contains('No SnipThemeScope found in the widget tree'));
    });
  });
}

/// Top-level so the broken-shape shells above can stay `const`.
Widget _aboutBuilder(BuildContext _) => const AboutSnipSnapDialog();

/// The `SnipSnapApp` that `lib/main.dart` used to hand to `runApp`, verbatim,
/// wrapping [child] the way it wrapped `MainScreen`.
Widget _preFixOuterApp(Widget child) => MaterialApp(
      title: 'SnipSnap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: child,
    );

/// Same <0.04 channel-spread definition of "neutral" that
/// `main_screen_color_scheme_test.dart` uses.
bool _isNeutral(Color c) {
  final maxC = math.max(c.r, math.max(c.g, c.b));
  final minC = math.min(c.r, math.min(c.g, c.b));
  return (maxC - minC) < 0.04;
}
