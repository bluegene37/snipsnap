import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/app_shortcut.dart';
import '../../services/shortcut_service.dart';
import '../../utils/snip_theme.dart';

class ShortcutSettingsDialog extends StatefulWidget {
  final Map<AppShortcutAction, CustomShortcut> initialShortcuts;
  final ValueChanged<Map<AppShortcutAction, CustomShortcut>> onShortcutsSaved;

  const ShortcutSettingsDialog({
    super.key,
    required this.initialShortcuts,
    required this.onShortcutsSaved,
  });

  @override
  State<ShortcutSettingsDialog> createState() => _ShortcutSettingsDialogState();
}

class _ShortcutSettingsDialogState extends State<ShortcutSettingsDialog> {
  late Map<AppShortcutAction, CustomShortcut> _shortcuts;
  AppShortcutAction? _editingAction;
  String? _errorMessage;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _shortcuts = Map.from(widget.initialShortcuts);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing(AppShortcutAction action) {
    setState(() {
      _editingAction = action;
      _errorMessage = null;
    });
    _focusNode.requestFocus();
  }

  void _cancelEditing() {
    setState(() {
      _editingAction = null;
      _errorMessage = null;
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (_editingAction == null) return;

    if (event is KeyDownEvent) {
      final key = event.logicalKey;

      // Ignore if user pressed ESC to cancel editing
      if (key == LogicalKeyboardKey.escape) {
        _cancelEditing();
        return;
      }

      // Check if pressed key is only a modifier
      final isModifier = key == LogicalKeyboardKey.meta ||
          key == LogicalKeyboardKey.metaLeft ||
          key == LogicalKeyboardKey.metaRight ||
          key == LogicalKeyboardKey.control ||
          key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight ||
          key == LogicalKeyboardKey.shift ||
          key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight ||
          key == LogicalKeyboardKey.alt ||
          key == LogicalKeyboardKey.altLeft ||
          key == LogicalKeyboardKey.altRight;

      if (isModifier) return;

      final hk = HardwareKeyboard.instance;
      final meta = hk.isMetaPressed;
      final ctrl = hk.isControlPressed;
      final shift = hk.isShiftPressed;
      final alt = hk.isAltPressed;

      String label = key.keyLabel;
      if (label.isEmpty) {
        label = key.debugName ?? 'Key';
      }

      final newShortcut = CustomShortcut(
        action: _editingAction!,
        keyId: key.keyId,
        keyLabel: label,
        meta: meta,
        ctrl: ctrl,
        shift: shift,
        alt: alt,
      );

      // Chords the OS keeps for itself register without error and then never
      // fire, so they have to be refused here — otherwise the user configures a
      // shortcut that silently does nothing and blames the app.
      if (ShortcutService.isReservedBySystem(newShortcut)) {
        setState(() {
          _errorMessage = 'The system already uses this shortcut. Pick another.';
        });
        return;
      }

      // Check collision
      AppShortcutAction? conflictingAction;
      for (final entry in _shortcuts.entries) {
        if (entry.key != _editingAction) {
          if (entry.value.keyId == newShortcut.keyId &&
              entry.value.meta == newShortcut.meta &&
              entry.value.ctrl == newShortcut.ctrl &&
              entry.value.shift == newShortcut.shift &&
              entry.value.alt == newShortcut.alt) {
            conflictingAction = entry.key;
            break;
          }
        }
      }

      if (conflictingAction != null) {
        setState(() {
          _errorMessage = 'Shortcut conflicts with "${conflictingAction!.displayName}"!';
        });
      } else {
        setState(() {
          _shortcuts[_editingAction!] = newShortcut;
          _editingAction = null;
          _errorMessage = null;
        });
      }
    }
  }

  void _resetDefaults() {
    setState(() {
      _shortcuts = ShortcutService.getDefaultShortcuts();
      _editingAction = null;
      _errorMessage = null;
    });
  }

  void _saveAndClose() {
    ShortcutService.saveShortcuts(_shortcuts);
    widget.onShortcutsSaved(_shortcuts);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Container(
          width: 640,
          constraints: const BoxConstraints(maxHeight: 620),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.surfaceRaised,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.keyboard_rounded, color: t.ink, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Keyboard Shortcuts',
                          style: TextStyle(
                            color: t.ink,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Click "Edit" on any action, then press your desired hotkey combination.',
                          style: TextStyle(color: t.inkMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: t.inkMuted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: t.border, height: 1),
              const SizedBox(height: 12),

              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    // A shortcut conflict is an error state — the danger
                    // token, never an inline red, is this design's one
                    // sanctioned chromatic exception (see SnipTheme's class
                    // doc comment).
                    color: t.danger.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.danger.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: t.danger, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: t.ink, fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),

              // Shortcuts List
              Expanded(
                child: ListView.separated(
                  itemCount: AppShortcutAction.values.length,
                  separatorBuilder: (ctx, index) => Divider(color: t.border, height: 1),
                  itemBuilder: (ctx, index) {
                    final action = AppShortcutAction.values[index];
                    final shortcut = _shortcuts[action]!;
                    final isEditing = _editingAction == action;

                    return Container(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                      // The row currently awaiting a hotkey press is a
                      // highlight, not the app's exclusive-active control
                      // (controlDecoration's non-exclusive shape gives the
                      // border the same colour as the fill, i.e. no visible
                      // outline — too quiet for "this row is now capturing
                      // keystrokes"), so the outline is hand-strengthened to
                      // borderStrong on top of the selectedFill highlight.
                      decoration: BoxDecoration(
                        color: isEditing ? t.selectedFill : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: isEditing ? Border.all(color: t.borderStrong, width: 1.5) : null,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  action.displayName,
                                  style: TextStyle(
                                    color: t.ink,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // Was a third, even-fainter text tier
                                // (Colors.white38/black38). inkFaint is
                                // documented for dividers/disabled state
                                // only, never text a user must read, and
                                // this caption is read (it explains what the
                                // action does) — inkMuted is the correct,
                                // legible secondary tone.
                                Text(
                                  action.description,
                                  style: TextStyle(
                                    color: t.inkMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Shortcut display pills
                          if (isEditing)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                // The one thing actively happening right
                                // now (awaiting a keypress) — the exclusive
                                // active knockout plate.
                                color: t.activeFill,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: t.onActive,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Press hotkey...',
                                    style: TextStyle(
                                      color: t.onActive,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            _buildShortcutBadges(t, shortcut),

                          const SizedBox(width: 12),

                          // Action Button
                          if (isEditing)
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: t.inkMuted,
                                side: BorderSide(color: t.border),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                minimumSize: const Size(60, 32),
                              ),
                              onPressed: _cancelEditing,
                              child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                            )
                          else
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: t.surfaceRaised,
                                foregroundColor: t.ink,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                minimumSize: const Size(60, 32),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              onPressed: () => _startEditing(action),
                              child: const Text('Edit', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),
              Divider(color: t.border, height: 1),
              const SizedBox(height: 12),

              // Bottom Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: t.inkMuted,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Reset Defaults', style: TextStyle(fontSize: 12)),
                    onPressed: _resetDefaults,
                  ),
                  Row(
                    children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.inkMuted,
                          side: BorderSide(color: t.border),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      // The dialog's one CTA — emphasis is a border/text-only
                      // token, never a fill (Task 3's corrected precedent).
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: t.surfaceRaised,
                          foregroundColor: t.emphasis,
                          side: BorderSide(color: t.emphasis, width: 1.2),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        onPressed: _saveAndClose,
                        child: const Text('Save Shortcuts', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShortcutBadges(SnipTheme t, CustomShortcut shortcut) {
    final isMac = Platform.isMacOS;
    final keys = <String>[];

    if (shortcut.meta) keys.add(isMac ? '⌘' : 'Win');
    if (shortcut.ctrl) keys.add(isMac ? 'Control' : 'Ctrl');
    if (shortcut.alt) keys.add(isMac ? '⌥' : 'Alt');
    if (shortcut.shift) keys.add(isMac ? '⇧' : 'Shift');
    keys.add(shortcut.keyLabel.toUpperCase());

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: keys
          .map((k) => Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: t.surfaceRaised,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: t.border),
                  // Decorative elevation shadow under a kbd-style badge,
                  // sitting on this dialog's own t.surface/t.surfaceRaised
                  // panel chrome (not arbitrary image content) — kept a
                  // fixed, mode-invariant literal like the app's other
                  // incidental drop shadows (e.g. OcrResultPanel's own
                  // boxShadow below).
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    )
                  ],
                ),
                child: Text(
                  k,
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ))
          .toList(),
    );
  }
}
