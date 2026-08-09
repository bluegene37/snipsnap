import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class AboutSnipSnapDialog extends StatelessWidget {
  final bool isDarkMode;

  const AboutSnipSnapDialog({super.key, this.isDarkMode = true});

  @override
  Widget build(BuildContext context) {
    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = isDarkMode ? Colors.white70 : Colors.black54;
    final cardBg = isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;

    return Dialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // App Icon Logo
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.accent, Color(0xFFFF8E53)],
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(Icons.camera_rounded, color: Colors.white, size: 40),
            ),

            const SizedBox(height: 16),

            // App Name & Version
            Text(
              'SnipSnap',
              style: TextStyle(
                color: textColor,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Version 1.0.0 (Build 1)',
              style: TextStyle(color: subTextColor, fontSize: 13),
            ),

            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'SnipSnap is a powerful, high-performance desktop screen capture & annotation tool built with Flutter & Drift SQLite.',
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor, fontSize: 13, height: 1.4),
              ),
            ),

            const SizedBox(height: 16),
            Text(
              'Copyright © 2026 SnipSnap. All rights reserved.',
              style: TextStyle(color: subTextColor, fontSize: 11),
            ),

            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
