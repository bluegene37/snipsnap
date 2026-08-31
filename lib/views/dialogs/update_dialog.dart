import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../services/update/update_controller.dart';
import '../../utils/snip_theme.dart';

/// Modal shown when a newer release is available. Offers install/download,
/// a session-only "Later", and a persistent "Skip this version".
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final update = controller.availableUpdate;
        if (update == null) {
          // Update dismissed while the dialog was open (e.g. install handoff).
          return const SizedBox.shrink();
        }
        final silentInstall = controller.canInstallDirectly;

        return Dialog(
          backgroundColor: t.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: t.border),
          ),
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.system_update_alt_rounded, color: t.emphasis),
                    const SizedBox(width: 12),
                    Text(
                      'Update Available',
                      style: TextStyle(
                        color: t.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '${AppInfo.appName} ${update.version} is available. '
                  'You are on ${controller.currentVersion}.',
                  style: TextStyle(color: t.ink, fontSize: 13.5),
                ),
                const SizedBox(height: 8),
                Text(
                  silentInstall
                      ? 'The update installs in the background and the app '
                            'restarts automatically.'
                      : 'The download page opens in your browser.',
                  style: TextStyle(color: t.inkMuted, fontSize: 12.5),
                ),
                if (controller.isDownloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: controller.downloadProgress,
                    backgroundColor: t.surfaceRaised,
                    color: t.emphasis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Downloading… '
                    '${(controller.downloadProgress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(color: t.inkMuted, fontSize: 12),
                  ),
                ],
                if (controller.installError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Update failed: ${controller.installError}. '
                    'Use the release page to download it manually.',
                    style: TextStyle(color: t.danger, fontSize: 12.5),
                  ),
                  // The advertised fallback must be reachable from here, not
                  // just described.
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: t.emphasis,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => controller.openReleasePage(),
                    child: const Text('Open release page'),
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: t.inkMuted),
                      onPressed: controller.isDownloading
                          ? null
                          : () async {
                              final navigator = Navigator.of(context);
                              await controller.skipAvailableVersion();
                              navigator.pop();
                            },
                      child: const Text('Skip this version'),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: t.inkMuted),
                      onPressed: controller.isDownloading
                          ? null
                          : () {
                              controller.dismiss();
                              Navigator.of(context).pop();
                            },
                      child: const Text('Later'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.surfaceRaised,
                        foregroundColor: t.emphasis,
                        side: BorderSide(color: t.emphasis, width: 1.2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
                      ),
                      onPressed: controller.isDownloading
                          ? null
                          : () => controller.applyUpdate(),
                      child: Text(
                        silentInstall ? 'Install & Restart' : 'Download',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
