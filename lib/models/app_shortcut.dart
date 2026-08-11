import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppShortcutAction {
  interactiveSnip,
  fullScreenSnip,
  timerSnip,
  openImage,
  copyToClipboard,
  saveAs,
  undo,
  redo,
  clearAnnotations,
  toggleHistory,
  flattenCanvas,
}

extension AppShortcutActionExtension on AppShortcutAction {
  String get displayName {
    switch (this) {
      case AppShortcutAction.interactiveSnip:
        return 'Interactive Area Snip';
      case AppShortcutAction.fullScreenSnip:
        return 'Full Screen Snip';
      case AppShortcutAction.timerSnip:
        return '3s Timer Snip';
      case AppShortcutAction.openImage:
        return 'Open Image File';
      case AppShortcutAction.copyToClipboard:
        return 'Copy to Clipboard';
      case AppShortcutAction.saveAs:
        return 'Save Image As...';
      case AppShortcutAction.undo:
        return 'Undo Annotation';
      case AppShortcutAction.redo:
        return 'Redo Annotation';
      case AppShortcutAction.clearAnnotations:
        return 'Clear All Annotations';
      case AppShortcutAction.toggleHistory:
        return 'Toggle Screenshots Panel';
      case AppShortcutAction.flattenCanvas:
        return 'Flatten Annotations';
    }
  }

  String get description {
    switch (this) {
      case AppShortcutAction.interactiveSnip:
        return 'Drag rectangle to capture portion of screen';
      case AppShortcutAction.fullScreenSnip:
        return 'Capture entire desktop display';
      case AppShortcutAction.timerSnip:
        return 'Wait 3 seconds then capture';
      case AppShortcutAction.openImage:
        return 'Import external image into editor';
      case AppShortcutAction.copyToClipboard:
        return 'Copy current annotated image to system clipboard';
      case AppShortcutAction.saveAs:
        return 'Export annotated image to local file';
      case AppShortcutAction.undo:
        return 'Revert last drawing action';
      case AppShortcutAction.redo:
        return 'Re-apply reverted drawing action';
      case AppShortcutAction.clearAnnotations:
        return 'Remove all drawings from canvas';
      case AppShortcutAction.toggleHistory:
        return 'Show or hide bottom recent captures bar';
      case AppShortcutAction.flattenCanvas:
        return 'Bake all annotations into background image';
    }
  }
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
