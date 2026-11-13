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
#include <windowsx.h>
#include <shlobj.h>
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
#include <atomic>
#include <chrono>
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

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
using CaptureMethodResult = flutter::MethodResult<EncodableValue>;

constexpr char kChannelName[] = "snipsnap/capture";

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

HWND FindMainAppHwnd() {
  auto gate = Gate();
  if (gate) {
    std::lock_guard<std::mutex> lock(gate->mutex);
    if (gate->registrar && gate->registrar->GetView()) {
      HWND view_hwnd = gate->registrar->GetView()->GetNativeWindow();
      if (view_hwnd) {
        HWND root = ::GetAncestor(view_hwnd, GA_ROOT);
        return root ? root : view_hwnd;
      }
    }
  }
  return ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
}

void SetMainWindowVisible(bool visible) {
  HWND hwnd = FindMainAppHwnd();
  if (!hwnd || !::IsWindow(hwnd)) return;
  if (visible) {
    ::ShowWindow(hwnd, SW_SHOW);
    if (::IsIconic(hwnd)) {
      ::ShowWindow(hwnd, SW_RESTORE);
    }
    ::SetForegroundWindow(hwnd);
  } else {
    ::ShowWindow(hwnd, SW_HIDE);
  }
}

EncodableList EnumerateWindowsAudioInputDevices() {
  EncodableList list;
  HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  bool did_init = (com_hr == S_OK || com_hr == S_FALSE);

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
    if (SUCCEEDED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                                 &collection)) &&
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

        EncodableMap item;
        item[EncodableValue("id")] = EncodableValue(WideToUtf8(dev_id));
        item[EncodableValue("name")] = EncodableValue(WideToUtf8(friendly_name));
        item[EncodableValue("isDefault")] =
            EncodableValue(!default_id.empty() && dev_id == default_id);
        list.push_back(EncodableValue(item));
      }
    }
  }

  if (did_init) {
    ::CoUninitialize();
  }
  return list;
}

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

  UINT buffer_size = static_cast<UINT>(stride * height);
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

  SIZE_T size = ::GlobalSize(hglobal);
  void* ptr = ::GlobalLock(hglobal);
  if (!ptr || size == 0) return false;

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

bool CaptureScreenRectBgra(int x, int y, int width, int height,
                           std::vector<uint8_t>* out_bgra) {
  if (width <= 0 || height <= 0 || !out_bgra) return false;

  HDC screen_dc = ::GetDC(nullptr);
  if (!screen_dc) return false;

  HDC mem_dc = ::CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ::ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // Top-down DIB
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib =
      ::CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) ::DeleteObject(dib);
    ::DeleteDC(mem_dc);
    ::ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old_obj = ::SelectObject(mem_dc, dib);
  BOOL blt_ok =
      ::BitBlt(mem_dc, 0, 0, width, height, screen_dc, x, y, SRCCOPY);

  size_t byte_count = static_cast<size_t>(width) * height * 4;
  if (blt_ok) {
    out_bgra->resize(byte_count);
    std::memcpy(out_bgra->data(), bits, byte_count);
    // Ensure alpha channel is 0xFF for opaque desktop pixels
    uint8_t* p = out_bgra->data();
    for (size_t i = 3; i < byte_count; i += 4) {
      p[i] = 0xFF;
    }
  }

  ::SelectObject(mem_dc, old_obj);
  ::DeleteObject(dib);
  ::DeleteDC(mem_dc);
  ::ReleaseDC(nullptr, screen_dc);
  return blt_ok == TRUE;
}

// ---------------------------------------------------------------------------
// Native Win32 Clipboard (Zero PowerShell)
// ---------------------------------------------------------------------------

bool CopyPngBytesToWin32Clipboard(const uint8_t* png_bytes, size_t png_size) {
  std::vector<uint8_t> bgra;
  int width = 0, height = 0;
  if (!DecodeImageBytesToBgra(png_bytes, png_size, &bgra, &width, &height)) {
    return false;
  }

  if (!::OpenClipboard(nullptr)) return false;
  ::EmptyClipboard();

  // 1. Register and set "PNG" clipboard format for modern apps
  UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (png_format != 0) {
    HGLOBAL hpng = ::GlobalAlloc(GMEM_MOVEABLE, png_size);
    if (hpng) {
      void* ptr = ::GlobalLock(hpng);
      if (ptr) {
        std::memcpy(ptr, png_bytes, png_size);
        ::GlobalUnlock(hpng);
        ::SetClipboardData(png_format, hpng);
      } else {
        ::GlobalFree(hpng);
      }
    }
  }

  // 2. Also set standard CF_DIB (bottom-up 32bpp) for universal Win32 compatibility
  size_t pixel_bytes = static_cast<size_t>(width) * height * 4;
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
      for (int row = 0; row < height; ++row) {
        const uint8_t* src_row = bgra.data() + (height - 1 - row) * stride;
        std::memcpy(dst_pixels + row * stride, src_row, stride);
      }
      ::GlobalUnlock(hdib);
      ::SetClipboardData(CF_DIB, hdib);
    } else {
      ::GlobalFree(hdib);
    }
  }

  ::CloseClipboard();
  return true;
}

bool PasteWin32ClipboardToPngFile(const std::wstring& target_path) {
  if (!::OpenClipboard(nullptr)) return false;

  UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && ::IsClipboardFormatAvailable(png_format)) {
    HANDLE hdata = ::GetClipboardData(png_format);
    if (hdata) {
      SIZE_T size = ::GlobalSize(hdata);
      const uint8_t* ptr = static_cast<const uint8_t*>(::GlobalLock(hdata));
      if (ptr && size > 0) {
        std::vector<uint8_t> bgra;
        int w = 0, h = 0;
        bool ok = DecodeImageBytesToBgra(ptr, size, &bgra, &w, &h) &&
                  SaveBgraToPngFile(bgra.data(), w, h, w * 4, target_path);
        ::GlobalUnlock(hdata);
        ::CloseClipboard();
        if (ok) return true;
      } else {
        if (ptr) ::GlobalUnlock(hdata);
      }
    }
  }

  if (::IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE hdib = ::GetClipboardData(CF_DIB);
    if (hdib) {
      const BITMAPINFO* bmi = static_cast<const BITMAPINFO*>(::GlobalLock(hdib));
      if (bmi) {
        int w = bmi->bmiHeader.biWidth;
        int h = std::abs(bmi->bmiHeader.biHeight);
        bool top_down = bmi->bmiHeader.biHeight < 0;
        int bpp = bmi->bmiHeader.biBitCount;
        if (w > 0 && h > 0 && (bpp == 32 || bpp == 24)) {
          const uint8_t* src = reinterpret_cast<const uint8_t*>(bmi) +
                               bmi->bmiHeader.biSize;
          if (bmi->bmiHeader.biCompression == BI_BITFIELDS) {
            src += 12;
          }
          std::vector<uint8_t> bgra(static_cast<size_t>(w) * h * 4);
          int src_stride = ((w * bpp + 31) / 32) * 4;
          for (int y = 0; y < h; ++y) {
            int sy = top_down ? y : (h - 1 - y);
            const uint8_t* srow = src + sy * src_stride;
            uint8_t* drow = bgra.data() + y * w * 4;
            for (int x = 0; x < w; ++x) {
              drow[x * 4 + 0] = srow[x * (bpp / 8) + 0];
              drow[x * 4 + 1] = srow[x * (bpp / 8) + 1];
              drow[x * 4 + 2] = srow[x * (bpp / 8) + 2];
              drow[x * 4 + 3] = (bpp == 32) ? srow[x * 4 + 3] : 0xFF;
            }
          }
          ::GlobalUnlock(hdib);
          ::CloseClipboard();
          return SaveBgraToPngFile(bgra.data(), w, h, w * 4, target_path);
        }
        ::GlobalUnlock(hdib);
      }
    }
  }

  ::CloseClipboard();
  return false;
}

bool CopyFileToWin32Clipboard(const std::wstring& file_path) {
  if (file_path.empty()) return false;
  if (!::OpenClipboard(nullptr)) return false;
  ::EmptyClipboard();

  size_t path_bytes = (file_path.size() + 2) * sizeof(wchar_t);
  size_t total_bytes = sizeof(DROPFILES) + path_bytes;
  HGLOBAL hdrop = ::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, total_bytes);
  if (!hdrop) {
    ::CloseClipboard();
    return false;
  }

  uint8_t* ptr = static_cast<uint8_t*>(::GlobalLock(hdrop));
  if (!ptr) {
    ::GlobalFree(hdrop);
    ::CloseClipboard();
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
  ::CloseClipboard();
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

// Old InteractiveOverlayState + StartWin32InteractiveOverlay implementation (retained commented per policy):
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
//   int selected_fps = 60;
//   bool record_mic = false;
//   std::string mic_device_id;
//   bool record_sys_audio = true;
//   bool record_cursor = true;
//   bool highlight_clicks = true;
//   bool is_full_screen_preset = false;
//   enum class Mode { kIdle, kDrawing, kAdjusting, kMoving, kResizing };
//   Mode mode = Mode::kIdle;
//   bool has_selection = false;
//   RECT sel = {0, 0, 0, 0};
//   POINT drag_start = {0, 0};
//   RECT sel_at_start = {0, 0, 0, 0};
//   int active_grip = -1;
//   RECT capture_btn = {0, 0, 0, 0};
//   RECT record_btn = {0, 0, 0, 0};
//   RECT cancel_btn = {0, 0, 0, 0};
//   RECT preset_full_btn = {0, 0, 0, 0};
//   RECT preset_1080_btn = {0, 0, 0, 0};
//   RECT preset_720_btn = {0, 0, 0, 0};
//   RECT fps_btn = {0, 0, 0, 0};
//   RECT mic_btn = {0, 0, 0, 0};
//   RECT sys_audio_btn = {0, 0, 0, 0};
//   RECT cursor_btn = {0, 0, 0, 0};
//   RECT mode_snip_btn = {0, 0, 0, 0};
//   bool settled = false;
// };
struct InteractiveOverlayState {
  HWND hwnd = nullptr;
  int virt_x = 0;
  int virt_y = 0;
  int virt_w = 0;
  int virt_h = 0;
  HBITMAP screen_bitmap = nullptr;
  uint8_t* screen_bits = nullptr;
  HBITMAP dim_bitmap = nullptr;
  HDC backbuf_dc = nullptr;
  HBITMAP backbuf_bitmap = nullptr;
  HGDIOBJ backbuf_old_bmp = nullptr;
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
  RECT sel = {0, 0, 0, 0};
  POINT drag_start = {0, 0};
  RECT sel_at_start = {0, 0, 0, 0};
  int active_grip = -1;  // 0..7 corners/edges

  RECT capture_btn = {0, 0, 0, 0};
  RECT record_btn = {0, 0, 0, 0};
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
  bool settled = false;
};

InteractiveOverlayState g_overlay;

RECT ScreenRectToOverlayRect(const RECT& sr) {
  return RECT{sr.left - g_overlay.virt_x, sr.top - g_overlay.virt_y,
              sr.right - g_overlay.virt_x, sr.bottom - g_overlay.virt_y};
}

RECT GetCurrentReferenceMonitorOverlayRect() {
  POINT screen_pt = {};
  if (g_overlay.has_selection &&
      g_overlay.sel.right > g_overlay.sel.left &&
      g_overlay.sel.bottom > g_overlay.sel.top) {
    screen_pt.x =
        g_overlay.virt_x +
        static_cast<int>((g_overlay.sel.left + g_overlay.sel.right) / 2);
    screen_pt.y =
        g_overlay.virt_y +
        static_cast<int>((g_overlay.sel.top + g_overlay.sel.bottom) / 2);
  } else if (!::GetCursorPos(&screen_pt)) {
    screen_pt.x = g_overlay.virt_x + g_overlay.virt_w / 2;
    screen_pt.y = g_overlay.virt_y + g_overlay.virt_h / 2;
  }
  return ScreenRectToOverlayRect(GetMonitorRectForScreenPoint(screen_pt));
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

int HitTestOverlayGrip(const RECT& s, POINT pt) {
  if ((s.right - s.left) < 12 || (s.bottom - s.top) < 12) return -1;
  POINT pts[8];
  ComputeOverlayGripPoints(s, pts);
  constexpr LONG kHitHalf = 7;
  for (int i = 0; i < 8; ++i) {
    RECT r = {pts[i].x - kHitHalf, pts[i].y - kHitHalf,
              pts[i].x + kHitHalf, pts[i].y + kHitHalf};
    if (::PtInRect(&r, pt)) return i;
  }
  return -1;
}

void ClearOverlayButtonRects() {
  g_overlay.capture_btn = {0, 0, 0, 0};
  g_overlay.record_btn = {0, 0, 0, 0};
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

void CloseInteractiveOverlay() {
  if (g_overlay.hwnd) {
    ::DestroyWindow(g_overlay.hwnd);
    g_overlay.hwnd = nullptr;
  }
  if (g_overlay.backbuf_dc) {
    if (g_overlay.backbuf_old_bmp) {
      ::SelectObject(g_overlay.backbuf_dc, g_overlay.backbuf_old_bmp);
      g_overlay.backbuf_old_bmp = nullptr;
    }
    ::DeleteDC(g_overlay.backbuf_dc);
    g_overlay.backbuf_dc = nullptr;
  }
  if (g_overlay.backbuf_bitmap) {
    ::DeleteObject(g_overlay.backbuf_bitmap);
    g_overlay.backbuf_bitmap = nullptr;
  }
  if (g_overlay.dim_bitmap) {
    ::DeleteObject(g_overlay.dim_bitmap);
    g_overlay.dim_bitmap = nullptr;
  }
  if (g_overlay.screen_bitmap) {
    ::DeleteObject(g_overlay.screen_bitmap);
    g_overlay.screen_bitmap = nullptr;
  }
  g_overlay.screen_bits = nullptr;
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

void SettleOverlayCapture(RECT r) {
  if (!g_overlay.screen_bits) {
    FinishOverlayCancelled();
    return;
  }
  int rx = std::clamp(static_cast<int>(r.left), 0, g_overlay.virt_w);
  int ry = std::clamp(static_cast<int>(r.top), 0, g_overlay.virt_h);
  int rw = std::clamp(static_cast<int>(r.right - r.left), 0,
                      g_overlay.virt_w - rx);
  int rh = std::clamp(static_cast<int>(r.bottom - r.top), 0,
                      g_overlay.virt_h - ry);
  if (rw <= 0 || rh <= 0) {
    FinishOverlayCancelled();
    return;
  }

  std::vector<uint8_t> cropped(static_cast<size_t>(rw) * rh * 4);
  size_t src_stride = static_cast<size_t>(g_overlay.virt_w) * 4;
  size_t dst_stride = static_cast<size_t>(rw) * 4;
  for (int row = 0; row < rh; ++row) {
    const uint8_t* s = g_overlay.screen_bits +
                       static_cast<size_t>(ry + row) * src_stride +
                       static_cast<size_t>(rx) * 4;
    uint8_t* d = cropped.data() + static_cast<size_t>(row) * dst_stride;
    std::memcpy(d, s, dst_stride);
  }
  for (size_t i = 3; i < cropped.size(); i += 4) {
    cropped[i] = 0xFF;
  }

  if (SaveBgraToPngFile(cropped.data(), rw, rh, static_cast<int>(dst_stride),
                        g_overlay.target_path)) {
    FinishOverlayWithString(WideToUtf8(g_overlay.target_path));
  } else {
    FinishOverlayCancelled();
  }
}

void SettleOverlayRecord(RECT r, bool full_screen_flag) {
  int rx = g_overlay.virt_x +
           std::clamp(static_cast<int>(r.left), 0, g_overlay.virt_w);
  int ry = g_overlay.virt_y +
           std::clamp(static_cast<int>(r.top), 0, g_overlay.virt_h);
  int rw =
      std::clamp(static_cast<int>(r.right - r.left), 16, g_overlay.virt_w);
  int rh =
      std::clamp(static_cast<int>(r.bottom - r.top), 16, g_overlay.virt_h);
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

void ApplyOverlayPresetSize(int target_w, int target_h, bool full_screen) {
  RECT mon = GetCurrentReferenceMonitorOverlayRect();
  int mon_w = std::max(16, static_cast<int>(mon.right - mon.left));
  int mon_h = std::max(16, static_cast<int>(mon.bottom - mon.top));
  if (full_screen || target_w <= 0 || target_h <= 0) {
    g_overlay.sel = mon;
    g_overlay.is_full_screen_preset = true;
  } else {
    int rw = std::min(target_w, mon_w);
    int rh = std::min(target_h, mon_h);
    int left = static_cast<int>(mon.left) + std::max(0, (mon_w - rw) / 2);
    int top = static_cast<int>(mon.top) + std::max(0, (mon_h - rh) / 2);
    g_overlay.sel = {left, top, left + rw, top + rh};
    g_overlay.is_full_screen_preset = (rw == mon_w && rh == mon_h);
  }
  g_overlay.has_selection = true;
  g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
  g_overlay.active_grip = -1;
  if (g_overlay.hwnd) {
    ::InvalidateRect(g_overlay.hwnd, nullptr, FALSE);
  }
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
                     const std::wstring& label, COLORREF text_color) {
  HBRUSH br = ::CreateSolidBrush(fill);
  HPEN pen = ::CreatePen(PS_SOLID, 1, border);
  HGDIOBJ old_br = ::SelectObject(hdc, br);
  HGDIOBJ old_pen = ::SelectObject(hdc, pen);
  ::RoundRect(hdc, r.left, r.top, r.right, r.bottom, 10, 10);
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

// Gene - Nov, 13, 2026: Forward-declare PopulateOverlayMicDevices before OverlayWndProc to fix MSVC C3861 identifier not found error.
void PopulateOverlayMicDevices();

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                LPARAM lparam) {
  switch (msg) {
    case WM_ERASEBKGND:
      return 1;

    case WM_SETCURSOR: {
      if (LOWORD(lparam) == HTCLIENT) {
        POINT pt = {};
        ::GetCursorPos(&pt);
        ::ScreenToClient(hwnd, &pt);
        LPCWSTR cur = IDC_CROSS;
        auto in_btn = [&](const RECT& r) {
          return (r.right > r.left && r.bottom > r.top) && ::PtInRect(&r, pt);
        };
        if (in_btn(g_overlay.cancel_btn) || in_btn(g_overlay.capture_btn) ||
            in_btn(g_overlay.record_btn) || in_btn(g_overlay.preset_full_btn) ||
            in_btn(g_overlay.preset_1080_btn) ||
            in_btn(g_overlay.preset_720_btn) || in_btn(g_overlay.tb_full_btn) ||
            in_btn(g_overlay.tb_1080_btn) || in_btn(g_overlay.tb_720_btn) ||
            in_btn(g_overlay.fps_btn) || in_btn(g_overlay.mic_btn) ||
            in_btn(g_overlay.mic_cycle_btn) ||
            in_btn(g_overlay.sys_audio_btn) || in_btn(g_overlay.cursor_btn) ||
            in_btn(g_overlay.mode_snip_btn)) {
          cur = IDC_HAND;
        } else if (g_overlay.has_selection &&
                   (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
                    g_overlay.mode == InteractiveOverlayState::Mode::kResizing)) {
          int grip = (g_overlay.mode == InteractiveOverlayState::Mode::kResizing)
                         ? g_overlay.active_grip
                         : HitTestOverlayGrip(g_overlay.sel, pt);
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
        bool full = !g_overlay.has_selection || g_overlay.is_full_screen_preset;
        RECT target = g_overlay.has_selection
                          ? g_overlay.sel
                          : ScreenRectToOverlayRect(GetCursorMonitorScreenRect());
        if (g_overlay.initial_mode == "record") {
          SettleOverlayRecord(target, full);
        } else {
          SettleOverlayCapture(target);
        }
        return 0;
      }
      break;
    }

    case WM_RBUTTONDOWN:
      FinishOverlayCancelled();
      return 0;

    case WM_LBUTTONDOWN: {
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
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
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
          if (::PtInRect(&g_overlay.mic_btn, pt)) {
            g_overlay.record_mic = !g_overlay.record_mic;
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
          if (::PtInRect(&g_overlay.mic_cycle_btn, pt)) {
            CycleOverlayMicDevice();
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
          if (::PtInRect(&g_overlay.sys_audio_btn, pt)) {
            g_overlay.record_sys_audio = !g_overlay.record_sys_audio;
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
          if (::PtInRect(&g_overlay.cursor_btn, pt)) {
            g_overlay.record_cursor = !g_overlay.record_cursor;
            g_overlay.highlight_clicks = g_overlay.record_cursor;
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
          if (::PtInRect(&g_overlay.mode_snip_btn, pt)) {
            g_overlay.initial_mode = "capture";
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
          if (::PtInRect(&g_overlay.record_btn, pt)) {
            SettleOverlayRecord(g_overlay.sel, g_overlay.is_full_screen_preset);
            return 0;
          }
        } else {
          if (::PtInRect(&g_overlay.capture_btn, pt)) {
            SettleOverlayCapture(g_overlay.sel);
            return 0;
          }
          // Gene - Nov, 13, 2026: Clicking Video in capture mode switches in-place to Snagit Pre-Recording Toolbar on the current selection instead of starting recording immediately.
          // Old implementation:
          // if (::PtInRect(&g_overlay.record_btn, pt)) {
          //   SettleOverlayRecord(g_overlay.sel, false);
          //   return 0;
          // }
          if (::PtInRect(&g_overlay.record_btn, pt)) {
            if (g_overlay.mic_devices.empty()) {
              PopulateOverlayMicDevices();
            }
            g_overlay.initial_mode = "record";
            ::InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
          }
        }
        int grip = HitTestOverlayGrip(g_overlay.sel, pt);
        if (grip >= 0) {
          g_overlay.active_grip = grip;
          g_overlay.sel_at_start = g_overlay.sel;
          g_overlay.is_full_screen_preset = false;
          g_overlay.mode = InteractiveOverlayState::Mode::kResizing;
          ::SetCapture(hwnd);
          ::InvalidateRect(hwnd, nullptr, FALSE);
          return 0;
        }
        if (::PtInRect(&g_overlay.sel, pt)) {
          g_overlay.sel_at_start = g_overlay.sel;
          g_overlay.is_full_screen_preset = false;
          g_overlay.mode = InteractiveOverlayState::Mode::kMoving;
          ::SetCapture(hwnd);
          ::InvalidateRect(hwnd, nullptr, FALSE);
          return 0;
        }
      }
      g_overlay.active_grip = -1;
      g_overlay.is_full_screen_preset = false;
      g_overlay.sel = {pt.x, pt.y, pt.x, pt.y};
      g_overlay.has_selection = true;
      g_overlay.mode = InteractiveOverlayState::Mode::kDrawing;
      ::SetCapture(hwnd);
      ::InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    }

    case WM_MOUSEMOVE: {
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (g_overlay.mode == InteractiveOverlayState::Mode::kDrawing) {
        g_overlay.sel.left =
            std::clamp(std::min(g_overlay.drag_start.x, pt.x), 0L,
                       static_cast<LONG>(g_overlay.virt_w));
        g_overlay.sel.top =
            std::clamp(std::min(g_overlay.drag_start.y, pt.y), 0L,
                       static_cast<LONG>(g_overlay.virt_h));
        g_overlay.sel.right =
            std::clamp(std::max(g_overlay.drag_start.x, pt.x), 0L,
                       static_cast<LONG>(g_overlay.virt_w));
        g_overlay.sel.bottom =
            std::clamp(std::max(g_overlay.drag_start.y, pt.y), 0L,
                       static_cast<LONG>(g_overlay.virt_h));
        ::InvalidateRect(hwnd, nullptr, FALSE);
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
        LONG max_w = static_cast<LONG>(g_overlay.virt_w);
        LONG max_h = static_cast<LONG>(g_overlay.virt_h);
        LONG nl = std::clamp(std::min(r.left, r.right), 0L, max_w);
        LONG nr = std::clamp(std::max(r.left, r.right), 0L, max_w);
        LONG nt = std::clamp(std::min(r.top, r.bottom), 0L, max_h);
        LONG nb = std::clamp(std::max(r.top, r.bottom), 0L, max_h);
        if (nr - nl < 4) nr = std::min(max_w, nl + 4);
        if (nb - nt < 4) nb = std::min(max_h, nt + 4);
        g_overlay.sel = {nl, nt, nr, nb};
        ::InvalidateRect(hwnd, nullptr, FALSE);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving) {
        int dx = pt.x - g_overlay.drag_start.x;
        int dy = pt.y - g_overlay.drag_start.y;
        RECT r = g_overlay.sel_at_start;
        int w = static_cast<int>(r.right - r.left);
        int h = static_cast<int>(r.bottom - r.top);
        int nl = std::clamp(static_cast<int>(r.left) + dx, 0,
                            std::max(0, g_overlay.virt_w - w));
        int nt = std::clamp(static_cast<int>(r.top) + dy, 0,
                            std::max(0, g_overlay.virt_h - h));
        g_overlay.sel = {nl, nt, nl + w, nt + h};
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      ::ReleaseCapture();
      if (g_overlay.mode == InteractiveOverlayState::Mode::kDrawing) {
        int w = static_cast<int>(g_overlay.sel.right - g_overlay.sel.left);
        int h = static_cast<int>(g_overlay.sel.bottom - g_overlay.sel.top);
        if (w < 8 || h < 8) {
          POINT screen_pt = {
              g_overlay.virt_x + g_overlay.drag_start.x,
              g_overlay.virt_y + g_overlay.drag_start.y,
          };
          RECT mon = ScreenRectToOverlayRect(
              GetMonitorRectForScreenPoint(screen_pt));
          // Gene - Nov, 13, 2026: Settle full-monitor selection on click without drag in both capture and record modes so the [Capture] / [Video] selector appears.
          // Old implementation:
          // if (g_overlay.initial_mode == "record") {
          //   g_overlay.sel = mon;
          //   g_overlay.has_selection = true;
          //   g_overlay.is_full_screen_preset = true;
          //   g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
          //   ::InvalidateRect(hwnd, nullptr, FALSE);
          // } else {
          //   SettleOverlayCapture(mon);
          // }
          g_overlay.sel = mon;
          g_overlay.has_selection = true;
          g_overlay.is_full_screen_preset = true;
          g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
          ::InvalidateRect(hwnd, nullptr, FALSE);
          return 0;
        }
        g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
        ::InvalidateRect(hwnd, nullptr, FALSE);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving ||
                 g_overlay.mode == InteractiveOverlayState::Mode::kResizing) {
        g_overlay.active_grip = -1;
        g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = ::BeginPaint(hwnd, &ps);
      ClearOverlayButtonRects();

      HDC mem_dc = g_overlay.backbuf_dc;
      HBITMAP temp_bmp = nullptr;
      HGDIOBJ temp_old = nullptr;
      if (!mem_dc) {
        mem_dc = ::CreateCompatibleDC(hdc);
        temp_bmp =
            ::CreateCompatibleBitmap(hdc, g_overlay.virt_w, g_overlay.virt_h);
        temp_old = ::SelectObject(mem_dc, temp_bmp);
      }

      // Blit pre-darkened desktop background in one SRCCOPY pass.
      if (g_overlay.dim_bitmap) {
        HDC dim_dc = ::CreateCompatibleDC(hdc);
        HGDIOBJ old_dim = ::SelectObject(dim_dc, g_overlay.dim_bitmap);
        ::BitBlt(mem_dc, 0, 0, g_overlay.virt_w, g_overlay.virt_h, dim_dc, 0, 0,
                 SRCCOPY);
        ::SelectObject(dim_dc, old_dim);
        ::DeleteDC(dim_dc);
      } else if (g_overlay.screen_bitmap) {
        HDC scr_dc = ::CreateCompatibleDC(hdc);
        HGDIOBJ old_scr = ::SelectObject(scr_dc, g_overlay.screen_bitmap);
        ::BitBlt(mem_dc, 0, 0, g_overlay.virt_w, g_overlay.virt_h, scr_dc, 0, 0,
                 SRCCOPY);
        ::SelectObject(scr_dc, old_scr);
        ::DeleteDC(scr_dc);
      }

      // Punch bright un-dimmed selection area straight from screen_bitmap.
      int sl = 0;
      int st = 0;
      int sr = 0;
      int sb = 0;
      if (g_overlay.has_selection) {
        sl = std::clamp(static_cast<int>(g_overlay.sel.left), 0,
                        g_overlay.virt_w);
        st = std::clamp(static_cast<int>(g_overlay.sel.top), 0,
                        g_overlay.virt_h);
        sr = std::clamp(static_cast<int>(g_overlay.sel.right), 0,
                        g_overlay.virt_w);
        sb = std::clamp(static_cast<int>(g_overlay.sel.bottom), 0,
                        g_overlay.virt_h);
        if (sr > sl && sb > st && g_overlay.screen_bitmap) {
          HDC scr_dc = ::CreateCompatibleDC(hdc);
          HGDIOBJ old_scr = ::SelectObject(scr_dc, g_overlay.screen_bitmap);
          ::BitBlt(mem_dc, sl, st, sr - sl, sb - st, scr_dc, sl, st, SRCCOPY);
          ::SelectObject(scr_dc, old_scr);
          ::DeleteDC(scr_dc);
        }
      }

      RECT cur_mon = GetCurrentReferenceMonitorOverlayRect();
      int cur_mon_l = static_cast<int>(cur_mon.left);
      int cur_mon_r = static_cast<int>(cur_mon.right);
      int cur_mon_b = static_cast<int>(cur_mon.bottom);
      int cur_mon_w = std::max(1, cur_mon_r - cur_mon_l);
      // Gene - Nov, 13, 2026: Track monitor height to detect full-monitor selection accurately.
      int cur_mon_h = std::max(1, static_cast<int>(cur_mon.bottom - cur_mon.top));

      if (!g_overlay.has_selection && g_overlay.initial_mode == "record") {
        int btn_h = 34;
        int w_full = 104;
        int w_1080 = 96;
        int w_720 = 92;
        int w_can = 76;
        int gap = 8;
        int total_w = w_full + w_1080 + w_720 + w_can + gap * 3;
        int bx = cur_mon_l + std::max(12, (cur_mon_w - total_w) / 2);
        int by = std::max(12, cur_mon_b - btn_h - 48);

        g_overlay.preset_full_btn = {bx, by, bx + w_full, by + btn_h};
        int x2 = bx + w_full + gap;
        g_overlay.preset_1080_btn = {x2, by, x2 + w_1080, by + btn_h};
        int x3 = x2 + w_1080 + gap;
        g_overlay.preset_720_btn = {x3, by, x3 + w_720, by + btn_h};
        int x4 = x3 + w_720 + gap;
        g_overlay.cancel_btn = {x4, by, x4 + w_can, by + btn_h};

        DrawRoundedPill(mem_dc, g_overlay.preset_full_btn, RGB(34, 30, 28),
                        RGB(140, 118, 102), L"Full Screen",
                        RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_overlay.preset_1080_btn, RGB(34, 30, 28),
                        RGB(140, 118, 102), L"1920x1080", RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_overlay.preset_720_btn, RGB(34, 30, 28),
                        RGB(140, 118, 102), L"1280x720", RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(50, 32, 32),
                        RGB(185, 70, 70), L"Cancel", RGB(255, 220, 220));
      }

      if (g_overlay.has_selection && sr > sl && sb > st) {
        HPEN pen = ::CreatePen(PS_SOLID, 2, RGB(215, 65, 55));
        HGDIOBJ old_pen = ::SelectObject(mem_dc, pen);
        HGDIOBJ old_brush =
            ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
        ::Rectangle(mem_dc, sl, st, sr, sb);
        ::SelectObject(mem_dc, old_brush);
        ::SelectObject(mem_dc, old_pen);
        ::DeleteObject(pen);

        if (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
            g_overlay.mode == InteractiveOverlayState::Mode::kResizing) {
          if ((sr - sl) >= 16 && (sb - st) >= 16) {
            POINT pts[8];
            ComputeOverlayGripPoints(RECT{sl, st, sr, sb}, pts);
            HBRUSH grip_fill = ::CreateSolidBrush(RGB(255, 255, 255));
            HPEN grip_pen = ::CreatePen(PS_SOLID, 1, RGB(215, 65, 55));
            HGDIOBJ old_gf = ::SelectObject(mem_dc, grip_fill);
            HGDIOBJ old_gp = ::SelectObject(mem_dc, grip_pen);
            for (int i = 0; i < 8; ++i) {
              ::Rectangle(mem_dc, pts[i].x - 4, pts[i].y - 4, pts[i].x + 5,
                          pts[i].y + 5);
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
        int badge_w = std::max(108, static_cast<int>(dim_str.size()) * 8 + 20);
        int badge_x = std::clamp(sl, 8, std::max(8, g_overlay.virt_w - badge_w - 8));
        int badge_y = (st >= 36) ? (st - 28) : (st + 8);
        RECT dim_badge = {badge_x, badge_y, badge_x + badge_w, badge_y + 22};
        DrawRoundedPill(mem_dc, dim_badge, RGB(28, 22, 18), RGB(111, 78, 55),
                        dim_str, RGB(255, 255, 255));

        if (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
            g_overlay.mode == InteractiveOverlayState::Mode::kMoving ||
            g_overlay.mode == InteractiveOverlayState::Mode::kResizing) {
          // Gene - Nov, 13, 2026: Reset stale button rects on mode switch and center controls cleanly above taskbar when full-monitor selected.
          bool is_full_mon = g_overlay.is_full_screen_preset ||
                             ((sr - sl) >= cur_mon_w - 8 &&
                              (sb - st) >= cur_mon_h - 8);
          if (g_overlay.initial_mode == "record") {
            g_overlay.capture_btn = {0, 0, 0, 0};
            bool has_multi_mic = g_overlay.mic_devices.size() > 1;
            int btn_h = 34;
            int w_full = 44;
            int w_1080 = 52;
            int w_720 = 46;
            int w_fps = 58;
            int w_mic = 68;
            int w_mic_cyc = has_multi_mic ? 24 : 0;
            int w_sys = 76;
            int w_cur = 82;
            int w_snip = 48;
            int w_rec = 64;
            int w_can = 30;
            int gap = 5;
            int total_w = w_full + w_1080 + w_720 + w_fps + w_mic +
                          (has_multi_mic ? (w_mic_cyc + 2) : 0) + w_sys +
                          w_cur + w_snip + w_rec + w_can + gap * 9;
            int min_bx = std::max(8, cur_mon_l + 8);
            int max_bx =
                std::max(min_bx, std::min(g_overlay.virt_w, cur_mon_r) -
                                     total_w - 8);
            int bx = std::clamp((sl + sr - total_w) / 2, min_bx, max_bx);
            // Old implementation:
            // int by = sb + 10;
            // if (by + btn_h > std::min(g_overlay.virt_h, cur_mon_b) - 10) {
            //   by = std::max(10, sb - btn_h - 14);
            // }
            int by = is_full_mon
                         ? std::max(12,
                                    std::min(g_overlay.virt_h, cur_mon_b) -
                                        btn_h - 68)
                         : (sb + 10);
            if (!is_full_mon &&
                by + btn_h > std::min(g_overlay.virt_h, cur_mon_b) - 10) {
              by = std::max(10, sb - btn_h - 14);
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

            DrawRoundedPill(
                mem_dc, g_overlay.tb_full_btn,
                g_overlay.is_full_screen_preset ? RGB(111, 78, 55)
                                                : RGB(38, 32, 28),
                RGB(120, 100, 86), L"Full", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.tb_1080_btn, RGB(38, 32, 28),
                            RGB(120, 100, 86), L"1080p", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.tb_720_btn, RGB(38, 32, 28),
                            RGB(120, 100, 86), L"720p", RGB(255, 255, 255));
            DrawRoundedPill(
                mem_dc, g_overlay.fps_btn, RGB(38, 32, 28), RGB(120, 100, 86),
                g_overlay.selected_fps == 60 ? L"60fps" : L"30fps",
                RGB(255, 255, 255));
            DrawRoundedPill(
                mem_dc, g_overlay.mic_btn,
                g_overlay.record_mic ? RGB(46, 105, 62) : RGB(38, 32, 28),
                RGB(120, 100, 86),
                g_overlay.record_mic ? L"Mic On" : L"Mic Off",
                RGB(255, 255, 255));
            if (has_multi_mic) {
              DrawRoundedPill(mem_dc, g_overlay.mic_cycle_btn, RGB(48, 40, 35),
                              RGB(120, 100, 86), L"v", RGB(255, 255, 255));
            }
            DrawRoundedPill(
                mem_dc, g_overlay.sys_audio_btn,
                g_overlay.record_sys_audio ? RGB(46, 105, 62)
                                           : RGB(38, 32, 28),
                RGB(120, 100, 86),
                g_overlay.record_sys_audio ? L"Sys On" : L"Sys Off",
                RGB(255, 255, 255));
            DrawRoundedPill(
                mem_dc, g_overlay.cursor_btn,
                g_overlay.record_cursor ? RGB(46, 105, 62) : RGB(38, 32, 28),
                RGB(120, 100, 86),
                g_overlay.record_cursor ? L"Cur On" : L"Cur Off",
                RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.mode_snip_btn, RGB(58, 46, 38),
                            RGB(130, 105, 88), L"Snip", RGB(240, 232, 224));
            DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(205, 42, 42),
                            RGB(240, 90, 90), L"Rec", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                            RGB(110, 90, 78), L"X", RGB(255, 255, 255));
          } else {
            g_overlay.tb_full_btn = {0, 0, 0, 0};
            g_overlay.tb_1080_btn = {0, 0, 0, 0};
            g_overlay.tb_720_btn = {0, 0, 0, 0};
            g_overlay.fps_btn = {0, 0, 0, 0};
            g_overlay.mic_btn = {0, 0, 0, 0};
            g_overlay.mic_cycle_btn = {0, 0, 0, 0};
            g_overlay.sys_audio_btn = {0, 0, 0, 0};
            g_overlay.cursor_btn = {0, 0, 0, 0};
            g_overlay.mode_snip_btn = {0, 0, 0, 0};
            int btn_h = 30;
            int cap_w = 88;
            int rec_w = 88;
            int can_w = 32;
            int gap = 6;
            int total_w = cap_w + gap + rec_w + gap + can_w;
            int min_bx = std::max(8, cur_mon_l + 8);
            int max_bx =
                std::max(min_bx, std::min(g_overlay.virt_w, cur_mon_r) -
                                     total_w - 8);
            // Gene - Nov, 13, 2026: Center [Capture] [Video] [X] above taskbar when full monitor selected, and relabel Record to Video.
            // Old implementation:
            // int bx = std::clamp(sr - total_w, min_bx, max_bx);
            // int by = sb + 8;
            // if (by + btn_h > std::min(g_overlay.virt_h, cur_mon_b) - 8) {
            //   by = std::max(8, st - btn_h - 8);
            // }
            int bx;
            int by;
            if (is_full_mon) {
              bx = std::clamp(cur_mon_l + (cur_mon_w - total_w) / 2, min_bx,
                              max_bx);
              by = std::max(
                  12, std::min(g_overlay.virt_h, cur_mon_b) - btn_h - 68);
            } else {
              bx = std::clamp(sr - total_w, min_bx, max_bx);
              by = sb + 8;
              if (by + btn_h > std::min(g_overlay.virt_h, cur_mon_b) - 8) {
                by = std::max(8, st - btn_h - 8);
              }
            }

            if (is_full_mon) {
              RECT tray = {bx - 10, by - 6, bx + total_w + 10, by + btn_h + 6};
              DrawRoundedPill(mem_dc, tray, RGB(24, 18, 14), RGB(110, 90, 78),
                              L"", RGB(255, 255, 255));
            }

            g_overlay.capture_btn = {bx, by, bx + cap_w, by + btn_h};
            g_overlay.record_btn = {bx + cap_w + gap, by,
                                    bx + cap_w + gap + rec_w, by + btn_h};
            g_overlay.cancel_btn = {bx + cap_w + gap + rec_w + gap, by,
                                    bx + total_w, by + btn_h};

            DrawRoundedPill(mem_dc, g_overlay.capture_btn, RGB(111, 78, 55),
                            RGB(160, 122, 92), L"Capture", RGB(255, 255, 255));
            // Old implementation:
            // DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(185, 45, 45),
            //                 RGB(230, 85, 85), L"Record", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(185, 45, 45),
                            RGB(230, 85, 85), L"Video", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                            RGB(110, 90, 78), L"X", RGB(255, 255, 255));
          }
        }
      }

      ::BitBlt(hdc, 0, 0, g_overlay.virt_w, g_overlay.virt_h, mem_dc, 0, 0,
               SRCCOPY);
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

void PopulateOverlayMicDevices() {
  g_overlay.mic_devices.clear();
  EncodableList list = EnumerateWindowsAudioInputDevices();
  for (const auto& entry : list) {
    const auto* m = std::get_if<EncodableMap>(&entry);
    if (!m) continue;
    std::string id;
    std::string name;
    auto it_id = m->find(EncodableValue("id"));
    if (it_id != m->end()) {
      if (const auto* s = std::get_if<std::string>(&it_id->second)) id = *s;
    }
    auto it_name = m->find(EncodableValue("name"));
    if (it_name != m->end()) {
      if (const auto* s = std::get_if<std::string>(&it_name->second)) name = *s;
    }
    if (!id.empty()) {
      g_overlay.mic_devices.emplace_back(id, name.empty() ? id : name);
    }
  }
}

void StartWin32InteractiveOverlay(
    const std::wstring& target_path, const std::string& initial_mode,
    int initial_fps, bool initial_record_mic,
    const std::string& initial_mic_id, bool initial_sys_audio,
    bool initial_cursor, bool initial_clicks,
    std::unique_ptr<CaptureMethodResult> result) {
  CloseInteractiveOverlay();
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

  g_overlay.virt_x = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  g_overlay.virt_y = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  g_overlay.virt_w = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  g_overlay.virt_h = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (g_overlay.virt_w <= 0 || g_overlay.virt_h <= 0) {
    FinishOverlayCancelled();
    return;
  }

  HDC screen_dc = ::GetDC(nullptr);
  if (!screen_dc) {
    FinishOverlayCancelled();
    return;
  }

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = g_overlay.virt_w;
  bmi.bmiHeader.biHeight = -g_overlay.virt_h;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* raw_bits = nullptr;
  g_overlay.screen_bitmap = ::CreateDIBSection(
      screen_dc, &bmi, DIB_RGB_COLORS, &raw_bits, nullptr, 0);
  if (!g_overlay.screen_bitmap || !raw_bits) {
    ::ReleaseDC(nullptr, screen_dc);
    FinishOverlayCancelled();
    return;
  }
  g_overlay.screen_bits = static_cast<uint8_t*>(raw_bits);

  HDC cap_dc = ::CreateCompatibleDC(screen_dc);
  if (!cap_dc) {
    ::ReleaseDC(nullptr, screen_dc);
    FinishOverlayCancelled();
    return;
  }
  HGDIOBJ old_cap = ::SelectObject(cap_dc, g_overlay.screen_bitmap);
  BOOL blt_ok = ::BitBlt(cap_dc, 0, 0, g_overlay.virt_w, g_overlay.virt_h,
                         screen_dc, g_overlay.virt_x, g_overlay.virt_y,
                         SRCCOPY);
  ::SelectObject(cap_dc, old_cap);
  ::DeleteDC(cap_dc);
  if (!blt_ok) {
    ::ReleaseDC(nullptr, screen_dc);
    FinishOverlayCancelled();
    return;
  }

  void* dim_raw = nullptr;
  g_overlay.dim_bitmap = ::CreateDIBSection(
      screen_dc, &bmi, DIB_RGB_COLORS, &dim_raw, nullptr, 0);
  if (g_overlay.dim_bitmap && dim_raw) {
    const uint32_t* src32 = reinterpret_cast<const uint32_t*>(raw_bits);
    uint32_t* dst32 = static_cast<uint32_t*>(dim_raw);
    size_t pixel_count = static_cast<size_t>(g_overlay.virt_w) *
                         static_cast<size_t>(g_overlay.virt_h);
    for (size_t i = 0; i < pixel_count; ++i) {
      uint32_t px = src32[i];
      uint32_t rb = (((px & 0x00FF00FFu) * 160u) >> 8) & 0x00FF00FFu;
      uint32_t g = (((px & 0x0000FF00u) * 160u) >> 8) & 0x0000FF00u;
      dst32[i] = rb | g | 0xFF000000u;
    }
  }

  g_overlay.backbuf_dc = ::CreateCompatibleDC(screen_dc);
  g_overlay.backbuf_bitmap = ::CreateCompatibleBitmap(
      screen_dc, g_overlay.virt_w, g_overlay.virt_h);
  if (g_overlay.backbuf_dc && g_overlay.backbuf_bitmap) {
    g_overlay.backbuf_old_bmp =
        ::SelectObject(g_overlay.backbuf_dc, g_overlay.backbuf_bitmap);
  }
  ::ReleaseDC(nullptr, screen_dc);

  static const wchar_t* kOverlayClass = L"SnipSnapOverlayWindowClass";
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

  g_overlay.hwnd = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kOverlayClass, L"SnipSnap Capture",
      WS_POPUP | WS_VISIBLE, g_overlay.virt_x, g_overlay.virt_y,
      g_overlay.virt_w, g_overlay.virt_h, nullptr, nullptr,
      ::GetModuleHandleW(nullptr), nullptr);
  ::SetForegroundWindow(g_overlay.hwnd);
  ::SetFocus(g_overlay.hwnd);
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
bool CaptureScreenRectBgraWithCursor(int x, int y, int width, int height,
                                     bool draw_cursor,
                                     std::vector<uint8_t>* out_bgra) {
  if (width <= 0 || height <= 0 || !out_bgra) return false;
  HDC screen_dc = ::GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_dc = ::CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ::ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib =
      ::CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) ::DeleteObject(dib);
    ::DeleteDC(mem_dc);
    ::ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old_obj = ::SelectObject(mem_dc, dib);
  BOOL blt_ok =
      ::BitBlt(mem_dc, 0, 0, width, height, screen_dc, x, y, SRCCOPY);
  if (blt_ok && draw_cursor) {
    CURSORINFO ci = {};
    ci.cbSize = sizeof(ci);
    if (::GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING) && ci.hCursor) {
      ICONINFO ii = {};
      int hot_x = 0;
      int hot_y = 0;
      if (::GetIconInfo(ci.hCursor, &ii)) {
        hot_x = static_cast<int>(ii.xHotspot);
        hot_y = static_cast<int>(ii.yHotspot);
        if (ii.hbmMask) ::DeleteObject(ii.hbmMask);
        if (ii.hbmColor) ::DeleteObject(ii.hbmColor);
      }
      ::DrawIconEx(mem_dc, ci.ptScreenPos.x - x - hot_x,
                   ci.ptScreenPos.y - y - hot_y, ci.hCursor, 0, 0, 0, nullptr,
                   DI_NORMAL);
    }
  }

  size_t byte_count = static_cast<size_t>(width) * height * 4;
  if (blt_ok) {
    out_bgra->resize(byte_count);
    std::memcpy(out_bgra->data(), bits, byte_count);
    uint8_t* p = out_bgra->data();
    for (size_t i = 3; i < byte_count; i += 4) {
      p[i] = 0xFF;
    }
  }

  ::SelectObject(mem_dc, old_obj);
  ::DeleteObject(dib);
  ::DeleteDC(mem_dc);
  ::ReleaseDC(nullptr, screen_dc);
  return blt_ok == TRUE;
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
  if (!bgra || bgra->size() < static_cast<size_t>(w) * h * 4) return;
  for (const auto& pulse : pulses) {
    auto age_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - pulse.started_at)
                      .count();
    if (age_ms < 0 || age_ms > 360) continue;
    float progress = static_cast<float>(age_ms) / 360.0f;
    float radius = 8.0f + progress * 22.0f;
    float half_thick = 2.2f;
    float alpha_scale = (1.0f - progress) * 0.85f;
    uint8_t rb = pulse.right_button ? 255 : 40;
    uint8_t gb = pulse.right_button ? 205 : 195;
    uint8_t bb = pulse.right_button ? 70 : 255;

    int cx = pulse.screen_x - rec_x;
    int cy = pulse.screen_y - rec_y;
    int max_r = static_cast<int>(std::ceil(radius + half_thick)) + 1;
    int min_py = std::max(0, cy - max_r);
    int max_py = std::min(h - 1, cy + max_r);
    int min_px = std::max(0, cx - max_r);
    int max_px = std::min(w - 1, cx + max_r);
    for (int py = min_py; py <= max_py; ++py) {
      float dy = static_cast<float>(py - cy);
      for (int px = min_px; px <= max_px; ++px) {
        float dx = static_cast<float>(px - cx);
        float dist = std::sqrt(dx * dx + dy * dy);
        float diff = std::abs(dist - radius);
        if (diff <= half_thick) {
          float coverage = (1.0f - diff / half_thick) * alpha_scale;
          size_t idx = (static_cast<size_t>(py) * w + px) * 4;
          float inv = 1.0f - coverage;
          (*bgra)[idx + 0] = static_cast<uint8_t>(
              std::clamp((*bgra)[idx + 0] * inv + rb * coverage, 0.0f, 255.0f));
          (*bgra)[idx + 1] = static_cast<uint8_t>(
              std::clamp((*bgra)[idx + 1] * inv + gb * coverage, 0.0f, 255.0f));
          (*bgra)[idx + 2] = static_cast<uint8_t>(
              std::clamp((*bgra)[idx + 2] * inv + bb * coverage, 0.0f, 255.0f));
        }
      }
    }
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
    std::vector<float> tmp_stereo;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet_frames)) &&
           packet_frames > 0) {
      BYTE* data = nullptr;
      UINT32 num_frames = 0;
      DWORD flags = 0;
      HRESULT hr =
          capture->GetBuffer(&data, &num_frames, &flags, nullptr, nullptr);
      if (FAILED(hr)) break;

      if (!discard && out_stereo && num_frames > 0) {
        tmp_stereo.resize(static_cast<size_t>(num_frames) * 2);
        bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || !data;
        if (silent) {
          std::fill(tmp_stereo.begin(), tmp_stereo.end(), 0.0f);
        } else {
          for (UINT32 f = 0; f < num_frames; ++f) {
            float l = 0.0f;
            float r = 0.0f;
            if (is_float && bits_per_sample == 32) {
              const float* fp = reinterpret_cast<const float*>(data) +
                                static_cast<size_t>(f) * channels;
              l = fp[0];
              r = (channels >= 2) ? fp[1] : l;
            } else if (!is_float && bits_per_sample == 16) {
              const int16_t* ip = reinterpret_cast<const int16_t*>(data) +
                                  static_cast<size_t>(f) * channels;
              l = static_cast<float>(ip[0]) / 32768.0f;
              r = (channels >= 2) ? (static_cast<float>(ip[1]) / 32768.0f) : l;
            }
            tmp_stereo[static_cast<size_t>(f) * 2 + 0] = l;
            tmp_stereo[static_cast<size_t>(f) * 2 + 1] = r;
          }
        }
        if (sample_rate == 48000) {
          out_stereo->insert(out_stereo->end(), tmp_stereo.begin(),
                             tmp_stereo.end());
        } else {
          double step = static_cast<double>(sample_rate) / 48000.0;
          while (resample_phase < static_cast<double>(num_frames)) {
            UINT32 idx0 = static_cast<UINT32>(resample_phase);
            UINT32 idx1 = std::min(idx0 + 1, num_frames - 1);
            float frac = static_cast<float>(resample_phase - idx0);
            float l0 = tmp_stereo[static_cast<size_t>(idx0) * 2];
            float r0 = tmp_stereo[static_cast<size_t>(idx0) * 2 + 1];
            float l1 = tmp_stereo[static_cast<size_t>(idx1) * 2];
            float r1 = tmp_stereo[static_cast<size_t>(idx1) * 2 + 1];
            out_stereo->push_back(l0 + (l1 - l0) * frac);
            out_stereo->push_back(r0 + (r1 - r0) * frac);
            resample_phase += step;
          }
          resample_phase -= static_cast<double>(num_frames);
        }
      }
      capture->ReleaseBuffer(num_frames);
    }
  }
};

// Gene - Nov, 13, 2026: Added multi-monitor HUD positioning, countdown click/Esc cancel, wrote_valid_video verification, join_mutex synchronization, and non-blocking StopWinRecordingSession.
// Old implementation:
// struct WinScreenRecorder {
//   std::atomic<bool> active{false};
//   std::atomic<bool> paused{false};
//   std::atomic<bool> cancelled{false};
//   std::atomic<bool> mic_muted{false};
//   std::atomic<int> countdown_remaining{0};
//   std::atomic<int64_t> elapsed_ms{0};
//   std::atomic<bool> actual_has_audio{false};
//   std::thread worker;
//   std::thread hud_thread;
//   std::mutex hud_mutex;
//   HWND hud_hwnd = nullptr;
//   std::wstring target_path;
//   std::wstring thumbnail_path;
//   std::string mic_device_id;
//   int rec_x = 0;
//   int rec_y = 0;
//   int rec_w = 0;
//   int rec_h = 0;
//   int fps = 60;
//   bool record_audio = false;
//   bool record_system_audio = true;
//   bool record_cursor = true;
//   bool highlight_clicks = true;
//
//   RECT pause_btn = {0, 0, 0, 0};
//   RECT stop_btn = {0, 0, 0, 0};
//   RECT restart_btn = {0, 0, 0, 0};
//   RECT mute_btn = {0, 0, 0, 0};
//   RECT cancel_btn = {0, 0, 0, 0};
//   bool hud_dragging = false;
//   POINT hud_drag_offset = {0, 0};
//   bool hud_in_countdown_mode = false;
// };
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

void StopWinRecordingSession(bool cancel,
                             std::unique_ptr<CaptureMethodResult> result);

void RefreshRecordingHudWindow() {
  std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
  if (g_recorder.hud_hwnd && ::IsWindow(g_recorder.hud_hwnd)) {
    ::InvalidateRect(g_recorder.hud_hwnd, nullptr, FALSE);
  }
}

void CloseRecordingHudWindow() {
  HWND hwnd_to_close = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
    hwnd_to_close = g_recorder.hud_hwnd;
  }
  if (hwnd_to_close && ::IsWindow(hwnd_to_close)) {
    ::PostMessageW(hwnd_to_close, WM_CLOSE, 0, 0);
  }
  if (g_recorder.hud_thread.joinable()) {
    g_recorder.hud_thread.join();
  }
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
        PostToPlatformThread([]() { StopWinRecordingSession(true, nullptr); });
        return 0;
      }
      break;
    }

    case WM_TIMER: {
      if (wparam == kHudTimerId) {
        int rem = g_recorder.countdown_remaining.load();
        bool want_countdown = rem > 0;
        if (want_countdown != g_recorder.hud_in_countdown_mode) {
          g_recorder.hud_in_countdown_mode = want_countdown;
          int mx = g_recorder.hud_mon_x;
          int my = g_recorder.hud_mon_y;
          int mw = std::max(320, g_recorder.hud_mon_w);
          int mh = std::max(240, g_recorder.hud_mon_h);
          if (want_countdown) {
            int cw = 148;
            int ch = 158;
            ::SetWindowPos(hwnd, HWND_TOPMOST, mx + (mw - cw) / 2,
                           my + (mh - ch) / 2, cw, ch,
                           SWP_NOACTIVATE | SWP_SHOWWINDOW);
          } else {
            int pw = 372;
            int ph = 46;
            ::SetWindowPos(hwnd, HWND_TOPMOST, mx + (mw - pw) / 2, my + 24,
                           pw, ph, SWP_NOACTIVATE | SWP_SHOWWINDOW);
          }
        }
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_LBUTTONDOWN: {
      if (g_recorder.countdown_remaining.load() > 0) {
        PostToPlatformThread([]() { StopWinRecordingSession(true, nullptr); });
        return 0;
      }
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (::PtInRect(&g_recorder.pause_btn, pt)) {
        bool now_paused = !g_recorder.paused.load();
        g_recorder.paused.store(now_paused);
        ::InvalidateRect(hwnd, nullptr, FALSE);
        EncodableMap args;
        args[EncodableValue("isPaused")] = EncodableValue(now_paused);
        InvokeDartMethod("onRecordingStateChanged", EncodableValue(args));
        return 0;
      }
      if (::PtInRect(&g_recorder.stop_btn, pt)) {
        PostToPlatformThread([]() { StopWinRecordingSession(false, nullptr); });
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
        PostToPlatformThread([]() { StopWinRecordingSession(true, nullptr); });
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
      if (rem > 0) {
        RECT num_rect = {0, 8, cw, ch - 30};
        ::SetTextColor(mem_dc, RGB(255, 255, 255));
        std::wstring num = std::to_wstring(rem);
        HFONT big_font = ::CreateFontW(
            68, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
            OUT_OUTLINE_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            VARIABLE_PITCH, L"Segoe UI");
        HGDIOBJ old_f = ::SelectObject(mem_dc, big_font);
        ::DrawTextW(mem_dc, num.c_str(), -1, &num_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        ::SelectObject(mem_dc, old_f);
        ::DeleteObject(big_font);

        RECT hint_rect = {8, ch - 28, cw - 8, ch - 6};
        ::SetTextColor(mem_dc, RGB(196, 178, 166));
        ::DrawTextW(mem_dc, L"Click or Esc to cancel", -1, &hint_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      } else {
        int64_t secs = g_recorder.elapsed_ms.load() / 1000;
        wchar_t time_buf[32] = {};
        std::swprintf(time_buf, 32, L"%02lld:%02lld",
                      static_cast<long long>(secs / 60),
                      static_cast<long long>(secs % 60));
        RECT time_rect = {10, 6, 74, ch - 6};
        ::SetTextColor(mem_dc, g_recorder.paused.load() ? RGB(255, 200, 90)
                                                        : RGB(255, 110, 100));
        ::DrawTextW(mem_dc, time_buf, -1, &time_rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);

        int bx = 78;
        int by = 8;
        int bh = ch - 16;
        g_recorder.pause_btn = {bx, by, bx + 58, by + bh};
        bx += 62;
        g_recorder.stop_btn = {bx, by, bx + 52, by + bh};
        bx += 56;
        g_recorder.restart_btn = {bx, by, bx + 60, by + bh};
        bx += 64;
        if (g_recorder.record_audio) {
          g_recorder.mute_btn = {bx, by, bx + 58, by + bh};
          bx += 62;
        } else {
          g_recorder.mute_btn = {0, 0, 0, 0};
        }
        g_recorder.cancel_btn = {bx, by, bx + 32, by + bh};

        DrawRoundedPill(
            mem_dc, g_recorder.pause_btn, RGB(48, 40, 35), RGB(110, 92, 80),
            g_recorder.paused.load() ? L"Resume" : L"Pause",
            RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_recorder.stop_btn, RGB(205, 42, 42),
                        RGB(240, 90, 90), L"Stop", RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_recorder.restart_btn, RGB(48, 40, 35),
                        RGB(110, 92, 80), L"Restart", RGB(255, 255, 255));
        if (g_recorder.record_audio) {
          bool muted = g_recorder.mic_muted.load();
          DrawRoundedPill(mem_dc, g_recorder.mute_btn,
                          muted ? RGB(130, 52, 42) : RGB(46, 105, 62),
                          RGB(110, 92, 80), muted ? L"Muted" : L"Mic",
                          RGB(255, 255, 255));
        }
        DrawRoundedPill(mem_dc, g_recorder.cancel_btn, RGB(40, 32, 28),
                        RGB(110, 92, 80), L"X", RGB(220, 200, 190));
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
      {
        std::lock_guard<std::mutex> lock(g_recorder.hud_mutex);
        g_recorder.hud_hwnd = nullptr;
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
    static std::atomic<bool> registered{false};
    if (!registered.exchange(true)) {
      WNDCLASSEXW wc = {};
      wc.cbSize = sizeof(WNDCLASSEXW);
      wc.lpfnWndProc = RecordingHudWndProc;
      wc.hInstance = ::GetModuleHandleW(nullptr);
      wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
      wc.lpszClassName = kHudClass;
      ::RegisterClassExW(&wc);
    }

    int mx = g_recorder.hud_mon_x;
    int my = g_recorder.hud_mon_y;
    int mw = std::max(320, g_recorder.hud_mon_w);
    int mh = std::max(240, g_recorder.hud_mon_h);
    int win_w = countdown_seconds > 0 ? 148 : 372;
    int win_h = countdown_seconds > 0 ? 158 : 46;
    int win_x = mx + (mw - win_w) / 2;
    int win_y = countdown_seconds > 0 ? (my + (mh - win_h) / 2) : (my + 24);

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
      MSG msg = {};
      while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
      }
    }
  });
}

// Old blocking StopWinRecordingSession retained commented per policy:
// void StopWinRecordingSession(bool cancel,
//                              std::unique_ptr<CaptureMethodResult> result) {
//   if (!g_recorder.active.load()) {
//     CloseRecordingHudWindow();
//     SetMainWindowVisible(true);
//     if (result) result->Success(EncodableValue());
//     return;
//   }
//   if (cancel) g_recorder.cancelled.store(true);
//   g_recorder.active.store(false);
//   g_recorder.countdown_remaining.store(0);
//   if (g_recorder.worker.joinable()) {
//     g_recorder.worker.join();
//   }
//   CloseRecordingHudWindow();
//   SetMainWindowVisible(true);
//   ...
// }
void StopWinRecordingSession(bool cancel,
                             std::unique_ptr<CaptureMethodResult> result) {
  std::shared_ptr<CaptureMethodResult> shared_result(std::move(result));
  if (!g_recorder.active.load() && !g_recorder.stopping.load()) {
    CloseRecordingHudWindow();
    SetMainWindowVisible(true);
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

  std::thread([cancel, shared_result]() {
    {
      std::lock_guard<std::mutex> lock(g_recorder.join_mutex);
      if (g_recorder.worker.joinable()) {
        g_recorder.worker.join();
      }
      CloseRecordingHudWindow();
    }
    PostToPlatformThread([cancel, shared_result]() {
      g_recorder.stopping.store(false);
      SetMainWindowVisible(true);

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
    HRESULT hr = ::MFCreateSinkWriterFromURL(
        g_recorder.target_path.c_str(), nullptr, nullptr, &writer);

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
    int64_t rt_start = 0;
    int64_t audio_frames_written = 0;
    auto frame_interval = std::chrono::microseconds(1000000 / rec_fps);
    std::vector<uint8_t> frame_bgra;
    std::vector<ClickPulse> click_pulses;
    bool prev_lbutton = false;
    bool prev_rbutton = false;
    std::deque<float> sys_queue;
    std::deque<float> mic_queue;

    while (SUCCEEDED(hr) && g_recorder.active.load()) {
      auto loop_start = std::chrono::steady_clock::now();
      bool paused_now = g_recorder.paused.load();

      if (sys_open) sys_loopback.Drain48kStereo(&sys_queue, paused_now);
      if (mic_open) mic_capture.Drain48kStereo(&mic_queue, paused_now);
      while (sys_queue.size() > 96000) sys_queue.pop_front();
      while (mic_queue.size() > 96000) mic_queue.pop_front();

      if (!paused_now) {
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
                                            &frame_bgra)) {
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
          DWORD cb_buffer = cb_width * h;
          ComPtr<IMFMediaBuffer> buffer;
          if (SUCCEEDED(::MFCreateMemoryBuffer(cb_buffer, &buffer))) {
            BYTE* dst = nullptr;
            if (SUCCEEDED(buffer->Lock(&dst, nullptr, nullptr))) {
              for (int row = 0; row < h; ++row) {
                const uint8_t* src_row =
                    frame_bgra.data() + (h - 1 - row) * cb_width;
                std::memcpy(dst + row * cb_width, src_row, cb_width);
              }
              buffer->Unlock();
              buffer->SetCurrentLength(cb_buffer);

              ComPtr<IMFSample> sample;
              if (SUCCEEDED(::MFCreateSample(&sample))) {
                sample->AddBuffer(buffer.Get());
                sample->SetSampleTime(rt_start);
                sample->SetSampleDuration(frame_duration_100ns);
                writer->WriteSample(video_stream_index, sample.Get());
                rt_start += frame_duration_100ns;
                g_recorder.elapsed_ms.store(rt_start / 10000);
              }
            }
          }

          if (has_audio_stream) {
            int64_t target_audio_frames = (rt_start * 48000LL) / 10000000LL;
            int64_t frames_to_write =
                target_audio_frames - audio_frames_written;
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

    if (writer && !g_recorder.cancelled.load() && rt_start > 0) {
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

// Gene - Nov, 13, 2026: Normalize MF_MT_DEFAULT_STRIDE and force opaque 0xFF alpha in ExtractVideoFrameAtMs; added native single-pass Media Foundation + WIC animated GIF exporter ExportVideoAsGifWic.
// Old implementation:
// bool ExtractVideoFrameAtMs(const std::wstring& video_path, int64_t timestamp_ms,
//                            const std::wstring& target_png_path) {
//   ::MFStartup(MF_VERSION);
//   ComPtr<IMFSourceReader> reader;
//   HRESULT hr = ::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr, &reader);
//   ...
//         if (w > 0 && h > 0 && len >= w * h * 4) {
//           ok = SaveBgraToPngFile(data, static_cast<int>(w), static_cast<int>(h),
//                                  static_cast<int>(w * 4), target_png_path);
//         }
//   ...
//   return ok;
// }
bool ExtractVideoFrameAtMs(const std::wstring& video_path, int64_t timestamp_ms,
                           const std::wstring& target_png_path) {
  ::MFStartup(MF_VERSION);
  ComPtr<IMFSourceReader> reader;
  HRESULT hr =
      ::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr, &reader);
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
    if (FAILED(::MFCreateSourceReaderFromURL(src_path.c_str(), nullptr,
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
    if (SUCCEEDED(reader->SetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
            pcm_req.Get()))) {
      has_audio = true;
    }

    ComPtr<IMFSinkWriter> writer;
    if (FAILED(::MFCreateSinkWriterFromURL(dst_path.c_str(), nullptr, nullptr,
                                           &writer)) ||
        !writer) {
      break;
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
      int64_t first_v_ts = -1;
      int64_t first_a_ts = -1;
      int64_t seg_max_dur = 0;

      while (!(v_done && a_done)) {
        DWORD stream_idx = 0;
        DWORD flags = 0;
        LONGLONG ts = 0;
        ComPtr<IMFSample> sample;
        HRESULT rhr = reader->ReadSample(
            static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &stream_idx,
            &flags, &ts, &sample);
        if (FAILED(rhr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
          break;
        }
        if (!sample) continue;

        GUID major_type = GUID_NULL;
        ComPtr<IMFMediaType> s_type;
        if (SUCCEEDED(reader->GetCurrentMediaType(stream_idx, &s_type)) &&
            s_type) {
          s_type->GetGUID(MF_MT_MAJOR_TYPE, &major_type);
        }

        if (major_type == MFMediaType_Video) {
          if (ts < seg_start_100ns) continue;
          if (ts > seg_end_100ns) {
            v_done = true;
            continue;
          }
          if (first_v_ts < 0) first_v_ts = ts;
          int64_t rel_ts = ts - first_v_ts;
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
              DWORD row_bytes = vw * 4;
              DWORD out_bytes = row_bytes * vh;
              if (slen >= out_bytes) {
                ComPtr<IMFMediaBuffer> dst_buf;
                if (SUCCEEDED(::MFCreateMemoryBuffer(out_bytes, &dst_buf))) {
                  BYTE* ddata = nullptr;
                  if (SUCCEEDED(dst_buf->Lock(&ddata, nullptr, nullptr))) {
                    UINT32 abs_stride = static_cast<UINT32>(
                        src_stride >= 0 ? src_stride : -src_stride);
                    for (UINT32 r = 0; r < vh; ++r) {
                      UINT32 src_r = (src_stride >= 0) ? (vh - 1 - r) : r;
                      std::memcpy(ddata + r * row_bytes,
                                  sdata + src_r * abs_stride, row_bytes);
                    }
                    dst_buf->Unlock();
                    dst_buf->SetCurrentLength(out_bytes);
                    ComPtr<IMFSample> out_sample;
                    if (SUCCEEDED(::MFCreateSample(&out_sample))) {
                      out_sample->AddBuffer(dst_buf.Get());
                      out_sample->SetSampleTime(total_out_100ns + rel_ts);
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
        } else if (writer_has_audio && major_type == MFMediaType_Audio) {
          if (ts < seg_start_100ns) continue;
          if (ts > seg_end_100ns) {
            a_done = true;
            continue;
          }
          if (first_a_ts < 0) first_a_ts = ts;
          int64_t rel_ts = ts - first_a_ts;
          LONGLONG dur = 0;
          sample->GetSampleDuration(&dur);
          sample->SetSampleTime(total_out_100ns + rel_ts);
          if (FAILED(writer->WriteSample(out_a_idx, sample.Get()))) {
            write_ok = false;
          }
          seg_max_dur = std::max(seg_max_dur, rel_ts + dur);
        }
        if (!write_ok) break;
      }
      total_out_100ns += seg_max_dur;
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
  int64_t texture_id = -1;
  int64_t duration_ms = 0;
  int width = 0;
  int height = 0;
  bool has_audio = false;

  std::unique_ptr<flutter::TextureVariant> texture_variant;
  std::mutex frame_mutex;
  std::vector<uint8_t> rgba_front;
  std::vector<uint8_t> rgba_back;
  FlutterDesktopPixelBuffer pixel_buffer = {};

  std::atomic<bool> playing{false};
  std::atomic<bool> disposed{false};
  std::atomic<bool> muted{false};
  std::atomic<float> volume{1.0f};
  std::atomic<float> speed{1.0f};
  std::atomic<int64_t> position_ms{0};
  std::atomic<int64_t> seek_request_ms{-1};
  // Gene - Nov, 13, 2026: Track dynamic playback speed changes so frame-pacing clock re-anchors without drift or stale waits.
  std::atomic<bool> reanchor_clock{false};

  std::wstring video_path;
  flutter::TextureRegistrar* registrar = nullptr;
  std::thread worker;

  static std::shared_ptr<WinVideoTexturePlayer> Create(
      const std::wstring& path, flutter::TextureRegistrar* reg) {
    if (!reg || path.empty()) return nullptr;
    auto player = std::make_shared<WinVideoTexturePlayer>();
    player->video_path = path;
    player->registrar = reg;

    ::MFStartup(MF_VERSION);
    ComPtr<IMFSourceReader> probe_reader;
    if (FAILED(::MFCreateSourceReaderFromURL(path.c_str(), nullptr,
                                             &probe_reader)) ||
        !probe_reader) {
      ::MFShutdown();
      return nullptr;
    }

    PROPVARIANT var;
    ::PropVariantInit(&var);
    if (SUCCEEDED(probe_reader->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
            &var))) {
      if (var.vt == VT_UI8) {
        player->duration_ms = static_cast<int64_t>(var.uhVal.QuadPart / 10000ULL);
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
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
            rgb_type.Get()))) {
      ::MFShutdown();
      return nullptr;
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
      ::MFShutdown();
      return nullptr;
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
      if (player->DecodeSampleIntoFrontBuffer(sample.Get(), default_stride)) {
        break;
      }
    }
    ::MFShutdown();

    std::weak_ptr<WinVideoTexturePlayer> weak_self = player;
    player->texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture(
            [weak_self](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
              auto self = weak_self.lock();
              if (!self || self->disposed.load()) return nullptr;
              std::lock_guard<std::mutex> lock(self->frame_mutex);
              if (self->rgba_front.empty() || self->width <= 0 ||
                  self->height <= 0) {
                return nullptr;
              }
              self->pixel_buffer.buffer = self->rgba_front.data();
              self->pixel_buffer.width = static_cast<size_t>(self->width);
              self->pixel_buffer.height = static_cast<size_t>(self->height);
              self->pixel_buffer.release_callback = nullptr;
              self->pixel_buffer.release_context = nullptr;
              return &self->pixel_buffer;
            }));

    player->texture_id = reg->RegisterTexture(player->texture_variant.get());
    reg->MarkTextureFrameAvailable(player->texture_id);

    player->worker = std::thread([player]() { player->RunLoop(); });
    return player;
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
    if (len >= static_cast<DWORD>(abs_stride * height)) {
      rgba_back.resize(total_bytes);
      for (int y = 0; y < height; ++y) {
        int sy = (src_stride >= 0) ? y : (height - 1 - y);
        const uint8_t* src_row = data + static_cast<size_t>(sy) * abs_stride;
        uint8_t* dst_row = rgba_back.data() + static_cast<size_t>(y) * row_bytes;
        for (int x = 0; x < width; ++x) {
          dst_row[x * 4 + 0] = src_row[x * 4 + 2];
          dst_row[x * 4 + 1] = src_row[x * 4 + 1];
          dst_row[x * 4 + 2] = src_row[x * 4 + 0];
          dst_row[x * 4 + 3] = 0xFF;
        }
      }
      {
        std::lock_guard<std::mutex> lock(frame_mutex);
        rgba_front.swap(rgba_back);
      }
      buf->Unlock();
      return true;
    }
    buf->Unlock();
    return false;
  }

  void RunLoop() {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ::MFStartup(MF_VERSION);

    ComPtr<IMFSourceReader> reader;
    HRESULT hr = ::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr,
                                               &reader);
    INT32 v_stride = width * 4;
    if (SUCCEEDED(hr) && reader) {
      ComPtr<IMFMediaType> rgb_type;
      ::MFCreateMediaType(&rgb_type);
      rgb_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      rgb_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      reader->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
          rgb_type.Get());
      ComPtr<IMFMediaType> actual_v;
      if (SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
              &actual_v)) &&
          actual_v) {
        UINT32 su = 0;
        if (SUCCEEDED(actual_v->GetUINT32(MF_MT_DEFAULT_STRIDE, &su)) &&
            su != 0) {
          v_stride = static_cast<INT32>(su);
        }
      }
      if (has_audio) {
        ComPtr<IMFMediaType> pcm_type;
        ::MFCreateMediaType(&pcm_type);
        pcm_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        pcm_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        pcm_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        pcm_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000);
        pcm_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        pcm_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
        pcm_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192000);
        reader->SetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
            pcm_type.Get());
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
        render_rate = rfmt->nSamplesPerSec;
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
            SUCCEEDED(render_client->GetService(IID_PPV_ARGS(&audio_render))) &&
            SUCCEEDED(render_client->Start())) {
          audio_ready = true;
        }
        ::CoTaskMemFree(rfmt);
      }
    }

    auto last_progress_emit = std::chrono::steady_clock::now();
    bool need_clock_anchor = true;
    auto wall_anchor = std::chrono::steady_clock::now();
    int64_t media_anchor_ms = 0;

    while (!disposed.load() && reader) {
      int64_t req_seek = seek_request_ms.exchange(-1);
      if (req_seek >= 0) {
        int64_t clamped = std::clamp<int64_t>(req_seek, 0, duration_ms);
        PROPVARIANT var;
        ::PropVariantInit(&var);
        var.vt = VT_I8;
        var.hVal.QuadPart = clamped * 10000LL;
        reader->SetCurrentPosition(GUID_NULL, var);
        ::PropVariantClear(&var);
        position_ms.store(clamped);
        need_clock_anchor = true;

        for (int i = 0; i < 6 && !disposed.load(); ++i) {
          DWORD flags = 0;
          LONGLONG ts = 0;
          ComPtr<IMFSample> s;
          if (FAILED(reader->ReadSample(
                  static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
                  nullptr, &flags, &ts, &s)) ||
              (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            break;
          }
          if (!s) continue;
          if (DecodeSampleIntoFrontBuffer(s.Get(), v_stride)) {
            if (registrar) registrar->MarkTextureFrameAvailable(texture_id);
            position_ms.store(std::max<int64_t>(clamped, ts / 10000LL));
            break;
          }
        }

        EncodableMap prog;
        prog[EncodableValue("textureId")] = EncodableValue(texture_id);
        prog[EncodableValue("positionMs")] = EncodableValue(position_ms.load());
        prog[EncodableValue("isPlaying")] = EncodableValue(playing.load());
        InvokeDartMethod("onVideoPlayerProgress", EncodableValue(prog));
      }

      if (!playing.load()) {
        need_clock_anchor = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
        continue;
      }

      DWORD stream_idx = 0;
      DWORD flags = 0;
      LONGLONG ts = 0;
      ComPtr<IMFSample> sample;
      HRESULT rhr = reader->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &stream_idx,
          &flags, &ts, &sample);
      if (FAILED(rhr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
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

      GUID major_type = GUID_NULL;
      ComPtr<IMFMediaType> s_type;
      if (SUCCEEDED(reader->GetCurrentMediaType(stream_idx, &s_type)) &&
          s_type) {
        s_type->GetGUID(MF_MT_MAJOR_TYPE, &major_type);
      }

      if (major_type == MFMediaType_Audio && audio_ready && audio_render) {
        ComPtr<IMFMediaBuffer> abuf;
        if (SUCCEEDED(sample->ConvertToContiguousBuffer(&abuf))) {
          BYTE* adata = nullptr;
          DWORD alen = 0;
          if (SUCCEEDED(abuf->Lock(&adata, nullptr, &alen)) && alen >= 4) {
            UINT32 in_frames = alen / 4;
            const int16_t* pcm = reinterpret_cast<const int16_t*>(adata);
            UINT32 padding = 0;
            render_client->GetCurrentPadding(&padding);
            UINT32 avail =
                (render_buf_frames > padding) ? (render_buf_frames - padding) : 0;
            UINT32 out_frames = static_cast<UINT32>(
                (static_cast<uint64_t>(in_frames) * render_rate) / 48000ULL);
            out_frames = std::min(out_frames, avail);
            if (out_frames > 0) {
              BYTE* rdata = nullptr;
              if (SUCCEEDED(audio_render->GetBuffer(out_frames, &rdata)) &&
                  rdata) {
                float gain = muted.load() ? 0.0f : volume.load();
                for (UINT32 f = 0; f < out_frames; ++f) {
                  UINT32 src_f = std::min<UINT32>(
                      in_frames - 1,
                      static_cast<UINT32>(
                          (static_cast<uint64_t>(f) * in_frames) / out_frames));
                  float sl =
                      (static_cast<float>(pcm[src_f * 2 + 0]) / 32768.0f) * gain;
                  float sr =
                      (static_cast<float>(pcm[src_f * 2 + 1]) / 32768.0f) * gain;
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
                    out_i[0] = static_cast<int16_t>(
                        std::clamp(sl, -1.0f, 1.0f) * 32767.0f);
                    if (render_channels >= 2) {
                      out_i[1] = static_cast<int16_t>(
                          std::clamp(sr, -1.0f, 1.0f) * 32767.0f);
                    }
                    for (UINT32 ch = 2; ch < render_channels; ++ch) {
                      out_i[ch] = 0;
                    }
                  }
                }
                audio_render->ReleaseBuffer(out_frames, 0);
              }
            }
            abuf->Unlock();
          }
        }
        continue;
      }

      if (major_type == MFMediaType_Video) {
        int64_t frame_ms = ts / 10000LL;
        // Gene - Nov, 13, 2026: Re-anchor pacing clock when requested (e.g., playback speed change) and exit stale sleeps immediately.
        // Old implementation:
        // if (need_clock_anchor) {
        //   wall_anchor = std::chrono::steady_clock::now();
        //   media_anchor_ms = frame_ms;
        //   need_clock_anchor = false;
        // } else {
        //   float cur_spd = std::clamp(speed.load(), 0.25f, 4.0f);
        //   int64_t target_wall_ms = static_cast<int64_t>(
        //       static_cast<double>(frame_ms - media_anchor_ms) / cur_spd);
        //   auto due = wall_anchor + std::chrono::milliseconds(target_wall_ms);
        //   while (!disposed.load() && playing.load() &&
        //          seek_request_ms.load() < 0 &&
        //          std::chrono::steady_clock::now() < due) {
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
            auto rem_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              due - std::chrono::steady_clock::now())
                              .count();
            std::this_thread::sleep_for(
                std::chrono::milliseconds(std::clamp<int64_t>(rem_ms, 1, 10)));
          }
        }
        if (disposed.load() || seek_request_ms.load() >= 0) continue;

        if (DecodeSampleIntoFrontBuffer(sample.Get(), v_stride)) {
          if (registrar) registrar->MarkTextureFrameAvailable(texture_id);
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

    if (render_client && audio_ready) {
      render_client->Stop();
    }
    audio_render.Reset();
    render_client.Reset();
    reader.Reset();
    ::MFShutdown();
    ::CoUninitialize();
  }

  // Gene - Nov, 13, 2026: Rewind to start when Play() is pressed at EOF, and re-anchor pacing clock on SetSpeed().
  // Old implementation:
  // void Play() { playing.store(true); }
  // void Pause() { playing.store(false); }
  // void Seek(int64_t ms) { seek_request_ms.store(ms); }
  // void SetVolume(float v) { volume.store(std::clamp(v, 0.0f, 1.0f)); }
  // void SetMuted(bool m) { muted.store(m); }
  // void SetSpeed(float s) { speed.store(std::clamp(s, 0.25f, 4.0f)); }
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

        // Old implementation:
        // if (method == "screenCaptureAuthorized" ||
        //     method == "accessibilityAuthorized") {
        //   result->Success(EncodableValue(true));
        //   return;
        // }
        if (method == "screenCaptureAuthorized" ||
            method == "accessibilityAuthorized" ||
            method == "microphoneAuthorized" ||
            method == "requestMicrophoneAccess") {
          result->Success(EncodableValue(true));
          return;
        }

        if (method == "setMainWindowVisible") {
          SetMainWindowVisible(get_bool("visible", true));
          result->Success(EncodableValue());
          return;
        }

        if (method == "listAudioInputDevices") {
          result->Success(EncodableValue(EnumerateWindowsAudioInputDevices()));
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
          // Gene - Nov, 13, 2026: Capture active display under cursor rather than spanning entire virtual desktop, matching macOS multi-monitor behavior.
          // Old implementation:
          // int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
          // int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
          // int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
          // int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
          // std::vector<uint8_t> bgra;
          // if (CaptureScreenRectBgra(vx, vy, vw, vh, &bgra) &&
          //     SaveBgraToPngFile(bgra.data(), vw, vh, vw * 4,
          //                       Utf8ToWide(target))) {
          //   result->Success(EncodableValue(target));
          // } else {
          //   result->Success(EncodableValue());
          // }
          RECT mon = GetCursorMonitorScreenRect();
          int vx = static_cast<int>(mon.left);
          int vy = static_cast<int>(mon.top);
          int vw = static_cast<int>(mon.right - mon.left);
          int vh = static_cast<int>(mon.bottom - mon.top);
          std::vector<uint8_t> bgra;
          if (vw > 0 && vh > 0 && CaptureScreenRectBgra(vx, vy, vw, vh, &bgra) &&
              SaveBgraToPngFile(bgra.data(), vw, vh, vw * 4,
                                Utf8ToWide(target))) {
            result->Success(EncodableValue(target));
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
          // Gene - Nov, 13, 2026: Forward initial Snagit recording options to Win32 overlay.
          // Old implementation:
          // StartWin32InteractiveOverlay(Utf8ToWide(target), initial_mode,
          //                              std::move(result));
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

        if (method == "captureRect") {
          int rx = static_cast<int>(std::round(get_double("x")));
          int ry = static_cast<int>(std::round(get_double("y")));
          int rw = static_cast<int>(std::round(get_double("width")));
          int rh = static_cast<int>(std::round(get_double("height")));
          std::vector<uint8_t> bgra;
          std::vector<uint8_t> png;
          if (CaptureScreenRectBgra(rx, ry, rw, rh, &bgra) &&
              EncodeBgraToPngBytes(bgra.data(), rw, rh, rw * 4, &png)) {
            result->Success(EncodableValue(png));
          } else {
            result->Success(EncodableValue());
          }
          return;
        }

        if (method == "copyImageToClipboard") {
          if (args) {
            auto bytes_it = args->find(EncodableValue("bytes"));
            if (bytes_it != args->end()) {
              if (const auto* bytes =
                      std::get_if<std::vector<uint8_t>>(&bytes_it->second)) {
                bool ok = CopyPngBytesToWin32Clipboard(bytes->data(),
                                                       bytes->size());
                result->Success(EncodableValue(ok));
                return;
              }
            }
          }
          std::string file_path = get_str("filePath");
          if (!file_path.empty()) {
            HANDLE f = ::CreateFileW(Utf8ToWide(file_path).c_str(),
                                     GENERIC_READ, FILE_SHARE_READ, nullptr,
                                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                                     nullptr);
            if (f != INVALID_HANDLE_VALUE) {
              DWORD sz = ::GetFileSize(f, nullptr);
              std::vector<uint8_t> buf(sz);
              DWORD rd = 0;
              BOOL read_ok = ::ReadFile(f, buf.data(), sz, &rd, nullptr);
              ::CloseHandle(f);
              if (read_ok && rd > 0) {
                bool ok = CopyPngBytesToWin32Clipboard(buf.data(), rd);
                result->Success(EncodableValue(ok));
                return;
              }
            }
          }
          result->Success(EncodableValue(false));
          return;
        }

        if (method == "pasteImageFromClipboard") {
          std::string target = get_str("targetPath");
          if (target.empty()) {
            result->Success(EncodableValue());
            return;
          }
          if (PasteWin32ClipboardToPngFile(Utf8ToWide(target))) {
            result->Success(EncodableValue(target));
          } else {
            result->Success(EncodableValue());
          }
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

        if (method == "cancelScreenRecording") {
          StopWinRecordingSession(true, std::move(result));
          return;
        }

        if (method == "extractVideoFrame") {
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t ts_ms = get_int64("timestampMs", 0);
          bool ok = ExtractVideoFrameAtMs(Utf8ToWide(video_path), ts_ms,
                                          Utf8ToWide(target_path));
          if (ok) {
            result->Success(EncodableValue(target_path));
          } else {
            result->Success(EncodableValue());
          }
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

        if (method == "createVideoPlayer") {
          std::string video_path = get_str("videoPath");
          auto cur_gate = Gate();
          flutter::TextureRegistrar* tex_reg =
              cur_gate ? cur_gate->texture_registrar : nullptr;
          auto player =
              WinVideoTexturePlayer::Create(Utf8ToWide(video_path), tex_reg);
          if (!player || player->texture_id < 0) {
            result->Success(EncodableValue());
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
          info[EncodableValue("hasAudio")] = EncodableValue(player->has_audio);
          result->Success(EncodableValue(info));
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
          if (player) player->Dispose();
          result->Success(EncodableValue());
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
void ShutdownCaptureHandler() {
  {
    std::vector<std::shared_ptr<WinVideoTexturePlayer>> to_dispose;
    {
      std::lock_guard<std::mutex> lock(g_players_mutex);
      for (auto& kv : g_video_players) {
        to_dispose.push_back(kv.second);
      }
      g_video_players.clear();
    }
    for (auto& p : to_dispose) {
      if (p) p->Dispose();
    }
  }
  CloseInteractiveOverlay();
  // Gene - Nov, 13, 2026: Ensure both active and in-flight stopping recorder workers are safely joined under join_mutex on shutdown.
  // Old implementation:
  // if (g_recorder.active.load()) {
  //   g_recorder.cancelled.store(true);
  //   g_recorder.active.store(false);
  //   g_recorder.countdown_remaining.store(0);
  //   if (g_recorder.worker.joinable()) {
  //     g_recorder.worker.join();
  //   }
  // }
  // CloseRecordingHudWindow();
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
  auto gate = Gate();
  if (!gate) return;
  std::lock_guard<std::mutex> lock(gate->mutex);
  gate->engine = nullptr;
  gate->registrar = nullptr;
  gate->texture_registrar = nullptr;
  gate->channel.reset();
}
