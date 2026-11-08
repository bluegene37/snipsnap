// Gene - Nov, 08, 2026: Native Windows C++ handler for `snipsnap/capture` (fast GDI/WIC screen capture, interactive overlay, native clipboard, and Media Foundation H.264 screen recording).
#ifndef RUNNER_CAPTURE_HANDLER_H_
#define RUNNER_CAPTURE_HANDLER_H_

#include <flutter/flutter_engine.h>

// Registers the `snipsnap/capture` MethodChannel on the Windows FlutterEngine.
// Must be called on the platform thread after the engine is initialized.
void RegisterCaptureHandler(flutter::FlutterEngine* engine);

// Tears down active capture overlays, recording threads, and releases the
// engine pointer before `FlutterWindow::OnDestroy` destroys the engine.
void ShutdownCaptureHandler();

#endif  // RUNNER_CAPTURE_HANDLER_H_
