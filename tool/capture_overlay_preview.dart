// Throwaway harness for eyeballing the capture overlay's palette and chrome
// without triggering a real screen grab. Run with:
//   flutter run -d macos -t tool/capture_overlay_preview.dart
import 'package:flutter/material.dart';
import 'package:snipsnap/views/capture/capture_overlay.dart';

void main() => runApp(const _Preview());

class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: [
            // Stand-in for the desktop underneath.
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFF4EFE7),
                      Color(0xFFD9CFC0),
                      Color(0xFFB9AB98),
                    ],
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 60,
              top: 60,
              child: Text(
                'Desktop behind the overlay',
                style: TextStyle(fontSize: 28, color: Color(0xFF3A2E24)),
              ),
            ),
            Positioned.fill(
              child: CaptureOverlay(
                devicePixelRatio: 2.0,
                onCapture: (r) => debugPrint('capture $r'),
                onCancel: () => debugPrint('cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
