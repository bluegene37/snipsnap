# Windows OCR — first build checklist

`windows/runner/ocr_handler.{h,cpp}` implements the `snipsnap/ocr` method channel
against `Windows.Media.Ocr`. It was written and reviewed on macOS.

**It has never been compiled and never been run.** There was no MSVC, Windows SDK
or C++/WinRT available when it was written. Treat the first build as debugging,
not verification.

Note also that `windows/runner/CMakeLists.txt` and `flutter_window.cpp` are now
edited, so a compile failure here breaks the **whole** Windows build — which was
green before this work.

## Check in this order

1. **`_HAS_EXCEPTIONS=0` vs C++/WinRT.** `windows/CMakeLists.txt`'s
   `APPLY_STANDARD_SETTINGS` defines it while also passing `/EHsc`, and C++/WinRT
   signals every error by throwing `winrt::hresult_error`. Reasoning says this is
   fine — it is an MSVC *STL* macro and `/EHsc` keeps language-level EH on — but it
   is the most likely first-build failure. Remedy: drop that definition before
   splitting the file into its own target.

2. **`/W4 /WX` over the WinRT projection headers.** One warning anywhere in them
   fails the build. Remedy: `#pragma warning(push, 0)` around the includes, or
   `/external:W0`.

3. **`CoIncrementMTAUsage`** — assumed `<combaseapi.h>`, `CO_MTA_USAGE_COOKIE*`,
   `HRESULT`. `ole32.lib` is not explicitly linked; it is almost certainly present
   via MSVC defaults, and would fail loudly at link time if not. Deleting
   `PinProcessMta` entirely costs performance, never correctness.

4. **`SoftwareBitmap::Convert` / `GetSoftwareBitmapAsync()` default format**, then
   `DataWriter::DetachStream()`. The two runtime-failure sites.

5. **Exercise shutdown**: trigger OCR, then close the window while the call is in
   flight. This confirms the engine gate drops the reply instead of posting to a
   destroyed engine. No Dart test can reach this path.

## The one failure a green build will not catch

`wf::Rect` is assumed to project as `{X, Y, Width, Height}`. Review confirmed that
order from `Windows.Foundation.idl`, but if it is ever wrong the code **compiles
cleanly and produces silently wrong boxes**.

So the acceptance test is not "text came back". It is **"the boxes land on the
text"**. Check that explicitly on the first successful run.
