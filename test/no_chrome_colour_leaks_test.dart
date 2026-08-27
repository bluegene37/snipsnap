import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `.dart` file under `lib/views/`, discovered rather than hardcoded.
///
/// A static allowlist can only guard files that existed when the list was
/// written — a new dialog or panel added later would simply be absent from
/// it, and the guard would pass while quietly not checking anything. Walking
/// the directory means every file under `lib/views/` is in scope forever,
/// including ones that don't exist yet.
List<String> _viewFiles() {
  final dir = Directory('lib/views');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.dart'))
      .toList();
}

void main() {
  test('no view references a deleted chrome colour', () {
    final offenders = <String>[];
    for (final path in _viewFiles()) {
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
    expect(
      offenders,
      isEmpty,
      reason:
          'chrome colour must come from SnipTheme:\n${offenders.join('\n')}',
    );
  });

  test('no view branches on an isDarkMode boolean', () {
    final offenders = <String>[];
    for (final path in _viewFiles()) {
      if (File(path).readAsStringSync().contains('isDarkMode')) {
        offenders.add(path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'state must come from SnipTheme.of(context):\n${offenders.join('\n')}',
    );
  });

  test('annotation colour data survives', () {
    final source = File('lib/utils/constants.dart').readAsStringSync();
    expect(
      source,
      contains('palette'),
      reason: 'annotation swatches are data and must not be deleted',
    );
    expect(
      source,
      contains('framingGradients'),
      reason:
          'export framing gradients are user-selected and must not be deleted',
    );
  });
}
