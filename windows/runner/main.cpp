#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  //
  // This also serves as the platform thread's C++/WinRT apartment: an STA.
  // Do NOT add winrt::init_apartment() here — it is only a wrapper around this
  // same CoInitializeEx call, so a second one would just add an unbalanced
  // reference. Note that being an STA is why ocr_handler.cpp does all of its
  // blocking WinRT work on its own multi-threaded worker instead.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // The Windows counterpart to the macOS bundle identifier. Shell features that
  // need a stable app identity - taskbar grouping and pinning, jump lists, toast
  // notifications - key off this rather than the executable path, and the
  // installer must declare the same string. Without it Windows derives an
  // identity from the exe path, so a reinstall to a different directory looks
  // like a different app.
  ::SetCurrentProcessExplicitAppUserModelID(L"dev.genexis.snipsnap");

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1360, 850);
  if (!window.Create(L"snipsnap", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
