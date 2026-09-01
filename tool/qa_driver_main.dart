// QA harness entrypoint: the real app with the Flutter Driver extension
// enabled so /qa can tap widgets and take surface screenshots reliably.
// Run with:
//   flutter run -d macos -t tool/qa_driver_main.dart
// Never ship this target; it is driver-instrumented.
import 'package:flutter_driver/driver_extension.dart';
import 'package:snipsnap/main.dart' as app;

void main() {
  enableFlutterDriverExtension();
  app.main();
}
