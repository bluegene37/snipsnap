import 'dart:typed_data';

import 'ocr_engine.dart';

/// Used where no OCR engine ships with the OS. Reports why rather than
/// failing at call time, so the UI can disable the tool with an explanation.
class UnavailableOcrEngine implements OcrEngine {
  final String reason;

  const UnavailableOcrEngine(this.reason);

  @override
  Future<OcrAvailability> availability() async =>
      OcrAvailability.unavailable(reason);

  @override
  Future<OcrResult> recognize(Uint8List pngBytes) async => OcrResult.empty;
}
