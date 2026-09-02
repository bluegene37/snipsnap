// QA evidence helper: saves a Flutter Driver surface screenshot of the running
// app to disk. Pairs with tool/qa_driver_main.dart. Run with:
//   dart run tool/qa_screenshot.dart <vm-service-ws-uri> <out.png>
// Only the app surface is captured, never the desktop.
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/qa_screenshot.dart <ws-uri> <out.png>');
    exit(64);
  }
  final driver = await FlutterDriver.connect(
    dartVmServiceUrl: args[0],
    printCommunication: false,
    logCommunicationToFile: false,
  );
  try {
    final bytes = await driver.screenshot();
    await File(args[1]).writeAsBytes(bytes);
    stdout.writeln('wrote ${args[1]} (${bytes.length} bytes)');
  } finally {
    await driver.close();
  }
}
