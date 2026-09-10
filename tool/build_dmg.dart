import 'dart:io';

/// Build script to package SnipSnap macOS desktop application into a polished DMG.
///
/// Usage:
///   dart run tool/build_dmg.dart [options]
///
/// Options:
///   --no-build      Skip `flutter build macos --release` and package existing .app
///   --sign `<id>`     Codesign signature identity
///   --notarize `<p>`  Notarize credentials profile name
///   --help          Show this help message
void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('''
SnipSnap DMG Packaging Utility

Usage:
  dart run tool/build_dmg.dart [options]

Options:
  --no-build           Skip `flutter build macos --release` (use current build)
  --sign <identity>    Codesign the DMG with the specified identity
  --notarize <profile> Notarize the DMG using xcrun notarytool profile
  -h, --help           Show this help message
''');
    exit(0);
  }

  final bool skipBuild = args.contains('--no-build');
  String? signIdentity;
  String? notarizeProfile;

  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--sign' && i + 1 < args.length) {
      signIdentity = args[i + 1];
    } else if (args[i] == '--notarize' && i + 1 < args.length) {
      notarizeProfile = args[i + 1];
    }
  }

  // 1. Read version and app name from pubspec.yaml
  final pubspecFile = File('pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    stderr.writeln('Error: pubspec.yaml not found in current directory.');
    exit(1);
  }

  final pubspecContent = pubspecFile.readAsStringSync();
  final versionMatch = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(pubspecContent);
  final version = versionMatch?.group(1) ?? '1.0.0';

  stdout.writeln('Packaging SnipSnap v$version for macOS...');

  // 2. Build macOS release if needed
  final appPath = 'build/macos/Build/Products/Release/SnipSnap.app';
  final appDir = Directory(appPath);

  if (!skipBuild || !appDir.existsSync()) {
    stdout.writeln('Running: flutter build macos --release');
    final buildProcess = await Process.start('flutter', [
      'build',
      'macos',
      '--release',
    ], mode: ProcessStartMode.inheritStdio);
    final exitCode = await buildProcess.exitCode;
    if (exitCode != 0) {
      stderr.writeln('Flutter build failed with exit code $exitCode');
      exit(exitCode);
    }
  } else {
    stdout.writeln('Skipping build step (--no-build). Using: $appPath');
  }

  if (!appDir.existsSync()) {
    stderr.writeln('Error: $appPath not found. Please run flutter build macos --release first.');
    exit(1);
  }

  // 3. Ensure output directory exists
  final distDir = Directory('dist');
  if (!distDir.existsSync()) {
    distDir.createSync(recursive: true);
  }

  final dmgName = 'SnipSnap-$version.dmg';
  final dmgPath = 'dist/$dmgName';
  final dmgFile = File(dmgPath);
  if (dmgFile.existsSync()) {
    dmgFile.deleteSync();
  }

  // 4. Prepare clean staging directory containing SnipSnap.app
  final stagingDir = Directory('build/dmg_staging');
  if (stagingDir.existsSync()) {
    stagingDir.deleteSync(recursive: true);
  }
  stagingDir.createSync(recursive: true);

  final stagedAppPath = 'build/dmg_staging/SnipSnap.app';
  stdout.writeln('Staging application bundle to $stagedAppPath...');
  final cpResult = await Process.run('cp', ['-R', appPath, stagedAppPath]);
  if (cpResult.exitCode != 0) {
    stderr.writeln('Failed to stage app: ${cpResult.stderr}');
    exit(cpResult.exitCode);
  }

  // 5. Locate create-dmg or fallback to hdiutil
  String? createDmgPath;
  for (final candidate in [
    '/opt/homebrew/bin/create-dmg',
    '/usr/local/bin/create-dmg',
    'create-dmg',
  ]) {
    final whichCheck = await Process.run('which', [candidate]);
    if (whichCheck.exitCode == 0) {
      createDmgPath = whichCheck.stdout.toString().trim();
      break;
    }
  }

  final iconPath = File('macos/Runner/AppIcon.icns').existsSync()
      ? 'macos/Runner/AppIcon.icns'
      : null;

  try {
    if (createDmgPath != null && createDmgPath.isNotEmpty) {
      stdout.writeln('Using create-dmg ($createDmgPath)...');
      final createDmgArgs = <String>[
        '--volname',
        'SnipSnap Installer',
        if (iconPath != null) ...['--volicon', iconPath],
        '--window-pos',
        '200',
        '120',
        '--window-size',
        '600',
        '380',
        '--icon-size',
        '110',
        '--text-size',
        '13',
        '--icon',
        'SnipSnap.app',
        '160',
        '175',
        '--app-drop-link',
        '440',
        '175',
        '--hide-extension',
        'SnipSnap.app',
        '--no-internet-enable',
      ];

      if (signIdentity != null) {
        createDmgArgs.addAll(['--codesign', signIdentity]);
      }
      if (notarizeProfile != null) {
        createDmgArgs.addAll(['--notarize', notarizeProfile]);
      }

      createDmgArgs.addAll([dmgPath, 'build/dmg_staging']);

      final proc = await Process.start(
        createDmgPath,
        createDmgArgs,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await proc.exitCode;
      if (code != 0 && code != 2) {
        // create-dmg sometimes exits with 2 for non-fatal AppleScript quirks
        stderr.writeln('Warning: create-dmg finished with code $code');
      }
    } else {
      stdout.writeln('create-dmg not found. Falling back to native macOS hdiutil...');
      final proc = await Process.run('hdiutil', [
        'create',
        '-volname',
        'SnipSnap',
        '-srcfolder',
        'build/dmg_staging',
        '-ov',
        '-format',
        'UDZO',
        dmgPath,
      ]);
      if (proc.exitCode != 0) {
        stderr.writeln('hdiutil failed: ${proc.stderr}');
        exit(proc.exitCode);
      }
    }
  } finally {
    if (stagingDir.existsSync()) {
      stagingDir.deleteSync(recursive: true);
    }
  }

  if (dmgFile.existsSync()) {
    final bytes = dmgFile.lengthSync();
    final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
    stdout.writeln('\nSUCCESS: DMG created at $dmgPath ($mb MB)');

    // Create a convenient generic symlink / copy for 'SnipSnap.dmg'
    final genericFile = File('dist/SnipSnap.dmg');
    if (genericFile.existsSync()) {
      genericFile.deleteSync();
    }
    try {
      Link('dist/SnipSnap.dmg').createSync(dmgName);
    } catch (_) {
      dmgFile.copySync('dist/SnipSnap.dmg');
    }
  } else {
    stderr.writeln('Error: Failed to create DMG output at $dmgPath');
    exit(1);
  }
}
