import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppShortcutAction {
  interactiveSnip(
    'Interactive Area Snip',
    'Drag rectangle to capture portion of screen',
  ),
  fullScreenSnip('Full Screen Snip', 'Capture entire desktop display'),
  timerSnip('3s Timer Snip', 'Wait 3 seconds then capture'),
  openImage('Open Image File', 'Import external image into editor'),
  copyToClipboard(
    'Copy to Clipboard',
    'Copy current annotated image to system clipboard',
  ),
  saveAs('Save Image As...', 'Export annotated image to local file'),
  undo('Undo Annotation', 'Revert last drawing action'),
  redo('Redo Annotation', 'Re-apply reverted drawing action'),
  clearAnnotations('Clear All Annotations', 'Remove all drawings from canvas'),
  toggleHistory(
    'Toggle Screenshots Panel',
    'Show or hide bottom recent captures bar',
  ),
  flattenCanvas(
    'Flatten Annotations',
    'Bake all annotations into background image',
  );

  final String displayName;
  final String description;

  const AppShortcutAction(this.displayName, this.description);
}

class CustomShortcut {
  final AppShortcutAction action;
  final int keyId;
  final String keyLabel;
  final bool meta;
  final bool ctrl;
  final bool shift;
  final bool alt;

  const CustomShortcut({
    required this.action,
    required this.keyId,
    required this.keyLabel,
    this.meta = false,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
  });

  LogicalKeyboardKey get logicalKey => LogicalKeyboardKey(keyId);

  SingleActivator toSingleActivator() {
    return SingleActivator(
      logicalKey,
      meta: meta,
      control: ctrl,
      shift: shift,
      alt: alt,
    );
  }

  String toDisplayString() {
    final parts = <String>[];
    final isMac = Platform.isMacOS;

    if (meta) parts.add(isMac ? '⌘' : 'Win');
    if (ctrl) parts.add(isMac ? 'Control' : 'Ctrl');
    if (alt) parts.add(isMac ? '⌥' : 'Alt');
    if (shift) parts.add(isMac ? '⇧' : 'Shift');

    parts.add(keyLabel.toUpperCase());
    return parts.join(isMac ? '' : '+');
  }

  Map<String, dynamic> toJson() {
    return {
      'action': action.name,
      'keyId': keyId,
      'keyLabel': keyLabel,
      'meta': meta,
      'ctrl': ctrl,
      'shift': shift,
      'alt': alt,
    };
  }

  factory CustomShortcut.fromJson(Map<String, dynamic> json) {
    final actionName = json['action'] as String;
    final action = AppShortcutAction.values.firstWhere(
      (a) => a.name == actionName,
      orElse: () => AppShortcutAction.interactiveSnip,
    );

    return CustomShortcut(
      action: action,
      keyId: json['keyId'] as int,
      keyLabel: json['keyLabel'] as String,
      meta: json['meta'] as bool? ?? false,
      ctrl: json['ctrl'] as bool? ?? false,
      shift: json['shift'] as bool? ?? false,
      alt: json['alt'] as bool? ?? false,
    );
  }

  CustomShortcut copyWith({
    int? keyId,
    String? keyLabel,
    bool? meta,
    bool? ctrl,
    bool? shift,
    bool? alt,
  }) {
    return CustomShortcut(
      action: action,
      keyId: keyId ?? this.keyId,
      keyLabel: keyLabel ?? this.keyLabel,
      meta: meta ?? this.meta,
      ctrl: ctrl ?? this.ctrl,
      shift: shift ?? this.shift,
      alt: alt ?? this.alt,
    );
  }
}
