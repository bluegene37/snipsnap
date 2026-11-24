// Gene - Nov, 08, 2026: Native Windows C++ handler for `snipsnap/capture` (fast GDI/WIC screen capture, interactive overlay, native clipboard, and Media Foundation H.264 screen recording).
#ifndef RUNNER_CAPTURE_HANDLER_H_
#define RUNNER_CAPTURE_HANDLER_H_

// Gene - Nov, 24, 2026: Added HandleCaptureWindowMessage for native Win32 hotkeys, tray icon, close-to-tray, and single-instance activation.
// Old implementation:
// #include <flutter/flutter_engine.h>
//
// // Registers the `snipsnap/capture` MethodChannel on the Windows FlutterEngine.
// // Must be called on the platform thread after the engine is initialized.
// void RegisterCaptureHandler(flutter::FlutterEngine* engine);
//
// // Tears down active capture overlays, recording threads, and releases the
// // engine pointer before `FlutterWindow::OnDestroy` destroys the engine.
// void ShutdownCaptureHandler();
#include <windows.h>

#include <flutter/flutter_engine.h>

// Registers the `snipsnap/capture` MethodChannel on the Windows FlutterEngine.
// Must be called on the platform thread after the engine is initialized.
void RegisterCaptureHandler(flutter::FlutterEngine* engine);

// Handles native Win32 messages (WM_HOTKEY, tray icon, close-to-tray, and
// single-instance show) before Flutter's top-level proc. Returns true when handled.
bool HandleCaptureWindowMessage(HWND hwnd, UINT message, WPARAM wparam,
                                LPARAM lparam, LRESULT* out_result);

// Tears down active capture overlays, recording threads, and releases the
// engine pointer before `FlutterWindow::OnDestroy` destroys the engine.
void ShutdownCaptureHandler();

#endif  // RUNNER_CAPTURE_HANDLER_H_
