import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../services/update/update_controller.dart';
import '../../services/update/update_service.dart';
import '../../utils/snip_theme.dart';

/// Header icon that runs a user-triggered update check. When an update is
/// found the [UpdateGate] listener opens the dialog; this button only gives
/// feedback for the quiet outcomes (up to date, offline).
class UpdateCheckButton extends StatelessWidget {
  const UpdateCheckButton({super.key, required this.controller});

  final UpdateController controller;

  Future<void> _check(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await controller.checkManually();

    final status = controller.lastResult?.status;
    if (status == UpdateStatus.upToDate) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${AppInfo.appName} ${controller.currentVersion} is up to date.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (status == UpdateStatus.failed) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not check for updates. Are you online?'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final isChecking = controller.isChecking;
        // Sized and bordered to match the HeaderBar's other 36x36 buttons.
        return Tooltip(
          message: 'Check for Updates',
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 0,
              padding: EdgeInsets.zero,
              minimumSize: const Size(36, 36),
              backgroundColor: Colors.transparent,
              foregroundColor: t.ink,
              disabledBackgroundColor: Colors.transparent,
              side: BorderSide(color: t.border, width: t.hairline),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: isChecking ? null : () => _check(context),
            child: isChecking
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: t.inkMuted,
                    ),
                  )
                : const Icon(Icons.system_update_alt_rounded, size: 16),
          ),
        );
      },
    );
  }
}
