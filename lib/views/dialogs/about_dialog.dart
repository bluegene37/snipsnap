import 'package:flutter/material.dart';
import '../../utils/snip_theme.dart';

class AboutSnipSnapDialog extends StatelessWidget {
  const AboutSnipSnapDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // App Icon Logo
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  // Decorative elevation shadow under the app icon, sitting
                  // on this dialog's own t.surface panel — ink is this
                  // design's only "mark" tone, so the shadow now traces the
                  // logo's own chrome fallback colour (ink) rather than an
                  // accent hue that no longer exists.
                  BoxShadow(
                    color: t.ink.withValues(alpha: 0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/images/app_logo.png',
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, err, stack) => Container(
                    color: t.ink,
                    child: Icon(Icons.camera_rounded, color: t.onActive, size: 40),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // App Name & Version
            Text(
              'SnipSnap',
              style: TextStyle(
                color: t.ink,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Version 1.0.0 (Build 1)',
              style: TextStyle(color: t.inkMuted, fontSize: 13),
            ),

            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'SnipSnap is a powerful, high-performance desktop screen capture & annotation tool built with Flutter & Drift SQLite.',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.ink, fontSize: 13, height: 1.4),
              ),
            ),

            const SizedBox(height: 16),
            Text(
              'Copyright © 2026 SnipSnap. All rights reserved.',
              style: TextStyle(color: t.inkMuted, fontSize: 11),
            ),

            const SizedBox(height: 20),
            // The dialog's one CTA — emphasis is a border/text-only token,
            // never a fill (Task 3's corrected precedent).
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: t.surfaceRaised,
                foregroundColor: t.emphasis,
                side: BorderSide(color: t.emphasis, width: 1.2),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
