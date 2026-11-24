cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
# Gene - Nov, 08, 2026: Added capture_handler.cpp to Windows runner executable sources.
# add_executable(${BINARY_NAME} WIN32
#   "flutter_window.cpp"
#   "main.cpp"
#   "ocr_handler.cpp"
#   "utils.cpp"
#   "win32_window.cpp"
#   "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
#   "Runner.rc"
#   "runner.exe.manifest"
# )
# Gene - Nov, 20, 2026: Added scrolling_capture_engine.cpp and Rust snipsnap_core staticlib build/link rules.
# Old implementation:
# add_executable(${BINARY_NAME} WIN32
#   "capture_handler.cpp"
#   "flutter_window.cpp"
#   "main.cpp"
#   "ocr_handler.cpp"
#   "utils.cpp"
#   "win32_window.cpp"
#   "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
#   "Runner.rc"
#   "runner.exe.manifest"
# )
# Gene - Nov, 24, 2026: Added dxgi_capture.cpp for fast DXGI Desktop Duplication & persistent GDI fallback capture.
# Old implementation:
# add_executable(${BINARY_NAME} WIN32
#   "capture_handler.cpp"
#   "scrolling_capture_engine.cpp"
#   "flutter_window.cpp"
#   "main.cpp"
#   "ocr_handler.cpp"
#   "utils.cpp"
#   "win32_window.cpp"
#   "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
#   "Runner.rc"
#   "runner.exe.manifest"
# )
add_executable(${BINARY_NAME} WIN32
  "capture_handler.cpp"
  "dxgi_capture.cpp"
  "scrolling_capture_engine.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "ocr_handler.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# C++/WinRT (ocr_handler.cpp) needs coroutine support. Under the standard
# settings' C++17 it reaches for <experimental/coroutine>, which MSVC 14.51+
# rejects outright (STL1011); C++20 gives it the standard <coroutine> instead.
# Overrides the cxx_std_17 from apply_standard_settings for this target only.
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
# Gene - Nov, 13, 2026: Link flutter_wrapper_plugin alongside flutter_wrapper_app so PluginRegistrarManager and PluginRegistrarWindows symbols in capture_handler.cpp resolve at link time.
# target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# SetCurrentProcessExplicitAppUserModelID, called from main.cpp.
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
# C++/WinRT, for the Windows.Media.Ocr implementation in ocr_handler.cpp.
# windowsapp.lib is the umbrella import library for the WinRT API surface
# (RoActivateInstance, WindowsCreateString and friends).
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
# Gene - Nov, 08, 2026: Link Windows Imaging Component (WIC) and Media Foundation libraries for native C++ screen capture, clipboard, and H.264 screen recording.
# Gene - Nov, 13, 2026: Added mmdevapi.lib, mf.lib, and msimg32.lib for WASAPI audio mixing, Media Foundation transcoding, and alpha-blended click/toolbar rendering.
# Old implementation:
# target_link_libraries(${BINARY_NAME} PRIVATE "windowscodecs.lib" "mfplat.lib" "mfreadwrite.lib" "mfuuid.lib" "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "windowscodecs.lib" "mfplat.lib" "mfreadwrite.lib" "mfuuid.lib" "mf.lib" "mmdevapi.lib" "msimg32.lib" "ole32.lib")

# Gene - Nov, 20, 2026: Build and link Rust snipsnap_core staticlib + D3D11/DXGI/Rust-std import libraries.
find_program(CARGO_EXECUTABLE NAMES cargo PATHS "$ENV{USERPROFILE}/.cargo/bin" REQUIRED)
set(SNIPSNAP_CORE_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/Cargo.toml")
set(SNIPSNAP_CORE_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/rust_target")
set(SNIPSNAP_CORE_LIB "${SNIPSNAP_CORE_TARGET_DIR}/x86_64-pc-windows-msvc/release/snipsnap_core.lib")
set(SNIPSNAP_CORE_DLL "${SNIPSNAP_CORE_TARGET_DIR}/x86_64-pc-windows-msvc/release/snipsnap_core.dll")
# Gene - Nov, 24, 2026: Track capture_ops.rs in Rust build dependencies.
# Old implementation:
# add_custom_command(
#   OUTPUT "${SNIPSNAP_CORE_LIB}" "${SNIPSNAP_CORE_DLL}"
#   COMMAND "${CARGO_EXECUTABLE}" build --manifest-path "${SNIPSNAP_CORE_MANIFEST}" --release --target x86_64-pc-windows-msvc --target-dir "${SNIPSNAP_CORE_TARGET_DIR}"
#   DEPENDS
#     "${SNIPSNAP_CORE_MANIFEST}"
#     "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/include/snipsnap_core.h"
#     "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/lib.rs"
#     "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/stitcher.rs"
#     "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/image_ops.rs"
#     "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/ffi.rs"
#   COMMENT "Building Rust snipsnap_core staticlib (x86_64-pc-windows-msvc)"
#   VERBATIM
# )
add_custom_command(
  OUTPUT "${SNIPSNAP_CORE_LIB}" "${SNIPSNAP_CORE_DLL}"
  COMMAND "${CARGO_EXECUTABLE}" build --manifest-path "${SNIPSNAP_CORE_MANIFEST}" --release --target x86_64-pc-windows-msvc --target-dir "${SNIPSNAP_CORE_TARGET_DIR}"
  DEPENDS
    "${SNIPSNAP_CORE_MANIFEST}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/include/snipsnap_core.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/lib.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/capture_ops.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/stitcher.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/image_ops.rs"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/src/ffi.rs"
  COMMENT "Building Rust snipsnap_core staticlib (x86_64-pc-windows-msvc)"
  VERBATIM
)
# Gene - Nov, 22, 2026: Track both snipsnap_core.lib and snipsnap_core.dll in snipsnap_core_rust target and link synchronization.lib for Rust std on Windows.
# Old implementation:
# add_custom_target(snipsnap_core_rust ALL DEPENDS "${SNIPSNAP_CORE_LIB}")
# add_dependencies(${BINARY_NAME} snipsnap_core_rust)
#
# target_link_libraries(${BINARY_NAME} PRIVATE
#   "${SNIPSNAP_CORE_LIB}"
#   "d3d11.lib"
#   "dxgi.lib"
#   "ws2_32.lib"
#   "userenv.lib"
#   "bcrypt.lib"
#   "ntdll.lib"
#   "advapi32.lib"
# )
add_custom_target(snipsnap_core_rust ALL DEPENDS "${SNIPSNAP_CORE_LIB}" "${SNIPSNAP_CORE_DLL}")
add_dependencies(${BINARY_NAME} snipsnap_core_rust)

target_link_libraries(${BINARY_NAME} PRIVATE
  "${SNIPSNAP_CORE_LIB}"
  "d3d11.lib"
  "dxgi.lib"
  "ws2_32.lib"
  "userenv.lib"
  "bcrypt.lib"
  "ntdll.lib"
  "advapi32.lib"
  "synchronization.lib"
)
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/snipsnap_core/include"
)

# Gene - Nov, 20, 2026: Copy snipsnap_core.dll beside snipsnap.exe so dart:ffi DynamicLibrary.open('snipsnap_core.dll') works seamlessly at runtime.
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${SNIPSNAP_CORE_DLL}"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/snipsnap_core.dll"
  COMMENT "Copying snipsnap_core.dll alongside executable"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
