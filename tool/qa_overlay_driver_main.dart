// QA harness: the adjustable capture-region overlay hosted in a normal window
// with the Flutter Driver extension enabled, so /qa can drive it engine-level
// without a real screen grab. Mirrors tool/capture_overlay_preview.dart.
// Run with:
//   flutter run -d macos -t tool/qa_overlay_driver_main.dart
// Never ship this target; it is driver-instrumented.
import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:snipsnap/views/capture/capture_overlay.dart';

void main() {
  enableFlutterDriverExtension();
  runApp(const _OverlayHarness());
}

class _OverlayHarness extends StatefulWidget {
  const _OverlayHarness();

  @override
  State<_OverlayHarness> createState() => _OverlayHarnessState();
}

class _OverlayHarnessState extends State<_OverlayHarness> {
  String _lastEvent = 'none';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: Container(color: const Color(0xFFD9CFC0)),
            ),
            Positioned(
              left: 24,
              top: 24,
              child: Text('harness-event: $_lastEvent',
                  style: const TextStyle(fontSize: 16)),
            ),
            Positioned.fill(
              child: CaptureOverlay(
                devicePixelRatio: 2.0,
                onCapture: (r) => setState(() => _lastEvent = 'capture $r'),
                onCancel: () => setState(() => _lastEvent = 'cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
