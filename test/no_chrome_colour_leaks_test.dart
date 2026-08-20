import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files whose chrome must be entirely token-driven.
const _viewFiles = [
  'lib/views/main_screen.dart',
  'lib/views/editor_canvas.dart',
  'lib/views/gallery_sidebar.dart',
  'lib/views/components/tool_sidebar.dart',
  'lib/views/components/header_bar.dart',
  'lib/views/components/style_picker.dart',
  'lib/views/components/ocr_result_panel.dart',
  'lib/views/components/crop_overlay_widget.dart',
  'lib/views/dialogs/save_as_dialog.dart',
  'lib/views/dialogs/shortcut_settings_dialog.dart',
  'lib/views/dialogs/about_dialog.dart',
];

void main() {
  test('no view references a deleted chrome colour', () {
    final offenders = <String>[];
    for (final path in _viewFiles) {
      final source = File(path).readAsStringSync();
      for (final banned in const [
        'AppColors.accent',
        'AppColors.accentHover',
        'AppColors.blueAccent',
        'AppColors.greenAccent',
        'AppColors.darkBg',
        'AppColors.darkSurface',
        'AppColors.lightBg',
        'AppColors.lightSurface',
        'AppColors.sidebarBg',
        'AppColors.canvasBg',
      ]) {
        if (source.contains(banned)) offenders.add('$path → $banned');
      }
    }
    expect(offenders, isEmpty,
        reason: 'chrome colour must come from SnipTheme:\n${offenders.join('\n')}');
  });

  test('no view branches on an isDarkMode boolean', () {
    final offenders = <String>[];
    for (final path in _viewFiles) {
      if (File(path).readAsStringSync().contains('isDarkMode')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'state must come from SnipTheme.of(context):\n${offenders.join('\n')}');
  });

  test('annotation colour data survives', () {
    final source = File('lib/utils/constants.dart').readAsStringSync();
    expect(source, contains('palette'),
        reason: 'annotation swatches are data and must not be deleted');
    expect(source, contains('framingGradients'),
        reason: 'export framing gradients are user-selected and must not be deleted');
  });
}
