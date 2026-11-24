// Gene - Nov, 08, 2026: Native Windows C++ implementation for `snipsnap/capture`:
// - <15ms Full-Screen & Region capture via Win32 BitBlt + WIC PNG encoder (replaces PowerShell)
// - Native Win32 Interactive Capture & Recording Overlay with 8 resize grips, dimension badge, [Capture], [Record], and [Cancel] buttons
// - <5ms Native Win32 Clipboard image/file copy & paste (CF_DIB, PNG format, CF_HDROP)
// - Native Windows Screen & Area Recording via Media Foundation IMFSinkWriter (H.264 MP4) with WDA_EXCLUDEFROMCAPTURE floating HUD
// - Video Frame Extraction & Video Trimming via IMFSourceReader / IMFSinkWriter

#include "capture_handler.h"

// Gene - Nov, 13, 2026: Added WASAPI audio headers, Flutter plugin registrar/texture registrar headers, and helpers for window visibility, URI encoding, and audio device enumeration.
// Old implementation:
// #include <windows.h>
// #include <windowsx.h>
// #include <shlobj.h>
// #include <wincodec.h>
// #include <mfapi.h>
// #include <mfidl.h>
// #include <mfreadwrite.h>
// #include <mferror.h>
// #include <wrl/client.h>
//
// #include <flutter/method_channel.h>
// #include <flutter/standard_method_codec.h>
//
// #include <algorithm>
// #include <atomic>
// #include <chrono>
// #include <cmath>
// #include <cstring>
// #include <functional>
// #include <memory>
// #include <mutex>
// #include <sstream>
// #include <string>
// #include <thread>
// #include <vector>
#include <windows.h>
// Gene - Nov, 22, 2026: Explicitly include oleauto.h (for VariantInit) and climits (for INT_MAX/UINT_MAX overflow checks).
#include <oleauto.h>
#include <windowsx.h>
#include <shlobj.h>
// Gene - Nov, 24, 2026: Added dwmapi, knownfolders, shellapi, dxgi_capture, resource, and snipsnap_core headers for DXGI capture, native hotkeys, tray icon, dark titlebar, Known Folders, and Rust pixel/audio ops.
#include <dwmapi.h>
#include <knownfolders.h>
#include <shellapi.h>
#include <wincodec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
// Gene - Nov, 13, 2026: Explicitly include propsys.h and mmreg.h for IPropertyStore and WAVEFORMATEXTENSIBLE across Windows SDK versions.
#include <propsys.h>
#include <mmreg.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <wrl/client.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <algorithm>
// Gene - Nov, 24, 2026: Include <array> for WinVideoTexturePlayer::decode_pool.
#include <array>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

// Gene - Nov, 20, 2026: Native Windows scrolling capture engine backed by Rust snipsnap_core staticlib.
#include "dxgi_capture.h"
#include "resource.h"
#include "scrolling_capture_engine.h"
#include "snipsnap_core.h"

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
// Gene - Nov, 24, 2026: Avoid redefining <dwmapi.h> enum DWMWA_USE_IMMERSIVE_DARK_MODE as a preprocessor macro across Windows SDK versions.
// #ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
// #define DWMWA_USE_IMMERSIVE_DARK_MODE 20
// #endif
#ifndef MOD_NOREPEAT
#define MOD_NOREPEAT 0x4000
#endif
#ifndef CF_DIBV5
#define CF_DIBV5 17
#endif

namespace {

constexpr DWORD kDwmwaUseImmersiveDarkMode = 20;
constexpr DWORD kDwmwaUseImmersiveDarkModeLegacy = 19;

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
using CaptureMethodResult = flutter::MethodResult<EncodableValue>;

constexpr char kChannelName[] = "snipsnap/capture";
std::unique_ptr<ScrollingCaptureEngine> g_scrolling_engine;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int count = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                    static_cast<int>(utf8.size()), nullptr, 0);
  if (count <= 0) return std::wstring();
  std::wstring wide(count, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), count);
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int count = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                    static_cast<int>(wide.size()), nullptr, 0,
                                    nullptr, nullptr);
  if (count <= 0) return std::string();
  std::string utf8(count, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        utf8.data(), count, nullptr, nullptr);
  return utf8;
}

// Gene - Nov, 13, 2026: Extended EngineGate with PluginRegistrarWindows/TextureRegistrar, added UriEncodeUtf8, SetMainWindowVisible, and WASAPI audio input device enumeration.
// Old implementation:
// struct EngineGate {
//   std::mutex mutex;
//   flutter::FlutterEngine* engine = nullptr;
//   std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
// };
struct EngineGate {
  std::mutex mutex;
  flutter::FlutterEngine* engine = nullptr;
  flutter::PluginRegistrarWindows* registrar = nullptr;
  flutter::TextureRegistrar* texture_registrar = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
};

std::shared_ptr<EngineGate>& Gate() {
  static std::shared_ptr<EngineGate> gate;
  return gate;
}

std::string UriEncodeUtf8(const std::string& input) {
  static constexpr char kHex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(input.size() * 3);
  for (unsigned char c : input) {
    bool is_unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                         (c >= '0' && c <= '9') || c == '-' || c == '_' ||
                         c == '.' || c == '~';
    if (is_unreserved) {
      out.push_back(static_cast<char>(c));
    } else {
      out.push_back('%');
      out.push_back(kHex[(c >> 4) & 0x0F]);
      out.push_back(kHex[c & 0x0F]);
    }
  }
  return out;
}

// Gene - Nov, 24, 2026: Added reliable foreground activation, DWM dark titlebar sync, Known Folder Desktop lookup, native WM_HOTKEY + precapture, tray icon, and async audio cache.
constexpr UINT kMsgTrayIcon = WM_APP + 201;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayCmdOpen = 4001;
constexpr UINT kTrayCmdArea = 4002;
constexpr UINT kTrayCmdFull = 4003;
constexpr UINT kTrayCmdScroll = 4004;
constexpr UINT kTrayCmdRecord = 4005;
constexpr UINT kTrayCmdToggleTray = 4006;
constexpr UINT kTrayCmdQuit = 4007;

HWND g_main_hwnd = nullptr;
bool g_tray_registered = false;
UINT g_show_window_msg = 0;
std::atomic<bool> g_close_to_tray{true};
std::atomic<bool> g_force_quit{false};
std::atomic<bool> g_overlay_active{false};

struct NativeHotKeyEntry {
  int id = 0;
  std::string action;
  UINT vk = 0;
  UINT mods = 0;
};
std::mutex g_hotkey_mutex;
std::map<int, NativeHotKeyEntry> g_native_hotkeys;
int g_next_hotkey_id = 1000;

struct PrecaptureSnapshot {
  bool valid = false;
  std::chrono::steady_clock::time_point captured_at{};
  bool is_single_monitor = false;
  HMONITOR single_hmon = nullptr;
  RECT single_rect = {0, 0, 0, 0};
  std::vector<uint8_t> single_bgra;
  std::vector<CapturedMonitorFrame> monitors;
};
std::mutex g_precapture_mutex;
PrecaptureSnapshot g_precapture;

std::mutex g_audio_cache_mutex;
std::vector<std::pair<std::string, std::string>> g_cached_audio_devices;
std::string g_cached_default_audio_id;
std::atomic<bool> g_audio_refresh_in_flight{false};

void PostToPlatformThread(std::function<void()> fn);
void InvokeDartMethod(const std::string& method, const EncodableValue& args);
void InvalidateActiveOverlayWindows();

HWND FindMainAppHwnd() {
  if (g_main_hwnd && ::IsWindow(g_main_hwnd)) {
    return g_main_hwnd;
  }
  auto gate = Gate();
  if (gate) {
    std::lock_guard<std::mutex> lock(gate->mutex);
    if (gate->registrar && gate->registrar->GetView()) {
      HWND view_hwnd = gate->registrar->GetView()->GetNativeWindow();
      if (view_hwnd) {
        HWND root = ::GetAncestor(view_hwnd, GA_ROOT);
        g_main_hwnd = root ? root : view_hwnd;
        return g_main_hwnd;
      }
    }
  }
  g_main_hwnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  return g_main_hwnd;
}

void ForceForegroundWindow(HWND hwnd) {
  if (!hwnd || !::IsWindow(hwnd)) return;
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  HWND fg = ::GetForegroundWindow();
  if (fg != hwnd) {
    DWORD fg_tid = fg ? ::GetWindowThreadProcessId(fg, nullptr) : 0;
    DWORD cur_tid = ::GetCurrentThreadId();
    bool attached = (fg_tid != 0 && fg_tid != cur_tid)
                        ? (::AttachThreadInput(cur_tid, fg_tid, TRUE) == TRUE)
                        : false;
    ::BringWindowToTop(hwnd);
    ::SetForegroundWindow(hwnd);
    ::SetFocus(hwnd);
    if (attached) {
      ::AttachThreadInput(cur_tid, fg_tid, FALSE);
    }
  }
}

// Old implementation:
// void SetMainWindowVisible(bool visible) {
//   HWND hwnd = FindMainAppHwnd();
//   if (!hwnd || !::IsWindow(hwnd)) return;
//   if (visible) {
//     ::ShowWindow(hwnd, SW_SHOW);
//     if (::IsIconic(hwnd)) {
//       ::ShowWindow(hwnd, SW_RESTORE);
//     }
//     ::SetForegroundWindow(hwnd);
//   } else {
//     ::ShowWindow(hwnd, SW_HIDE);
//   }
// }
void SetMainWindowVisible(bool visible) {
  HWND hwnd = FindMainAppHwnd();
  if (!hwnd || !::IsWindow(hwnd)) return;
  if (visible) {
    ForceForegroundWindow(hwnd);
  } else {
    ::ShowWindow(hwnd, SW_HIDE);
  }
}

void SetMainWindowDarkMode(bool dark_mode) {
  HWND hwnd = FindMainAppHwnd();
  if (!hwnd || !::IsWindow(hwnd)) return;
  BOOL enable_dark = dark_mode ? TRUE : FALSE;
  // Gene - Nov, 24, 2026: Use constexpr DWM attribute values to prevent <dwmapi.h> enum/macro collisions on MSVC /W4 /WX.
  // HRESULT hr = ::DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
  //                                      &enable_dark, sizeof(enable_dark));
  // if (FAILED(hr)) {
  //   ::DwmSetWindowAttribute(hwnd, 19, &enable_dark, sizeof(enable_dark));
  // }
  HRESULT hr = ::DwmSetWindowAttribute(hwnd, kDwmwaUseImmersiveDarkMode,
                                       &enable_dark, sizeof(enable_dark));
  if (FAILED(hr)) {
    ::DwmSetWindowAttribute(hwnd, kDwmwaUseImmersiveDarkModeLegacy,
                            &enable_dark, sizeof(enable_dark));
  }
}

std::string GetKnownDesktopPathUtf8() {
  PWSTR raw_path = nullptr;
  std::string out;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_Desktop, 0, nullptr,
                                       &raw_path)) &&
      raw_path) {
    out = WideToUtf8(raw_path);
    ::CoTaskMemFree(raw_path);
  }
  return out;
}

void InstallTrayIcon(HWND hwnd) {
  if (g_tray_registered || !hwnd || !::IsWindow(hwnd)) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kMsgTrayIcon;
  nid.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr),
                          MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(nid.szTip, L"SnipSnap — Press shortcut to capture");
  if (::Shell_NotifyIconW(NIM_ADD, &nid)) {
    g_tray_registered = true;
  }
}

void RemoveTrayIcon() {
  if (!g_tray_registered) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = g_main_hwnd;
  nid.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &nid);
  g_tray_registered = false;
}

void TriggerTrayAction(const std::string& action) {
  EncodableMap args;
  args[EncodableValue("action")] = EncodableValue(action);
  InvokeDartMethod("onGlobalHotKey", EncodableValue(args));
}

void ShowTrayContextMenu(HWND hwnd) {
  HMENU menu = ::CreatePopupMenu();
  if (!menu) return;
  ::AppendMenuW(menu, MF_STRING, kTrayCmdOpen, L"Open SnipSnap");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayCmdArea, L"Area Snip");
  ::AppendMenuW(menu, MF_STRING, kTrayCmdFull, L"Full Screen Snip");
  ::AppendMenuW(menu, MF_STRING, kTrayCmdScroll, L"Panoramic Scroll");
  ::AppendMenuW(menu, MF_STRING, kTrayCmdRecord, L"Record Area");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  UINT tray_flags =
      MF_STRING | (g_close_to_tray.load() ? MF_CHECKED : MF_UNCHECKED);
  ::AppendMenuW(menu, tray_flags, kTrayCmdToggleTray,
                L"Keep in Tray on Close");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayCmdQuit, L"Quit SnipSnap");

  POINT pt = {};
  ::GetCursorPos(&pt);
  ::SetForegroundWindow(hwnd);
  UINT cmd = static_cast<UINT>(
      ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                       pt.x, pt.y, 0, hwnd, nullptr));
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  switch (cmd) {
    case kTrayCmdOpen:
      SetMainWindowVisible(true);
      break;
    case kTrayCmdArea:
      TriggerTrayAction("interactiveSnip");
      break;
    case kTrayCmdFull:
      TriggerTrayAction("fullScreenSnip");
      break;
    case kTrayCmdScroll:
      TriggerTrayAction("scrollingSnip");
      break;
    case kTrayCmdRecord:
      TriggerTrayAction("recordArea");
      break;
    case kTrayCmdToggleTray:
      g_close_to_tray.store(!g_close_to_tray.load());
      break;
    case kTrayCmdQuit:
      g_force_quit.store(true);
      RemoveTrayIcon();
      ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
      break;
    default:
      break;
  }
}

void UnregisterAllNativeHotKeys() {
  std::lock_guard<std::mutex> lock(g_hotkey_mutex);
  HWND hwnd = FindMainAppHwnd();
  for (const auto& kv : g_native_hotkeys) {
    if (hwnd && ::IsWindow(hwnd)) {
      ::UnregisterHotKey(hwnd, kv.first);
    }
  }
  g_native_hotkeys.clear();
}

EncodableList RegisterNativeHotKeys(const EncodableList& entries) {
  UnregisterAllNativeHotKeys();
  EncodableList failed;
  HWND hwnd = FindMainAppHwnd();
  if (!hwnd || !::IsWindow(hwnd)) {
    for (const auto& item : entries) {
      const auto* m = std::get_if<EncodableMap>(&item);
      if (!m) continue;
      auto it = m->find(EncodableValue("action"));
      if (it != m->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) {
          failed.push_back(EncodableValue(*s));
        }
      }
    }
    return failed;
  }

  std::lock_guard<std::mutex> lock(g_hotkey_mutex);
  for (const auto& item : entries) {
    const auto* m = std::get_if<EncodableMap>(&item);
    if (!m) continue;
    std::string action;
    int vk = 0;
    int mods = 0;
    auto it_act = m->find(EncodableValue("action"));
    if (it_act != m->end()) {
      if (const auto* s = std::get_if<std::string>(&it_act->second)) action = *s;
    }
    auto it_vk = m->find(EncodableValue("vk"));
    if (it_vk != m->end()) {
      if (const auto* v = std::get_if<int32_t>(&it_vk->second)) vk = *v;
    }
    auto it_mods = m->find(EncodableValue("modifiers"));
    if (it_mods != m->end()) {
      if (const auto* mv = std::get_if<int32_t>(&it_mods->second)) mods = *mv;
    }
    if (action.empty() || vk <= 0) {
      if (!action.empty()) failed.push_back(EncodableValue(action));
      continue;
    }
    int id = ++g_next_hotkey_id;
    UINT win_mods = static_cast<UINT>(mods) | MOD_NOREPEAT;
    if (::RegisterHotKey(hwnd, id, win_mods, static_cast<UINT>(vk))) {
      NativeHotKeyEntry entry;
      entry.id = id;
      entry.action = action;
      entry.vk = static_cast<UINT>(vk);
      entry.mods = static_cast<UINT>(mods);
      g_native_hotkeys[id] = std::move(entry);
    } else {
      failed.push_back(EncodableValue(action));
    }
  }
  return failed;
}

void CapturePrecaptureForAction(const std::string& action) {
  if (action == "interactiveSnip" || action == "scrollingSnip") {
    std::vector<CapturedMonitorFrame> mons;
    if (CaptureAllMonitorsFast(&mons)) {
      std::lock_guard<std::mutex> lock(g_precapture_mutex);
      g_precapture = PrecaptureSnapshot{};
      g_precapture.valid = true;
      g_precapture.captured_at = std::chrono::steady_clock::now();
      g_precapture.is_single_monitor = false;
      g_precapture.monitors = std::move(mons);
    }
  } else if (action == "fullScreenSnip") {
    POINT pt = {};
    if (!::GetCursorPos(&pt)) {
      pt.x = 0;
      pt.y = 0;
    }
    HMONITOR hmon = ::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (hmon && ::GetMonitorInfoW(hmon, &mi)) {
      std::vector<uint8_t> bgra;
      if (CaptureSingleMonitorFast(hmon, mi.rcMonitor, &bgra)) {
        std::lock_guard<std::mutex> lock(g_precapture_mutex);
        g_precapture = PrecaptureSnapshot{};
        g_precapture.valid = true;
        g_precapture.captured_at = std::chrono::steady_clock::now();
        g_precapture.is_single_monitor = true;
        g_precapture.single_hmon = hmon;
        g_precapture.single_rect = mi.rcMonitor;
        g_precapture.single_bgra = std::move(bgra);
      }
    }
  }
}

bool ConsumePrecaptureMonitors(std::vector<CapturedMonitorFrame>* out_mons) {
  if (!out_mons) return false;
  std::lock_guard<std::mutex> lock(g_precapture_mutex);
  if (!g_precapture.valid || g_precapture.is_single_monitor) return false;
  auto age_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - g_precapture.captured_at)
                    .count();
  if (age_ms > 1500 || g_precapture.monitors.empty()) {
    g_precapture = PrecaptureSnapshot{};
    return false;
  }
  *out_mons = std::move(g_precapture.monitors);
  g_precapture = PrecaptureSnapshot{};
  return true;
}

bool ConsumePrecaptureSingleMonitor(HMONITOR* out_hmon, RECT* out_rect,
                                    std::vector<uint8_t>* out_bgra) {
  if (!out_hmon || !out_rect || !out_bgra) return false;
  std::lock_guard<std::mutex> lock(g_precapture_mutex);
  if (!g_precapture.valid || !g_precapture.is_single_monitor) return false;
  auto age_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - g_precapture.captured_at)
                    .count();
  if (age_ms > 1500 || g_precapture.single_bgra.empty()) {
    g_precapture = PrecaptureSnapshot{};
    return false;
  }
  *out_hmon = g_precapture.single_hmon;
  *out_rect = g_precapture.single_rect;
  *out_bgra = std::move(g_precapture.single_bgra);
  g_precapture = PrecaptureSnapshot{};
  return true;
}

// Gene - Nov, 24, 2026: Worker-thread WASAPI audio device enumerator that updates g_cached_audio_devices without blocking the Win32 UI thread.
EncodableList BuildAudioDeviceListFromCache() {
  std::lock_guard<std::mutex> lock(g_audio_cache_mutex);
  EncodableList list;
  for (const auto& kv : g_cached_audio_devices) {
    EncodableMap item;
    item[EncodableValue("id")] = EncodableValue(kv.first);
    item[EncodableValue("name")] = EncodableValue(kv.second);
    item[EncodableValue("isDefault")] = EncodableValue(
        !g_cached_default_audio_id.empty() &&
        kv.first == g_cached_default_audio_id);
    list.push_back(EncodableValue(item));
  }
  return list;
}

void EnumerateWindowsAudioDevicesWorker(
    std::shared_ptr<CaptureMethodResult> opt_result, bool invalidate_overlay) {
  std::thread([opt_result, invalidate_overlay]() {
    HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool did_init = (com_hr == S_OK || com_hr == S_FALSE);

    std::vector<std::pair<std::string, std::string>> devices;
    std::string default_id_utf8;

    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (SUCCEEDED(hr) && enumerator) {
      std::wstring default_id;
      ComPtr<IMMDevice> def_dev;
      if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole,
                                                        &def_dev)) &&
          def_dev) {
        LPWSTR raw_def_id = nullptr;
        if (SUCCEEDED(def_dev->GetId(&raw_def_id)) && raw_def_id) {
          default_id = raw_def_id;
          default_id_utf8 = WideToUtf8(default_id);
          ::CoTaskMemFree(raw_def_id);
        }
      }

      static const PROPERTYKEY kDevPKeyFriendlyName = {
          {0xa45c254e,
           0xdf1c,
           0x4efd,
           {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
          14};

      ComPtr<IMMDeviceCollection> collection;
      if (SUCCEEDED(enumerator->EnumAudioEndpoints(
              eCapture, DEVICE_STATE_ACTIVE, &collection)) &&
          collection) {
        UINT count = 0;
        collection->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
          ComPtr<IMMDevice> dev;
          if (FAILED(collection->Item(i, &dev)) || !dev) continue;

          LPWSTR raw_id = nullptr;
          std::wstring dev_id;
          if (SUCCEEDED(dev->GetId(&raw_id)) && raw_id) {
            dev_id = raw_id;
            ::CoTaskMemFree(raw_id);
          }
          if (dev_id.empty()) continue;

          std::wstring friendly_name = dev_id;
          ComPtr<IPropertyStore> props;
          if (SUCCEEDED(dev->OpenPropertyStore(STGM_READ, &props)) && props) {
            PROPVARIANT var_name;
            ::PropVariantInit(&var_name);
            if (SUCCEEDED(props->GetValue(kDevPKeyFriendlyName, &var_name))) {
              if (var_name.vt == VT_LPWSTR && var_name.pwszVal) {
                friendly_name = var_name.pwszVal;
              }
              ::PropVariantClear(&var_name);
            }
          }

          std::string id_u8 = WideToUtf8(dev_id);
          std::string name_u8 = WideToUtf8(friendly_name);
          devices.emplace_back(id_u8, name_u8.empty() ? id_u8 : name_u8);
        }
      }
    }

    if (did_init) {
      ::CoUninitialize();
    }

    {
      std::lock_guard<std::mutex> lock(g_audio_cache_mutex);
      g_cached_audio_devices = std::move(devices);
      g_cached_default_audio_id = std::move(default_id_utf8);
    }
    g_audio_refresh_in_flight.store(false);

    if (opt_result || invalidate_overlay) {
      PostToPlatformThread([opt_result, invalidate_overlay]() {
        if (invalidate_overlay) {
          InvalidateActiveOverlayWindows();
        }
        if (opt_result) {
          opt_result->Success(EncodableValue(BuildAudioDeviceListFromCache()));
        }
      });
    }
  }).detach();
}

// Old synchronous EnumerateWindowsAudioInputDevices implementation (retained commented per policy):
// EncodableList EnumerateWindowsAudioInputDevices() {
//   EncodableList list;
//   HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
//   bool did_init = (com_hr == S_OK || com_hr == S_FALSE);
//
//   ComPtr<IMMDeviceEnumerator> enumerator;
//   HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
//                                   CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
//   if (SUCCEEDED(hr) && enumerator) {
//     std::wstring default_id;
//     ComPtr<IMMDevice> def_dev;
//     if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole,
//                                                       &def_dev)) &&
//         def_dev) {
//       LPWSTR raw_def_id = nullptr;
//       if (SUCCEEDED(def_dev->GetId(&raw_def_id)) && raw_def_id) {
//         default_id = raw_def_id;
//         ::CoTaskMemFree(raw_def_id);
//       }
//     }
//
//     static const PROPERTYKEY kDevPKeyFriendlyName = {
//         {0xa45c254e,
//          0xdf1c,
//          0x4efd,
//          {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
//         14};
//
//     ComPtr<IMMDeviceCollection> collection;
//     if (SUCCEEDED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
//                                                  &collection)) &&
//         collection) {
//       UINT count = 0;
//       collection->GetCount(&count);
//       for (UINT i = 0; i < count; ++i) {
//         ComPtr<IMMDevice> dev;
//         if (FAILED(collection->Item(i, &dev)) || !dev) continue;
//
//         LPWSTR raw_id = nullptr;
//         std::wstring dev_id;
//         if (SUCCEEDED(dev->GetId(&raw_id)) && raw_id) {
//           dev_id = raw_id;
//           ::CoTaskMemFree(raw_id);
//         }
//         if (dev_id.empty()) continue;
//
//         std::wstring friendly_name = dev_id;
//         ComPtr<IPropertyStore> props;
//         if (SUCCEEDED(dev->OpenPropertyStore(STGM_READ, &props)) && props) {
//           PROPVARIANT var_name;
//           ::PropVariantInit(&var_name);
//           if (SUCCEEDED(props->GetValue(kDevPKeyFriendlyName, &var_name))) {
//             if (var_name.vt == VT_LPWSTR && var_name.pwszVal) {
//               friendly_name = var_name.pwszVal;
//             }
//             ::PropVariantClear(&var_name);
//           }
//         }
//
//         EncodableMap item;
//         item[EncodableValue("id")] = EncodableValue(WideToUtf8(dev_id));
//         item[EncodableValue("name")] = EncodableValue(WideToUtf8(friendly_name));
//         item[EncodableValue("isDefault")] =
//             EncodableValue(!default_id.empty() && dev_id == default_id);
//         list.push_back(EncodableValue(item));
//       }
//     }
//   }
//
//   if (did_init) {
//     ::CoUninitialize();
//   }
//   return list;
// }

void PostToPlatformThread(std::function<void()> fn) {
  auto gate = Gate();
  if (!gate) return;
  std::lock_guard<std::mutex> lock(gate->mutex);
  if (!gate->engine) return;
  gate->engine->PostPlatformThreadTask(std::move(fn));
}

void InvokeDartMethod(const std::string& method, const EncodableValue& args) {
  PostToPlatformThread([method, args]() {
    auto gate = Gate();
    if (!gate || !gate->channel) return;
    gate->channel->InvokeMethod(method, std::make_unique<EncodableValue>(args));
  });
}

// ---------------------------------------------------------------------------
// WIC PNG Encoding & Decoding Helpers
// ---------------------------------------------------------------------------

bool EncodeBgraToPngBytes(const uint8_t* bgra_pixels, int width, int height,
                          int stride, std::vector<uint8_t>* out_png) {
  if (!bgra_pixels || width <= 0 || height <= 0 || !out_png) return false;

  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return false;

  ComPtr<IStream> stream;
  hr = ::CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (FAILED(hr)) return false;

  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (FAILED(hr)) return false;

  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) return false;

  ComPtr<IWICBitmapFrameEncode> frame;
  hr = encoder->CreateNewFrame(&frame, nullptr);
  if (FAILED(hr)) return false;

  hr = frame->Initialize(nullptr);
  if (FAILED(hr)) return false;

  hr = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height));
  if (FAILED(hr)) return false;

  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return false;

  // Gene - Nov, 22, 2026: Check 32-bit byte size overflow for tall panoramic screenshots and read logical IStream byte length via STATSTG instead of GlobalSize slack.
  // Old implementation:
  // UINT buffer_size = static_cast<UINT>(stride * height);
  // hr = frame->WritePixels(
  //     static_cast<UINT>(height), static_cast<UINT>(stride), buffer_size,
  //     const_cast<BYTE*>(reinterpret_cast<const BYTE*>(bgra_pixels)));
  // if (FAILED(hr)) return false;
  //
  // hr = frame->Commit();
  // if (FAILED(hr)) return false;
  //
  // hr = encoder->Commit();
  // if (FAILED(hr)) return false;
  //
  // HGLOBAL hglobal = nullptr;
  // hr = ::GetHGlobalFromStream(stream.Get(), &hglobal);
  // if (FAILED(hr) || !hglobal) return false;
  //
  // SIZE_T size = ::GlobalSize(hglobal);
  // void* ptr = ::GlobalLock(hglobal);
  // if (!ptr || size == 0) return false;
  //
  // out_png->assign(static_cast<const uint8_t*>(ptr),
  //                 static_cast<const uint8_t*>(ptr) + size);
  // ::GlobalUnlock(hglobal);
  // return true;
  if (stride <= 0) return false;
  const size_t total_bytes =
      static_cast<size_t>(stride) * static_cast<size_t>(height);
  if (total_bytes > UINT_MAX) return false;
  UINT buffer_size = static_cast<UINT>(total_bytes);
  hr = frame->WritePixels(
      static_cast<UINT>(height), static_cast<UINT>(stride), buffer_size,
      const_cast<BYTE*>(reinterpret_cast<const BYTE*>(bgra_pixels)));
  if (FAILED(hr)) return false;

  hr = frame->Commit();
  if (FAILED(hr)) return false;

  hr = encoder->Commit();
  if (FAILED(hr)) return false;

  HGLOBAL hglobal = nullptr;
  hr = ::GetHGlobalFromStream(stream.Get(), &hglobal);
  if (FAILED(hr) || !hglobal) return false;

  SIZE_T alloc_size = ::GlobalSize(hglobal);
  SIZE_T size = alloc_size;
  STATSTG stat = {};
  if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) &&
      stat.cbSize.QuadPart > 0) {
    size = static_cast<SIZE_T>(
        std::min<ULONGLONG>(stat.cbSize.QuadPart, alloc_size));
  }
  void* ptr = ::GlobalLock(hglobal);
  if (!ptr || size == 0) {
    if (ptr) ::GlobalUnlock(hglobal);
    return false;
  }

  out_png->assign(static_cast<const uint8_t*>(ptr),
                  static_cast<const uint8_t*>(ptr) + size);
  ::GlobalUnlock(hglobal);
  return true;
}

bool SaveBgraToPngFile(const uint8_t* bgra_pixels, int width, int height,
                       int stride, const std::wstring& path) {
  std::vector<uint8_t> png_bytes;
  if (!EncodeBgraToPngBytes(bgra_pixels, width, height, stride, &png_bytes)) {
    return false;
  }
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  BOOL ok = ::WriteFile(file, png_bytes.data(),
                        static_cast<DWORD>(png_bytes.size()), &written, nullptr);
  ::CloseHandle(file);
  return ok && written == png_bytes.size();
}

bool DecodeImageBytesToBgra(const uint8_t* bytes, size_t size,
                            std::vector<uint8_t>* out_bgra, int* out_width,
                            int* out_height) {
  if (!bytes || size == 0 || !out_bgra || !out_width || !out_height) {
    return false;
  }
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return false;

  ComPtr<IWICStream> stream;
  hr = factory->CreateStream(&stream);
  if (FAILED(hr)) return false;

  hr = stream->InitializeFromMemory(const_cast<BYTE*>(bytes),
                                    static_cast<DWORD>(size));
  if (FAILED(hr)) return false;

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromStream(
      stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
  if (FAILED(hr)) return false;

  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) return false;

  UINT w = 0, h = 0;
  hr = frame->GetSize(&w, &h);
  if (FAILED(hr) || w == 0 || h == 0) return false;

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) return false;

  hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return false;

  *out_width = static_cast<int>(w);
  *out_height = static_cast<int>(h);
  UINT stride = w * 4;
  out_bgra->resize(static_cast<size_t>(stride) * h);
  hr = converter->CopyPixels(nullptr, stride,
                             static_cast<UINT>(out_bgra->size()),
                             out_bgra->data());
  return SUCCEEDED(hr);
}

// ---------------------------------------------------------------------------
// Fast GDI Screen Capture (Top-Down 32-bit BGRA)
// ---------------------------------------------------------------------------

// Gene - Nov, 24, 2026: Delegate screen capture to reusable DXGI/persistent-GDI helper, add OpenClipboardWithRetry/ClipboardGuard, verify SetClipboardData return values, and decode CF_DIB/CF_DIBV5 safely in Rust.
// Old implementation:
// bool CaptureScreenRectBgra(int x, int y, int width, int height,
//                            std::vector<uint8_t>* out_bgra) {
//   ...
// }
//
// bool CopyPngBytesToWin32Clipboard(const uint8_t* png_bytes, size_t png_size) {
//   std::vector<uint8_t> bgra;
//   int width = 0, height = 0;
//   if (!DecodeImageBytesToBgra(png_bytes, png_size, &bgra, &width, &height)) {
//     return false;
//   }
//   if (!::OpenClipboard(nullptr)) return false;
//   ::EmptyClipboard();
//   ...
//   ::CloseClipboard();
//   return true;
// }
//
// bool PasteWin32ClipboardToPngFile(const std::wstring& target_path) {
//   ...
// }
//
// bool CopyFileToWin32Clipboard(const std::wstring& file_path) {
//   ...
// }
// Gene - Nov, 24, 2026: Comment out obsolete unreferenced wrapper CaptureScreenRectBgra so MSVC /W4 /WX never emits C4505.
// bool CaptureScreenRectBgra(int x, int y, int width, int height,
//                            std::vector<uint8_t>* out_bgra) {
//   return CaptureRectFast(x, y, width, height, false, false, nullptr, out_bgra);
// }

bool OpenClipboardWithRetry(HWND owner) {
  HWND hwnd = (owner && ::IsWindow(owner)) ? owner : FindMainAppHwnd();
  for (int attempt = 0; attempt < 8; ++attempt) {
    if (::OpenClipboard(hwnd)) {
      return true;
    }
    ::Sleep(10);
  }
  return ::OpenClipboard(nullptr) == TRUE;
}

struct ClipboardGuard {
  bool opened = false;
  explicit ClipboardGuard(HWND owner) : opened(OpenClipboardWithRetry(owner)) {}
  ~ClipboardGuard() {
    if (opened) {
      ::CloseClipboard();
      opened = false;
    }
  }
  ClipboardGuard(const ClipboardGuard&) = delete;
  ClipboardGuard& operator=(const ClipboardGuard&) = delete;
};

bool CopyPngBytesToWin32Clipboard(const uint8_t* png_bytes, size_t png_size) {
  if (!png_bytes || png_size == 0) return false;
  std::vector<uint8_t> bgra;
  int width = 0, height = 0;
  if (!DecodeImageBytesToBgra(png_bytes, png_size, &bgra, &width, &height) ||
      width <= 0 || height <= 0) {
    return false;
  }

  ClipboardGuard clip(FindMainAppHwnd());
  if (!clip.opened) return false;
  if (!::EmptyClipboard()) return false;

  bool wrote_any = false;

  // 1. Register and set "PNG" clipboard format for modern apps
  UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (png_format != 0) {
    HGLOBAL hpng = ::GlobalAlloc(GMEM_MOVEABLE, png_size);
    if (hpng) {
      void* ptr = ::GlobalLock(hpng);
      if (ptr) {
        std::memcpy(ptr, png_bytes, png_size);
        ::GlobalUnlock(hpng);
        if (::SetClipboardData(png_format, hpng) != nullptr) {
          wrote_any = true;
        } else {
          ::GlobalFree(hpng);
        }
      } else {
        ::GlobalFree(hpng);
      }
    }
  }

  // 2. Also set standard CF_DIB (bottom-up 32bpp BGRX) via Rust converter
  size_t pixel_bytes =
      static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  size_t dib_size = sizeof(BITMAPINFOHEADER) + pixel_bytes;
  HGLOBAL hdib = ::GlobalAlloc(GMEM_MOVEABLE, dib_size);
  if (hdib) {
    uint8_t* ptr = static_cast<uint8_t*>(::GlobalLock(hdib));
    if (ptr) {
      BITMAPINFOHEADER bih = {};
      bih.biSize = sizeof(BITMAPINFOHEADER);
      bih.biWidth = width;
      bih.biHeight = height;  // Bottom-up for CF_DIB compatibility
      bih.biPlanes = 1;
      bih.biBitCount = 32;
      bih.biCompression = BI_RGB;
      bih.biSizeImage = static_cast<DWORD>(pixel_bytes);
      std::memcpy(ptr, &bih, sizeof(BITMAPINFOHEADER));

      uint8_t* dst_pixels = ptr + sizeof(BITMAPINFOHEADER);
      int stride = width * 4;
      bool conv_ok = snipsnap_bgra_to_bottom_up_bgrx(
          bgra.data(), width, height, stride, dst_pixels, stride);
      ::GlobalUnlock(hdib);
      if (conv_ok && ::SetClipboardData(CF_DIB, hdib) != nullptr) {
        wrote_any = true;
      } else {
        ::GlobalFree(hdib);
      }
    } else {
      ::GlobalFree(hdib);
    }
  }

  return wrote_any;
}

bool PasteWin32ClipboardToPngFile(const std::wstring& target_path) {
  std::vector<uint8_t> bgra;
  int w = 0;
  int h = 0;
  bool decoded = false;

  {
    ClipboardGuard clip(FindMainAppHwnd());
    if (!clip.opened) return false;

    UINT png_format = ::RegisterClipboardFormatW(L"PNG");
    if (png_format != 0 && ::IsClipboardFormatAvailable(png_format)) {
      HANDLE hdata = ::GetClipboardData(png_format);
      if (hdata) {
        SIZE_T size = ::GlobalSize(hdata);
        const uint8_t* ptr = static_cast<const uint8_t*>(::GlobalLock(hdata));
        if (ptr && size > 0) {
          decoded = DecodeImageBytesToBgra(ptr, size, &bgra, &w, &h);
        }
        if (ptr) ::GlobalUnlock(hdata);
      }
    }

    if (!decoded) {
      UINT dib_formats[] = {CF_DIBV5, CF_DIB};
      for (UINT fmt : dib_formats) {
        if (!::IsClipboardFormatAvailable(fmt)) continue;
        HANDLE hdib = ::GetClipboardData(fmt);
        if (!hdib) continue;
        SIZE_T dib_size = ::GlobalSize(hdib);
        const uint8_t* ptr = static_cast<const uint8_t*>(::GlobalLock(hdib));
        if (ptr && dib_size >= 40) {
          SnipSnapImageBuffer rust_buf = {};
          if (snipsnap_decode_dib_to_bgra(ptr, static_cast<size_t>(dib_size),
                                          &rust_buf) &&
              rust_buf.data && rust_buf.width > 0 && rust_buf.height > 0) {
            w = rust_buf.width;
            h = rust_buf.height;
            bgra.assign(rust_buf.data, rust_buf.data + rust_buf.len);
            decoded = true;
          }
          snipsnap_buffer_free(&rust_buf);
        }
        if (ptr) ::GlobalUnlock(hdib);
        if (decoded) break;
      }
    }
  }

  if (!decoded || bgra.empty() || w <= 0 || h <= 0) {
    return false;
  }
  return SaveBgraToPngFile(bgra.data(), w, h, w * 4, target_path);
}

bool CopyFileToWin32Clipboard(const std::wstring& file_path) {
  if (file_path.empty()) return false;
  ClipboardGuard clip(FindMainAppHwnd());
  if (!clip.opened) return false;
  if (!::EmptyClipboard()) return false;

  size_t path_bytes = (file_path.size() + 2) * sizeof(wchar_t);
  size_t total_bytes = sizeof(DROPFILES) + path_bytes;
  HGLOBAL hdrop = ::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total_bytes);
  if (!hdrop) return false;

  uint8_t* ptr = static_cast<uint8_t*>(::GlobalLock(hdrop));
  if (!ptr) {
    ::GlobalFree(hdrop);
    return false;
  }

  DROPFILES* df = reinterpret_cast<DROPFILES*>(ptr);
  df->pFiles = sizeof(DROPFILES);
  df->fWide = TRUE;
  wchar_t* dst = reinterpret_cast<wchar_t*>(ptr + sizeof(DROPFILES));
  std::memcpy(dst, file_path.c_str(), file_path.size() * sizeof(wchar_t));
  dst[file_path.size()] = L'\0';
  dst[file_path.size() + 1] = L'\0';

  ::GlobalUnlock(hdrop);
  bool ok = ::SetClipboardData(CF_HDROP, hdrop) != nullptr;
  if (!ok) ::GlobalFree(hdrop);
  return ok;
}

// ---------------------------------------------------------------------------
// Native Win32 Interactive Capture & Record Overlay Window
// ---------------------------------------------------------------------------

// Gene - Nov, 13, 2026: Extended InteractiveOverlayState with Snagit pre-recording presets (Full Screen, 1920x1080, 1280x720), FPS/Mic/SysAudio/Cursor toggles, and full toolbar bounds.
// Old implementation:
// struct InteractiveOverlayState {
//   HWND hwnd = nullptr;
//   int virt_x = 0;
//   int virt_y = 0;
//   int virt_w = 0;
//   int virt_h = 0;
//   std::vector<uint8_t> screen_bgra;
//   HBITMAP screen_bitmap = nullptr;
//   std::wstring target_path;
//   std::string initial_mode = "capture";
//   std::unique_ptr<CaptureMethodResult> pending_result;
//
//   enum class Mode { kIdle, kDrawing, kAdjusting, kMoving, kResizing };
//   Mode mode = Mode::kIdle;
//   bool has_selection = false;
//   RECT sel = {0, 0, 0, 0};
//   POINT drag_start = {0, 0};
//   RECT sel_at_start = {0, 0, 0, 0};
//   int active_grip = -1;  // 0..7 corners/edges, 8 body
//
//   RECT capture_btn = {0, 0, 0, 0};
//   RECT record_btn = {0, 0, 0, 0};
//   RECT cancel_btn = {0, 0, 0, 0};
//   bool settled = false;
// };
// Gene - Nov, 13, 2026: Added multi-monitor helpers, 8-handle resize grips, WM_SETCURSOR/WM_ERASEBKGND, zero-copy DIB overlay capture + pre-darkened dim bitmap + persistent backbuffer, and active-monitor presets/toolbar.
// Gene - Nov, 24, 2026: Per-monitor HiDPI interactive overlay using DXGI/precapture frames, Rust pixel dimming, cached GDI backbuffers, dirty-rect painting, scrolling initialMode, and temporary WH_KEYBOARD_LL hook.
// Old single-virtual-desktop InteractiveOverlayState + OverlayWndProc + StartWin32InteractiveOverlay implementation retained commented per policy:
// RECT GetMonitorRectForScreenPoint(POINT screen_pt) {
//   HMONITOR hmon = ::MonitorFromPoint(screen_pt, MONITOR_DEFAULTTONEAREST);
//   MONITORINFO mi = {};
//   mi.cbSize = sizeof(mi);
//   if (hmon && ::GetMonitorInfoW(hmon, &mi)) {
//     return mi.rcMonitor;
//   }
//   int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
//   int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
//   int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
//   int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
//   return RECT{vx, vy, vx + vw, vy + vh};
// }
//
// RECT GetCursorMonitorScreenRect() {
//   POINT pt = {};
//   if (!::GetCursorPos(&pt)) {
//     pt.x = 0;
//     pt.y = 0;
//   }
//   return GetMonitorRectForScreenPoint(pt);
// }
//
// struct InteractiveOverlayState {
//   HWND hwnd = nullptr;
//   int virt_x = 0;
//   int virt_y = 0;
//   int virt_w = 0;
//   int virt_h = 0;
//   HBITMAP screen_bitmap = nullptr;
//   uint8_t* screen_bits = nullptr;
//   HBITMAP dim_bitmap = nullptr;
//   HDC backbuf_dc = nullptr;
//   HBITMAP backbuf_bitmap = nullptr;
//   HGDIOBJ backbuf_old_bmp = nullptr;
//   std::wstring target_path;
//   std::string initial_mode = "capture";
//   std::unique_ptr<CaptureMethodResult> pending_result;
//   ...
// };

constexpr UINT kMsgOverlayCancel = WM_APP + 210;
constexpr UINT kMsgOverlayConfirm = WM_APP + 211;

std::atomic<bool> g_overlay_hook_active{false};
std::atomic<HWND> g_overlay_primary_hwnd{nullptr};

int OverlayScalePx(int px, double scale) {
  return static_cast<int>(std::lround(static_cast<double>(px) * scale));
}

RECT GetMonitorRectForScreenPoint(POINT screen_pt) {
  HMONITOR hmon = ::MonitorFromPoint(screen_pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (hmon && ::GetMonitorInfoW(hmon, &mi)) {
    return mi.rcMonitor;
  }
  int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  return RECT{vx, vy, vx + vw, vy + vh};
}

RECT GetCursorMonitorScreenRect() {
  POINT pt = {};
  if (!::GetCursorPos(&pt)) {
    pt.x = 0;
    pt.y = 0;
  }
  return GetMonitorRectForScreenPoint(pt);
}

struct OverlayMonitorPane {
  HWND hwnd = nullptr;
  HMONITOR hmon = nullptr;
  RECT screen_rect = {0, 0, 0, 0};
  int width = 0;
  int height = 0;
  double dpi_scale = 1.0;

  HBITMAP screen_bitmap = nullptr;
  uint8_t* screen_bits = nullptr;
  HBITMAP dim_bitmap = nullptr;

  HDC scr_dc = nullptr;
  HGDIOBJ scr_old_bmp = nullptr;
  HDC dim_dc = nullptr;
  HGDIOBJ dim_old_bmp = nullptr;
  HDC backbuf_dc = nullptr;
  HBITMAP backbuf_bitmap = nullptr;
  HGDIOBJ backbuf_old_bmp = nullptr;

  HFONT font_ui = nullptr;
  HFONT font_bold = nullptr;
  bool has_last_chrome = false;
  RECT last_chrome_bounds = {0, 0, 0, 0};

  void CleanupResources() {
    if (hwnd) {
      ::DestroyWindow(hwnd);
      hwnd = nullptr;
    }
    if (scr_dc) {
      if (scr_old_bmp) {
        ::SelectObject(scr_dc, scr_old_bmp);
        scr_old_bmp = nullptr;
      }
      ::DeleteDC(scr_dc);
      scr_dc = nullptr;
    }
    if (dim_dc) {
      if (dim_old_bmp) {
        ::SelectObject(dim_dc, dim_old_bmp);
        dim_old_bmp = nullptr;
      }
      ::DeleteDC(dim_dc);
      dim_dc = nullptr;
    }
    if (backbuf_dc) {
      if (backbuf_old_bmp) {
        ::SelectObject(backbuf_dc, backbuf_old_bmp);
        backbuf_old_bmp = nullptr;
      }
      ::DeleteDC(backbuf_dc);
      backbuf_dc = nullptr;
    }
    if (backbuf_bitmap) {
      ::DeleteObject(backbuf_bitmap);
      backbuf_bitmap = nullptr;
    }
    if (dim_bitmap) {
      ::DeleteObject(dim_bitmap);
      dim_bitmap = nullptr;
    }
    if (screen_bitmap) {
      ::DeleteObject(screen_bitmap);
      screen_bitmap = nullptr;
    }
    if (font_ui) {
      ::DeleteObject(font_ui);
      font_ui = nullptr;
    }
    if (font_bold) {
      ::DeleteObject(font_bold);
      font_bold = nullptr;
    }
    screen_bits = nullptr;
  }
};

struct InteractiveOverlayState {
  std::vector<OverlayMonitorPane> panes;
  int active_pane = 0;

  std::wstring target_path;
  std::string initial_mode = "capture";
  std::unique_ptr<CaptureMethodResult> pending_result;

  int selected_fps = 60;
  bool record_mic = false;
  std::string mic_device_id;
  std::vector<std::pair<std::string, std::string>> mic_devices;
  bool record_sys_audio = true;
  bool record_cursor = true;
  bool highlight_clicks = true;
  bool is_full_screen_preset = false;

  enum class Mode { kIdle, kDrawing, kAdjusting, kMoving, kResizing };
  Mode mode = Mode::kIdle;
  bool has_selection = false;
  RECT sel = {0, 0, 0, 0};  // Local pixels in panes[active_pane]
  POINT drag_start = {0, 0};
  RECT sel_at_start = {0, 0, 0, 0};
  int active_grip = -1;  // 0..7 corners/edges

  RECT capture_btn = {0, 0, 0, 0};
  RECT record_btn = {0, 0, 0, 0};
  RECT scroll_btn = {0, 0, 0, 0};
  RECT cancel_btn = {0, 0, 0, 0};
  RECT preset_full_btn = {0, 0, 0, 0};
  RECT preset_1080_btn = {0, 0, 0, 0};
  RECT preset_720_btn = {0, 0, 0, 0};
  RECT tb_full_btn = {0, 0, 0, 0};
  RECT tb_1080_btn = {0, 0, 0, 0};
  RECT tb_720_btn = {0, 0, 0, 0};
  RECT fps_btn = {0, 0, 0, 0};
  RECT mic_btn = {0, 0, 0, 0};
  RECT mic_cycle_btn = {0, 0, 0, 0};
  RECT sys_audio_btn = {0, 0, 0, 0};
  RECT cursor_btn = {0, 0, 0, 0};
  RECT mode_snip_btn = {0, 0, 0, 0};
  HHOOK key_hook = nullptr;
  bool settled = false;
};

InteractiveOverlayState g_overlay;

OverlayMonitorPane* ActiveOverlayPane() {
  if (g_overlay.active_pane < 0 ||
      g_overlay.active_pane >= static_cast<int>(g_overlay.panes.size())) {
    return nullptr;
  }
  return &g_overlay.panes[static_cast<size_t>(g_overlay.active_pane)];
}

void ComputeOverlayGripPoints(const RECT& s, POINT out_pts[8]) {
  LONG cx = (s.left + s.right) / 2;
  LONG cy = (s.top + s.bottom) / 2;
  out_pts[0] = {s.left, s.top};      // NW
  out_pts[1] = {cx, s.top};          // N
  out_pts[2] = {s.right, s.top};     // NE
  out_pts[3] = {s.right, cy};        // E
  out_pts[4] = {s.right, s.bottom};  // SE
  out_pts[5] = {cx, s.bottom};       // S
  out_pts[6] = {s.left, s.bottom};   // SW
  out_pts[7] = {s.left, cy};         // W
}

int HitTestOverlayGrip(const RECT& s, POINT pt, double dpi_scale) {
  if ((s.right - s.left) < 12 || (s.bottom - s.top) < 12) return -1;
  POINT pts[8];
  ComputeOverlayGripPoints(s, pts);
  LONG hit_half = static_cast<LONG>(OverlayScalePx(7, dpi_scale));
  for (int i = 0; i < 8; ++i) {
    RECT r = {pts[i].x - hit_half, pts[i].y - hit_half,
              pts[i].x + hit_half, pts[i].y + hit_half};
    if (::PtInRect(&r, pt)) return i;
  }
  return -1;
}

void ClearOverlayButtonRects() {
  g_overlay.capture_btn = {0, 0, 0, 0};
  g_overlay.record_btn = {0, 0, 0, 0};
  g_overlay.scroll_btn = {0, 0, 0, 0};
  g_overlay.cancel_btn = {0, 0, 0, 0};
  g_overlay.preset_full_btn = {0, 0, 0, 0};
  g_overlay.preset_1080_btn = {0, 0, 0, 0};
  g_overlay.preset_720_btn = {0, 0, 0, 0};
  g_overlay.tb_full_btn = {0, 0, 0, 0};
  g_overlay.tb_1080_btn = {0, 0, 0, 0};
  g_overlay.tb_720_btn = {0, 0, 0, 0};
  g_overlay.fps_btn = {0, 0, 0, 0};
  g_overlay.mic_btn = {0, 0, 0, 0};
  g_overlay.mic_cycle_btn = {0, 0, 0, 0};
  g_overlay.sys_audio_btn = {0, 0, 0, 0};
  g_overlay.cursor_btn = {0, 0, 0, 0};
  g_overlay.mode_snip_btn = {0, 0, 0, 0};
}

void InvalidateOverlayPaneDirty(int pane_idx, bool force_full = false) {
  if (pane_idx < 0 ||
      pane_idx >= static_cast<int>(g_overlay.panes.size())) {
    return;
  }
  OverlayMonitorPane& pane = g_overlay.panes[static_cast<size_t>(pane_idx)];
  if (!pane.hwnd || !::IsWindow(pane.hwnd)) return;

  if (force_full || !pane.has_last_chrome) {
    ::InvalidateRect(pane.hwnd, nullptr, FALSE);
    return;
  }

  RECT next_est = {0, 0, 0, 0};
  if (pane_idx == g_overlay.active_pane) {
    if (g_overlay.has_selection) {
      int pad_x = OverlayScalePx(24, pane.dpi_scale);
      int pad_top = OverlayScalePx(44, pane.dpi_scale);
      int pad_bot = OverlayScalePx(84, pane.dpi_scale);
      int sl = static_cast<int>(g_overlay.sel.left);
      int st = static_cast<int>(g_overlay.sel.top);
      int sr = static_cast<int>(g_overlay.sel.right);
      int sb = static_cast<int>(g_overlay.sel.bottom);
      RECT sel_band = {
          std::max(0, sl - pad_x),
          std::max(0, st - pad_top),
          std::min(pane.width, sr + pad_x),
          std::min(pane.height, sb + pad_bot),
      };
      // Include horizontal span for wide centered/clamped toolbars near selection edge
      RECT tb_band = {
          0,
          std::max(0, std::min(st - pad_top, sb - OverlayScalePx(90, pane.dpi_scale))),
          pane.width,
          std::min(pane.height, sb + pad_bot),
      };
      ::UnionRect(&next_est, &sel_band, &tb_band);
    } else if (g_overlay.initial_mode == "record") {
      next_est = {
          0,
          std::max(0, pane.height - OverlayScalePx(120, pane.dpi_scale)),
          pane.width,
          pane.height,
      };
    }
  }

  RECT dirty = {};
  if (::IsRectEmpty(&next_est)) {
    dirty = pane.last_chrome_bounds;
  } else {
    ::UnionRect(&dirty, &pane.last_chrome_bounds, &next_est);
  }
  if (::IsRectEmpty(&dirty)) {
    ::InvalidateRect(pane.hwnd, nullptr, FALSE);
    return;
  }
  dirty.left = std::clamp<LONG>(dirty.left, 0, pane.width);
  dirty.top = std::clamp<LONG>(dirty.top, 0, pane.height);
  dirty.right = std::clamp<LONG>(dirty.right, 0, pane.width);
  dirty.bottom = std::clamp<LONG>(dirty.bottom, 0, pane.height);
  if (dirty.right > dirty.left && dirty.bottom > dirty.top) {
    ::InvalidateRect(pane.hwnd, &dirty, FALSE);
  }
}

void InvalidateActiveOverlayWindows() {
  if (!g_overlay_active.load()) return;
  InvalidateOverlayPaneDirty(g_overlay.active_pane, true);
}

LRESULT CALLBACK OverlayLowLevelKeyboardProc(int ncode, WPARAM wparam,
                                             LPARAM lparam) {
  if (ncode == HC_ACTION &&
      (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN) &&
      g_overlay_hook_active.load(std::memory_order_relaxed)) {
    const auto* kb = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
    HWND target = g_overlay_primary_hwnd.load(std::memory_order_relaxed);
    if (kb && target) {
      if (kb->vkCode == VK_ESCAPE) {
        ::PostMessageW(target, kMsgOverlayCancel, 0, 0);
        return 1;
      }
      if (kb->vkCode == VK_RETURN || kb->vkCode == VK_SPACE) {
        bool mod_down = (::GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
                        (::GetAsyncKeyState(VK_MENU) & 0x8000) != 0 ||
                        (::GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
        if (!mod_down) {
          ::PostMessageW(target, kMsgOverlayConfirm, 0, 0);
          return 1;
        }
      }
    }
  }
  return ::CallNextHookEx(nullptr, ncode, wparam, lparam);
}

void UninstallOverlayKeyboardHook() {
  g_overlay_hook_active.store(false);
  g_overlay_primary_hwnd.store(nullptr);
  if (g_overlay.key_hook) {
    ::UnhookWindowsHookEx(g_overlay.key_hook);
    g_overlay.key_hook = nullptr;
  }
}

void CloseInteractiveOverlay() {
  g_overlay_active.store(false);
  UninstallOverlayKeyboardHook();
  for (auto& pane : g_overlay.panes) {
    pane.CleanupResources();
  }
  g_overlay.panes.clear();
  g_overlay.active_pane = 0;
  g_overlay.mic_devices.clear();
}

void FinishOverlayWithString(const std::string& val) {
  if (g_overlay.settled) return;
  g_overlay.settled = true;
  auto res = std::move(g_overlay.pending_result);
  CloseInteractiveOverlay();
  if (res) res->Success(EncodableValue(val));
}

void FinishOverlayCancelled() {
  if (g_overlay.settled) return;
  g_overlay.settled = true;
  auto res = std::move(g_overlay.pending_result);
  CloseInteractiveOverlay();
  if (res) res->Success(EncodableValue());
}

void SettleOverlayCapture(OverlayMonitorPane* pane, RECT r) {
  if (!pane || !pane->screen_bits) {
    FinishOverlayCancelled();
    return;
  }
  int rx = std::clamp(static_cast<int>(r.left), 0, pane->width);
  int ry = std::clamp(static_cast<int>(r.top), 0, pane->height);
  int rw = std::clamp(static_cast<int>(r.right - r.left), 0, pane->width - rx);
  int rh = std::clamp(static_cast<int>(r.bottom - r.top), 0, pane->height - ry);
  if (rw <= 0 || rh <= 0) {
    FinishOverlayCancelled();
    return;
  }

  std::vector<uint8_t> cropped(static_cast<size_t>(rw) * rh * 4);
  size_t src_stride = static_cast<size_t>(pane->width) * 4;
  size_t dst_stride = static_cast<size_t>(rw) * 4;
  for (int row = 0; row < rh; ++row) {
    const uint8_t* s = pane->screen_bits +
                       static_cast<size_t>(ry + row) * src_stride +
                       static_cast<size_t>(rx) * 4;
    uint8_t* d = cropped.data() + static_cast<size_t>(row) * dst_stride;
    std::memcpy(d, s, dst_stride);
  }
  for (size_t i = 3; i < cropped.size(); i += 4) {
    cropped[i] = 0xFF;
  }

  if (g_overlay.settled) return;
  g_overlay.settled = true;
  auto res = std::move(g_overlay.pending_result);
  std::wstring target_w = g_overlay.target_path;
  CloseInteractiveOverlay();

  std::shared_ptr<CaptureMethodResult> shared_res(res.release());
  std::thread([pixels = std::move(cropped), rw, rh, dst_stride, target_w,
               shared_res]() mutable {
    HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool did_init = (co_hr == S_OK || co_hr == S_FALSE);
    bool ok = SaveBgraToPngFile(pixels.data(), rw, rh,
                                static_cast<int>(dst_stride), target_w);
    if (did_init) {
      ::CoUninitialize();
    }
    std::string utf8_path = ok ? WideToUtf8(target_w) : std::string();
    PostToPlatformThread([shared_res, ok, utf8_path]() {
      if (!shared_res) return;
      if (ok) {
        shared_res->Success(EncodableValue(utf8_path));
      } else {
        shared_res->Success(EncodableValue());
      }
    });
  }).detach();
}

void SettleOverlayRecord(OverlayMonitorPane* pane, RECT r,
                         bool full_screen_flag) {
  if (!pane) {
    FinishOverlayCancelled();
    return;
  }
  int rx = static_cast<int>(pane->screen_rect.left) +
           std::clamp(static_cast<int>(r.left), 0, pane->width);
  int ry = static_cast<int>(pane->screen_rect.top) +
           std::clamp(static_cast<int>(r.top), 0, pane->height);
  int rw = std::clamp(static_cast<int>(r.right - r.left), 16, pane->width);
  int rh = std::clamp(static_cast<int>(r.bottom - r.top), 16, pane->height);
  std::ostringstream oss;
  oss << "record:" << rx << ":" << ry << ":" << rw << ":" << rh << ":"
      << g_overlay.selected_fps << ":" << (g_overlay.record_mic ? 1 : 0) << ":"
      << (g_overlay.record_sys_audio ? 1 : 0) << ":"
      << (g_overlay.record_cursor ? 1 : 0) << ":"
      << (g_overlay.highlight_clicks ? 1 : 0) << ":"
      << (full_screen_flag ? 1 : 0) << ":"
      << UriEncodeUtf8(g_overlay.mic_device_id);
  FinishOverlayWithString(oss.str());
}

void SettleOverlayScroll(OverlayMonitorPane* pane, RECT r) {
  if (!pane) {
    FinishOverlayCancelled();
    return;
  }
  int rx = static_cast<int>(pane->screen_rect.left) +
           std::clamp(static_cast<int>(r.left), 0, pane->width);
  int ry = static_cast<int>(pane->screen_rect.top) +
           std::clamp(static_cast<int>(r.top), 0, pane->height);
  int rw = std::clamp(static_cast<int>(r.right - r.left), 24, pane->width);
  int rh = std::clamp(static_cast<int>(r.bottom - r.top), 24, pane->height);
  std::ostringstream oss;
  oss << "scrolling:" << rx << ":" << ry << ":" << rw << ":" << rh;
  FinishOverlayWithString(oss.str());
  SetMainWindowVisible(false);
}

void ConfirmOverlaySelection() {
  OverlayMonitorPane* pane = ActiveOverlayPane();
  if (!pane) {
    FinishOverlayCancelled();
    return;
  }
  bool full = !g_overlay.has_selection || g_overlay.is_full_screen_preset;
  RECT target = g_overlay.has_selection
                    ? g_overlay.sel
                    : RECT{0, 0, pane->width, pane->height};
  if (g_overlay.initial_mode == "record") {
    SettleOverlayRecord(pane, target, full);
  } else if (g_overlay.initial_mode == "scrolling") {
    SettleOverlayScroll(pane, target);
  } else {
    SettleOverlayCapture(pane, target);
  }
}

void ApplyOverlayPresetSize(int target_w, int target_h, bool full_screen) {
  OverlayMonitorPane* pane = ActiveOverlayPane();
  if (!pane) return;
  int mon_w = std::max(16, pane->width);
  int mon_h = std::max(16, pane->height);
  if (full_screen || target_w <= 0 || target_h <= 0) {
    g_overlay.sel = {0, 0, mon_w, mon_h};
    g_overlay.is_full_screen_preset = true;
  } else {
    int rw = std::min(target_w, mon_w);
    int rh = std::min(target_h, mon_h);
    int left = std::max(0, (mon_w - rw) / 2);
    int top = std::max(0, (mon_h - rh) / 2);
    g_overlay.sel = {left, top, left + rw, top + rh};
    g_overlay.is_full_screen_preset = (rw == mon_w && rh == mon_h);
  }
  g_overlay.has_selection = true;
  g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
  g_overlay.active_grip = -1;
  InvalidateOverlayPaneDirty(g_overlay.active_pane, true);
}

void CycleOverlayMicDevice() {
  if (g_overlay.mic_devices.empty()) return;
  size_t cur_idx = 0;
  bool found = false;
  for (size_t i = 0; i < g_overlay.mic_devices.size(); ++i) {
    if (g_overlay.mic_devices[i].first == g_overlay.mic_device_id) {
      cur_idx = i;
      found = true;
      break;
    }
  }
  size_t next_idx = found ? ((cur_idx + 1) % g_overlay.mic_devices.size()) : 0;
  g_overlay.mic_device_id = g_overlay.mic_devices[next_idx].first;
  g_overlay.record_mic = true;
}

std::wstring GetOverlaySelectedMicLabel() {
  for (const auto& kv : g_overlay.mic_devices) {
    if (kv.first == g_overlay.mic_device_id && !kv.second.empty()) {
      std::wstring w = Utf8ToWide(kv.second);
      if (w.size() > 24) w = w.substr(0, 21) + L"...";
      return w;
    }
  }
  if (!g_overlay.mic_devices.empty()) {
    std::wstring w = Utf8ToWide(g_overlay.mic_devices.front().second);
    if (w.size() > 24) w = w.substr(0, 21) + L"...";
    return w;
  }
  return L"Default Mic";
}

void DrawRoundedPill(HDC hdc, const RECT& r, COLORREF fill, COLORREF border,
                     const std::wstring& label, COLORREF text_color,
                     int corner = 10) {
  HBRUSH br = ::CreateSolidBrush(fill);
  HPEN pen = ::CreatePen(PS_SOLID, 1, border);
  HGDIOBJ old_br = ::SelectObject(hdc, br);
  HGDIOBJ old_pen = ::SelectObject(hdc, pen);
  ::RoundRect(hdc, r.left, r.top, r.right, r.bottom, corner, corner);
  ::SelectObject(hdc, old_br);
  ::SelectObject(hdc, old_pen);
  ::DeleteObject(br);
  ::DeleteObject(pen);
  ::SetBkMode(hdc, TRANSPARENT);
  ::SetTextColor(hdc, text_color);
  RECT txt = r;
  ::DrawTextW(hdc, label.c_str(), -1, &txt,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

void PopulateOverlayMicDevices() {
  {
    std::lock_guard<std::mutex> lock(g_audio_cache_mutex);
    g_overlay.mic_devices = g_cached_audio_devices;
  }
  if (g_overlay.mic_devices.empty() &&
      !g_audio_refresh_in_flight.exchange(true)) {
    EnumerateWindowsAudioDevicesWorker(nullptr, true);
  }
}

void UpdateChromeUnion(RECT* acc, bool* has_acc, const RECT& r) {
  if (r.right <= r.left || r.bottom <= r.top) return;
  if (!*has_acc) {
    *acc = r;
    *has_acc = true;
  } else {
    ::UnionRect(acc, acc, &r);
  }
}

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                LPARAM lparam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  int pane_idx = static_cast<int>(
      reinterpret_cast<intptr_t>(::GetWindowLongPtrW(hwnd, GWLP_USERDATA)));
  OverlayMonitorPane* pane =
      (pane_idx >= 0 && pane_idx < static_cast<int>(g_overlay.panes.size()))
          ? &g_overlay.panes[static_cast<size_t>(pane_idx)]
          : nullptr;

  switch (msg) {
    case WM_ERASEBKGND:
      return 1;

    case kMsgOverlayCancel:
      FinishOverlayCancelled();
      return 0;

    case kMsgOverlayConfirm:
      ConfirmOverlaySelection();
      return 0;

    case WM_SETCURSOR: {
      if (LOWORD(lparam) == HTCLIENT && pane) {
        POINT pt = {};
        ::GetCursorPos(&pt);
        ::ScreenToClient(hwnd, &pt);
        LPCWSTR cur = IDC_CROSS;
        auto in_btn = [&](const RECT& r) {
          return (r.right > r.left && r.bottom > r.top) && ::PtInRect(&r, pt);
        };
        if (pane_idx == g_overlay.active_pane) {
          if (in_btn(g_overlay.cancel_btn) || in_btn(g_overlay.capture_btn) ||
              in_btn(g_overlay.record_btn) || in_btn(g_overlay.scroll_btn) ||
              in_btn(g_overlay.preset_full_btn) ||
              in_btn(g_overlay.preset_1080_btn) ||
              in_btn(g_overlay.preset_720_btn) ||
              in_btn(g_overlay.tb_full_btn) ||
              in_btn(g_overlay.tb_1080_btn) ||
              in_btn(g_overlay.tb_720_btn) || in_btn(g_overlay.fps_btn) ||
              in_btn(g_overlay.mic_btn) || in_btn(g_overlay.mic_cycle_btn) ||
              in_btn(g_overlay.sys_audio_btn) ||
              in_btn(g_overlay.cursor_btn) ||
              in_btn(g_overlay.mode_snip_btn)) {
            cur = IDC_HAND;
          } else if (g_overlay.has_selection &&
                     (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
                      g_overlay.mode == InteractiveOverlayState::Mode::kResizing)) {
            int grip =
                (g_overlay.mode == InteractiveOverlayState::Mode::kResizing)
                    ? g_overlay.active_grip
                    : HitTestOverlayGrip(g_overlay.sel, pt, pane->dpi_scale);
            if (grip == 0 || grip == 4) {
              cur = IDC_SIZENWSE;
            } else if (grip == 1 || grip == 5) {
              cur = IDC_SIZENS;
            } else if (grip == 2 || grip == 6) {
              cur = IDC_SIZENESW;
            } else if (grip == 3 || grip == 7) {
              cur = IDC_SIZEWE;
            } else if (::PtInRect(&g_overlay.sel, pt)) {
              cur = IDC_SIZEALL;
            }
          } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving) {
            cur = IDC_SIZEALL;
          }
        }
        ::SetCursor(::LoadCursorW(nullptr, cur));
        return TRUE;
      }
      break;
    }

    case WM_KEYDOWN: {
      if (wparam == VK_ESCAPE) {
        FinishOverlayCancelled();
        return 0;
      }
      if (wparam == VK_RETURN || wparam == VK_SPACE) {
        ConfirmOverlaySelection();
        return 0;
      }
      break;
    }

    case WM_RBUTTONDOWN:
      FinishOverlayCancelled();
      return 0;

    case WM_LBUTTONDOWN: {
      if (!pane) return 0;
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      int prev_active = g_overlay.active_pane;
      if (prev_active != pane_idx) {
        g_overlay.active_pane = pane_idx;
        g_overlay.has_selection = false;
        g_overlay.mode = InteractiveOverlayState::Mode::kIdle;
        g_overlay.active_grip = -1;
        g_overlay.is_full_screen_preset = false;
        ClearOverlayButtonRects();
        InvalidateOverlayPaneDirty(prev_active, true);
      }

      g_overlay.drag_start = pt;
      if (!g_overlay.has_selection && g_overlay.initial_mode == "record") {
        if (::PtInRect(&g_overlay.cancel_btn, pt)) {
          FinishOverlayCancelled();
          return 0;
        }
        if (::PtInRect(&g_overlay.preset_full_btn, pt)) {
          ApplyOverlayPresetSize(0, 0, true);
          return 0;
        }
        if (::PtInRect(&g_overlay.preset_1080_btn, pt)) {
          ApplyOverlayPresetSize(1920, 1080, false);
          return 0;
        }
        if (::PtInRect(&g_overlay.preset_720_btn, pt)) {
          ApplyOverlayPresetSize(1280, 720, false);
          return 0;
        }
      }
      if (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting &&
          g_overlay.has_selection) {
        if (::PtInRect(&g_overlay.cancel_btn, pt)) {
          FinishOverlayCancelled();
          return 0;
        }
        if (g_overlay.initial_mode == "record") {
          if (::PtInRect(&g_overlay.tb_full_btn, pt)) {
            ApplyOverlayPresetSize(0, 0, true);
            return 0;
          }
          if (::PtInRect(&g_overlay.tb_1080_btn, pt)) {
            ApplyOverlayPresetSize(1920, 1080, false);
            return 0;
          }
          if (::PtInRect(&g_overlay.tb_720_btn, pt)) {
            ApplyOverlayPresetSize(1280, 720, false);
            return 0;
          }
          if (::PtInRect(&g_overlay.fps_btn, pt)) {
            g_overlay.selected_fps = (g_overlay.selected_fps == 60) ? 30 : 60;
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.mic_btn, pt)) {
            g_overlay.record_mic = !g_overlay.record_mic;
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.mic_cycle_btn, pt)) {
            CycleOverlayMicDevice();
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.sys_audio_btn, pt)) {
            g_overlay.record_sys_audio = !g_overlay.record_sys_audio;
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.cursor_btn, pt)) {
            g_overlay.record_cursor = !g_overlay.record_cursor;
            g_overlay.highlight_clicks = g_overlay.record_cursor;
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.mode_snip_btn, pt)) {
            g_overlay.initial_mode = "capture";
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.record_btn, pt)) {
            SettleOverlayRecord(pane, g_overlay.sel,
                                g_overlay.is_full_screen_preset);
            return 0;
          }
        } else {
          if (::PtInRect(&g_overlay.capture_btn, pt)) {
            SettleOverlayCapture(pane, g_overlay.sel);
            return 0;
          }
          if (::PtInRect(&g_overlay.record_btn, pt)) {
            PopulateOverlayMicDevices();
            g_overlay.initial_mode = "record";
            InvalidateOverlayPaneDirty(pane_idx);
            return 0;
          }
          if (::PtInRect(&g_overlay.scroll_btn, pt)) {
            SettleOverlayScroll(pane, g_overlay.sel);
            return 0;
          }
        }
        int grip = HitTestOverlayGrip(g_overlay.sel, pt, pane->dpi_scale);
        if (grip >= 0) {
          g_overlay.active_grip = grip;
          g_overlay.sel_at_start = g_overlay.sel;
          g_overlay.is_full_screen_preset = false;
          g_overlay.mode = InteractiveOverlayState::Mode::kResizing;
          ::SetCapture(hwnd);
          InvalidateOverlayPaneDirty(pane_idx);
          return 0;
        }
        if (::PtInRect(&g_overlay.sel, pt)) {
          g_overlay.sel_at_start = g_overlay.sel;
          g_overlay.is_full_screen_preset = false;
          g_overlay.mode = InteractiveOverlayState::Mode::kMoving;
          ::SetCapture(hwnd);
          InvalidateOverlayPaneDirty(pane_idx);
          return 0;
        }
      }
      g_overlay.active_grip = -1;
      g_overlay.is_full_screen_preset = false;
      g_overlay.sel = {pt.x, pt.y, pt.x, pt.y};
      g_overlay.has_selection = true;
      g_overlay.mode = InteractiveOverlayState::Mode::kDrawing;
      ::SetCapture(hwnd);
      InvalidateOverlayPaneDirty(pane_idx);
      return 0;
    }

    case WM_MOUSEMOVE: {
      if (!pane) return 0;
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (g_overlay.mode == InteractiveOverlayState::Mode::kIdle &&
          !g_overlay.has_selection && g_overlay.active_pane != pane_idx) {
        int prev_active = g_overlay.active_pane;
        g_overlay.active_pane = pane_idx;
        if (g_overlay.initial_mode == "record") {
          InvalidateOverlayPaneDirty(prev_active);
          InvalidateOverlayPaneDirty(pane_idx);
        }
        return 0;
      }
      if (pane_idx != g_overlay.active_pane) return 0;

      if (g_overlay.mode == InteractiveOverlayState::Mode::kDrawing) {
        g_overlay.sel.left = std::clamp(std::min(g_overlay.drag_start.x, pt.x),
                                        0L, static_cast<LONG>(pane->width));
        g_overlay.sel.top = std::clamp(std::min(g_overlay.drag_start.y, pt.y),
                                       0L, static_cast<LONG>(pane->height));
        g_overlay.sel.right = std::clamp(std::max(g_overlay.drag_start.x, pt.x),
                                         0L, static_cast<LONG>(pane->width));
        g_overlay.sel.bottom = std::clamp(
            std::max(g_overlay.drag_start.y, pt.y), 0L,
            static_cast<LONG>(pane->height));
        InvalidateOverlayPaneDirty(pane_idx);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kResizing &&
                 g_overlay.active_grip >= 0 && g_overlay.active_grip < 8) {
        int dx = pt.x - g_overlay.drag_start.x;
        int dy = pt.y - g_overlay.drag_start.y;
        RECT r = g_overlay.sel_at_start;
        switch (g_overlay.active_grip) {
          case 0:
            r.left += dx;
            r.top += dy;
            break;
          case 1:
            r.top += dy;
            break;
          case 2:
            r.right += dx;
            r.top += dy;
            break;
          case 3:
            r.right += dx;
            break;
          case 4:
            r.right += dx;
            r.bottom += dy;
            break;
          case 5:
            r.bottom += dy;
            break;
          case 6:
            r.left += dx;
            r.bottom += dy;
            break;
          case 7:
            r.left += dx;
            break;
        }
        LONG max_w = static_cast<LONG>(pane->width);
        LONG max_h = static_cast<LONG>(pane->height);
        LONG nl = std::clamp(std::min(r.left, r.right), 0L, max_w);
        LONG nr = std::clamp(std::max(r.left, r.right), 0L, max_w);
        LONG nt = std::clamp(std::min(r.top, r.bottom), 0L, max_h);
        LONG nb = std::clamp(std::max(r.top, r.bottom), 0L, max_h);
        if (nr - nl < 4) nr = std::min(max_w, nl + 4);
        if (nb - nt < 4) nb = std::min(max_h, nt + 4);
        g_overlay.sel = {nl, nt, nr, nb};
        InvalidateOverlayPaneDirty(pane_idx);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving) {
        int dx = pt.x - g_overlay.drag_start.x;
        int dy = pt.y - g_overlay.drag_start.y;
        RECT r = g_overlay.sel_at_start;
        int w = static_cast<int>(r.right - r.left);
        int h = static_cast<int>(r.bottom - r.top);
        int nl = std::clamp(static_cast<int>(r.left) + dx, 0,
                            std::max(0, pane->width - w));
        int nt = std::clamp(static_cast<int>(r.top) + dy, 0,
                            std::max(0, pane->height - h));
        g_overlay.sel = {nl, nt, nl + w, nt + h};
        InvalidateOverlayPaneDirty(pane_idx);
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      if (!pane || pane_idx != g_overlay.active_pane) return 0;
      ::ReleaseCapture();
      if (g_overlay.mode == InteractiveOverlayState::Mode::kDrawing) {
        int w = static_cast<int>(g_overlay.sel.right - g_overlay.sel.left);
        int h = static_cast<int>(g_overlay.sel.bottom - g_overlay.sel.top);
        if (w < 8 || h < 8) {
          g_overlay.sel = {0, 0, pane->width, pane->height};
          g_overlay.has_selection = true;
          g_overlay.is_full_screen_preset = true;
          g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
          InvalidateOverlayPaneDirty(pane_idx, true);
          return 0;
        }
        g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
        InvalidateOverlayPaneDirty(pane_idx);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving ||
                 g_overlay.mode == InteractiveOverlayState::Mode::kResizing) {
        g_overlay.active_grip = -1;
        g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
        InvalidateOverlayPaneDirty(pane_idx);
      }
      return 0;
    }

    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = ::BeginPaint(hwnd, &ps);
      if (!pane) {
        ::EndPaint(hwnd, &ps);
        return 0;
      }

      RECT rc_paint = ps.rcPaint;
      rc_paint.left = std::clamp<LONG>(rc_paint.left, 0, pane->width);
      rc_paint.top = std::clamp<LONG>(rc_paint.top, 0, pane->height);
      rc_paint.right = std::clamp<LONG>(rc_paint.right, 0, pane->width);
      rc_paint.bottom = std::clamp<LONG>(rc_paint.bottom, 0, pane->height);
      int dirty_w = static_cast<int>(rc_paint.right - rc_paint.left);
      int dirty_h = static_cast<int>(rc_paint.bottom - rc_paint.top);
      if (dirty_w <= 0 || dirty_h <= 0) {
        ::EndPaint(hwnd, &ps);
        return 0;
      }

      HDC mem_dc = pane->backbuf_dc;
      HBITMAP temp_bmp = nullptr;
      HGDIOBJ temp_old = nullptr;
      if (!mem_dc) {
        mem_dc = ::CreateCompatibleDC(hdc);
        temp_bmp = ::CreateCompatibleBitmap(hdc, pane->width, pane->height);
        temp_old = ::SelectObject(mem_dc, temp_bmp);
      }

      if (pane->dim_dc) {
        ::BitBlt(mem_dc, rc_paint.left, rc_paint.top, dirty_w, dirty_h,
                 pane->dim_dc, rc_paint.left, rc_paint.top, SRCCOPY);
      } else if (pane->scr_dc) {
        ::BitBlt(mem_dc, rc_paint.left, rc_paint.top, dirty_w, dirty_h,
                 pane->scr_dc, rc_paint.left, rc_paint.top, SRCCOPY);
      }

      const bool is_active = (pane_idx == g_overlay.active_pane);
      RECT chrome_bounds = {0, 0, 0, 0};
      bool has_chrome = false;

      if (is_active) {
        ClearOverlayButtonRects();
        HGDIOBJ old_font =
            pane->font_ui ? ::SelectObject(mem_dc, pane->font_ui) : nullptr;
        const double s = pane->dpi_scale;
        const int corner = OverlayScalePx(10, s);

        int sl = 0;
        int st = 0;
        int sr = 0;
        int sb = 0;
        if (g_overlay.has_selection) {
          sl = std::clamp(static_cast<int>(g_overlay.sel.left), 0, pane->width);
          st = std::clamp(static_cast<int>(g_overlay.sel.top), 0, pane->height);
          sr = std::clamp(static_cast<int>(g_overlay.sel.right), 0,
                          pane->width);
          sb = std::clamp(static_cast<int>(g_overlay.sel.bottom), 0,
                          pane->height);
          if (sr > sl && sb > st && pane->scr_dc) {
            RECT sel_rc = {sl, st, sr, sb};
            RECT punch = {};
            if (::IntersectRect(&punch, &sel_rc, &rc_paint)) {
              ::BitBlt(mem_dc, punch.left, punch.top, punch.right - punch.left,
                       punch.bottom - punch.top, pane->scr_dc, punch.left,
                       punch.top, SRCCOPY);
            }
          }
        }

        if (!g_overlay.has_selection && g_overlay.initial_mode == "record") {
          int btn_h = OverlayScalePx(34, s);
          int w_full = OverlayScalePx(104, s);
          int w_1080 = OverlayScalePx(96, s);
          int w_720 = OverlayScalePx(92, s);
          int w_can = OverlayScalePx(76, s);
          int gap = OverlayScalePx(8, s);
          int total_w = w_full + w_1080 + w_720 + w_can + gap * 3;
          int bx = std::max(OverlayScalePx(12, s), (pane->width - total_w) / 2);
          int by = std::max(OverlayScalePx(12, s),
                            pane->height - btn_h - OverlayScalePx(48, s));

          g_overlay.preset_full_btn = {bx, by, bx + w_full, by + btn_h};
          int x2 = bx + w_full + gap;
          g_overlay.preset_1080_btn = {x2, by, x2 + w_1080, by + btn_h};
          int x3 = x2 + w_1080 + gap;
          g_overlay.preset_720_btn = {x3, by, x3 + w_720, by + btn_h};
          int x4 = x3 + w_720 + gap;
          g_overlay.cancel_btn = {x4, by, x4 + w_can, by + btn_h};

          UpdateChromeUnion(&chrome_bounds, &has_chrome,
                            {bx - 4, by - 4, x4 + w_can + 4, by + btn_h + 4});

          DrawRoundedPill(mem_dc, g_overlay.preset_full_btn, RGB(34, 30, 28),
                          RGB(140, 118, 102), L"Full Screen",
                          RGB(255, 255, 255), corner);
          DrawRoundedPill(mem_dc, g_overlay.preset_1080_btn, RGB(34, 30, 28),
                          RGB(140, 118, 102), L"1920x1080", RGB(255, 255, 255),
                          corner);
          DrawRoundedPill(mem_dc, g_overlay.preset_720_btn, RGB(34, 30, 28),
                          RGB(140, 118, 102), L"1280x720", RGB(255, 255, 255),
                          corner);
          DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(50, 32, 32),
                          RGB(185, 70, 70), L"Cancel", RGB(255, 220, 220),
                          corner);
        }

        if (g_overlay.has_selection && sr > sl && sb > st) {
          int stroke_w = std::max(2, OverlayScalePx(2, s));
          HPEN pen = ::CreatePen(PS_SOLID, stroke_w, RGB(215, 65, 55));
          HGDIOBJ old_pen = ::SelectObject(mem_dc, pen);
          HGDIOBJ old_brush =
              ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
          ::Rectangle(mem_dc, sl, st, sr, sb);
          ::SelectObject(mem_dc, old_brush);
          ::SelectObject(mem_dc, old_pen);
          ::DeleteObject(pen);
          UpdateChromeUnion(&chrome_bounds, &has_chrome,
                            {sl - stroke_w - 6, st - stroke_w - 6,
                             sr + stroke_w + 6, sb + stroke_w + 6});

          if (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
              g_overlay.mode == InteractiveOverlayState::Mode::kResizing) {
            if ((sr - sl) >= 16 && (sb - st) >= 16) {
              POINT pts[8];
              ComputeOverlayGripPoints(RECT{sl, st, sr, sb}, pts);
              int grip_half = std::max(4, OverlayScalePx(4, s));
              HBRUSH grip_fill = ::CreateSolidBrush(RGB(255, 255, 255));
              HPEN grip_pen = ::CreatePen(PS_SOLID, 1, RGB(215, 65, 55));
              HGDIOBJ old_gf = ::SelectObject(mem_dc, grip_fill);
              HGDIOBJ old_gp = ::SelectObject(mem_dc, grip_pen);
              for (int i = 0; i < 8; ++i) {
                ::Rectangle(mem_dc, pts[i].x - grip_half, pts[i].y - grip_half,
                            pts[i].x + grip_half + 1,
                            pts[i].y + grip_half + 1);
              }
              ::SelectObject(mem_dc, old_gf);
              ::SelectObject(mem_dc, old_gp);
              ::DeleteObject(grip_fill);
              ::DeleteObject(grip_pen);
            }
          }

          int sel_w = sr - sl;
          int sel_h = sb - st;
          std::wostringstream dim_oss;
          dim_oss << sel_w << L" x " << sel_h;
          if (g_overlay.initial_mode == "record" && g_overlay.record_mic) {
            dim_oss << L"  |  " << GetOverlaySelectedMicLabel();
          }
          std::wstring dim_str = dim_oss.str();
          int pad_edge = OverlayScalePx(8, s);
          int badge_h = OverlayScalePx(22, s);
          int badge_w =
              std::max(OverlayScalePx(108, s),
                       static_cast<int>(dim_str.size()) *
                               OverlayScalePx(8, s) +
                           OverlayScalePx(20, s));
          int badge_x =
              std::clamp(sl, pad_edge,
                         std::max(pad_edge, pane->width - badge_w - pad_edge));
          int badge_y = (st >= OverlayScalePx(36, s))
                            ? (st - OverlayScalePx(28, s))
                            : (st + pad_edge);
          RECT dim_badge = {badge_x, badge_y, badge_x + badge_w,
                            badge_y + badge_h};
          UpdateChromeUnion(&chrome_bounds, &has_chrome, dim_badge);
          DrawRoundedPill(mem_dc, dim_badge, RGB(28, 22, 18),
                          RGB(111, 78, 55), dim_str, RGB(255, 255, 255),
                          OverlayScalePx(8, s));

          if (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
              g_overlay.mode == InteractiveOverlayState::Mode::kMoving ||
              g_overlay.mode == InteractiveOverlayState::Mode::kResizing) {
            bool is_full_mon =
                g_overlay.is_full_screen_preset ||
                ((sr - sl) >= pane->width - 8 && (sb - st) >= pane->height - 8);
            if (g_overlay.initial_mode == "record") {
              g_overlay.capture_btn = {0, 0, 0, 0};
              bool has_multi_mic = g_overlay.mic_devices.size() > 1;
              int btn_h = OverlayScalePx(34, s);
              int w_full = OverlayScalePx(44, s);
              int w_1080 = OverlayScalePx(52, s);
              int w_720 = OverlayScalePx(46, s);
              int w_fps = OverlayScalePx(58, s);
              int w_mic = OverlayScalePx(68, s);
              int w_mic_cyc = has_multi_mic ? OverlayScalePx(24, s) : 0;
              int w_sys = OverlayScalePx(76, s);
              int w_cur = OverlayScalePx(82, s);
              int w_snip = OverlayScalePx(48, s);
              int w_rec = OverlayScalePx(64, s);
              int w_can = OverlayScalePx(30, s);
              int gap = OverlayScalePx(5, s);
              int total_w = w_full + w_1080 + w_720 + w_fps + w_mic +
                            (has_multi_mic ? (w_mic_cyc + 2) : 0) + w_sys +
                            w_cur + w_snip + w_rec + w_can + gap * 9;
              int min_bx = pad_edge;
              int max_bx = std::max(min_bx, pane->width - total_w - pad_edge);
              int bx = std::clamp((sl + sr - total_w) / 2, min_bx, max_bx);
              int by =
                  is_full_mon
                      ? std::max(OverlayScalePx(12, s),
                                 pane->height - btn_h - OverlayScalePx(68, s))
                      : (sb + OverlayScalePx(10, s));
              if (!is_full_mon &&
                  by + btn_h > pane->height - OverlayScalePx(10, s)) {
                by = std::max(OverlayScalePx(10, s),
                              sb - btn_h - OverlayScalePx(14, s));
              }

              int cx = bx;
              g_overlay.tb_full_btn = {cx, by, cx + w_full, by + btn_h};
              cx += w_full + gap;
              g_overlay.tb_1080_btn = {cx, by, cx + w_1080, by + btn_h};
              cx += w_1080 + gap;
              g_overlay.tb_720_btn = {cx, by, cx + w_720, by + btn_h};
              cx += w_720 + gap;
              g_overlay.fps_btn = {cx, by, cx + w_fps, by + btn_h};
              cx += w_fps + gap;
              g_overlay.mic_btn = {cx, by, cx + w_mic, by + btn_h};
              cx += w_mic;
              if (has_multi_mic) {
                cx += 2;
                g_overlay.mic_cycle_btn = {cx, by, cx + w_mic_cyc, by + btn_h};
                cx += w_mic_cyc;
              }
              cx += gap;
              g_overlay.sys_audio_btn = {cx, by, cx + w_sys, by + btn_h};
              cx += w_sys + gap;
              g_overlay.cursor_btn = {cx, by, cx + w_cur, by + btn_h};
              cx += w_cur + gap;
              g_overlay.mode_snip_btn = {cx, by, cx + w_snip, by + btn_h};
              cx += w_snip + gap;
              g_overlay.record_btn = {cx, by, cx + w_rec, by + btn_h};
              cx += w_rec + gap;
              g_overlay.cancel_btn = {cx, by, cx + w_can, by + btn_h};

              UpdateChromeUnion(&chrome_bounds, &has_chrome,
                                {bx - 6, by - 6, cx + w_can + 6, by + btn_h + 6});

              DrawRoundedPill(
                  mem_dc, g_overlay.tb_full_btn,
                  g_overlay.is_full_screen_preset ? RGB(111, 78, 55)
                                                  : RGB(38, 32, 28),
                  RGB(120, 100, 86), L"Full", RGB(255, 255, 255), corner);
              DrawRoundedPill(mem_dc, g_overlay.tb_1080_btn, RGB(38, 32, 28),
                              RGB(120, 100, 86), L"1080p", RGB(255, 255, 255),
                              corner);
              DrawRoundedPill(mem_dc, g_overlay.tb_720_btn, RGB(38, 32, 28),
                              RGB(120, 100, 86), L"720p", RGB(255, 255, 255),
                              corner);
              DrawRoundedPill(
                  mem_dc, g_overlay.fps_btn, RGB(38, 32, 28), RGB(120, 100, 86),
                  g_overlay.selected_fps == 60 ? L"60fps" : L"30fps",
                  RGB(255, 255, 255), corner);
              DrawRoundedPill(
                  mem_dc, g_overlay.mic_btn,
                  g_overlay.record_mic ? RGB(46, 105, 62) : RGB(38, 32, 28),
                  RGB(120, 100, 86),
                  g_overlay.record_mic ? L"Mic On" : L"Mic Off",
                  RGB(255, 255, 255), corner);
              if (has_multi_mic) {
                DrawRoundedPill(mem_dc, g_overlay.mic_cycle_btn,
                                RGB(48, 40, 35), RGB(120, 100, 86), L"v",
                                RGB(255, 255, 255), corner);
              }
              DrawRoundedPill(
                  mem_dc, g_overlay.sys_audio_btn,
                  g_overlay.record_sys_audio ? RGB(46, 105, 62)
                                             : RGB(38, 32, 28),
                  RGB(120, 100, 86),
                  g_overlay.record_sys_audio ? L"Sys On" : L"Sys Off",
                  RGB(255, 255, 255), corner);
              DrawRoundedPill(
                  mem_dc, g_overlay.cursor_btn,
                  g_overlay.record_cursor ? RGB(46, 105, 62) : RGB(38, 32, 28),
                  RGB(120, 100, 86),
                  g_overlay.record_cursor ? L"Cur On" : L"Cur Off",
                  RGB(255, 255, 255), corner);
              DrawRoundedPill(mem_dc, g_overlay.mode_snip_btn, RGB(58, 46, 38),
                              RGB(130, 105, 88), L"Snip", RGB(240, 232, 224),
                              corner);
              DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(205, 42, 42),
                              RGB(240, 90, 90), L"Rec", RGB(255, 255, 255),
                              corner);
              DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                              RGB(110, 90, 78), L"X", RGB(255, 255, 255),
                              corner);
            } else {
              bool scroll_mode = (g_overlay.initial_mode == "scrolling");
              int btn_h = OverlayScalePx(30, s);
              int cap_w = OverlayScalePx(88, s);
              int rec_w = OverlayScalePx(78, s);
              int scr_w = OverlayScalePx(scroll_mode ? 104 : 78, s);
              int can_w = OverlayScalePx(32, s);
              int gap = OverlayScalePx(6, s);
              int total_w = cap_w + gap + rec_w + gap + scr_w + gap + can_w;
              int min_bx = pad_edge;
              int max_bx = std::max(min_bx, pane->width - total_w - pad_edge);
              int bx = 0;
              int by = 0;
              if (is_full_mon) {
                bx = std::clamp((pane->width - total_w) / 2, min_bx, max_bx);
                by = std::max(OverlayScalePx(12, s),
                              pane->height - btn_h - OverlayScalePx(68, s));
              } else {
                bx = std::clamp(sr - total_w, min_bx, max_bx);
                by = sb + pad_edge;
                if (by + btn_h > pane->height - pad_edge) {
                  by = std::max(pad_edge, st - btn_h - pad_edge);
                }
              }

              int tray_px = OverlayScalePx(10, s);
              int tray_py = OverlayScalePx(6, s);
              RECT tray = {bx - tray_px, by - tray_py, bx + total_w + tray_px,
                           by + btn_h + tray_py};
              UpdateChromeUnion(&chrome_bounds, &has_chrome, tray);
              if (is_full_mon) {
                DrawRoundedPill(mem_dc, tray, RGB(24, 18, 14),
                                RGB(110, 90, 78), L"", RGB(255, 255, 255),
                                corner);
              }

              if (scroll_mode) {
                g_overlay.scroll_btn = {bx, by, bx + scr_w, by + btn_h};
                g_overlay.capture_btn = {bx + scr_w + gap, by,
                                         bx + scr_w + gap + cap_w, by + btn_h};
                g_overlay.record_btn = {
                    bx + scr_w + gap + cap_w + gap, by,
                    bx + scr_w + gap + cap_w + gap + rec_w, by + btn_h};
                g_overlay.cancel_btn = {
                    bx + scr_w + gap + cap_w + gap + rec_w + gap, by,
                    bx + total_w, by + btn_h};

                DrawRoundedPill(mem_dc, g_overlay.scroll_btn, RGB(111, 78, 55),
                                RGB(190, 148, 110), L"Start Scroll",
                                RGB(255, 255, 255), corner);
                DrawRoundedPill(mem_dc, g_overlay.capture_btn, RGB(58, 48, 41),
                                RGB(160, 122, 92), L"Capture",
                                RGB(255, 255, 255), corner);
                DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(185, 45, 45),
                                RGB(230, 85, 85), L"Video", RGB(255, 255, 255),
                                corner);
                DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                                RGB(110, 90, 78), L"X", RGB(255, 255, 255),
                                corner);
              } else {
                g_overlay.capture_btn = {bx, by, bx + cap_w, by + btn_h};
                g_overlay.record_btn = {bx + cap_w + gap, by,
                                        bx + cap_w + gap + rec_w, by + btn_h};
                g_overlay.scroll_btn = {
                    bx + cap_w + gap + rec_w + gap, by,
                    bx + cap_w + gap + rec_w + gap + scr_w, by + btn_h};
                g_overlay.cancel_btn = {
                    bx + cap_w + gap + rec_w + gap + scr_w + gap, by,
                    bx + total_w, by + btn_h};

                DrawRoundedPill(mem_dc, g_overlay.capture_btn, RGB(111, 78, 55),
                                RGB(160, 122, 92), L"Capture",
                                RGB(255, 255, 255), corner);
                DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(185, 45, 45),
                                RGB(230, 85, 85), L"Video", RGB(255, 255, 255),
                                corner);
                DrawRoundedPill(mem_dc, g_overlay.scroll_btn, RGB(58, 48, 41),
                                RGB(160, 122, 92), L"Scroll",
                                RGB(255, 255, 255), corner);
                DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                                RGB(110, 90, 78), L"X", RGB(255, 255, 255),
                                corner);
              }
            }
          }
        }

        if (old_font) {
          ::SelectObject(mem_dc, old_font);
        }
      }

      pane->has_last_chrome = has_chrome;
      pane->last_chrome_bounds = chrome_bounds;

      ::BitBlt(hdc, rc_paint.left, rc_paint.top, dirty_w, dirty_h, mem_dc,
               rc_paint.left, rc_paint.top, SRCCOPY);
      if (temp_bmp) {
        ::SelectObject(mem_dc, temp_old);
        ::DeleteObject(temp_bmp);
        ::DeleteDC(mem_dc);
      }
      ::EndPaint(hwnd, &ps);
      return 0;
    }
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void StartWin32InteractiveOverlay(
    const std::wstring& target_path, const std::string& initial_mode,
    int initial_fps, bool initial_record_mic,
    const std::string& initial_mic_id, bool initial_sys_audio,
    bool initial_cursor, bool initial_clicks,
    std::unique_ptr<CaptureMethodResult> result) {
  if (g_overlay.pending_result && !g_overlay.settled) {
    FinishOverlayCancelled();
  } else {
    CloseInteractiveOverlay();
  }

  g_overlay = InteractiveOverlayState{};
  g_overlay.target_path = target_path;
  g_overlay.initial_mode = initial_mode;
  g_overlay.selected_fps = (initial_fps == 30) ? 30 : 60;
  g_overlay.record_mic = initial_record_mic;
  g_overlay.mic_device_id = initial_mic_id;
  g_overlay.record_sys_audio = initial_sys_audio;
  g_overlay.record_cursor = initial_cursor;
  g_overlay.highlight_clicks = initial_clicks;
  g_overlay.pending_result = std::move(result);

  if (initial_mode == "record") {
    PopulateOverlayMicDevices();
  }

  std::vector<CapturedMonitorFrame> monitors;
  if (!ConsumePrecaptureMonitors(&monitors)) {
    if (!CaptureAllMonitorsFast(&monitors) || monitors.empty()) {
      FinishOverlayCancelled();
      return;
    }
  }

  POINT cursor_pt = {};
  if (!::GetCursorPos(&cursor_pt)) {
    cursor_pt.x = 0;
    cursor_pt.y = 0;
  }

  static const wchar_t* kOverlayClass = L"SnipSnapOverlayMonitorClass";
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = OverlayWndProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.hCursor = ::LoadCursor(nullptr, IDC_CROSS);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kOverlayClass;
    ::RegisterClassExW(&wc);
    registered = true;
  }

  HDC screen_dc = ::GetDC(nullptr);
  if (!screen_dc) {
    FinishOverlayCancelled();
    return;
  }

  int cursor_pane_idx = 0;
  g_overlay.panes.reserve(monitors.size());
  for (size_t i = 0; i < monitors.size(); ++i) {
    const auto& mon = monitors[i];
    if (mon.width <= 0 || mon.height <= 0 || mon.bgra.empty()) continue;

    OverlayMonitorPane pane;
    pane.hmon = mon.hmon;
    pane.screen_rect = mon.monitor_rect;
    pane.width = mon.width;
    pane.height = mon.height;
    pane.dpi_scale =
        std::clamp(static_cast<double>(mon.dpi) / 96.0, 1.0, 3.0);

    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = pane.width;
    bmi.bmiHeader.biHeight = -pane.height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* raw_bits = nullptr;
    pane.screen_bitmap = ::CreateDIBSection(
        screen_dc, &bmi, DIB_RGB_COLORS, &raw_bits, nullptr, 0);
    if (!pane.screen_bitmap || !raw_bits) {
      pane.CleanupResources();
      continue;
    }
    pane.screen_bits = static_cast<uint8_t*>(raw_bits);
    size_t copy_bytes = std::min(
        mon.bgra.size(),
        static_cast<size_t>(pane.width) * static_cast<size_t>(pane.height) * 4);
    std::memcpy(pane.screen_bits, mon.bgra.data(), copy_bytes);

    void* dim_raw = nullptr;
    pane.dim_bitmap = ::CreateDIBSection(
        screen_dc, &bmi, DIB_RGB_COLORS, &dim_raw, nullptr, 0);
    if (pane.dim_bitmap && dim_raw) {
      int stride = pane.width * 4;
      snipsnap_dim_bgra(pane.screen_bits, static_cast<uint8_t*>(dim_raw),
                        pane.width, pane.height, stride, stride, 160);
    }

    pane.scr_dc = ::CreateCompatibleDC(screen_dc);
    if (pane.scr_dc) {
      pane.scr_old_bmp = ::SelectObject(pane.scr_dc, pane.screen_bitmap);
    }
    pane.dim_dc = ::CreateCompatibleDC(screen_dc);
    if (pane.dim_dc && pane.dim_bitmap) {
      pane.dim_old_bmp = ::SelectObject(pane.dim_dc, pane.dim_bitmap);
    }
    pane.backbuf_dc = ::CreateCompatibleDC(screen_dc);
    pane.backbuf_bitmap =
        ::CreateCompatibleBitmap(screen_dc, pane.width, pane.height);
    if (pane.backbuf_dc && pane.backbuf_bitmap) {
      pane.backbuf_old_bmp =
          ::SelectObject(pane.backbuf_dc, pane.backbuf_bitmap);
    }

    pane.font_ui = ::CreateFontW(
        -OverlayScalePx(13, pane.dpi_scale), 0, 0, 0, FW_SEMIBOLD, FALSE,
        FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    pane.font_bold = ::CreateFontW(
        -OverlayScalePx(14, pane.dpi_scale), 0, 0, 0, FW_BOLD, FALSE, FALSE,
        FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");

    int pane_index = static_cast<int>(g_overlay.panes.size());
    if (::PtInRect(&pane.screen_rect, cursor_pt)) {
      cursor_pane_idx = pane_index;
    }

    pane.hwnd = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kOverlayClass, L"SnipSnap Capture",
        WS_POPUP, static_cast<int>(pane.screen_rect.left),
        static_cast<int>(pane.screen_rect.top), pane.width, pane.height,
        nullptr, nullptr, ::GetModuleHandleW(nullptr),
        reinterpret_cast<LPVOID>(static_cast<intptr_t>(pane_index)));
    if (!pane.hwnd) {
      pane.CleanupResources();
      continue;
    }
    g_overlay.panes.push_back(std::move(pane));
  }

  ::ReleaseDC(nullptr, screen_dc);

  if (g_overlay.panes.empty()) {
    FinishOverlayCancelled();
    return;
  }

  g_overlay.active_pane = std::clamp(
      cursor_pane_idx, 0, static_cast<int>(g_overlay.panes.size()) - 1);
  g_overlay_active.store(true);

  HWND primary_hwnd =
      g_overlay.panes[static_cast<size_t>(g_overlay.active_pane)].hwnd;
  g_overlay_primary_hwnd.store(primary_hwnd);
  g_overlay_hook_active.store(true);
  g_overlay.key_hook = ::SetWindowsHookExW(
      WH_KEYBOARD_LL, OverlayLowLevelKeyboardProc, ::GetModuleHandleW(nullptr),
      0);

  for (auto& pane : g_overlay.panes) {
    ::ShowWindow(pane.hwnd, SW_SHOWNOACTIVATE);
  }
  ForceForegroundWindow(primary_hwnd);
}

// ---------------------------------------------------------------------------
// Native Windows Media Foundation H.264 Screen & Area Recorder
// ---------------------------------------------------------------------------

// Gene - Nov, 13, 2026: Added CaptureScreenRectBgraWithCursor, click-highlight ring compositing, WASAPI loopback + mic 48kHz stereo mixer, floating WDA_EXCLUDEFROMCAPTURE HUD + 3-2-1 countdown, and updated WinScreenRecorder.
// Old implementation:
// struct WinScreenRecorder {
//   std::atomic<bool> active{false};
//   std::atomic<bool> paused{false};
//   std::atomic<bool> cancelled{false};
//   std::atomic<int64_t> elapsed_ms{0};
//   std::thread worker;
//   std::wstring target_path;
//   std::wstring thumbnail_path;
//   int rec_x = 0;
//   int rec_y = 0;
//   int rec_w = 0;
//   int rec_h = 0;
//   int fps = 30;
//   bool record_audio = false;
// };
// Gene - Nov, 24, 2026: Upgrade recorder capture, Rust click rings & WASAPI resampler, hardware MF transforms, wall-clock timestamps, HiDPI HUD + capture-excluded guide border, countdown Esc hook, and restore_window flag.
// Old implementation (CaptureScreenRectBgraWithCursor, CompositeClickPulsesOntoBgra, WasapiCaptureStream::Drain48kStereo, RecordingHudWndProc, StopWinRecordingSession, StartWinRecordingSession, ExtractVideoFrameAtMs):
// bool CaptureScreenRectBgraWithCursor(int x, int y, int width, int height, bool draw_cursor, std::vector<uint8_t>* out_bgra) {
//   HDC mem_dc = ::CreateCompatibleDC(screen_dc); ::BitBlt(..., SRCCOPY); ...
// }
// void CompositeClickPulsesOntoBgra(...) {
//   for (const auto& pulse : pulses) { ... (*bgra)[idx + 0] = ... rb ... (*bgra)[idx + 2] = ... bb ... } // B/R swapped
// }
// void Drain48kStereo(...) { ... /* manual 16i/32f loop only */ ... }
// bool StartWinRecordingSession(...) { ... rt_start += frame_duration_100ns; ... }
ComPtr<IMFAttributes> CreateHardwareMfAttributes(bool enable_video_proc) {
  ComPtr<IMFAttributes> attrs;
  if (SUCCEEDED(::MFCreateAttributes(&attrs, enable_video_proc ? 2 : 1)) &&
      attrs) {
    attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    if (enable_video_proc) {
      attrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    }
  }
  return attrs;
}

bool CaptureScreenRectBgraWithCursor(
    int x, int y, int width, int height, bool draw_cursor,
    std::vector<uint8_t>* out_bgra,
    PersistentGdiRectGrabber* gdi_scratch = nullptr) {
  return CaptureRectFast(x, y, width, height, draw_cursor, true, gdi_scratch,
                         out_bgra);
}

struct ClickPulse {
  int screen_x = 0;
  int screen_y = 0;
  std::chrono::steady_clock::time_point started_at;
  bool right_button = false;
};

void CompositeClickPulsesOntoBgra(std::vector<uint8_t>* bgra, int rec_x,
                                 int rec_y, int w, int h,
                                 const std::vector<ClickPulse>& pulses,
                                 std::chrono::steady_clock::time_point now) {
  if (!bgra || w <= 0 || h <= 0 ||
      bgra->size() < static_cast<size_t>(w) * static_cast<size_t>(h) * 4) {
    return;
  }
  for (const auto& pulse : pulses) {
    auto age_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - pulse.started_at)
                      .count();
    if (age_ms < 0 || age_ms > 360) continue;
    float progress = static_cast<float>(age_ms) / 360.0f;
    int cx = pulse.screen_x - rec_x;
    int cy = pulse.screen_y - rec_y;
    snipsnap_composite_click_ring_bgra(
        bgra->data(), static_cast<int32_t>(w), static_cast<int32_t>(h),
        static_cast<int32_t>(w * 4), static_cast<int32_t>(cx),
        static_cast<int32_t>(cy), progress, pulse.right_button);
  }
}

struct WasapiCaptureStream {
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  UINT32 sample_rate = 48000;
  UINT32 channels = 2;
  UINT32 bits_per_sample = 32;
  bool is_float = true;
  bool started = false;
  double resample_phase = 0.0;
  std::vector<float> tmp_out;

  ~WasapiCaptureStream() { Close(); }

  void Close() {
    if (client && started) {
      client->Stop();
    }
    started = false;
    capture.Reset();
    client.Reset();
    device.Reset();
  }

  bool Open(bool loopback, const std::wstring& device_id) {
    Close();
    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
    if (FAILED(hr) || !enumerator) return false;

    if (loopback) {
      hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    } else if (!device_id.empty()) {
      hr = enumerator->GetDevice(device_id.c_str(), &device);
      if (FAILED(hr)) {
        hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
      }
    } else {
      hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    }
    if (FAILED(hr) || !device) return false;

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(client.GetAddressOf()));
    if (FAILED(hr) || !client) return false;

    WAVEFORMATEX* mix_fmt = nullptr;
    hr = client->GetMixFormat(&mix_fmt);
    if (FAILED(hr) || !mix_fmt) return false;

    sample_rate = mix_fmt->nSamplesPerSec;
    channels = std::max<UINT32>(1, mix_fmt->nChannels);
    bits_per_sample = mix_fmt->wBitsPerSample;
    is_float = false;
    if (mix_fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
      is_float = true;
    } else if (mix_fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
               mix_fmt->cbSize >= 22) {
      const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(mix_fmt);
      static const GUID kFloatSub = {
          0x00000003,
          0x0000,
          0x0010,
          {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
      if (std::memcmp(&ext->SubFormat, &kFloatSub, sizeof(GUID)) == 0) {
        is_float = true;
      }
    }

    DWORD flags = loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2000000, 0,
                            mix_fmt, nullptr);
    ::CoTaskMemFree(mix_fmt);
    if (FAILED(hr)) {
      Close();
      return false;
    }

    hr = client->GetService(IID_PPV_ARGS(&capture));
    if (FAILED(hr) || !capture) {
      Close();
      return false;
    }

    hr = client->Start();
    if (FAILED(hr)) {
      Close();
      return false;
    }
    started = true;
    resample_phase = 0.0;
    return true;
  }

  void Drain48kStereo(std::deque<float>* out_stereo, bool discard) {
    if (!started || !capture) return;
    UINT32 packet_frames = 0;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet_frames)) &&
           packet_frames > 0) {
      BYTE* data = nullptr;
      UINT32 num_frames = 0;
      DWORD flags = 0;
      HRESULT hr =
          capture->GetBuffer(&data, &num_frames, &flags, nullptr, nullptr);
      if (FAILED(hr)) break;

      if (!discard && out_stereo && num_frames > 0 && sample_rate > 0) {
        bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || !data;
        if (silent) {
          double step = static_cast<double>(sample_rate) / 48000.0;
          double total = static_cast<double>(num_frames);
          while (resample_phase < total) {
            out_stereo->push_back(0.0f);
            out_stereo->push_back(0.0f);
            resample_phase += step;
          }
          resample_phase -= total;
        } else {
          uint32_t frame_bytes = channels * (bits_per_sample / 8U);
          size_t src_len = static_cast<size_t>(num_frames) * frame_bytes;
          size_t max_out =
              (static_cast<size_t>(num_frames) * 48000ULL / sample_rate + 8) *
              2;
          if (tmp_out.size() < max_out) {
            tmp_out.resize(max_out);
          }
          size_t written = 0;
          if (snipsnap_pcm_to_f32_stereo_48k(
                  data, src_len, num_frames, channels, bits_per_sample,
                  is_float, sample_rate, &resample_phase, tmp_out.data(),
                  tmp_out.size(), &written) &&
              written > 0) {
            out_stereo->insert(out_stereo->end(), tmp_out.data(),
                               tmp_out.data() + written);
          }
        }
      } else if (discard) {
        resample_phase = 0.0;
      }
      capture->ReleaseBuffer(num_frames);
    }
  }
};

struct WinScreenRecorder {
  std::atomic<bool> active{false};
  std::atomic<bool> stopping{false};
  std::atomic<bool> paused{false};
  std::atomic<bool> cancelled{false};
  std::atomic<bool> wrote_valid_video{false};
  std::atomic<bool> mic_muted{false};
  std::atomic<int> countdown_remaining{0};
  std::atomic<int64_t> elapsed_ms{0};
  std::atomic<bool> actual_has_audio{false};
  std::mutex join_mutex;
  std::thread worker;
  std::thread hud_thread;
  std::mutex hud_mutex;
  HWND hud_hwnd = nullptr;
  HWND guide_hwnd = nullptr;
  HHOOK countdown_hook = nullptr;
  HFONT hud_font = nullptr;
  HFONT hud_big_font = nullptr;
  HFONT hud_hint_font = nullptr;
  double hud_dpi_scale = 1.0;
  std::wstring target_path;
  std::wstring thumbnail_path;
  std::string mic_device_id;
  int rec_x = 0;
  int rec_y = 0;
  int rec_w = 0;
  int rec_h = 0;
  int hud_mon_x = 0;
  int hud_mon_y = 0;
  int hud_mon_w = 1920;
  int hud_mon_h = 1080;
  int fps = 60;
  bool record_audio = false;
  bool record_system_audio = true;
  bool record_cursor = true;
  bool highlight_clicks = true;

  RECT pause_btn = {0, 0, 0, 0};
  RECT stop_btn = {0, 0, 0, 0};
  RECT restart_btn = {0, 0, 0, 0};
  RECT mute_btn = {0, 0, 0, 0};
  RECT cancel_btn = {0, 0, 0, 0};
  bool hud_dragging = false;
  POINT hud_drag_offset = {0, 0};
  bool hud_in_countdown_mode = false;
};

WinScreenRecorder g_recorder;
std::atomic<bool> g_recorder_countdown_hook_active{false};

void StopWinRecordingSession(bool cancel,
                             std::unique_ptr<CaptureMethodResult> result,
                             bool restore_window = true);

LRESULT CALLBACK CountdownLowLevelKeyboardProc(int nCode, WPARAM wparam,
                                                 LPARAM lparam) {
  if (nCode == HC_ACTION &&
      g_recorder_countdown_hook_active.load(std::memory_order_acquire) &&
      g_recorder.countdown_remaining.load(std::memory_order_acquire) > 0 &&
      (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)) {
    const auto* kbd = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
    if (kbd && kbd->vkCode == VK_ESCAPE) {
      g_recorder_countdown_hook_active.store(false, std::memory_order_release);
      PostToPlatformThread(
          []() { StopWinRecordingSession(true, nullptr, true); });
      return 1;
    }
  }
  return ::CallNextHookEx(nullptr, nCode, wparam, lparam);
}

void RefreshRecordingHudWindow() {
  std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
  if (g_recorder.hud_hwnd && ::IsWindow(g_recorder.hud_hwnd)) {
    ::InvalidateRect(g_recorder.hud_hwnd, nullptr, FALSE);
  }
  if (g_recorder.guide_hwnd && ::IsWindow(g_recorder.guide_hwnd)) {
    ::InvalidateRect(g_recorder.guide_hwnd, nullptr, FALSE);
  }
}

void CloseRecordingHudWindow() {
  g_recorder_countdown_hook_active.store(false, std::memory_order_release);
  HWND hwnd_to_close = nullptr;
  HWND guide_to_close = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
    hwnd_to_close = g_recorder.hud_hwnd;
    guide_to_close = g_recorder.guide_hwnd;
  }
  if (guide_to_close && ::IsWindow(guide_to_close)) {
    ::PostMessageW(guide_to_close, WM_CLOSE, 0, 0);
  }
  if (hwnd_to_close && ::IsWindow(hwnd_to_close)) {
    ::PostMessageW(hwnd_to_close, WM_CLOSE, 0, 0);
  }
  if (g_recorder.hud_thread.joinable()) {
    g_recorder.hud_thread.join();
  }
}

LRESULT CALLBACK RecordingGuideWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                       LPARAM lparam) {
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = ::BeginPaint(hwnd, &ps);
      RECT client = {};
      ::GetClientRect(hwnd, &client);
      // Black interior becomes fully click-through transparent via LWA_COLORKEY.
      HBRUSH black_br = ::CreateSolidBrush(RGB(0, 0, 0));
      ::FillRect(hdc, &client, black_br);
      ::DeleteObject(black_br);

      COLORREF stroke = RGB(240, 68, 56);
      if (g_recorder.countdown_remaining.load() > 0 ||
          g_recorder.paused.load()) {
        stroke = RGB(245, 185, 66);
      }
      int pen_w = std::max(2, OverlayScalePx(2, g_recorder.hud_dpi_scale));
      HPEN pen = ::CreatePen(PS_SOLID, pen_w, stroke);
      HGDIOBJ old_pen = ::SelectObject(hdc, pen);
      HGDIOBJ old_br = ::SelectObject(hdc, ::GetStockObject(NULL_BRUSH));
      ::Rectangle(hdc, pen_w / 2, pen_w / 2, client.right - pen_w / 2,
                  client.bottom - pen_w / 2);
      ::SelectObject(hdc, old_br);
      ::SelectObject(hdc, old_pen);
      ::DeleteObject(pen);
      ::EndPaint(hwnd, &ps);
      return 0;
    }

    case WM_CLOSE:
      ::DestroyWindow(hwnd);
      return 0;

    case WM_DESTROY: {
      std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
      g_recorder.guide_hwnd = nullptr;
      return 0;
    }
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

LRESULT CALLBACK RecordingHudWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                     LPARAM lparam) {
  constexpr UINT_PTR kHudTimerId = 101;
  switch (msg) {
    case WM_CREATE:
      ::SetTimer(hwnd, kHudTimerId, 120, nullptr);
      return 0;

    case WM_KEYDOWN: {
      if (wparam == VK_ESCAPE) {
        PostToPlatformThread(
            []() { StopWinRecordingSession(true, nullptr, true); });
        return 0;
      }
      break;
    }

    case WM_TIMER: {
      if (wparam == kHudTimerId) {
        int rem = g_recorder.countdown_remaining.load();
        bool want_countdown = rem > 0;
        if (!want_countdown && g_recorder.countdown_hook) {
          g_recorder_countdown_hook_active.store(false,
                                                 std::memory_order_release);
          ::UnhookWindowsHookEx(g_recorder.countdown_hook);
          g_recorder.countdown_hook = nullptr;
        }
        if (want_countdown != g_recorder.hud_in_countdown_mode) {
          g_recorder.hud_in_countdown_mode = want_countdown;
          double s = g_recorder.hud_dpi_scale;
          int mx = g_recorder.hud_mon_x;
          int my = g_recorder.hud_mon_y;
          int mw = std::max(320, g_recorder.hud_mon_w);
          int mh = std::max(240, g_recorder.hud_mon_h);
          if (want_countdown) {
            int cw = OverlayScalePx(168, s);
            int ch = OverlayScalePx(172, s);
            ::SetWindowPos(hwnd, HWND_TOPMOST, mx + (mw - cw) / 2,
                           my + (mh - ch) / 2, cw, ch,
                           SWP_NOACTIVATE | SWP_SHOWWINDOW);
          } else {
            int base_pw = g_recorder.record_audio ? 386 : 324;
            int pw = OverlayScalePx(base_pw, s);
            int ph = OverlayScalePx(48, s);
            int py = my + OverlayScalePx(24, s);
            ::SetWindowPos(hwnd, HWND_TOPMOST, mx + (mw - pw) / 2, py, pw, ph,
                           SWP_NOACTIVATE | SWP_SHOWWINDOW);
          }
          HWND guide = nullptr;
          {
            std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
            guide = g_recorder.guide_hwnd;
          }
          if (guide && ::IsWindow(guide)) {
            ::InvalidateRect(guide, nullptr, FALSE);
          }
        }
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_LBUTTONDOWN: {
      if (g_recorder.countdown_remaining.load() > 0) {
        PostToPlatformThread(
            []() { StopWinRecordingSession(true, nullptr, true); });
        return 0;
      }
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (::PtInRect(&g_recorder.pause_btn, pt)) {
        bool now_paused = !g_recorder.paused.load();
        g_recorder.paused.store(now_paused);
        RefreshRecordingHudWindow();
        EncodableMap args;
        args[EncodableValue("isPaused")] = EncodableValue(now_paused);
        InvokeDartMethod("onRecordingStateChanged", EncodableValue(args));
        return 0;
      }
      if (::PtInRect(&g_recorder.stop_btn, pt)) {
        PostToPlatformThread(
            []() { StopWinRecordingSession(false, nullptr, true); });
        return 0;
      }
      if (::PtInRect(&g_recorder.restart_btn, pt)) {
        InvokeDartMethod("onRecordingRestartRequested", EncodableValue());
        return 0;
      }
      if (g_recorder.record_audio && ::PtInRect(&g_recorder.mute_btn, pt)) {
        bool now_muted = !g_recorder.mic_muted.load();
        g_recorder.mic_muted.store(now_muted);
        ::InvalidateRect(hwnd, nullptr, FALSE);
        EncodableMap args;
        args[EncodableValue("isMuted")] = EncodableValue(now_muted);
        InvokeDartMethod("onRecordingMicMutedChanged", EncodableValue(args));
        return 0;
      }
      if (::PtInRect(&g_recorder.cancel_btn, pt)) {
        PostToPlatformThread(
            []() { StopWinRecordingSession(true, nullptr, true); });
        return 0;
      }
      g_recorder.hud_dragging = true;
      g_recorder.hud_drag_offset = pt;
      ::SetCapture(hwnd);
      return 0;
    }

    case WM_MOUSEMOVE: {
      if (g_recorder.hud_dragging) {
        POINT cursor = {};
        ::GetCursorPos(&cursor);
        ::SetWindowPos(hwnd, HWND_TOPMOST,
                       cursor.x - g_recorder.hud_drag_offset.x,
                       cursor.y - g_recorder.hud_drag_offset.y, 0, 0,
                       SWP_NOSIZE | SWP_NOACTIVATE);
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      if (g_recorder.hud_dragging) {
        g_recorder.hud_dragging = false;
        ::ReleaseCapture();
      }
      return 0;
    }

    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = ::BeginPaint(hwnd, &ps);
      RECT client = {};
      ::GetClientRect(hwnd, &client);
      int cw = client.right - client.left;
      int ch = client.bottom - client.top;
      double s = g_recorder.hud_dpi_scale;

      HDC mem_dc = ::CreateCompatibleDC(hdc);
      HBITMAP bmp = ::CreateCompatibleBitmap(hdc, cw, ch);
      HGDIOBJ old_bmp = ::SelectObject(mem_dc, bmp);

      HBRUSH bg = ::CreateSolidBrush(RGB(26, 22, 20));
      ::FillRect(mem_dc, &client, bg);
      ::DeleteObject(bg);

      HPEN border_pen = ::CreatePen(PS_SOLID, 1, RGB(120, 96, 80));
      HGDIOBJ old_pen = ::SelectObject(mem_dc, border_pen);
      HGDIOBJ old_br = ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
      ::Rectangle(mem_dc, 0, 0, cw, ch);
      ::SelectObject(mem_dc, old_br);
      ::SelectObject(mem_dc, old_pen);
      ::DeleteObject(border_pen);

      ::SetBkMode(mem_dc, TRANSPARENT);
      int rem = g_recorder.countdown_remaining.load();
      int corner = OverlayScalePx(10, s);
      if (rem > 0) {
        RECT num_rect = {0, OverlayScalePx(8, s), cw, ch - OverlayScalePx(30, s)};
        ::SetTextColor(mem_dc, RGB(255, 255, 255));
        std::wstring num = std::to_wstring(rem);
        HGDIOBJ old_f = g_recorder.hud_big_font
                            ? ::SelectObject(mem_dc, g_recorder.hud_big_font)
                            : nullptr;
        ::DrawTextW(mem_dc, num.c_str(), -1, &num_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        if (old_f) ::SelectObject(mem_dc, old_f);

        RECT hint_rect = {OverlayScalePx(8, s), ch - OverlayScalePx(30, s),
                          cw - OverlayScalePx(8, s), ch - OverlayScalePx(6, s)};
        HGDIOBJ old_hf = g_recorder.hud_hint_font
                             ? ::SelectObject(mem_dc, g_recorder.hud_hint_font)
                             : nullptr;
        ::SetTextColor(mem_dc, RGB(196, 178, 166));
        ::DrawTextW(mem_dc, L"Click or Esc to cancel", -1, &hint_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        if (old_hf) ::SelectObject(mem_dc, old_hf);
      } else {
        HGDIOBJ old_f = g_recorder.hud_font
                            ? ::SelectObject(mem_dc, g_recorder.hud_font)
                            : nullptr;
        int64_t secs = g_recorder.elapsed_ms.load() / 1000;
        wchar_t time_buf[32] = {};
        std::swprintf(time_buf, 32, L"%02lld:%02lld",
                      static_cast<long long>(secs / 60),
                      static_cast<long long>(secs % 60));
        int time_w = OverlayScalePx(66, s);
        int margin_x = OverlayScalePx(10, s);
        RECT time_rect = {margin_x, OverlayScalePx(6, s), margin_x + time_w,
                          ch - OverlayScalePx(6, s)};
        ::SetTextColor(mem_dc, g_recorder.paused.load() ? RGB(255, 200, 90)
                                                        : RGB(255, 110, 100));
        ::DrawTextW(mem_dc, time_buf, -1, &time_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);

        int bx = margin_x + time_w + OverlayScalePx(4, s);
        int by = OverlayScalePx(8, s);
        int bh = ch - OverlayScalePx(16, s);
        int gap = OverlayScalePx(5, s);
        int w_pause = OverlayScalePx(60, s);
        int w_stop = OverlayScalePx(54, s);
        int w_restart = OverlayScalePx(62, s);
        int w_mute = OverlayScalePx(58, s);
        int w_cancel = OverlayScalePx(32, s);

        g_recorder.pause_btn = {bx, by, bx + w_pause, by + bh};
        bx += w_pause + gap;
        g_recorder.stop_btn = {bx, by, bx + w_stop, by + bh};
        bx += w_stop + gap;
        g_recorder.restart_btn = {bx, by, bx + w_restart, by + bh};
        bx += w_restart + gap;
        if (g_recorder.record_audio) {
          g_recorder.mute_btn = {bx, by, bx + w_mute, by + bh};
          bx += w_mute + gap;
        } else {
          g_recorder.mute_btn = {0, 0, 0, 0};
        }
        g_recorder.cancel_btn = {bx, by, bx + w_cancel, by + bh};

        DrawRoundedPill(
            mem_dc, g_recorder.pause_btn, RGB(48, 40, 35), RGB(110, 92, 80),
            g_recorder.paused.load() ? L"Resume" : L"Pause",
            RGB(255, 255, 255), corner);
        DrawRoundedPill(mem_dc, g_recorder.stop_btn, RGB(205, 42, 42),
                        RGB(240, 90, 90), L"Stop", RGB(255, 255, 255), corner);
        DrawRoundedPill(mem_dc, g_recorder.restart_btn, RGB(48, 40, 35),
                        RGB(110, 92, 80), L"Restart", RGB(255, 255, 255),
                        corner);
        if (g_recorder.record_audio) {
          bool muted = g_recorder.mic_muted.load();
          DrawRoundedPill(mem_dc, g_recorder.mute_btn,
                          muted ? RGB(130, 52, 42) : RGB(46, 105, 62),
                          RGB(110, 92, 80), muted ? L"Muted" : L"Mic",
                          RGB(255, 255, 255), corner);
        }
        DrawRoundedPill(mem_dc, g_recorder.cancel_btn, RGB(40, 32, 28),
                        RGB(110, 92, 80), L"X", RGB(220, 200, 190), corner);
        if (old_f) ::SelectObject(mem_dc, old_f);
      }

      ::BitBlt(hdc, 0, 0, cw, ch, mem_dc, 0, 0, SRCCOPY);
      ::SelectObject(mem_dc, old_bmp);
      ::DeleteObject(bmp);
      ::DeleteDC(mem_dc);
      ::EndPaint(hwnd, &ps);
      return 0;
    }

    case WM_CLOSE:
      ::KillTimer(hwnd, kHudTimerId);
      ::DestroyWindow(hwnd);
      return 0;

    case WM_DESTROY: {
      if (g_recorder.countdown_hook) {
        g_recorder_countdown_hook_active.store(false,
                                               std::memory_order_release);
        ::UnhookWindowsHookEx(g_recorder.countdown_hook);
        g_recorder.countdown_hook = nullptr;
      }
      // Gene - Nov, 24, 2026: Ensure capture guide border window on hud_thread is synchronously destroyed before exiting message loop.
      HWND guide = nullptr;
      {
        std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
        guide = g_recorder.guide_hwnd;
        g_recorder.guide_hwnd = nullptr;
        g_recorder.hud_hwnd = nullptr;
      }
      if (guide && ::IsWindow(guide)) {
        ::DestroyWindow(guide);
      }
      if (g_recorder.hud_font) {
        ::DeleteObject(g_recorder.hud_font);
        g_recorder.hud_font = nullptr;
      }
      if (g_recorder.hud_big_font) {
        ::DeleteObject(g_recorder.hud_big_font);
        g_recorder.hud_big_font = nullptr;
      }
      if (g_recorder.hud_hint_font) {
        ::DeleteObject(g_recorder.hud_hint_font);
        g_recorder.hud_hint_font = nullptr;
      }
      ::PostQuitMessage(0);
      return 0;
    }
  }
  return ::DefWindowProcW(hwnd, msg, wparam, lparam);
}

void LaunchRecordingHudWindow(int countdown_seconds) {
  CloseRecordingHudWindow();
  g_recorder.hud_in_countdown_mode = countdown_seconds > 0;
  g_recorder.hud_thread = std::thread([countdown_seconds]() {
    static const wchar_t* kHudClass = L"SnipSnapRecordingHudClass";
    static const wchar_t* kGuideClass = L"SnipSnapRecordingGuideClass";
    static std::atomic<bool> registered{false};
    if (!registered.exchange(true)) {
      WNDCLASSEXW wc = {};
      wc.cbSize = sizeof(WNDCLASSEXW);
      wc.lpfnWndProc = RecordingHudWndProc;
      wc.hInstance = ::GetModuleHandleW(nullptr);
      wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
      wc.lpszClassName = kHudClass;
      ::RegisterClassExW(&wc);

      WNDCLASSEXW gc = {};
      gc.cbSize = sizeof(WNDCLASSEXW);
      gc.lpfnWndProc = RecordingGuideWndProc;
      gc.hInstance = ::GetModuleHandleW(nullptr);
      gc.lpszClassName = kGuideClass;
      ::RegisterClassExW(&gc);
    }

    POINT pt = {g_recorder.hud_mon_x + 1, g_recorder.hud_mon_y + 1};
    HMONITOR hmon = ::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    double s = std::clamp(static_cast<double>(GetMonitorDpi(hmon)) / 96.0,
                          1.0, 3.0);
    g_recorder.hud_dpi_scale = s;

    g_recorder.hud_font = ::CreateFontW(
        -OverlayScalePx(13, s), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    g_recorder.hud_big_font = ::CreateFontW(
        -OverlayScalePx(68, s), 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_OUTLINE_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, VARIABLE_PITCH, L"Segoe UI");
    g_recorder.hud_hint_font = ::CreateFontW(
        -OverlayScalePx(12, s), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");

    int pad = std::max(3, OverlayScalePx(3, s));
    HWND guide_hwnd = ::CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
            WS_EX_NOACTIVATE,
        kGuideClass, L"SnipSnap Recording Guide", WS_POPUP | WS_VISIBLE,
        g_recorder.rec_x - pad, g_recorder.rec_y - pad,
        g_recorder.rec_w + pad * 2, g_recorder.rec_h + pad * 2, nullptr,
        nullptr, ::GetModuleHandleW(nullptr), nullptr);
    if (guide_hwnd) {
      ::SetLayeredWindowAttributes(guide_hwnd, RGB(0, 0, 0), 0, LWA_COLORKEY);
      ::SetWindowDisplayAffinity(guide_hwnd, WDA_EXCLUDEFROMCAPTURE);
      std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
      g_recorder.guide_hwnd = guide_hwnd;
    }

    int mx = g_recorder.hud_mon_x;
    int my = g_recorder.hud_mon_y;
    int mw = std::max(320, g_recorder.hud_mon_w);
    int mh = std::max(240, g_recorder.hud_mon_h);
    int base_pw = g_recorder.record_audio ? 386 : 324;
    int win_w = countdown_seconds > 0 ? OverlayScalePx(168, s)
                                      : OverlayScalePx(base_pw, s);
    int win_h = countdown_seconds > 0 ? OverlayScalePx(172, s)
                                      : OverlayScalePx(48, s);
    int win_x = mx + (mw - win_w) / 2;
    int win_y = countdown_seconds > 0 ? (my + (mh - win_h) / 2)
                                      : (my + OverlayScalePx(24, s));

    HWND hwnd = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kHudClass,
        L"SnipSnap Recording HUD", WS_POPUP | WS_VISIBLE, win_x, win_y, win_w,
        win_h, nullptr, nullptr, ::GetModuleHandleW(nullptr), nullptr);
    if (hwnd) {
      ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
      {
        std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
        g_recorder.hud_hwnd = hwnd;
      }
      if (countdown_seconds > 0) {
        g_recorder_countdown_hook_active.store(true, std::memory_order_release);
        g_recorder.countdown_hook = ::SetWindowsHookExW(
            WH_KEYBOARD_LL, CountdownLowLevelKeyboardProc,
            ::GetModuleHandleW(nullptr), 0);
      }
      MSG msg = {};
      while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
      }
    }
  });
}

void StopWinRecordingSession(bool cancel,
                             std::unique_ptr<CaptureMethodResult> result,
                             bool restore_window) {
  std::shared_ptr<CaptureMethodResult> shared_result(std::move(result));
  if (!g_recorder.active.load() && !g_recorder.stopping.load()) {
    CloseRecordingHudWindow();
    if (restore_window) SetMainWindowVisible(true);
    if (shared_result) shared_result->Success(EncodableValue());
    return;
  }
  if (g_recorder.stopping.exchange(true)) {
    if (cancel) g_recorder.cancelled.store(true);
    if (shared_result) shared_result->Success(EncodableValue());
    return;
  }

  if (cancel) g_recorder.cancelled.store(true);
  g_recorder.active.store(false);
  g_recorder.countdown_remaining.store(0);

  std::thread([cancel, restore_window, shared_result]() {
    {
      std::lock_guard<std::mutex> lock(g_recorder.join_mutex);
      if (g_recorder.worker.joinable()) {
        g_recorder.worker.join();
      }
      CloseRecordingHudWindow();
    }
    PostToPlatformThread([cancel, restore_window, shared_result]() {
      g_recorder.stopping.store(false);
      if (restore_window) SetMainWindowVisible(true);

      bool valid = !cancel && !g_recorder.cancelled.load() &&
                   g_recorder.wrote_valid_video.load();
      if (!valid) {
        ::DeleteFileW(g_recorder.target_path.c_str());
        ::DeleteFileW(g_recorder.thumbnail_path.c_str());
        if (shared_result) {
          shared_result->Success(EncodableValue());
        } else {
          InvokeDartMethod("onRecordingCancelled", EncodableValue());
        }
        return;
      }

      EncodableMap map;
      map[EncodableValue("filePath")] =
          EncodableValue(WideToUtf8(g_recorder.target_path));
      map[EncodableValue("thumbnailPath")] =
          EncodableValue(WideToUtf8(g_recorder.thumbnail_path));
      map[EncodableValue("width")] = EncodableValue(g_recorder.rec_w);
      map[EncodableValue("height")] = EncodableValue(g_recorder.rec_h);
      map[EncodableValue("durationMs")] =
          EncodableValue(static_cast<int64_t>(g_recorder.elapsed_ms.load()));
      map[EncodableValue("hasAudio")] =
          EncodableValue(g_recorder.actual_has_audio.load());
      if (shared_result) {
        shared_result->Success(EncodableValue(map));
      } else {
        InvokeDartMethod("onRecordingStopped", EncodableValue(map));
      }
    });
  }).detach();
}

bool StartWinRecordingSession(
    const std::wstring& target_path, const std::wstring& thumbnail_path, int x,
    int y, int width, int height, int fps, bool record_audio,
    const std::string& mic_device_id, bool record_system_audio,
    bool record_cursor, bool highlight_clicks, int countdown_seconds) {
  if (g_recorder.active.load() || g_recorder.stopping.load()) return false;

  int even_w = (width % 2 == 0) ? width : (width - 1);
  int even_h = (height % 2 == 0) ? height : (height - 1);
  if (even_w < 16 || even_h < 16) return false;

  int clamped_countdown = std::clamp(countdown_seconds, 0, 10);
  POINT rec_center = {x + even_w / 2, y + even_h / 2};
  RECT mon = GetMonitorRectForScreenPoint(rec_center);

  g_recorder.target_path = target_path;
  g_recorder.thumbnail_path = thumbnail_path;
  g_recorder.mic_device_id = mic_device_id;
  g_recorder.rec_x = x;
  g_recorder.rec_y = y;
  g_recorder.rec_w = even_w;
  g_recorder.rec_h = even_h;
  g_recorder.hud_mon_x = static_cast<int>(mon.left);
  g_recorder.hud_mon_y = static_cast<int>(mon.top);
  g_recorder.hud_mon_w = std::max(320, static_cast<int>(mon.right - mon.left));
  g_recorder.hud_mon_h = std::max(240, static_cast<int>(mon.bottom - mon.top));
  g_recorder.fps = std::clamp(fps, 15, 60);
  g_recorder.record_audio = record_audio;
  g_recorder.record_system_audio = record_system_audio;
  g_recorder.record_cursor = record_cursor;
  g_recorder.highlight_clicks = highlight_clicks;
  g_recorder.paused.store(false);
  g_recorder.cancelled.store(false);
  g_recorder.wrote_valid_video.store(false);
  g_recorder.mic_muted.store(false);
  g_recorder.countdown_remaining.store(clamped_countdown);
  g_recorder.elapsed_ms.store(0);
  g_recorder.actual_has_audio.store(false);
  g_recorder.active.store(true);

  LaunchRecordingHudWindow(clamped_countdown);

  g_recorder.worker = std::thread([clamped_countdown]() {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ::MFStartup(MF_VERSION);

    if (clamped_countdown > 0) {
      auto cd_start = std::chrono::steady_clock::now();
      while (g_recorder.active.load() && !g_recorder.cancelled.load()) {
        auto elapsed_cd_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - cd_start)
                .count();
        int total_cd_ms = clamped_countdown * 1000;
        if (elapsed_cd_ms >= total_cd_ms) {
          g_recorder.countdown_remaining.store(0);
          RefreshRecordingHudWindow();
          break;
        }
        int rem_sec = static_cast<int>((total_cd_ms - elapsed_cd_ms + 999) / 1000);
        g_recorder.countdown_remaining.store(rem_sec);
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
      }
      if (!g_recorder.active.load() || g_recorder.cancelled.load()) {
        ::MFShutdown();
        ::CoUninitialize();
        return;
      }
    }

    int w = g_recorder.rec_w;
    int h = g_recorder.rec_h;
    int rec_fps = g_recorder.fps;

    ComPtr<IMFSinkWriter> writer;
    DWORD video_stream_index = 0;
    DWORD audio_stream_index = 1;
    bool has_audio_stream = false;
    auto hw_attrs = CreateHardwareMfAttributes(false);
    HRESULT hr = ::MFCreateSinkWriterFromURL(
        g_recorder.target_path.c_str(), nullptr, hw_attrs.Get(), &writer);
    if (FAILED(hr) || !writer) {
      hr = ::MFCreateSinkWriterFromURL(g_recorder.target_path.c_str(), nullptr,
                                       nullptr, &writer);
    }

    if (SUCCEEDED(hr)) {
      ComPtr<IMFMediaType> out_type;
      ::MFCreateMediaType(&out_type);
      out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
      out_type->SetUINT32(MF_MT_AVG_BITRATE,
                          static_cast<UINT32>(std::clamp(w * h * 4, 2000000, 20000000)));
      out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      ::MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE,
                           static_cast<UINT32>(w), static_cast<UINT32>(h));
      ::MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE,
                            static_cast<UINT32>(rec_fps), 1);
      ::MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      hr = writer->AddStream(out_type.Get(), &video_stream_index);
    }

    if (SUCCEEDED(hr)) {
      ComPtr<IMFMediaType> in_type;
      ::MFCreateMediaType(&in_type);
      in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      ::MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE,
                           static_cast<UINT32>(w), static_cast<UINT32>(h));
      ::MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE,
                            static_cast<UINT32>(rec_fps), 1);
      ::MFSetAttributeRatio(in_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      hr = writer->SetInputMediaType(video_stream_index, in_type.Get(), nullptr);
    }

    WasapiCaptureStream sys_loopback;
    WasapiCaptureStream mic_capture;
    bool sys_open = false;
    bool mic_open = false;
    if (SUCCEEDED(hr) &&
        (g_recorder.record_system_audio || g_recorder.record_audio)) {
      if (g_recorder.record_system_audio) {
        sys_open = sys_loopback.Open(true, L"");
      }
      if (g_recorder.record_audio) {
        mic_open =
            mic_capture.Open(false, Utf8ToWide(g_recorder.mic_device_id));
      }
      if (sys_open || mic_open) {
        ComPtr<IMFMediaType> a_out;
        ComPtr<IMFMediaType> a_in;
        ::MFCreateMediaType(&a_out);
        a_out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        a_out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        a_out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        a_out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
        a_out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        a_out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 20000);

        ::MFCreateMediaType(&a_in);
        a_in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        a_in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        a_in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        a_in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
        a_in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        a_in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
        a_in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000);

        if (SUCCEEDED(writer->AddStream(a_out.Get(), &audio_stream_index)) &&
            SUCCEEDED(writer->SetInputMediaType(audio_stream_index, a_in.Get(),
                                                nullptr))) {
          has_audio_stream = true;
          g_recorder.actual_has_audio.store(true);
        }
      }
    }

    if (SUCCEEDED(hr)) {
      hr = writer->BeginWriting();
    }

    bool saved_thumb = false;
    int64_t frame_duration_100ns = 10000000LL / rec_fps;
    int64_t active_100ns = 0;
    int64_t last_video_ts = -frame_duration_100ns;
    int64_t frames_written = 0;
    int64_t audio_frames_written = 0;
    auto frame_interval = std::chrono::microseconds(1000000 / rec_fps);
    auto last_wall = std::chrono::steady_clock::now();
    std::vector<uint8_t> frame_bgra;
    PersistentGdiRectGrabber rec_gdi;
    std::vector<ClickPulse> click_pulses;
    bool prev_lbutton = false;
    bool prev_rbutton = false;
    std::deque<float> sys_queue;
    std::deque<float> mic_queue;

    while (SUCCEEDED(hr) && g_recorder.active.load()) {
      auto loop_start = std::chrono::steady_clock::now();
      int64_t delta_100ns =
          std::chrono::duration_cast<std::chrono::nanoseconds>(loop_start -
                                                               last_wall)
              .count() /
          100LL;
      last_wall = loop_start;
      bool paused_now = g_recorder.paused.load();

      if (sys_open) sys_loopback.Drain48kStereo(&sys_queue, paused_now);
      if (mic_open) mic_capture.Drain48kStereo(&mic_queue, paused_now);
      while (sys_queue.size() > 96000) sys_queue.pop_front();
      while (mic_queue.size() > 96000) mic_queue.pop_front();

      if (!paused_now) {
        if (frames_written > 0 && delta_100ns > 0) {
          active_100ns += delta_100ns;
        }
        if (g_recorder.highlight_clicks) {
          bool ldown = (::GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
          bool rdown = (::GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
          if ((ldown && !prev_lbutton) || (rdown && !prev_rbutton)) {
            POINT cpt = {};
            if (::GetCursorPos(&cpt)) {
              ClickPulse pulse;
              pulse.screen_x = cpt.x;
              pulse.screen_y = cpt.y;
              pulse.started_at = loop_start;
              pulse.right_button = (rdown && !prev_rbutton);
              click_pulses.push_back(pulse);
            }
          }
          prev_lbutton = ldown;
          prev_rbutton = rdown;
          click_pulses.erase(
              std::remove_if(
                  click_pulses.begin(), click_pulses.end(),
                  [&](const ClickPulse& p) {
                    return std::chrono::duration_cast<std::chrono::milliseconds>(
                               loop_start - p.started_at)
                               .count() > 360;
                  }),
              click_pulses.end());
        }

        if (CaptureScreenRectBgraWithCursor(g_recorder.rec_x, g_recorder.rec_y,
                                            w, h, g_recorder.record_cursor,
                                            &frame_bgra, &rec_gdi)) {
          if (g_recorder.highlight_clicks && !click_pulses.empty()) {
            CompositeClickPulsesOntoBgra(&frame_bgra, g_recorder.rec_x,
                                         g_recorder.rec_y, w, h, click_pulses,
                                         loop_start);
          }

          if (!saved_thumb && !g_recorder.thumbnail_path.empty()) {
            SaveBgraToPngFile(frame_bgra.data(), w, h, w * 4,
                              g_recorder.thumbnail_path);
            saved_thumb = true;
          }

          DWORD cb_width = static_cast<DWORD>(w * 4);
          DWORD cb_buffer = cb_width * static_cast<DWORD>(h);
          ComPtr<IMFMediaBuffer> buffer;
          if (SUCCEEDED(::MFCreateMemoryBuffer(cb_buffer, &buffer))) {
            BYTE* dst = nullptr;
            if (SUCCEEDED(buffer->Lock(&dst, nullptr, nullptr))) {
              bool converted = snipsnap_bgra_to_bottom_up_bgrx(
                  frame_bgra.data(), static_cast<int32_t>(w),
                  static_cast<int32_t>(h), static_cast<int32_t>(cb_width), dst,
                  static_cast<int32_t>(cb_width));
              buffer->Unlock();
              if (converted) {
                buffer->SetCurrentLength(cb_buffer);
                ComPtr<IMFSample> sample;
                if (SUCCEEDED(::MFCreateSample(&sample))) {
                  int64_t pts = std::max<int64_t>(0, active_100ns);
                  if (frames_written > 0 && pts <= last_video_ts) {
                    pts = last_video_ts + 10000LL;
                  }
                  last_video_ts = pts;
                  sample->AddBuffer(buffer.Get());
                  sample->SetSampleTime(pts);
                  sample->SetSampleDuration(frame_duration_100ns);
                  writer->WriteSample(video_stream_index, sample.Get());
                  ++frames_written;
                  g_recorder.elapsed_ms.store(
                      (pts + frame_duration_100ns) / 10000LL);
                }
              }
            }
          }

          if (has_audio_stream) {
            int64_t target_audio_frames =
                ((active_100ns + frame_duration_100ns) * 48000LL) / 10000000LL;
            int64_t frames_to_write =
                std::min<int64_t>(48000LL,
                                  target_audio_frames - audio_frames_written);
            if (frames_to_write > 0) {
              DWORD audio_bytes = static_cast<DWORD>(frames_to_write * 4);
              ComPtr<IMFMediaBuffer> a_buf;
              if (SUCCEEDED(::MFCreateMemoryBuffer(audio_bytes, &a_buf))) {
                BYTE* adst = nullptr;
                if (SUCCEEDED(a_buf->Lock(&adst, nullptr, nullptr))) {
                  int16_t* pcm = reinterpret_cast<int16_t*>(adst);
                  bool muted_now = g_recorder.mic_muted.load();
                  for (int64_t i = 0; i < frames_to_write; ++i) {
                    float sl = 0.0f;
                    float sr = 0.0f;
                    if (sys_queue.size() >= 2) {
                      sl += sys_queue.front();
                      sys_queue.pop_front();
                      sr += sys_queue.front();
                      sys_queue.pop_front();
                    }
                    if (mic_queue.size() >= 2) {
                      float ml = mic_queue.front();
                      mic_queue.pop_front();
                      float mr = mic_queue.front();
                      mic_queue.pop_front();
                      if (!muted_now) {
                        sl += ml;
                        sr += mr;
                      }
                    }
                    sl = std::clamp(sl, -1.0f, 1.0f);
                    sr = std::clamp(sr, -1.0f, 1.0f);
                    pcm[i * 2 + 0] = static_cast<int16_t>(sl * 32767.0f);
                    pcm[i * 2 + 1] = static_cast<int16_t>(sr * 32767.0f);
                  }
                  a_buf->Unlock();
                  a_buf->SetCurrentLength(audio_bytes);

                  ComPtr<IMFSample> a_sample;
                  if (SUCCEEDED(::MFCreateSample(&a_sample))) {
                    int64_t a_time =
                        (audio_frames_written * 10000000LL) / 48000LL;
                    int64_t a_dur = (frames_to_write * 10000000LL) / 48000LL;
                    a_sample->AddBuffer(a_buf.Get());
                    a_sample->SetSampleTime(a_time);
                    a_sample->SetSampleDuration(a_dur);
                    writer->WriteSample(audio_stream_index, a_sample.Get());
                    audio_frames_written += frames_to_write;
                  }
                }
              }
            }
          }
        }
      }
      auto elapsed = std::chrono::steady_clock::now() - loop_start;
      if (elapsed < frame_interval) {
        std::this_thread::sleep_for(frame_interval - elapsed);
      }
    }

    sys_loopback.Close();
    mic_capture.Close();

    if (writer && !g_recorder.cancelled.load() && frames_written > 0) {
      if (SUCCEEDED(writer->Finalize())) {
        g_recorder.wrote_valid_video.store(true);
      }
    }
    writer.Reset();
    ::MFShutdown();
    ::CoUninitialize();
  });

  return true;
}

bool ExtractVideoFrameAtMs(const std::wstring& video_path, int64_t timestamp_ms,
                           const std::wstring& target_png_path) {
  ::MFStartup(MF_VERSION);
  ComPtr<IMFSourceReader> reader;
  auto hw_attrs = CreateHardwareMfAttributes(true);
  HRESULT hr = ::MFCreateSourceReaderFromURL(video_path.c_str(),
                                             hw_attrs.Get(), &reader);
  if (FAILED(hr) || !reader) {
    hr = ::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr, &reader);
  }
  if (FAILED(hr)) {
    ::MFShutdown();
    return false;
  }

  ComPtr<IMFMediaType> rgb_type;
  ::MFCreateMediaType(&rgb_type);
  rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  hr = reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
      rgb_type.Get());
  if (FAILED(hr)) {
    ::MFShutdown();
    return false;
  }

  PROPVARIANT var;
  PropVariantInit(&var);
  var.vt = VT_I8;
  var.hVal.QuadPart = std::max<int64_t>(0, timestamp_ms) * 10000LL;
  reader->SetCurrentPosition(GUID_NULL, var);
  PropVariantClear(&var);

  ComPtr<IMFMediaType> actual_type;
  reader->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &actual_type);
  UINT32 w = 0, h = 0;
  INT32 src_stride = 0;
  if (actual_type) {
    ::MFGetAttributeSize(actual_type.Get(), MF_MT_FRAME_SIZE, &w, &h);
    src_stride = static_cast<INT32>(w * 4);
    UINT32 stride_u = 0;
    if (SUCCEEDED(actual_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_u)) &&
        stride_u != 0) {
      src_stride = static_cast<INT32>(stride_u);
    }
  }

  bool ok = false;
  for (int attempt = 0; attempt < 15 && !ok; ++attempt) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
        &flags, nullptr, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) break;
    if (!sample) continue;

    ComPtr<IMFMediaBuffer> buf;
    if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
      BYTE* data = nullptr;
      DWORD len = 0;
      if (SUCCEEDED(buf->Lock(&data, nullptr, &len))) {
        UINT32 abs_stride =
            static_cast<UINT32>(src_stride >= 0 ? src_stride : -src_stride);
        if (w > 0 && h > 0 && len >= abs_stride * h) {
          size_t row_bytes = static_cast<size_t>(w) * 4;
          std::vector<uint8_t> top_down(row_bytes * h);
          for (UINT32 y = 0; y < h; ++y) {
            UINT32 sy = (src_stride >= 0) ? y : (h - 1 - y);
            const uint8_t* src_row =
                data + static_cast<size_t>(sy) * abs_stride;
            uint8_t* dst_row =
                top_down.data() + static_cast<size_t>(y) * row_bytes;
            std::memcpy(dst_row, src_row, row_bytes);
            for (UINT32 x = 0; x < w; ++x) {
              dst_row[x * 4 + 3] = 0xFF;
            }
          }
          ok = SaveBgraToPngFile(top_down.data(), static_cast<int>(w),
                                 static_cast<int>(h),
                                 static_cast<int>(row_bytes), target_png_path);
        }
        buf->Unlock();
      }
    }
  }

  ::MFShutdown();
  return ok;
}

bool ExportVideoAsGifWic(const std::wstring& video_path,
                         const std::wstring& target_path, int64_t start_ms,
                         int64_t end_ms, int fps, int max_width) {
  if (video_path.empty() || target_path.empty()) return false;

  HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool did_com = (com_hr == S_OK || com_hr == S_FALSE);
  ::MFStartup(MF_VERSION);

  bool success = false;
  int frames_written = 0;

  do {
    ComPtr<IMFSourceReader> reader;
    if (FAILED(::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr,
                                             &reader)) ||
        !reader) {
      break;
    }

    ComPtr<IMFMediaType> rgb_type;
    ::MFCreateMediaType(&rgb_type);
    rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
            rgb_type.Get()))) {
      break;
    }

    ComPtr<IMFMediaType> actual_v;
    if (FAILED(reader->GetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
            &actual_v)) ||
        !actual_v) {
      break;
    }

    UINT32 vw = 0;
    UINT32 vh = 0;
    if (FAILED(::MFGetAttributeSize(actual_v.Get(), MF_MT_FRAME_SIZE, &vw,
                                    &vh)) ||
        vw < 2 || vh < 2) {
      break;
    }

    INT32 src_stride = static_cast<INT32>(vw * 4);
    UINT32 stride_u = 0;
    if (SUCCEEDED(actual_v->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_u)) &&
        stride_u != 0) {
      src_stride = static_cast<INT32>(stride_u);
    }

    int64_t total_ms = 0;
    {
      PROPVARIANT dur_var;
      ::PropVariantInit(&dur_var);
      if (SUCCEEDED(reader->GetPresentationAttribute(
              static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
              &dur_var))) {
        if (dur_var.vt == VT_UI8) {
          total_ms = static_cast<int64_t>(dur_var.uhVal.QuadPart / 10000ULL);
        } else if (dur_var.vt == VT_I8) {
          total_ms = dur_var.hVal.QuadPart / 10000LL;
        }
        ::PropVariantClear(&dur_var);
      }
    }

    int64_t eff_start = std::max<int64_t>(0, start_ms);
    int64_t eff_end = (end_ms > eff_start) ? end_ms : total_ms;
    if (total_ms > 0) eff_end = std::min(eff_end, total_ms);
    if (eff_end <= eff_start) eff_end = eff_start + 500;

    int target_max_w = (max_width > 0) ? max_width : 720;
    int out_w = static_cast<int>(vw);
    int out_h = static_cast<int>(vh);
    if (out_w > target_max_w) {
      out_h = std::max(
          2, static_cast<int>((static_cast<int64_t>(out_h) * target_max_w) /
                              out_w));
      out_w = target_max_w;
    }

    int clamped_fps = std::clamp(fps, 5, 25);
    int64_t step_ms = std::max<int64_t>(40, 1000 / clamped_fps);
    int64_t step_100ns = step_ms * 10000LL;
    USHORT delay_cs = static_cast<USHORT>(std::max<int64_t>(2, (step_ms + 5) / 10));

    ComPtr<IWICImagingFactory> factory;
    if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory))) ||
        !factory) {
      break;
    }

    ComPtr<IWICStream> wic_stream;
    if (FAILED(factory->CreateStream(&wic_stream)) || !wic_stream) break;
    if (FAILED(wic_stream->InitializeFromFilename(target_path.c_str(),
                                                  GENERIC_WRITE))) {
      break;
    }

    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(factory->CreateEncoder(GUID_ContainerFormatGif, nullptr,
                                      &encoder)) ||
        !encoder) {
      break;
    }
    if (FAILED(encoder->Initialize(wic_stream.Get(), WICBitmapEncoderNoCache))) {
      break;
    }

    {
      ComPtr<IWICMetadataQueryWriter> container_meta;
      if (SUCCEEDED(encoder->GetMetadataQueryWriter(&container_meta)) &&
          container_meta) {
        static BYTE kNetscapeApp[11] = {'N', 'E', 'T', 'S', 'C', 'A',
                                        'P', 'E', '2', '.', '0'};
        PROPVARIANT app_var;
        ::PropVariantInit(&app_var);
        app_var.vt = VT_UI1 | VT_VECTOR;
        app_var.caub.cElems = 11;
        app_var.caub.pElems = kNetscapeApp;
        container_meta->SetMetadataByName(L"/appext/Application", &app_var);

        static BYTE kLoopData[5] = {3, 1, 0, 0, 0};
        PROPVARIANT data_var;
        ::PropVariantInit(&data_var);
        data_var.vt = VT_UI1 | VT_VECTOR;
        data_var.caub.cElems = 5;
        data_var.caub.pElems = kLoopData;
        container_meta->SetMetadataByName(L"/appext/Data", &data_var);
      }
    }

    PROPVARIANT seek_var;
    ::PropVariantInit(&seek_var);
    seek_var.vt = VT_I8;
    seek_var.hVal.QuadPart = eff_start * 10000LL;
    reader->SetCurrentPosition(GUID_NULL, seek_var);
    ::PropVariantClear(&seek_var);

    int64_t next_ts = eff_start * 10000LL;
    int64_t end_ts = eff_end * 10000LL;
    std::vector<uint8_t> scaled_bgra(static_cast<size_t>(out_w) * out_h * 4);
    UINT32 abs_stride =
        static_cast<UINT32>(src_stride >= 0 ? src_stride : -src_stride);

    while (frames_written < 300) {
      DWORD flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      HRESULT rhr = reader->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
          &flags, &ts, &sample);
      if (FAILED(rhr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) break;
      if (!sample) continue;
      if (ts > end_ts) break;
      if (ts < next_ts) continue;

      ComPtr<IMFMediaBuffer> buf;
      if (FAILED(sample->ConvertToContiguousBuffer(&buf))) continue;
      BYTE* sdata = nullptr;
      DWORD slen = 0;
      if (FAILED(buf->Lock(&sdata, nullptr, &slen))) continue;

      bool frame_ready = (slen >= abs_stride * vh);
      if (frame_ready) {
        for (int y = 0; y < out_h; ++y) {
          int src_y = (out_h == static_cast<int>(vh))
                          ? y
                          : static_cast<int>(
                                (static_cast<int64_t>(y) * vh) / out_h);
          int mem_y =
              (src_stride >= 0) ? src_y : (static_cast<int>(vh) - 1 - src_y);
          const uint8_t* src_row =
              sdata + static_cast<size_t>(mem_y) * abs_stride;
          uint8_t* dst_row =
              scaled_bgra.data() + static_cast<size_t>(y) * out_w * 4;
          for (int x = 0; x < out_w; ++x) {
            int src_x = (out_w == static_cast<int>(vw))
                            ? x
                            : static_cast<int>(
                                  (static_cast<int64_t>(x) * vw) / out_w);
            dst_row[x * 4 + 0] = src_row[src_x * 4 + 0];
            dst_row[x * 4 + 1] = src_row[src_x * 4 + 1];
            dst_row[x * 4 + 2] = src_row[src_x * 4 + 2];
            dst_row[x * 4 + 3] = 0xFF;
          }
        }
      }
      buf->Unlock();
      if (!frame_ready) continue;

      ComPtr<IWICBitmapFrameEncode> frame_enc;
      ComPtr<IPropertyBag2> props;
      if (FAILED(encoder->CreateNewFrame(&frame_enc, &props)) || !frame_enc) {
        break;
      }
      if (FAILED(frame_enc->Initialize(props.Get()))) break;
      frame_enc->SetSize(static_cast<UINT>(out_w), static_cast<UINT>(out_h));

      ComPtr<IWICMetadataQueryWriter> frame_meta;
      if (SUCCEEDED(frame_enc->GetMetadataQueryWriter(&frame_meta)) &&
          frame_meta) {
        PROPVARIANT delay_var;
        ::PropVariantInit(&delay_var);
        delay_var.vt = VT_UI2;
        delay_var.uiVal = delay_cs;
        frame_meta->SetMetadataByName(L"/grctlext/Delay", &delay_var);
      }

      ComPtr<IWICBitmap> wic_bmp;
      if (FAILED(factory->CreateBitmapFromMemory(
              static_cast<UINT>(out_w), static_cast<UINT>(out_h),
              GUID_WICPixelFormat32bppBGRA, static_cast<UINT>(out_w * 4),
              static_cast<UINT>(scaled_bgra.size()), scaled_bgra.data(),
              &wic_bmp)) ||
          !wic_bmp) {
        continue;
      }

      ComPtr<IWICPalette> palette;
      if (FAILED(factory->CreatePalette(&palette)) || !palette) continue;
      if (FAILED(palette->InitializeFromBitmap(wic_bmp.Get(), 256, FALSE))) {
        continue;
      }
      frame_enc->SetPalette(palette.Get());

      WICPixelFormatGUID idx_fmt = GUID_WICPixelFormat8bppIndexed;
      frame_enc->SetPixelFormat(&idx_fmt);

      ComPtr<IWICFormatConverter> conv;
      if (FAILED(factory->CreateFormatConverter(&conv)) || !conv) continue;
      if (FAILED(conv->Initialize(wic_bmp.Get(), GUID_WICPixelFormat8bppIndexed,
                                  WICBitmapDitherTypeSpiral8x8, palette.Get(),
                                  0.0, WICBitmapPaletteTypeCustom))) {
        continue;
      }

      if (SUCCEEDED(frame_enc->WriteSource(conv.Get(), nullptr)) &&
          SUCCEEDED(frame_enc->Commit())) {
        ++frames_written;
        next_ts = ts + step_100ns;
      }
    }

    if (frames_written > 0 && SUCCEEDED(encoder->Commit())) {
      success = true;
    }
  } while (false);

  if (!success) {
    ::DeleteFileW(target_path.c_str());
  }
  ::MFShutdown();
  if (did_com) ::CoUninitialize();
  return success;
}

// Gene - Nov, 13, 2026: Added QueryVideoDurationMs, TranscodeVideoSegments (for trimVideo & cutVideo), and WinVideoTexturePlayer (Flutter PixelBufferTexture + WASAPI audio render).
int64_t QueryVideoDurationMs(const std::wstring& video_path) {
  ComPtr<IMFSourceReader> reader;
  if (FAILED(::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr,
                                           &reader)) ||
      !reader) {
    return 0;
  }
  PROPVARIANT var;
  ::PropVariantInit(&var);
  int64_t dur_ms = 0;
  if (SUCCEEDED(reader->GetPresentationAttribute(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
          &var))) {
    if (var.vt == VT_UI8) {
      dur_ms = static_cast<int64_t>(var.uhVal.QuadPart / 10000ULL);
    } else if (var.vt == VT_I8) {
      dur_ms = var.hVal.QuadPart / 10000LL;
    }
    ::PropVariantClear(&var);
  }
  return dur_ms;
}

// Gene - Nov, 24, 2026: Upgrade TranscodeVideoSegments (hardware transforms, seg_start_100ns A/V alignment, per-stream EOF, stride-checked copy) and WinVideoTexturePlayer (PixelBufferLease thread safety, Rust BGRA->RGBA, async Create/Dispose, pause/seek audio reset, speed-scaled WASAPI audio, frame-exact seek, ReleaseVideoPlayersForPath).
// Old implementation (TranscodeVideoSegments, WinVideoTexturePlayer):
// bool TranscodeVideoSegments(...) {
//   // Used MFCreateSourceReaderFromURL(..., nullptr, ...), broke on single ENDOFSTREAM,
//   // anchored first_v_ts/first_a_ts separately, and checked slen >= vw * 4 * vh.
// }
// class WinVideoTexturePlayer {
//   // Synchronous Create() and Dispose(), single rgba_front buffer without lease,
//   // 1.0x fixed WASAPI output even at non-1.0x speed, and no audio flush on pause/seek.
// };
bool PathsEqualInsensitive(const std::wstring& a, const std::wstring& b) {
  auto norm = [](std::wstring s) {
    for (wchar_t& ch : s) {
      if (ch == L'/') ch = L'\\';
    }
    return s;
  };
  std::wstring na = norm(a);
  std::wstring nb = norm(b);
  return ::_wcsicmp(na.c_str(), nb.c_str()) == 0;
}

bool TranscodeVideoSegments(
    const std::wstring& src_path, const std::wstring& dst_path,
    const std::vector<std::pair<int64_t, int64_t>>& ranges_ms,
    int64_t* out_duration_ms) {
  if (src_path.empty() || dst_path.empty() || ranges_ms.empty()) return false;

  HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool did_com = (com_hr == S_OK || com_hr == S_FALSE);
  ::MFStartup(MF_VERSION);

  bool success = false;
  int64_t total_out_100ns = 0;

  do {
    ComPtr<IMFSourceReader> reader;
    auto r_attrs = CreateHardwareMfAttributes(true);
    if (FAILED(::MFCreateSourceReaderFromURL(src_path.c_str(), r_attrs.Get(),
                                             &reader)) ||
        !reader) {
      if (FAILED(::MFCreateSourceReaderFromURL(src_path.c_str(), nullptr,
                                               &reader)) ||
          !reader) {
        break;
      }
    }

    DWORD in_v_idx = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
    DWORD in_a_idx = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    bool found_v = false;
    bool found_a = false;
    for (DWORD idx = 0; idx < 16; ++idx) {
      ComPtr<IMFMediaType> native_mt;
      if (FAILED(reader->GetNativeMediaType(idx, 0, &native_mt)) || !native_mt) {
        break;
      }
      GUID maj = GUID_NULL;
      if (SUCCEEDED(native_mt->GetGUID(MF_MT_MAJOR_TYPE, &maj))) {
        if (!found_v && maj == MFMediaType_Video) {
          in_v_idx = idx;
          found_v = true;
        } else if (!found_a && maj == MFMediaType_Audio) {
          in_a_idx = idx;
          found_a = true;
        }
      }
    }

    ComPtr<IMFMediaType> rgb_type;
    ::MFCreateMediaType(&rgb_type);
    rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType(in_v_idx, nullptr, rgb_type.Get()))) {
      break;
    }

    ComPtr<IMFMediaType> actual_v;
    if (FAILED(reader->GetCurrentMediaType(in_v_idx, &actual_v)) || !actual_v) {
      break;
    }

    UINT32 vw = 0;
    UINT32 vh = 0;
    if (FAILED(::MFGetAttributeSize(actual_v.Get(), MF_MT_FRAME_SIZE, &vw,
                                    &vh)) ||
        vw < 2 || vh < 2) {
      break;
    }

    UINT32 fps_num = 60;
    UINT32 fps_den = 1;
    if (FAILED(::MFGetAttributeRatio(actual_v.Get(), MF_MT_FRAME_RATE, &fps_num,
                                     &fps_den)) ||
        fps_num == 0 || fps_den == 0) {
      fps_num = 60;
      fps_den = 1;
    }

    UINT32 stride_u = 0;
    INT32 src_stride = static_cast<INT32>(vw * 4);
    if (SUCCEEDED(actual_v->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_u)) &&
        stride_u != 0) {
      src_stride = static_cast<INT32>(stride_u);
    }

    bool has_audio = false;
    ComPtr<IMFMediaType> pcm_req;
    ::MFCreateMediaType(&pcm_req);
    pcm_req->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    pcm_req->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    pcm_req->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    pcm_req->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
    pcm_req->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
    pcm_req->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
    pcm_req->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000);
    if (found_a &&
        SUCCEEDED(reader->SetCurrentMediaType(in_a_idx, nullptr, pcm_req.Get()))) {
      has_audio = true;
    }

    ComPtr<IMFSinkWriter> writer;
    auto w_attrs = CreateHardwareMfAttributes(false);
    if (FAILED(::MFCreateSinkWriterFromURL(dst_path.c_str(), nullptr,
                                           w_attrs.Get(), &writer)) ||
        !writer) {
      if (FAILED(::MFCreateSinkWriterFromURL(dst_path.c_str(), nullptr, nullptr,
                                             &writer)) ||
          !writer) {
        break;
      }
    }

    DWORD out_v_idx = 0;
    ComPtr<IMFMediaType> v_out;
    ::MFCreateMediaType(&v_out);
    v_out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    v_out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    v_out->SetUINT32(
        MF_MT_AVG_BITRATE,
        static_cast<UINT32>(std::clamp<UINT64>(
            static_cast<UINT64>(vw) * vh * 4ULL, 2000000ULL, 20000000ULL)));
    v_out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    ::MFSetAttributeSize(v_out.Get(), MF_MT_FRAME_SIZE, vw, vh);
    ::MFSetAttributeRatio(v_out.Get(), MF_MT_FRAME_RATE, fps_num, fps_den);
    ::MFSetAttributeRatio(v_out.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (FAILED(writer->AddStream(v_out.Get(), &out_v_idx))) break;

    ComPtr<IMFMediaType> v_in;
    ::MFCreateMediaType(&v_in);
    v_in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    v_in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    v_in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    ::MFSetAttributeSize(v_in.Get(), MF_MT_FRAME_SIZE, vw, vh);
    ::MFSetAttributeRatio(v_in.Get(), MF_MT_FRAME_RATE, fps_num, fps_den);
    ::MFSetAttributeRatio(v_in.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (FAILED(writer->SetInputMediaType(out_v_idx, v_in.Get(), nullptr))) {
      break;
    }

    DWORD out_a_idx = 1;
    bool writer_has_audio = false;
    if (has_audio) {
      ComPtr<IMFMediaType> a_out;
      ::MFCreateMediaType(&a_out);
      a_out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      a_out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      a_out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
      a_out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
      a_out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
      a_out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 20000);

      if (SUCCEEDED(writer->AddStream(a_out.Get(), &out_a_idx)) &&
          SUCCEEDED(writer->SetInputMediaType(out_a_idx, pcm_req.Get(),
                                              nullptr))) {
        writer_has_audio = true;
      }
    }

    if (FAILED(writer->BeginWriting())) break;

    bool write_ok = true;
    int64_t last_out_v_ts = -1;
    int64_t last_out_a_ts = -1;
    UINT32 abs_stride =
        static_cast<UINT32>(src_stride >= 0 ? src_stride : -src_stride);
    DWORD row_bytes = vw * 4;
    DWORD out_bytes = row_bytes * vh;
    DWORD required_src_bytes = abs_stride * vh;

    for (const auto& seg : ranges_ms) {
      if (seg.second <= seg.first) continue;
      int64_t seg_start_100ns = seg.first * 10000LL;
      int64_t seg_end_100ns = seg.second * 10000LL;

      PROPVARIANT seek_var;
      ::PropVariantInit(&seek_var);
      seek_var.vt = VT_I8;
      seek_var.hVal.QuadPart = seg_start_100ns;
      reader->SetCurrentPosition(GUID_NULL, seek_var);
      ::PropVariantClear(&seek_var);

      bool v_done = false;
      bool a_done = !writer_has_audio;
      bool v_eof = false;
      bool a_eof = !writer_has_audio;
      int64_t seg_max_dur = 0;

      while (!(v_done && a_done) && !(v_eof && a_eof)) {
        DWORD stream_idx = 0;
        DWORD flags = 0;
        LONGLONG ts = 0;
        ComPtr<IMFSample> sample;
        HRESULT rhr = reader->ReadSample(
            static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &stream_idx,
            &flags, &ts, &sample);
        if (FAILED(rhr)) {
          break;
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
          if (stream_idx == in_v_idx) {
            v_eof = true;
            v_done = true;
          } else if (writer_has_audio && stream_idx == in_a_idx) {
            a_eof = true;
            a_done = true;
          } else {
            break;
          }
          if (!sample) continue;
        }
        if (!sample) continue;

        if (stream_idx == in_v_idx && !v_done) {
          if (ts < seg_start_100ns) continue;
          if (ts > seg_end_100ns) {
            v_done = true;
            continue;
          }
          int64_t rel_ts = std::max<int64_t>(0, ts - seg_start_100ns);
          LONGLONG dur = 0;
          sample->GetSampleDuration(&dur);
          if (dur <= 0) {
            dur = (static_cast<LONGLONG>(fps_den) * 10000000LL) /
                  static_cast<LONGLONG>(fps_num);
          }

          ComPtr<IMFMediaBuffer> src_buf;
          if (SUCCEEDED(sample->ConvertToContiguousBuffer(&src_buf))) {
            BYTE* sdata = nullptr;
            DWORD slen = 0;
            if (SUCCEEDED(src_buf->Lock(&sdata, nullptr, &slen))) {
              if (abs_stride >= row_bytes && slen >= required_src_bytes) {
                ComPtr<IMFMediaBuffer> dst_buf;
                if (SUCCEEDED(::MFCreateMemoryBuffer(out_bytes, &dst_buf))) {
                  BYTE* ddata = nullptr;
                  if (SUCCEEDED(dst_buf->Lock(&ddata, nullptr, nullptr))) {
                    for (UINT32 r = 0; r < vh; ++r) {
                      UINT32 src_r = (src_stride >= 0) ? (vh - 1 - r) : r;
                      std::memcpy(ddata + r * row_bytes,
                                  sdata + src_r * abs_stride, row_bytes);
                    }
                    dst_buf->Unlock();
                    dst_buf->SetCurrentLength(out_bytes);
                    ComPtr<IMFSample> out_sample;
                    if (SUCCEEDED(::MFCreateSample(&out_sample))) {
                      int64_t out_ts = total_out_100ns + rel_ts;
                      if (out_ts <= last_out_v_ts) {
                        out_ts = last_out_v_ts + 10000LL;
                      }
                      last_out_v_ts = out_ts;
                      out_sample->AddBuffer(dst_buf.Get());
                      out_sample->SetSampleTime(out_ts);
                      out_sample->SetSampleDuration(dur);
                      if (FAILED(writer->WriteSample(out_v_idx,
                                                     out_sample.Get()))) {
                        write_ok = false;
                      }
                    }
                  }
                }
              }
              src_buf->Unlock();
            }
          }
          seg_max_dur = std::max(seg_max_dur, rel_ts + dur);
        } else if (writer_has_audio && stream_idx == in_a_idx && !a_done) {
          if (ts < seg_start_100ns) continue;
          if (ts > seg_end_100ns) {
            a_done = true;
            continue;
          }
          int64_t rel_ts = std::max<int64_t>(0, ts - seg_start_100ns);
          LONGLONG dur = 0;
          sample->GetSampleDuration(&dur);
          int64_t out_ts = total_out_100ns + rel_ts;
          if (out_ts <= last_out_a_ts) {
            out_ts = last_out_a_ts + 10000LL;
          }
          last_out_a_ts = out_ts;
          sample->SetSampleTime(out_ts);
          if (FAILED(writer->WriteSample(out_a_idx, sample.Get()))) {
            write_ok = false;
          }
          seg_max_dur = std::max(seg_max_dur, rel_ts + dur);
        }
        if (!write_ok) break;
      }
      total_out_100ns +=
          std::max<int64_t>(seg_max_dur, seg_end_100ns - seg_start_100ns);
      if (!write_ok) break;
    }

    if (write_ok && total_out_100ns > 0 && SUCCEEDED(writer->Finalize())) {
      success = true;
    }
  } while (false);

  if (out_duration_ms) {
    *out_duration_ms = total_out_100ns / 10000LL;
  }
  ::MFShutdown();
  if (did_com) ::CoUninitialize();
  return success;
}

class WinVideoTexturePlayer
    : public std::enable_shared_from_this<WinVideoTexturePlayer> {
 public:
  struct PixelBufferLease {
    std::shared_ptr<const std::vector<uint8_t>> frame;
    FlutterDesktopPixelBuffer descriptor = {};
  };

  int64_t texture_id = -1;
  int64_t duration_ms = 0;
  int width = 0;
  int height = 0;
  bool has_audio = false;

  std::unique_ptr<flutter::TextureVariant> texture_variant;
  std::mutex frame_mutex;
  std::shared_ptr<const std::vector<uint8_t>> front_frame;
  std::array<std::shared_ptr<std::vector<uint8_t>>, 3> decode_pool;

  std::atomic<bool> playing{false};
  std::atomic<bool> disposed{false};
  std::atomic<bool> muted{false};
  std::atomic<float> volume{1.0f};
  std::atomic<float> speed{1.0f};
  std::atomic<int64_t> position_ms{0};
  std::atomic<int64_t> seek_request_ms{-1};
  std::atomic<bool> reanchor_clock{false};

  std::wstring video_path;
  flutter::TextureRegistrar* registrar = nullptr;
  std::thread worker;

  static void CreateAsync(
      const std::wstring& path, flutter::TextureRegistrar* reg,
      std::function<void(std::shared_ptr<WinVideoTexturePlayer>)> on_ready) {
    if (!reg || path.empty()) {
      PostToPlatformThread([on_ready]() {
        if (on_ready) on_ready(nullptr);
      });
      return;
    }

    auto player = std::make_shared<WinVideoTexturePlayer>();
    player->video_path = path;
    player->registrar = reg;

    std::thread([player, path, reg, on_ready]() {
      HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      bool did_com = (com_hr == S_OK || com_hr == S_FALSE);
      ::MFStartup(MF_VERSION);

      bool probed_ok = false;
      do {
        ComPtr<IMFSourceReader> probe_reader;
        auto attrs = CreateHardwareMfAttributes(true);
        if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), attrs.Get(),
                                                 &probe_reader)) ||
            !probe_reader) {
          if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                                   &probe_reader)) ||
              !probe_reader) {
            break;
          }
        }

        PROPVARIANT var;
        ::PropVariantInit(&var);
        if (SUCCEEDED(probe_reader->GetPresentationAttribute(
                static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE),
                MF_PD_DURATION, &var))) {
          if (var.vt == VT_UI8) {
            player->duration_ms =
                static_cast<int64_t>(var.uhVal.QuadPart / 10000ULL);
          } else if (var.vt == VT_I8) {
            player->duration_ms = var.hVal.QuadPart / 10000LL;
          }
          ::PropVariantClear(&var);
        }

        ComPtr<IMFMediaType> rgb_type;
        ::MFCreateMediaType(&rgb_type);
        rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
        if (FAILED(probe_reader->SetCurrentMediaType(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                nullptr, rgb_type.Get()))) {
          break;
        }

        ComPtr<IMFMediaType> actual_v;
        UINT32 vw = 0;
        UINT32 vh = 0;
        if (FAILED(probe_reader->GetCurrentMediaType(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                &actual_v)) ||
            !actual_v ||
            FAILED(::MFGetAttributeSize(actual_v.Get(), MF_MT_FRAME_SIZE, &vw,
                                        &vh)) ||
            vw == 0 || vh == 0) {
          break;
        }

        player->width = static_cast<int>(vw);
        player->height = static_cast<int>(vh);

        ComPtr<IMFMediaType> probe_audio;
        if (SUCCEEDED(probe_reader->GetCurrentMediaType(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                &probe_audio))) {
          player->has_audio = true;
        }

        UINT32 stride_u = 0;
        INT32 default_stride = static_cast<INT32>(vw * 4);
        if (SUCCEEDED(actual_v->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_u)) &&
            stride_u != 0) {
          default_stride = static_cast<INT32>(stride_u);
        }

        for (int i = 0; i < 8; ++i) {
          DWORD flags = 0;
          ComPtr<IMFSample> sample;
          if (FAILED(probe_reader->ReadSample(
                  static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
                  nullptr, &flags, nullptr, &sample)) ||
              (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            break;
          }
          if (!sample) continue;
          if (player->DecodeSampleIntoFrontBuffer(sample.Get(),
                                                  default_stride)) {
            break;
          }
        }
        probed_ok = true;
      } while (false);

      ::MFShutdown();
      if (did_com) ::CoUninitialize();

      PostToPlatformThread([player, reg, probed_ok, on_ready]() {
        if (!probed_ok || player->disposed.load()) {
          if (on_ready) on_ready(nullptr);
          return;
        }

        std::weak_ptr<WinVideoTexturePlayer> weak_self = player;
        player->texture_variant = std::make_unique<flutter::TextureVariant>(
            flutter::PixelBufferTexture(
                [weak_self](size_t, size_t)
                    -> const FlutterDesktopPixelBuffer* {
                  auto self = weak_self.lock();
                  if (!self || self->disposed.load()) return nullptr;
                  std::shared_ptr<const std::vector<uint8_t>> frame;
                  int w = 0;
                  int h = 0;
                  {
                    std::lock_guard<std::mutex> lock(self->frame_mutex);
                    frame = self->front_frame;
                    w = self->width;
                    h = self->height;
                  }
                  if (!frame || frame->empty() || w <= 0 || h <= 0) {
                    return nullptr;
                  }
                  auto* lease = new PixelBufferLease();
                  lease->frame = std::move(frame);
                  lease->descriptor.buffer = lease->frame->data();
                  lease->descriptor.width = static_cast<size_t>(w);
                  lease->descriptor.height = static_cast<size_t>(h);
                  lease->descriptor.release_context = lease;
                  lease->descriptor.release_callback = [](void* ctx) {
                    delete static_cast<PixelBufferLease*>(ctx);
                  };
                  return &lease->descriptor;
                }));

        player->texture_id = reg->RegisterTexture(player->texture_variant.get());
        reg->MarkTextureFrameAvailable(player->texture_id);
        player->worker = std::thread([player]() { player->RunLoop(); });
        if (on_ready) on_ready(player);
      });
    }).detach();
  }

  std::shared_ptr<std::vector<uint8_t>> AcquireDecodeBuffer(size_t total_bytes) {
    for (auto& slot : decode_pool) {
      if (!slot) {
        slot = std::make_shared<std::vector<uint8_t>>(total_bytes);
        return slot;
      }
      if (slot.use_count() == 1) {
        if (slot->size() != total_bytes) {
          slot->resize(total_bytes);
        }
        return slot;
      }
    }
    return std::make_shared<std::vector<uint8_t>>(total_bytes);
  }

  bool DecodeSampleIntoFrontBuffer(IMFSample* sample, INT32 src_stride) {
    if (!sample || width <= 0 || height <= 0) return false;
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(sample->ConvertToContiguousBuffer(&buf))) return false;
    BYTE* data = nullptr;
    DWORD len = 0;
    if (FAILED(buf->Lock(&data, nullptr, &len))) return false;

    size_t row_bytes = static_cast<size_t>(width) * 4;
    size_t total_bytes = row_bytes * static_cast<size_t>(height);
    UINT32 abs_stride =
        static_cast<UINT32>(src_stride >= 0 ? src_stride : -src_stride);
    bool decoded = false;
    if (abs_stride >= row_bytes &&
        len >= static_cast<DWORD>(abs_stride * static_cast<UINT32>(height))) {
      auto frame = AcquireDecodeBuffer(total_bytes);
      if (snipsnap_bgra_to_rgba_top_down(
              data, static_cast<int32_t>(width), static_cast<int32_t>(height),
              static_cast<int32_t>(abs_stride), src_stride < 0,
              frame->data())) {
        std::lock_guard<std::mutex> lock(frame_mutex);
        front_frame = std::move(frame);
        decoded = true;
      }
    }
    buf->Unlock();
    return decoded;
  }

  void RunLoop() {
    HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool did_com = (com_hr == S_OK || com_hr == S_FALSE);
    ::MFStartup(MF_VERSION);

    ComPtr<IMFSourceReader> reader;
    auto attrs = CreateHardwareMfAttributes(true);
    HRESULT hr = ::MFCreateSourceReaderFromURL(video_path.c_str(), attrs.Get(),
                                               &reader);
    if (FAILED(hr) || !reader) {
      hr = ::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr, &reader);
    }

    DWORD v_stream_idx = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
    DWORD a_stream_idx = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    INT32 v_stride = width * 4;
    if (SUCCEEDED(hr) && reader) {
      bool got_v = false;
      bool got_a = false;
      for (DWORD idx = 0; idx < 16; ++idx) {
        ComPtr<IMFMediaType> native_mt;
        if (FAILED(reader->GetNativeMediaType(idx, 0, &native_mt)) ||
            !native_mt) {
          break;
        }
        GUID maj = GUID_NULL;
        if (SUCCEEDED(native_mt->GetGUID(MF_MT_MAJOR_TYPE, &maj))) {
          if (!got_v && maj == MFMediaType_Video) {
            v_stream_idx = idx;
            got_v = true;
          } else if (!got_a && maj == MFMediaType_Audio) {
            a_stream_idx = idx;
            got_a = true;
          }
        }
      }

      ComPtr<IMFMediaType> rgb_type;
      ::MFCreateMediaType(&rgb_type);
      rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      reader->SetCurrentMediaType(v_stream_idx, nullptr, rgb_type.Get());
      ComPtr<IMFMediaType> actual_v;
      if (SUCCEEDED(reader->GetCurrentMediaType(v_stream_idx, &actual_v)) &&
          actual_v) {
        UINT32 su = 0;
        if (SUCCEEDED(actual_v->GetUINT32(MF_MT_DEFAULT_STRIDE, &su)) &&
            su != 0) {
          v_stride = static_cast<INT32>(su);
        }
      }
      if (has_audio && got_a) {
        ComPtr<IMFMediaType> pcm_type;
        ::MFCreateMediaType(&pcm_type);
        pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
        pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        pcm_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
        pcm_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000);
        reader->SetCurrentMediaType(a_stream_idx, nullptr, pcm_type.Get());
      }
    }

    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> render_dev;
    ComPtr<IAudioClient> render_client;
    ComPtr<IAudioRenderClient> audio_render;
    UINT32 render_buf_frames = 0;
    UINT32 render_rate = 48000;
    UINT32 render_channels = 2;
    bool render_float = true;
    bool audio_ready = false;
    bool audio_started = false;

    if (has_audio &&
        SUCCEEDED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                     CLSCTX_ALL, IID_PPV_ARGS(&enumerator))) &&
        enumerator &&
        SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                                      &render_dev)) &&
        render_dev &&
        SUCCEEDED(render_dev->Activate(
            __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
            reinterpret_cast<void**>(render_client.GetAddressOf()))) &&
        render_client) {
      WAVEFORMATEX* rfmt = nullptr;
      if (SUCCEEDED(render_client->GetMixFormat(&rfmt)) && rfmt) {
        render_rate = std::max<UINT32>(1, rfmt->nSamplesPerSec);
        render_channels = std::max<UINT32>(1, rfmt->nChannels);
        render_float = (rfmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT);
        if (rfmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE && rfmt->cbSize >= 22) {
          const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(rfmt);
          static const GUID kFloatSub = {
              0x00000003,
              0x0000,
              0x0010,
              {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
          render_float =
              std::memcmp(&ext->SubFormat, &kFloatSub, sizeof(GUID)) == 0;
        }
        if (SUCCEEDED(render_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                                2000000, 0, rfmt, nullptr)) &&
            SUCCEEDED(render_client->GetBufferSize(&render_buf_frames)) &&
            SUCCEEDED(render_client->GetService(IID_PPV_ARGS(&audio_render)))) {
          audio_ready = true;
        }
        ::CoTaskMemFree(rfmt);
      }
    }

    std::deque<float> audio_fifo;
    double audio_src_phase = 0.0;

    auto stop_and_flush_audio = [&]() {
      audio_fifo.clear();
      audio_src_phase = 0.0;
      if (audio_ready && render_client) {
        if (audio_started) {
          render_client->Stop();
          audio_started = false;
        }
        render_client->Reset();
      }
    };

    auto flush_audio_fifo = [&]() {
      if (!audio_ready || !render_client || !audio_render ||
          audio_fifo.size() < 2) {
        return;
      }
      if (!audio_started) {
        if (SUCCEEDED(render_client->Start())) {
          audio_started = true;
        } else {
          return;
        }
      }
      UINT32 padding = 0;
      if (FAILED(render_client->GetCurrentPadding(&padding))) return;
      UINT32 avail =
          (render_buf_frames > padding) ? (render_buf_frames - padding) : 0;
      if (avail == 0) return;

      double cur_spd = static_cast<double>(std::clamp(speed.load(), 0.25f, 4.0f));
      double step = (48000.0 * cur_spd) / static_cast<double>(render_rate);
      if (step <= 0.0) return;

      size_t avail_in_frames = audio_fifo.size() / 2;
      double max_phase = static_cast<double>(avail_in_frames) - 1.0001;
      if (max_phase <= audio_src_phase) return;
      UINT32 can_produce =
          static_cast<UINT32>((max_phase - audio_src_phase) / step) + 1;
      UINT32 out_frames = std::min(avail, can_produce);
      if (out_frames == 0) return;

      BYTE* rdata = nullptr;
      if (SUCCEEDED(audio_render->GetBuffer(out_frames, &rdata)) && rdata) {
        float gain = muted.load() ? 0.0f : volume.load();
        double phase = audio_src_phase;
        for (UINT32 f = 0; f < out_frames; ++f) {
          size_t idx0 = static_cast<size_t>(phase);
          size_t idx1 = std::min(idx0 + 1, avail_in_frames - 1);
          float frac = static_cast<float>(phase - static_cast<double>(idx0));
          float l0 = audio_fifo[idx0 * 2 + 0];
          float r0 = audio_fifo[idx0 * 2 + 1];
          float l1 = audio_fifo[idx1 * 2 + 0];
          float r1 = audio_fifo[idx1 * 2 + 1];
          float sl = (l0 + (l1 - l0) * frac) * gain;
          float sr = (r0 + (r1 - r0) * frac) * gain;

          if (render_float) {
            float* out_f = reinterpret_cast<float*>(rdata) +
                           static_cast<size_t>(f) * render_channels;
            out_f[0] = sl;
            if (render_channels >= 2) out_f[1] = sr;
            for (UINT32 ch = 2; ch < render_channels; ++ch) {
              out_f[ch] = 0.0f;
            }
          } else {
            int16_t* out_i = reinterpret_cast<int16_t*>(rdata) +
                             static_cast<size_t>(f) * render_channels;
            out_i[0] =
                static_cast<int16_t>(std::clamp(sl, -1.0f, 1.0f) * 32767.0f);
            if (render_channels >= 2) {
              out_i[1] =
                  static_cast<int16_t>(std::clamp(sr, -1.0f, 1.0f) * 32767.0f);
            }
            for (UINT32 ch = 2; ch < render_channels; ++ch) {
              out_i[ch] = 0;
            }
          }
          phase += step;
        }
        audio_render->ReleaseBuffer(out_frames, 0);

        size_t consumed_frames = static_cast<size_t>(phase);
        if (consumed_frames >= avail_in_frames) {
          audio_fifo.clear();
          audio_src_phase = 0.0;
        } else {
          audio_fifo.erase(audio_fifo.begin(),
                           audio_fifo.begin() +
                               static_cast<ptrdiff_t>(consumed_frames * 2));
          audio_src_phase = phase - static_cast<double>(consumed_frames);
        }
      }
    };

    auto last_progress_emit = std::chrono::steady_clock::now();
    bool need_clock_anchor = true;
    auto wall_anchor = std::chrono::steady_clock::now();
    int64_t media_anchor_ms = 0;

    while (!disposed.load() && reader) {
      int64_t req_seek = seek_request_ms.exchange(-1);
      if (req_seek >= 0) {
        int64_t clamped = std::clamp<int64_t>(req_seek, 0, duration_ms);
        int64_t target_100ns = clamped * 10000LL;
        stop_and_flush_audio();

        PROPVARIANT var;
        ::PropVariantInit(&var);
        var.vt = VT_I8;
        var.hVal.QuadPart = target_100ns;
        reader->SetCurrentPosition(GUID_NULL, var);
        ::PropVariantClear(&var);
        position_ms.store(clamped);
        need_clock_anchor = true;

        ComPtr<IMFSample> best_sample;
        LONGLONG best_ts = 0;
        for (int i = 0; i < 120 && !disposed.load(); ++i) {
          DWORD flags = 0;
          LONGLONG ts = 0;
          ComPtr<IMFSample> s;
          if (FAILED(reader->ReadSample(v_stream_idx, 0, nullptr, &flags, &ts,
                                        &s)) ||
              (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            break;
          }
          if (!s) continue;
          best_sample = s;
          best_ts = ts;
          if (ts >= target_100ns - 200000LL) {
            break;
          }
        }
        if (best_sample &&
            DecodeSampleIntoFrontBuffer(best_sample.Get(), v_stride)) {
          if (registrar && texture_id >= 0) {
            registrar->MarkTextureFrameAvailable(texture_id);
          }
          position_ms.store(std::max<int64_t>(clamped, best_ts / 10000LL));
        }

        EncodableMap prog;
        prog[EncodableValue("textureId")] = EncodableValue(texture_id);
        prog[EncodableValue("positionMs")] = EncodableValue(position_ms.load());
        prog[EncodableValue("isPlaying")] = EncodableValue(playing.load());
        InvokeDartMethod("onVideoPlayerProgress", EncodableValue(prog));
      }

      if (!playing.load()) {
        if (audio_started || !audio_fifo.empty()) {
          stop_and_flush_audio();
        }
        need_clock_anchor = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
        continue;
      }

      flush_audio_fifo();

      DWORD stream_idx = 0;
      DWORD flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      HRESULT rhr = reader->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &stream_idx,
          &flags, &ts, &sample);
      if (FAILED(rhr) ||
          ((flags & MF_SOURCE_READERF_ENDOFSTREAM) &&
           stream_idx == v_stream_idx) ||
          ((flags & MF_SOURCE_READERF_ENDOFSTREAM) && !sample && !has_audio)) {
        stop_and_flush_audio();
        playing.store(false);
        position_ms.store(duration_ms);
        EncodableMap prog;
        prog[EncodableValue("textureId")] = EncodableValue(texture_id);
        prog[EncodableValue("positionMs")] = EncodableValue(duration_ms);
        prog[EncodableValue("isPlaying")] = EncodableValue(false);
        InvokeDartMethod("onVideoPlayerProgress", EncodableValue(prog));

        EncodableMap done_args;
        done_args[EncodableValue("textureId")] = EncodableValue(texture_id);
        InvokeDartMethod("onVideoPlayerCompleted", EncodableValue(done_args));
        continue;
      }
      if (!sample) continue;

      if (stream_idx == a_stream_idx && has_audio && audio_ready &&
          audio_render) {
        ComPtr<IMFMediaBuffer> abuf;
        if (SUCCEEDED(sample->ConvertToContiguousBuffer(&abuf))) {
          BYTE* adata = nullptr;
          DWORD alen = 0;
          if (SUCCEEDED(abuf->Lock(&adata, nullptr, &alen)) && alen >= 4) {
            UINT32 in_frames = alen / 4;
            const int16_t* pcm = reinterpret_cast<const int16_t*>(adata);
            for (UINT32 f = 0; f < in_frames; ++f) {
              audio_fifo.push_back(static_cast<float>(pcm[f * 2 + 0]) /
                                   32768.0f);
              audio_fifo.push_back(static_cast<float>(pcm[f * 2 + 1]) /
                                   32768.0f);
            }
            while (audio_fifo.size() > 192000) {
              audio_fifo.pop_front();
              audio_fifo.pop_front();
            }
            abuf->Unlock();
            flush_audio_fifo();
          }
        }
        continue;
      }

      if (stream_idx == v_stream_idx) {
        int64_t frame_ms = ts / 10000LL;
        if (need_clock_anchor || reanchor_clock.exchange(false)) {
          wall_anchor = std::chrono::steady_clock::now();
          media_anchor_ms = frame_ms;
          need_clock_anchor = false;
        } else {
          float cur_spd = std::clamp(speed.load(), 0.25f, 4.0f);
          int64_t target_wall_ms = static_cast<int64_t>(
              static_cast<double>(frame_ms - media_anchor_ms) / cur_spd);
          auto due = wall_anchor + std::chrono::milliseconds(target_wall_ms);
          while (!disposed.load() && playing.load() &&
                 seek_request_ms.load() < 0 && !reanchor_clock.load() &&
                 std::chrono::steady_clock::now() < due) {
            flush_audio_fifo();
            auto rem_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              due - std::chrono::steady_clock::now())
                              .count();
            std::this_thread::sleep_for(
                std::chrono::milliseconds(std::clamp<int64_t>(rem_ms, 1, 10)));
          }
        }
        if (disposed.load() || seek_request_ms.load() >= 0) continue;

        if (DecodeSampleIntoFrontBuffer(sample.Get(), v_stride)) {
          if (registrar && texture_id >= 0) {
            registrar->MarkTextureFrameAvailable(texture_id);
          }
        }
        position_ms.store(frame_ms);

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(
                now - last_progress_emit)
                .count() >= 33) {
          last_progress_emit = now;
          EncodableMap prog;
          prog[EncodableValue("textureId")] = EncodableValue(texture_id);
          prog[EncodableValue("positionMs")] = EncodableValue(frame_ms);
          prog[EncodableValue("isPlaying")] = EncodableValue(true);
          InvokeDartMethod("onVideoPlayerProgress", EncodableValue(prog));
        }
      }
    }

    stop_and_flush_audio();
    audio_render.Reset();
    render_client.Reset();
    reader.Reset();
    ::MFShutdown();
    if (did_com) ::CoUninitialize();
  }

  void Play() {
    if (duration_ms > 0 && position_ms.load() >= duration_ms - 40) {
      seek_request_ms.store(0);
    }
    playing.store(true);
  }
  void Pause() { playing.store(false); }
  void Seek(int64_t ms) { seek_request_ms.store(ms); }
  void SetVolume(float v) { volume.store(std::clamp(v, 0.0f, 1.0f)); }
  void SetMuted(bool m) { muted.store(m); }
  void SetSpeed(float s) {
    speed.store(std::clamp(s, 0.25f, 4.0f));
    reanchor_clock.store(true);
  }

  void DisposeAsync(std::function<void()> on_done) {
    if (disposed.exchange(true)) {
      if (on_done) on_done();
      return;
    }
    playing.store(false);
    if (registrar && texture_id >= 0) {
      auto keep_alive = shared_from_this();
      int64_t tid = texture_id;
      registrar->UnregisterTexture(tid, [keep_alive]() {});
      texture_id = -1;
    }
    if (worker.joinable()) {
      auto self = shared_from_this();
      std::thread([self, on_done]() {
        if (self->worker.joinable()) {
          self->worker.join();
        }
        if (on_done) on_done();
      }).detach();
    } else {
      if (on_done) on_done();
    }
  }

  void Dispose() {
    if (disposed.exchange(true)) return;
    playing.store(false);
    if (worker.joinable()) {
      worker.join();
    }
    if (registrar && texture_id >= 0) {
      auto keep_alive = shared_from_this();
      int64_t tid = texture_id;
      registrar->UnregisterTexture(tid, [keep_alive]() {});
      texture_id = -1;
    }
  }
};

std::mutex g_players_mutex;
std::map<int64_t, std::shared_ptr<WinVideoTexturePlayer>> g_video_players;

void ReleaseVideoPlayersForPath(const std::wstring& path,
                                std::function<void()> on_done) {
  std::vector<std::shared_ptr<WinVideoTexturePlayer>> to_dispose;
  {
    std::lock_guard<std::mutex> lock(g_players_mutex);
    for (auto it = g_video_players.begin(); it != g_video_players.end();) {
      if (it->second && PathsEqualInsensitive(it->second->video_path, path)) {
        to_dispose.push_back(it->second);
        it = g_video_players.erase(it);
      } else {
        ++it;
      }
    }
  }
  if (to_dispose.empty()) {
    if (on_done) on_done();
    return;
  }
  auto remaining = std::make_shared<std::atomic<size_t>>(to_dispose.size());
  for (auto& player : to_dispose) {
    player->DisposeAsync([remaining, on_done]() {
      if (remaining->fetch_sub(1) == 1 && on_done) {
        PostToPlatformThread(on_done);
      }
    });
  }
}

void DestroyAllVideoPlayers() {
  std::vector<std::shared_ptr<WinVideoTexturePlayer>> players;
  {
    std::lock_guard<std::mutex> lock(g_players_mutex);
    for (auto& kv : g_video_players) {
      if (kv.second) players.push_back(kv.second);
    }
    g_video_players.clear();
  }
  for (auto& p : players) {
    p->Dispose();
  }
}

}  // namespace

void RegisterCaptureHandler(flutter::FlutterEngine* engine) {
  auto gate = std::make_shared<EngineGate>();
  gate->engine = engine;
  // Gene - Nov, 13, 2026: Obtain PluginRegistrarWindows for TextureRegistrar and native window handle.
  auto registrar_ref = engine->GetRegistrarForPlugin("SnipSnapCapturePlugin");
  auto* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);
  gate->registrar = registrar;
  gate->texture_registrar = registrar ? registrar->texture_registrar() : nullptr;
  gate->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  Gate() = gate;

  // Gene - Nov, 24, 2026: Cache main HWND, install tray icon, register single-instance message, and warm WASAPI audio cache off-thread.
  g_main_hwnd = FindMainAppHwnd();
  g_show_window_msg =
      ::RegisterWindowMessageW(L"dev.genexis.snipsnap.ShowWindow");
  InstallTrayIcon(g_main_hwnd);
  if (!g_audio_refresh_in_flight.exchange(true)) {
    EnumerateWindowsAudioDevicesWorker(nullptr, false);
  }

  gate->channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<CaptureMethodResult> result) {
        const std::string& method = call.method_name();
        const auto* args = std::get_if<EncodableMap>(call.arguments());

        auto get_str = [&](const char* key) -> std::string {
          if (!args) return "";
          auto it = args->find(EncodableValue(key));
          if (it == args->end()) return "";
          if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
          return "";
        };

        auto get_double = [&](const char* key, double fallback = 0.0) -> double {
          if (!args) return fallback;
          auto it = args->find(EncodableValue(key));
          if (it == args->end()) return fallback;
          if (const auto* d = std::get_if<double>(&it->second)) return *d;
          if (const auto* i = std::get_if<int32_t>(&it->second)) {
            return static_cast<double>(*i);
          }
          if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
            return static_cast<double>(*i64);
          }
          return fallback;
        };

        auto get_bool = [&](const char* key, bool fallback = false) -> bool {
          if (!args) return fallback;
          auto it = args->find(EncodableValue(key));
          if (it == args->end()) return fallback;
          if (const auto* b = std::get_if<bool>(&it->second)) return *b;
          return fallback;
        };

        // Gene - Nov, 13, 2026: Added 64-bit integer helper, window visibility, audio enumeration, mic permission/mute handlers.
        auto get_int64 = [&](const char* key, int64_t fallback = 0) -> int64_t {
          if (!args) return fallback;
          auto it = args->find(EncodableValue(key));
          if (it == args->end()) return fallback;
          if (const auto* i64 = std::get_if<int64_t>(&it->second)) return *i64;
          if (const auto* i = std::get_if<int32_t>(&it->second)) {
            return static_cast<int64_t>(*i);
          }
          if (const auto* d = std::get_if<double>(&it->second)) {
            return static_cast<int64_t>(std::llround(*d));
          }
          return fallback;
        };

        if (method == "screenCaptureAuthorized" ||
            method == "accessibilityAuthorized" ||
            method == "microphoneAuthorized" ||
            method == "requestMicrophoneAccess") {
          result->Success(EncodableValue(true));
          return;
        }

        // Gene - Nov, 24, 2026: Native Win32 hotkeys, dark titlebar, Known Folder Desktop lookup, tray behavior, and non-blocking audio enumeration.
        if (method == "registerWindowsHotKeys") {
          EncodableList failed;
          if (args) {
            auto it = args->find(EncodableValue("entries"));
            if (it != args->end()) {
              if (const auto* entries = std::get_if<EncodableList>(&it->second)) {
                failed = RegisterNativeHotKeys(*entries);
              }
            }
          }
          result->Success(EncodableValue(failed));
          return;
        }

        if (method == "unregisterWindowsHotKeys") {
          UnregisterAllNativeHotKeys();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "setWindowTheme") {
          SetMainWindowDarkMode(get_bool("darkMode", true));
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "getKnownDesktopPath") {
          std::string desktop = GetKnownDesktopPathUtf8();
          if (!desktop.empty()) {
            result->Success(EncodableValue(desktop));
          } else {
            result->Success(EncodableValue());
          }
          return;
        }

        if (method == "setCloseToTray") {
          g_close_to_tray.store(get_bool("enabled", true));
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "setMainWindowVisible") {
          SetMainWindowVisible(get_bool("visible", true));
          result->Success(EncodableValue());
          return;
        }

        // Old synchronous listAudioInputDevices retained commented per policy:
        // if (method == "listAudioInputDevices") {
        //   result->Success(EncodableValue(EnumerateWindowsAudioInputDevices()));
        //   return;
        // }
        if (method == "listAudioInputDevices") {
          EncodableList cached = BuildAudioDeviceListFromCache();
          if (!cached.empty()) {
            if (!g_audio_refresh_in_flight.exchange(true)) {
              EnumerateWindowsAudioDevicesWorker(nullptr, false);
            }
            result->Success(EncodableValue(cached));
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          g_audio_refresh_in_flight.store(true);
          EnumerateWindowsAudioDevicesWorker(shared_res, false);
          return;
        }

        if (method == "setRecordingMicrophoneMuted") {
          bool muted = get_bool("muted", false);
          g_recorder.mic_muted.store(muted);
          RefreshRecordingHudWindow();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "captureFullScreen") {
          std::string target = get_str("targetPath");
          if (target.empty()) {
            result->Error("bad_args", "targetPath missing");
            return;
          }
          // Gene - Nov, 24, 2026: Prefer WM_HOTKEY precapture snapshot when available; otherwise use DXGI fast single-monitor capture with GDI fallback.
          // Old implementation:
          // RECT mon = GetCursorMonitorScreenRect();
          // int vx = static_cast<int>(mon.left);
          // int vy = static_cast<int>(mon.top);
          // int vw = static_cast<int>(mon.right - mon.left);
          // int vh = static_cast<int>(mon.bottom - mon.top);
          // std::vector<uint8_t> bgra;
          // if (vw > 0 && vh > 0 && CaptureScreenRectBgra(vx, vy, vw, vh, &bgra)) {
          HMONITOR hmon = nullptr;
          RECT mon = {};
          std::vector<uint8_t> bgra;
          bool captured = ConsumePrecaptureSingleMonitor(&hmon, &mon, &bgra);
          int vw = static_cast<int>(mon.right - mon.left);
          int vh = static_cast<int>(mon.bottom - mon.top);
          if (!captured) {
            POINT pt = {};
            if (!::GetCursorPos(&pt)) {
              pt.x = 0;
              pt.y = 0;
            }
            hmon = ::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
            MONITORINFO mi = {};
            mi.cbSize = sizeof(mi);
            if (hmon && ::GetMonitorInfoW(hmon, &mi)) {
              mon = mi.rcMonitor;
            } else {
              mon = GetCursorMonitorScreenRect();
            }
            vw = static_cast<int>(mon.right - mon.left);
            vh = static_cast<int>(mon.bottom - mon.top);
            captured =
                (vw > 0 && vh > 0 && CaptureSingleMonitorFast(hmon, mon, &bgra));
          }
          if (captured && vw > 0 && vh > 0 && !bgra.empty()) {
            std::shared_ptr<CaptureMethodResult> shared_res(result.release());
            std::wstring target_w = Utf8ToWide(target);
            std::thread([pixels = std::move(bgra), vw, vh, target, target_w,
                         shared_res]() mutable {
              HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
              bool did_init = (co_hr == S_OK || co_hr == S_FALSE);
              bool ok = SaveBgraToPngFile(pixels.data(), vw, vh, vw * 4,
                                          target_w);
              if (did_init) {
                ::CoUninitialize();
              }
              PostToPlatformThread([shared_res, ok, target]() {
                if (!shared_res) return;
                if (ok) {
                  shared_res->Success(EncodableValue(target));
                } else {
                  shared_res->Success(EncodableValue());
                }
              });
            }).detach();
          } else {
            result->Success(EncodableValue());
          }
          return;
        }

        if (method == "captureInteractive") {
          std::string target = get_str("targetPath");
          std::string initial_mode = get_str("initialMode");
          if (initial_mode.empty()) initial_mode = "capture";
          if (target.empty()) {
            result->Error("bad_args", "targetPath missing");
            return;
          }
          int initial_fps = static_cast<int>(get_double("initialFps", 60.0));
          bool initial_mic = get_bool("initialRecordMic", false);
          std::string initial_mic_id = get_str("initialMicDeviceId");
          bool initial_sys = get_bool("initialRecordSystemAudio", true);
          bool initial_cursor = get_bool("initialRecordCursor", true);
          bool initial_clicks = get_bool("initialHighlightClicks", true);

          StartWin32InteractiveOverlay(
              Utf8ToWide(target), initial_mode, initial_fps, initial_mic,
              initial_mic_id, initial_sys, initial_cursor, initial_clicks,
              std::move(result));
          return;
        }

        // Gene - Nov, 24, 2026: Use DXGI fast capture and offload PNG encoding off the Win32 platform thread in captureRect.
        // Old implementation:
        // if (method == "captureRect") {
        //   int rx = static_cast<int>(std::round(get_double("x")));
        //   int ry = static_cast<int>(std::round(get_double("y")));
        //   int rw = static_cast<int>(std::round(get_double("width")));
        //   int rh = static_cast<int>(std::round(get_double("height")));
        //   std::vector<uint8_t> bgra;
        //   std::vector<uint8_t> png;
        //   if (CaptureScreenRectBgra(rx, ry, rw, rh, &bgra) &&
        //       EncodeBgraToPngBytes(bgra.data(), rw, rh, rw * 4, &png)) {
        //     result->Success(EncodableValue(png));
        //   } else {
        //     result->Success(EncodableValue());
        //   }
        //   return;
        // }
        if (method == "captureRect") {
          int rx = static_cast<int>(std::round(get_double("x")));
          int ry = static_cast<int>(std::round(get_double("y")));
          int rw = static_cast<int>(std::round(get_double("width")));
          int rh = static_cast<int>(std::round(get_double("height")));
          std::vector<uint8_t> bgra;
          if (rw > 0 && rh > 0 &&
              CaptureRectFast(rx, ry, rw, rh, false, false, nullptr, &bgra)) {
            std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
            std::thread(
                [pixels = std::move(bgra), rw, rh, shared_res]() mutable {
                  HRESULT co_hr =
                      ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
                  bool did_init = (co_hr == S_OK || co_hr == S_FALSE);
                  std::vector<uint8_t> png;
                  bool ok = EncodeBgraToPngBytes(pixels.data(), rw, rh, rw * 4,
                                                 &png);
                  if (did_init) ::CoUninitialize();
                  PostToPlatformThread(
                      [shared_res, ok, png = std::move(png)]() mutable {
                        if (!shared_res) return;
                        if (ok && !png.empty()) {
                          shared_res->Success(EncodableValue(png));
                        } else {
                          shared_res->Success(EncodableValue());
                        }
                      });
                })
                .detach();
          } else {
            result->Success(EncodableValue());
          }
          return;
        }

        // Gene - Nov, 20, 2026: Native Windows scrolling capture session MethodChannel commands backed by Rust snipsnap_core.
        if (method == "startScrollingCapture") {
          std::string target = get_str("targetPath");
          if (target.empty()) {
            result->Error("bad_args", "targetPath missing");
            return;
          }
          ScrollingCaptureConfig cfg;
          cfg.x = static_cast<int>(std::llround(get_double("x")));
          cfg.y = static_cast<int>(std::llround(get_double("y")));
          cfg.width = static_cast<int>(std::llround(get_double("width")));
          cfg.height = static_cast<int>(std::llround(get_double("height")));
          cfg.max_dimension =
              static_cast<int>(get_int64("maxDimension", 16000));
          cfg.axis_mode = static_cast<int>(get_int64("axisMode", 0));
          cfg.target_path = Utf8ToWide(target);
          cfg.target_path_utf8 = target;

          SetMainWindowVisible(false);
          if (g_scrolling_engine) {
            g_scrolling_engine->Cancel();
            g_scrolling_engine.reset();
          }
          g_scrolling_engine = std::make_unique<ScrollingCaptureEngine>();

          ScrollingCaptureCallbacks cbs;
          cbs.save_png = [](const uint8_t* bgra, int w, int h, int stride,
                            const std::wstring& path) -> bool {
            return SaveBgraToPngFile(bgra, w, h, stride, path);
          };
          cbs.on_progress = [](int width, int height, int frame_count, int axis,
                               int status, bool paused, bool auto_scrolling,
                               const std::string& warning) {
            PostToPlatformThread([width, height, frame_count, axis, status,
                                  paused, auto_scrolling, warning]() {
              EncodableMap m;
              m[EncodableValue("width")] = EncodableValue(width);
              m[EncodableValue("height")] = EncodableValue(height);
              m[EncodableValue("frameCount")] = EncodableValue(frame_count);
              m[EncodableValue("axis")] = EncodableValue(axis);
              m[EncodableValue("status")] = EncodableValue(status);
              m[EncodableValue("isPaused")] = EncodableValue(paused);
              m[EncodableValue("isAutoScrolling")] =
                  EncodableValue(auto_scrolling);
              if (!warning.empty()) {
                m[EncodableValue("warning")] = EncodableValue(warning);
              }
              InvokeDartMethod("onScrollingProgress", EncodableValue(m));
            });
          };
          cbs.on_completed = [](const std::string& path, int width, int height,
                                int frame_count, int axis, bool truncated) {
            PostToPlatformThread(
                [path, width, height, frame_count, axis, truncated]() {
                  SetMainWindowVisible(true);
                  EncodableMap m;
                  m[EncodableValue("path")] = EncodableValue(path);
                  m[EncodableValue("width")] = EncodableValue(width);
                  m[EncodableValue("height")] = EncodableValue(height);
                  m[EncodableValue("frameCount")] = EncodableValue(frame_count);
                  m[EncodableValue("axis")] = EncodableValue(axis);
                  m[EncodableValue("truncated")] = EncodableValue(truncated);
                  InvokeDartMethod("onScrollingCompleted", EncodableValue(m));
                });
          };
          cbs.on_cancel = []() {
            PostToPlatformThread([]() {
              SetMainWindowVisible(true);
              InvokeDartMethod("onScrollingCancel", EncodableValue());
            });
          };
          cbs.on_error = [](const std::string& message) {
            PostToPlatformThread([message]() {
              SetMainWindowVisible(true);
              EncodableMap m;
              m[EncodableValue("message")] = EncodableValue(message);
              InvokeDartMethod("onScrollingError", EncodableValue(m));
            });
          };

          bool started = g_scrolling_engine->Start(cfg, cbs);
          if (!started) {
            g_scrolling_engine.reset();
            SetMainWindowVisible(true);
          }
          result->Success(EncodableValue(started));
          return;
        }

        if (method == "setScrollingAutoMode") {
          if (g_scrolling_engine) {
            g_scrolling_engine->SetAutoScroll(get_bool("enabled", false));
          }
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "pauseScrollingCapture") {
          if (g_scrolling_engine) g_scrolling_engine->Pause();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "resumeScrollingCapture") {
          if (g_scrolling_engine) g_scrolling_engine->Resume();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "finishScrollingCapture") {
          if (g_scrolling_engine) g_scrolling_engine->Finish();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "cancelScrollingCapture") {
          if (g_scrolling_engine) g_scrolling_engine->Cancel();
          result->Success(EncodableValue(true));
          return;
        }

        // Gene - Nov, 20, 2026: Worker-thread WIC PNG/JPEG encoders for RGBA pixel buffers edited via Rust FFI.
        if (method == "saveRgbaToPng") {
          std::string target = get_str("targetPath");
          int w = static_cast<int>(get_int64("width", 0));
          int h = static_cast<int>(get_int64("height", 0));
          std::vector<uint8_t> rgba;
          if (args) {
            auto it = args->find(EncodableValue("bytes"));
            if (it != args->end()) {
              if (const auto* vec = std::get_if<std::vector<uint8_t>>(&it->second)) {
                rgba = *vec;
              }
            }
          }
          if (target.empty() || w <= 0 || h <= 0 ||
              rgba.size() < static_cast<size_t>(w) * h * 4) {
            result->Success(EncodableValue(false));
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(result.release());
          std::wstring target_w = Utf8ToWide(target);
          std::thread([pixels = std::move(rgba), w, h, target_w,
                       shared_res]() mutable {
            // Convert RGBA -> BGRA in-place before passing to WIC BGRA PNG encoder.
            const size_t total = static_cast<size_t>(w) * h * 4;
            for (size_t i = 0; i < total; i += 4) {
              std::swap(pixels[i], pixels[i + 2]);
            }
            HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_init = SUCCEEDED(co_hr);
            bool ok = SaveBgraToPngFile(pixels.data(), w, h, w * 4, target_w);
            if (did_init) ::CoUninitialize();
            PostToPlatformThread([shared_res, ok]() {
              if (shared_res) shared_res->Success(EncodableValue(ok));
            });
          }).detach();
          return;
        }

        if (method == "encodeRgbaToJpg") {
          int w = static_cast<int>(get_int64("width", 0));
          int h = static_cast<int>(get_int64("height", 0));
          int quality = std::clamp(static_cast<int>(get_int64("quality", 90)), 10, 100);
          std::vector<uint8_t> rgba;
          if (args) {
            auto it = args->find(EncodableValue("bytes"));
            if (it != args->end()) {
              if (const auto* vec = std::get_if<std::vector<uint8_t>>(&it->second)) {
                rgba = *vec;
              }
            }
          }
          if (w <= 0 || h <= 0 || rgba.size() < static_cast<size_t>(w) * h * 4) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(result.release());
          std::thread([pixels = std::move(rgba), w, h, quality,
                       shared_res]() mutable {
            HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_init = SUCCEEDED(co_hr);
            std::vector<uint8_t> out_jpg;
            do {
              ComPtr<IWICImagingFactory> factory;
              if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                            CLSCTX_INPROC_SERVER,
                                            IID_PPV_ARGS(&factory)))) {
                break;
              }
              ComPtr<IStream> stream;
              if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream))) break;
              ComPtr<IWICBitmapEncoder> encoder;
              if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg,
                                                nullptr, &encoder))) {
                break;
              }
              if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
                break;
              }
              ComPtr<IWICBitmapFrameEncode> frame;
              ComPtr<IPropertyBag2> props;
              if (FAILED(encoder->CreateNewFrame(&frame, &props))) break;
              if (props) {
                PROPBAG2 opt = {};
                opt.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
                VARIANT val;
                ::VariantInit(&val);
                val.vt = VT_R4;
                val.fltVal = static_cast<float>(quality) / 100.0f;
                props->Write(1, &opt, &val);
              }
              if (FAILED(frame->Initialize(props.Get()))) break;
              if (FAILED(frame->SetSize(static_cast<UINT>(w), static_cast<UINT>(h)))) {
                break;
              }
              WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
              if (FAILED(frame->SetPixelFormat(&fmt))) break;

              // Gene - Nov, 22, 2026: Alpha-composite semi-transparent/erased pixels onto white before 24bpp JPEG encoding, guard UINT size overflow, and trim trailing GlobalSize slack via STATSTG.
              // Old implementation:
              // const size_t px_count = static_cast<size_t>(w) * h;
              // std::vector<uint8_t> bgr(px_count * 3);
              // for (size_t i = 0; i < px_count; ++i) {
              //   bgr[i * 3 + 0] = pixels[i * 4 + 2];
              //   bgr[i * 3 + 1] = pixels[i * 4 + 1];
              //   bgr[i * 3 + 2] = pixels[i * 4 + 0];
              // }
              // UINT stride24 = static_cast<UINT>(w * 3);
              // if (FAILED(frame->WritePixels(static_cast<UINT>(h), stride24,
              //                               static_cast<UINT>(bgr.size()),
              //                               bgr.data()))) {
              //   break;
              // }
              // if (FAILED(frame->Commit())) break;
              // if (FAILED(encoder->Commit())) break;
              //
              // HGLOBAL hglobal = nullptr;
              // if (FAILED(::GetHGlobalFromStream(stream.Get(), &hglobal)) ||
              //     !hglobal) {
              //   break;
              // }
              // SIZE_T sz = ::GlobalSize(hglobal);
              // void* ptr = ::GlobalLock(hglobal);
              // if (ptr && sz > 0) {
              //   out_jpg.assign(static_cast<const uint8_t*>(ptr),
              //                  static_cast<const uint8_t*>(ptr) + sz);
              // }
              // if (ptr) ::GlobalUnlock(hglobal);
              const size_t px_count = static_cast<size_t>(w) * h;
              if (static_cast<size_t>(w) > UINT_MAX / 3 ||
                  px_count > UINT_MAX / 3) {
                break;
              }
              std::vector<uint8_t> bgr(px_count * 3);
              for (size_t i = 0; i < px_count; ++i) {
                uint8_t r = pixels[i * 4 + 0];
                uint8_t g = pixels[i * 4 + 1];
                uint8_t b = pixels[i * 4 + 2];
                uint8_t a = pixels[i * 4 + 3];
                if (a == 255) {
                  bgr[i * 3 + 0] = b;
                  bgr[i * 3 + 1] = g;
                  bgr[i * 3 + 2] = r;
                } else if (a == 0) {
                  bgr[i * 3 + 0] = 255;
                  bgr[i * 3 + 1] = 255;
                  bgr[i * 3 + 2] = 255;
                } else {
                  const int inv = 255 - static_cast<int>(a);
                  bgr[i * 3 + 0] = static_cast<uint8_t>(
                      (static_cast<int>(b) * a + 255 * inv + 127) / 255);
                  bgr[i * 3 + 1] = static_cast<uint8_t>(
                      (static_cast<int>(g) * a + 255 * inv + 127) / 255);
                  bgr[i * 3 + 2] = static_cast<uint8_t>(
                      (static_cast<int>(r) * a + 255 * inv + 127) / 255);
                }
              }
              UINT stride24 = static_cast<UINT>(w * 3);
              if (FAILED(frame->WritePixels(static_cast<UINT>(h), stride24,
                                            static_cast<UINT>(bgr.size()),
                                            bgr.data()))) {
                break;
              }
              if (FAILED(frame->Commit())) break;
              if (FAILED(encoder->Commit())) break;

              HGLOBAL hglobal = nullptr;
              if (FAILED(::GetHGlobalFromStream(stream.Get(), &hglobal)) ||
                  !hglobal) {
                break;
              }
              SIZE_T alloc_sz = ::GlobalSize(hglobal);
              SIZE_T sz = alloc_sz;
              STATSTG stat = {};
              if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) &&
                  stat.cbSize.QuadPart > 0) {
                sz = static_cast<SIZE_T>(
                    std::min<ULONGLONG>(stat.cbSize.QuadPart, alloc_sz));
              }
              void* ptr = ::GlobalLock(hglobal);
              if (ptr && sz > 0) {
                out_jpg.assign(static_cast<const uint8_t*>(ptr),
                               static_cast<const uint8_t*>(ptr) + sz);
              }
              if (ptr) ::GlobalUnlock(hglobal);
            } while (false);

            if (did_init) ::CoUninitialize();
            PostToPlatformThread([shared_res, out_jpg = std::move(out_jpg)]() mutable {
              if (!shared_res) return;
              if (!out_jpg.empty()) {
                shared_res->Success(EncodableValue(out_jpg));
              } else {
                shared_res->Success(EncodableValue());
              }
            });
          }).detach();
          return;
        }

        // Gene - Nov, 24, 2026: Offload clipboard encode/decode and file reads off the Win32 UI thread.
        // Old implementation:
        // if (method == "copyImageToClipboard") { ... CopyPngBytesToWin32Clipboard(...); ... }
        // if (method == "pasteImageFromClipboard") { ... PasteWin32ClipboardToPngFile(...); ... }
        if (method == "copyImageToClipboard") {
          std::vector<uint8_t> png_bytes;
          bool has_bytes = false;
          if (args) {
            auto bytes_it = args->find(EncodableValue("bytes"));
            if (bytes_it != args->end()) {
              if (const auto* bytes =
                      std::get_if<std::vector<uint8_t>>(&bytes_it->second)) {
                png_bytes = *bytes;
                has_bytes = true;
              }
            }
          }
          std::string file_path = has_bytes ? "" : get_str("filePath");
          if (!has_bytes && file_path.empty()) {
            result->Success(EncodableValue(false));
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          std::thread([has_bytes, png_bytes = std::move(png_bytes), file_path,
                       shared_res]() mutable {
            HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_init = (co_hr == S_OK || co_hr == S_FALSE);
            bool ok = false;
            if (has_bytes) {
              ok = CopyPngBytesToWin32Clipboard(png_bytes.data(),
                                                png_bytes.size());
            } else {
              HANDLE f = ::CreateFileW(Utf8ToWide(file_path).c_str(),
                                       GENERIC_READ, FILE_SHARE_READ, nullptr,
                                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                                       nullptr);
              if (f != INVALID_HANDLE_VALUE) {
                DWORD sz = ::GetFileSize(f, nullptr);
                if (sz > 0 && sz != INVALID_FILE_SIZE) {
                  std::vector<uint8_t> buf(sz);
                  DWORD rd = 0;
                  BOOL read_ok = ::ReadFile(f, buf.data(), sz, &rd, nullptr);
                  ::CloseHandle(f);
                  if (read_ok && rd > 0) {
                    ok = CopyPngBytesToWin32Clipboard(buf.data(), rd);
                  }
                } else {
                  ::CloseHandle(f);
                }
              }
            }
            if (did_init) ::CoUninitialize();
            PostToPlatformThread([shared_res, ok]() {
              if (shared_res) shared_res->Success(EncodableValue(ok));
            });
          }).detach();
          return;
        }

        if (method == "pasteImageFromClipboard") {
          std::string target = get_str("targetPath");
          if (target.empty()) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          std::thread([target, shared_res]() {
            HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_init = (co_hr == S_OK || co_hr == S_FALSE);
            bool ok = PasteWin32ClipboardToPngFile(Utf8ToWide(target));
            if (did_init) ::CoUninitialize();
            PostToPlatformThread([shared_res, ok, target]() {
              if (!shared_res) return;
              if (ok) {
                shared_res->Success(EncodableValue(target));
              } else {
                shared_res->Success(EncodableValue());
              }
            });
          }).detach();
          return;
        }

        if (method == "copyFileToClipboard") {
          std::string file_path = get_str("filePath");
          bool ok = CopyFileToWin32Clipboard(Utf8ToWide(file_path));
          result->Success(EncodableValue(ok));
          return;
        }

        if (method == "startScreenRecording") {
          std::string target = get_str("targetPath");
          std::string thumb = get_str("thumbnailPath");
          bool full_screen = get_bool("fullScreen", false);
          // Gene - Nov, 13, 2026: Respect passed monitor rect or cursor's active monitor when starting full-screen recording on Windows.
          // Old implementation:
          // int rx = full_screen ? ::GetSystemMetrics(SM_XVIRTUALSCREEN)
          //                      : static_cast<int>(std::round(get_double("x")));
          // int ry = full_screen ? ::GetSystemMetrics(SM_YVIRTUALSCREEN)
          //                      : static_cast<int>(std::round(get_double("y")));
          // int rw = full_screen
          //              ? ::GetSystemMetrics(SM_CXVIRTUALSCREEN)
          //              : static_cast<int>(std::round(get_double("width")));
          // int rh = full_screen
          //              ? ::GetSystemMetrics(SM_CYVIRTUALSCREEN)
          //              : static_cast<int>(std::round(get_double("height")));
          int arg_x = static_cast<int>(std::round(get_double("x")));
          int arg_y = static_cast<int>(std::round(get_double("y")));
          int arg_w = static_cast<int>(std::round(get_double("width")));
          int arg_h = static_cast<int>(std::round(get_double("height")));
          int rx = arg_x;
          int ry = arg_y;
          int rw = arg_w;
          int rh = arg_h;
          if (full_screen && (arg_w < 10 || arg_h < 10)) {
            POINT cursor_pt{};
            MONITORINFO mi{};
            mi.cbSize = sizeof(mi);
            if (::GetCursorPos(&cursor_pt) &&
                ::GetMonitorInfoW(
                    ::MonitorFromPoint(cursor_pt, MONITOR_DEFAULTTONEAREST),
                    &mi)) {
              rx = mi.rcMonitor.left;
              ry = mi.rcMonitor.top;
              rw = mi.rcMonitor.right - mi.rcMonitor.left;
              rh = mi.rcMonitor.bottom - mi.rcMonitor.top;
            } else {
              rx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
              ry = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
              rw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
              rh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
            }
          }
          // Gene - Nov, 13, 2026: Default 60 FPS and forward mic device, system audio, cursor, click highlights, and countdown.
          // Old implementation:
          // int fps = static_cast<int>(get_double("fps", 30.0));
          // bool record_audio = get_bool("recordAudio", false);
          // bool ok = StartWinRecordingSession(Utf8ToWide(target),
          //                                    Utf8ToWide(thumb), rx, ry, rw, rh,
          //                                    fps, record_audio);
          int fps = static_cast<int>(get_double("fps", 60.0));
          bool record_audio = get_bool("recordAudio", false);
          std::string mic_id = get_str("microphoneDeviceId");
          bool record_sys_audio = get_bool("recordSystemAudio", true);
          bool record_cursor = get_bool("recordCursor", true);
          bool highlight_clicks = get_bool("highlightClicks", true);
          int countdown_seconds =
              static_cast<int>(get_double("countdownSeconds", 0.0));

          bool ok = StartWinRecordingSession(
              Utf8ToWide(target), Utf8ToWide(thumb), rx, ry, rw, rh, fps,
              record_audio, mic_id, record_sys_audio, record_cursor,
              highlight_clicks, countdown_seconds);
          result->Success(EncodableValue(ok));
          return;
        }

        if (method == "pauseScreenRecording") {
          g_recorder.paused.store(true);
          RefreshRecordingHudWindow();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "resumeScreenRecording") {
          g_recorder.paused.store(false);
          RefreshRecordingHudWindow();
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "stopScreenRecording") {
          StopWinRecordingSession(false, std::move(result));
          return;
        }

        // Gene - Nov, 24, 2026: Support restoreWindow flag in cancelScreenRecording and offload extractVideoFrame off the UI thread.
        // Old implementation:
        // if (method == "cancelScreenRecording") {
        //   StopWinRecordingSession(true, std::move(result));
        //   return;
        // }
        // if (method == "extractVideoFrame") { ... ExtractVideoFrameAtMs(...); ... }
        if (method == "cancelScreenRecording") {
          bool restore_window = get_bool("restoreWindow", true);
          StopWinRecordingSession(true, std::move(result), restore_window);
          return;
        }

        if (method == "extractVideoFrame") {
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t ts_ms = get_int64("timestampMs", 0);
          if (video_path.empty() || target_path.empty()) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          std::thread([video_path, target_path, ts_ms, shared_res]() {
            HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_init = (co_hr == S_OK || co_hr == S_FALSE);
            bool ok = ExtractVideoFrameAtMs(Utf8ToWide(video_path), ts_ms,
                                            Utf8ToWide(target_path));
            if (did_init) ::CoUninitialize();
            PostToPlatformThread([shared_res, ok, target_path]() {
              if (!shared_res) return;
              if (ok) {
                shared_res->Success(EncodableValue(target_path));
              } else {
                shared_res->Success(EncodableValue());
              }
            });
          }).detach();
          return;
        }

        if (method == "trimVideo") {
          // Gene - Nov, 13, 2026: Replaced CopyFileW placeholder with real Media Foundation segment transcoder, offloaded onto background thread with explicit COM/MF initialization.
          // Old implementation:
          // std::string video_path = get_str("videoPath");
          // std::string target_path = get_str("targetPath");
          // int64_t start_ms = std::max<int64_t>(0, get_int64("startMs", 0));
          // int64_t end_ms = get_int64("endMs", 0);
          // if (end_ms <= start_ms) {
          //   end_ms = QueryVideoDurationMs(Utf8ToWide(video_path));
          // }
          // int64_t out_dur = 0;
          // if (!video_path.empty() && !target_path.empty() &&
          //     end_ms > start_ms &&
          //     TranscodeVideoSegments(Utf8ToWide(video_path),
          //                            Utf8ToWide(target_path),
          //                            {{start_ms, end_ms}}, &out_dur)) {
          //   result->Success(EncodableValue(target_path));
          // } else {
          //   result->Success(EncodableValue());
          // }
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t start_ms = std::max<int64_t>(0, get_int64("startMs", 0));
          int64_t end_ms = get_int64("endMs", 0);
          if (video_path.empty() || target_path.empty()) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          std::thread([shared_res, video_path, target_path, start_ms,
                       end_ms]() {
            HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_com = (com_hr == S_OK || com_hr == S_FALSE);
            ::MFStartup(MF_VERSION);
            std::wstring wide_src = Utf8ToWide(video_path);
            int64_t eff_end = end_ms;
            if (eff_end <= start_ms) {
              eff_end = QueryVideoDurationMs(wide_src);
            }
            int64_t out_dur = 0;
            bool ok = (eff_end > start_ms) &&
                      TranscodeVideoSegments(wide_src, Utf8ToWide(target_path),
                                             {{start_ms, eff_end}}, &out_dur);
            ::MFShutdown();
            if (did_com) ::CoUninitialize();
            PostToPlatformThread([shared_res, ok, target_path]() {
              if (!shared_res) return;
              if (ok) {
                shared_res->Success(EncodableValue(target_path));
              } else {
                shared_res->Success(EncodableValue());
              }
            });
          }).detach();
          return;
        }

        // Gene - Nov, 13, 2026: Added cutVideo and native PixelBufferTexture video player handlers.
        if (method == "cutVideo") {
          // Gene - Nov, 13, 2026: Offload cutVideo transcoding to background thread with explicit COM/MF init so UI thread never freezes.
          // Old implementation:
          // std::string video_path = get_str("videoPath");
          // std::string target_path = get_str("targetPath");
          // int64_t cut_start = std::max<int64_t>(0, get_int64("cutStartMs", 0));
          // int64_t cut_end = std::max<int64_t>(cut_start, get_int64("cutEndMs", 0));
          // std::wstring wide_src = Utf8ToWide(video_path);
          // int64_t total_ms = QueryVideoDurationMs(wide_src);
          // std::vector<std::pair<int64_t, int64_t>> keep_segments;
          // if (cut_start > 50) {
          //   keep_segments.push_back({0, cut_start});
          // }
          // if (total_ms > cut_end + 50) {
          //   keep_segments.push_back({cut_end, total_ms});
          // }
          // int64_t out_dur = 0;
          // if (!video_path.empty() && !target_path.empty() &&
          //     !keep_segments.empty() &&
          //     TranscodeVideoSegments(wide_src, Utf8ToWide(target_path),
          //                            keep_segments, &out_dur)) {
          //   EncodableMap res;
          //   res[EncodableValue("filePath")] = EncodableValue(target_path);
          //   res[EncodableValue("durationMs")] = EncodableValue(out_dur);
          //   result->Success(EncodableValue(res));
          // } else {
          //   result->Success(EncodableValue());
          // }
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t cut_start = std::max<int64_t>(0, get_int64("cutStartMs", 0));
          int64_t cut_end = std::max<int64_t>(cut_start, get_int64("cutEndMs", 0));
          if (video_path.empty() || target_path.empty()) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          std::thread([shared_res, video_path, target_path, cut_start,
                       cut_end]() {
            HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            bool did_com = (com_hr == S_OK || com_hr == S_FALSE);
            ::MFStartup(MF_VERSION);
            std::wstring wide_src = Utf8ToWide(video_path);
            int64_t total_ms = QueryVideoDurationMs(wide_src);
            std::vector<std::pair<int64_t, int64_t>> keep_segments;
            if (cut_start > 50) {
              keep_segments.push_back({0, cut_start});
            }
            if (total_ms > cut_end + 50) {
              keep_segments.push_back({cut_end, total_ms});
            }
            int64_t out_dur = 0;
            bool ok = !keep_segments.empty() &&
                      TranscodeVideoSegments(wide_src, Utf8ToWide(target_path),
                                             keep_segments, &out_dur);
            ::MFShutdown();
            if (did_com) ::CoUninitialize();
            PostToPlatformThread([shared_res, ok, target_path, out_dur]() {
              if (!shared_res) return;
              if (ok) {
                EncodableMap res;
                res[EncodableValue("filePath")] = EncodableValue(target_path);
                res[EncodableValue("durationMs")] = EncodableValue(out_dur);
                shared_res->Success(EncodableValue(res));
              } else {
                shared_res->Success(EncodableValue());
              }
            });
          }).detach();
          return;
        }

        // Gene - Nov, 13, 2026: Added native WIC + Media Foundation animated GIF export offloaded to worker thread.
        if (method == "exportVideoAsGif") {
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t start_ms = std::max<int64_t>(0, get_int64("startMs", 0));
          int64_t end_ms = get_int64("endMs", 0);
          int fps = static_cast<int>(
              std::clamp<int64_t>(get_int64("fps", 15), 5, 30));
          int max_width = static_cast<int>(
              std::max<int64_t>(160, get_int64("maxWidth", 720)));
          if (video_path.empty() || target_path.empty()) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          std::thread([shared_res, video_path, target_path, start_ms, end_ms,
                       fps, max_width]() {
            bool ok = ExportVideoAsGifWic(
                Utf8ToWide(video_path), Utf8ToWide(target_path), start_ms,
                end_ms, fps, max_width);
            PostToPlatformThread([shared_res, ok, target_path]() {
              if (!shared_res) return;
              if (ok) {
                shared_res->Success(EncodableValue(target_path));
              } else {
                shared_res->Success(EncodableValue());
              }
            });
          }).detach();
          return;
        }

        // Gene - Nov, 24, 2026: Asynchronous createVideoPlayer/disposeVideoPlayer and explicit releaseVideoPlayersForPath before deleting video files on Windows.
        // Old implementation:
        // if (method == "createVideoPlayer") {
        //   auto player = WinVideoTexturePlayer::Create(Utf8ToWide(video_path), tex_reg);
        //   ...
        // }
        if (method == "createVideoPlayer") {
          std::string video_path = get_str("videoPath");
          auto cur_gate = Gate();
          flutter::TextureRegistrar* tex_reg =
              cur_gate ? cur_gate->texture_registrar : nullptr;
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          WinVideoTexturePlayer::CreateAsync(
              Utf8ToWide(video_path), tex_reg,
              [shared_res](std::shared_ptr<WinVideoTexturePlayer> player) {
                if (!shared_res) return;
                if (!player || player->texture_id < 0) {
                  shared_res->Success(EncodableValue());
                  return;
                }
                {
                  std::lock_guard<std::mutex> lock(g_players_mutex);
                  g_video_players[player->texture_id] = player;
                }
                EncodableMap info;
                info[EncodableValue("textureId")] =
                    EncodableValue(player->texture_id);
                info[EncodableValue("durationMs")] =
                    EncodableValue(player->duration_ms);
                info[EncodableValue("width")] = EncodableValue(player->width);
                info[EncodableValue("height")] = EncodableValue(player->height);
                info[EncodableValue("hasAudio")] =
                    EncodableValue(player->has_audio);
                shared_res->Success(EncodableValue(info));
              });
          return;
        }

        if (method == "playVideo") {
          int64_t tid = get_int64("textureId", -1);
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) player = it->second;
          }
          if (player) player->Play();
          result->Success(EncodableValue());
          return;
        }

        if (method == "pauseVideo") {
          int64_t tid = get_int64("textureId", -1);
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) player = it->second;
          }
          if (player) player->Pause();
          result->Success(EncodableValue());
          return;
        }

        if (method == "seekVideo") {
          int64_t tid = get_int64("textureId", -1);
          int64_t pos_ms = get_int64("positionMs", 0);
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) player = it->second;
          }
          if (player) player->Seek(pos_ms);
          result->Success(EncodableValue());
          return;
        }

        if (method == "setVideoVolume") {
          int64_t tid = get_int64("textureId", -1);
          float vol = static_cast<float>(get_double("volume", 1.0));
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) player = it->second;
          }
          if (player) player->SetVolume(vol);
          result->Success(EncodableValue());
          return;
        }

        if (method == "setVideoMuted") {
          int64_t tid = get_int64("textureId", -1);
          bool m = get_bool("muted", false);
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) player = it->second;
          }
          if (player) player->SetMuted(m);
          result->Success(EncodableValue());
          return;
        }

        if (method == "setVideoSpeed") {
          int64_t tid = get_int64("textureId", -1);
          float spd = static_cast<float>(get_double("speed", 1.0));
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) player = it->second;
          }
          if (player) player->SetSpeed(spd);
          result->Success(EncodableValue());
          return;
        }

        // Old implementation:
        // if (method == "disposeVideoPlayer") {
        //   ...
        //   if (player) player->Dispose();
        //   result->Success(EncodableValue());
        //   return;
        // }
        if (method == "disposeVideoPlayer") {
          int64_t tid = get_int64("textureId", -1);
          std::shared_ptr<WinVideoTexturePlayer> player;
          {
            std::lock_guard<std::mutex> lock(g_players_mutex);
            auto it = g_video_players.find(tid);
            if (it != g_video_players.end()) {
              player = it->second;
              g_video_players.erase(it);
            }
          }
          if (!player) {
            result->Success(EncodableValue());
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          player->DisposeAsync([shared_res]() {
            PostToPlatformThread([shared_res]() {
              if (shared_res) shared_res->Success(EncodableValue());
            });
          });
          return;
        }

        if (method == "releaseVideoPlayersForPath") {
          std::string file_path = get_str("filePath");
          if (file_path.empty()) {
            result->Success(EncodableValue(false));
            return;
          }
          std::shared_ptr<CaptureMethodResult> shared_res(std::move(result));
          ReleaseVideoPlayersForPath(Utf8ToWide(file_path), [shared_res]() {
            if (shared_res) shared_res->Success(EncodableValue(true));
          });
          return;
        }

        result->NotImplemented();
      });
}

// Gene - Nov, 13, 2026: Dispose active video texture players, HUD window, and registrar pointers on shutdown.
// Old implementation:
// void ShutdownCaptureHandler() {
//   CloseInteractiveOverlay();
//   if (g_recorder.active.load()) {
//     g_recorder.cancelled.store(true);
//     g_recorder.active.store(false);
//     if (g_recorder.worker.joinable()) {
//       g_recorder.worker.join();
//     }
//   }
//   auto gate = Gate();
//   if (!gate) return;
//   std::lock_guard<std::mutex> lock(gate->mutex);
//   gate->engine = nullptr;
//   gate->channel.reset();
// }
// Gene - Nov, 24, 2026: Handle native Win32 hotkeys, tray menu/restore, close-to-tray SC_CLOSE, shutdown notifications, and single-instance reactivation; clean up hotkeys, tray icon, and DXGI cache in ShutdownCaptureHandler.
// Old implementation:
// void ShutdownCaptureHandler() {
//   ...
//   auto gate = Gate();
//   if (!gate) return;
//   std::lock_guard<std::mutex> lock(gate->mutex);
//   gate->engine = nullptr;
//   gate->registrar = nullptr;
//   gate->texture_registrar = nullptr;
//   gate->channel.reset();
// }
bool HandleCaptureWindowMessage(HWND hwnd, UINT message, WPARAM wparam,
                                LPARAM lparam, LRESULT* out_result) {
  if (g_show_window_msg != 0 && message == g_show_window_msg) {
    SetMainWindowVisible(true);
    if (out_result) *out_result = 0;
    return true;
  }

  switch (message) {
    case WM_HOTKEY: {
      std::string action;
      {
        std::lock_guard<std::mutex> lock(g_hotkey_mutex);
        auto it = g_native_hotkeys.find(static_cast<int>(wparam));
        if (it != g_native_hotkeys.end()) {
          action = it->second.action;
        }
      }
      if (!action.empty()) {
        if (!g_overlay_active.load() && !g_recorder.active.load()) {
          CapturePrecaptureForAction(action);
        }
        EncodableMap args;
        args[EncodableValue("action")] = EncodableValue(action);
        InvokeDartMethod("onGlobalHotKey", EncodableValue(args));
        if (out_result) *out_result = 0;
        return true;
      }
      break;
    }

    case WM_SYSCOMMAND: {
      if ((wparam & 0xFFF0) == SC_CLOSE && g_close_to_tray.load() &&
          !g_force_quit.load() && g_tray_registered) {
        ::ShowWindow(hwnd, SW_HIDE);
        if (out_result) *out_result = 0;
        return true;
      }
      break;
    }

    case WM_QUERYENDSESSION:
    case WM_ENDSESSION:
      g_force_quit.store(true);
      break;

    case WM_CLOSE:
      RemoveTrayIcon();
      break;

    case kMsgTrayIcon: {
      UINT tray_ev = LOWORD(lparam);
      if (tray_ev == WM_LBUTTONUP || tray_ev == WM_LBUTTONDBLCLK) {
        SetMainWindowVisible(true);
      } else if (tray_ev == WM_RBUTTONUP || tray_ev == WM_CONTEXTMENU) {
        ShowTrayContextMenu(hwnd);
      }
      if (out_result) *out_result = 0;
      return true;
    }

    default:
      break;
  }
  return false;
}

void ShutdownCaptureHandler() {
  DestroyAllVideoPlayers();
  CloseInteractiveOverlay();
  // Gene - Nov, 20, 2026: Tear down active Windows scrolling capture engine before engine destruction.
  if (g_scrolling_engine) {
    g_scrolling_engine->Cancel();
    g_scrolling_engine.reset();
  }
  if (g_recorder.active.load() || g_recorder.stopping.load()) {
    g_recorder.cancelled.store(true);
    g_recorder.active.store(false);
    g_recorder.countdown_remaining.store(0);
  }
  {
    std::lock_guard<std::mutex> lock(g_recorder.join_mutex);
    if (g_recorder.worker.joinable()) {
      g_recorder.worker.join();
    }
    CloseRecordingHudWindow();
  }
  UnregisterAllNativeHotKeys();
  RemoveTrayIcon();
  ResetDxgiCapture();
  g_main_hwnd = nullptr;

  auto gate = Gate();
  if (!gate) return;
  std::lock_guard<std::mutex> lock(gate->mutex);
  gate->engine = nullptr;
  gate->registrar = nullptr;
  gate->texture_registrar = nullptr;
  gate->channel.reset();
}
