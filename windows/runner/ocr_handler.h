#ifndef RUNNER_OCR_HANDLER_H_
#define RUNNER_OCR_HANDLER_H_

#include <flutter/flutter_engine.h>

// Registers the `snipsnap/ocr` channel against Windows.Media.Ocr.
//
// Must be called on the platform thread, once, after the engine exists.
void RegisterOcrHandler(flutter::FlutterEngine* engine);

// Tells the handler that |engine| is about to be destroyed.
//
// Recognition runs on worker threads that post their replies back to the
// platform thread through the engine. Once the engine is gone that pointer is
// dangling, so this must be called on the platform thread *before* the engine
// is torn down. After it returns, in-flight workers drop their replies instead
// of touching the engine.
void ShutdownOcrHandler();

#endif  // RUNNER_OCR_HANDLER_H_
