import 'package:flutter/material.dart';
import '../../utils/snip_theme.dart';

class AboutSnipSnapDialog extends StatelessWidget {
  const AboutSnipSnapDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

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
          children: [
            // App Icon Logo (Nano Banana / Gemini asset)
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset(
                  'assets/images/app_logo.png',
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, err, stack) => ColoredBox(
                    color: t.ink,
                    child: Icon(
                      Icons.camera_rounded,
                      color: t.onActive,
                      size: 40,
                    ),
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
                border: Border.all(color: t.border),
              ),
              child: Text(
                'SnipSnap is a powerful, high-performance desktop screen capture & annotation tool built with Flutter & Drift SQLite.',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.ink, fontSize: 13, height: 1.4),
              ),
            ),

            const SizedBox(height: 14),

            // Feature Highlights Chips
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _featureChip(t, 'Vector Annotations', Icons.gesture_rounded),
                _featureChip(
                  t,
                  'OCR Extraction',
                  Icons.document_scanner_rounded,
                ),
                _featureChip(t, 'Drift SQLite', Icons.storage_rounded),
                _featureChip(t, 'High-DPI Capture', Icons.hd_rounded),
              ],
            ),

            const SizedBox(height: 16),
            Text(
              'Copyright © 2026 genexis.dev. All rights reserved.',
              style: TextStyle(color: t.inkMuted, fontSize: 11),
            ),

            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: t.surfaceRaised,
                foregroundColor: t.emphasis,
                side: BorderSide(color: t.emphasis, width: 1.2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Close',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _featureChip(SnipTheme t, String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: t.emphasis),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: t.ink,
            ),
          ),
        ],
      ),
    );
  }
}
