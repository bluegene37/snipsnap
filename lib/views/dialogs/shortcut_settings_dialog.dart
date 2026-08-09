import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/app_shortcut.dart';
import '../../services/shortcut_service.dart';
import '../../utils/constants.dart';

class ShortcutSettingsDialog extends StatefulWidget {
  final Map<AppShortcutAction, CustomShortcut> initialShortcuts;
  final ValueChanged<Map<AppShortcutAction, CustomShortcut>> onShortcutsSaved;
  final bool isDarkMode;

  const ShortcutSettingsDialog({
    super.key,
    required this.initialShortcuts,
    required this.onShortcutsSaved,
    this.isDarkMode = true,
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
    final dialogBg = widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = widget.isDarkMode ? Colors.white54 : Colors.black54;
    final subSubTextColor = widget.isDarkMode ? Colors.white38 : Colors.black38;
    final dividerColor = widget.isDarkMode ? Colors.white10 : Colors.black12;
    final editBtnBg = widget.isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;

    return Dialog(
      backgroundColor: dialogBg,
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
                      color: AppColors.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.keyboard_rounded, color: AppColors.accent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Keyboard Shortcuts',
                          style: TextStyle(
                            color: textColor,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Click "Edit" on any action, then press your desired hotkey combination.',
                          style: TextStyle(color: subTextColor, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: subTextColor),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: dividerColor, height: 1),
              const SizedBox(height: 12),

              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),

              // Shortcuts List
              Expanded(
                child: ListView.separated(
                  itemCount: AppShortcutAction.values.length,
                  separatorBuilder: (ctx, index) => Divider(color: dividerColor, height: 1),
                  itemBuilder: (ctx, index) {
                    final action = AppShortcutAction.values[index];
                    final shortcut = _shortcuts[action]!;
                    final isEditing = _editingAction == action;

                    return Container(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                      decoration: BoxDecoration(
                        color: isEditing
                            ? AppColors.accent.withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: isEditing
                            ? Border.all(color: AppColors.accent, width: 1.5)
                            : null,
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
                                    color: textColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  action.description,
                                  style: TextStyle(
                                    color: subSubTextColor,
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
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Row(
                                children: [
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Press hotkey...',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            _buildShortcutBadges(shortcut),

                          const SizedBox(width: 12),

                          // Action Button
                          if (isEditing)
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: subTextColor,
                                side: BorderSide(color: dividerColor),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                minimumSize: const Size(60, 32),
                              ),
                              onPressed: _cancelEditing,
                              child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                            )
                          else
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: editBtnBg,
                                foregroundColor: textColor,
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
              Divider(color: dividerColor, height: 1),
              const SizedBox(height: 12),

              // Bottom Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: subTextColor,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Reset Defaults', style: TextStyle(fontSize: 12)),
                    onPressed: _resetDefaults,
                  ),
                  Row(
                    children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: subTextColor,
                          side: BorderSide(color: dividerColor),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
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

  Widget _buildShortcutBadges(CustomShortcut shortcut) {
    final isMac = Platform.isMacOS;
    final keys = <String>[];

    if (shortcut.meta) keys.add(isMac ? '⌘' : 'Win');
    if (shortcut.ctrl) keys.add(isMac ? 'Control' : 'Ctrl');
    if (shortcut.alt) keys.add(isMac ? '⌥' : 'Alt');
    if (shortcut.shift) keys.add(isMac ? '⇧' : 'Shift');
    keys.add(shortcut.keyLabel.toUpperCase());

    final badgeBg = widget.isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;
    final badgeBorder = widget.isDarkMode ? Colors.white12 : Colors.black12;
    final badgeText = widget.isDarkMode ? Colors.white : Colors.black87;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: keys
          .map((k) => Container(
                margin: const EdgeInsets.only(left: 4),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: badgeBorder),
                  boxShadow: [
                    BoxShadow(
                      color: widget.isDarkMode ? Colors.black26 : Colors.black12,
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    )
                  ],
                ),
                child: Text(
                  k,
                  style: TextStyle(
                    color: badgeText,
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
