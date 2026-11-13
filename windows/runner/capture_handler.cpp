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
struct InteractiveOverlayState {
  HWND hwnd = nullptr;
  int virt_x = 0;
  int virt_y = 0;
  int virt_w = 0;
  int virt_h = 0;
  std::vector<uint8_t> screen_bgra;
  HBITMAP screen_bitmap = nullptr;
  std::wstring target_path;
  std::string initial_mode = "capture";
  std::unique_ptr<CaptureMethodResult> pending_result;

  int selected_fps = 60;
  bool record_mic = false;
  std::string mic_device_id;
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
  int active_grip = -1;  // 0..7 corners/edges, 8 body

  RECT capture_btn = {0, 0, 0, 0};
  RECT record_btn = {0, 0, 0, 0};
  RECT cancel_btn = {0, 0, 0, 0};
  RECT preset_full_btn = {0, 0, 0, 0};
  RECT preset_1080_btn = {0, 0, 0, 0};
  RECT preset_720_btn = {0, 0, 0, 0};
  RECT fps_btn = {0, 0, 0, 0};
  RECT mic_btn = {0, 0, 0, 0};
  RECT sys_audio_btn = {0, 0, 0, 0};
  RECT cursor_btn = {0, 0, 0, 0};
  RECT mode_snip_btn = {0, 0, 0, 0};
  bool settled = false;
};

InteractiveOverlayState g_overlay;

void CloseInteractiveOverlay() {
  if (g_overlay.hwnd) {
    ::DestroyWindow(g_overlay.hwnd);
    g_overlay.hwnd = nullptr;
  }
  if (g_overlay.screen_bitmap) {
    ::DeleteObject(g_overlay.screen_bitmap);
    g_overlay.screen_bitmap = nullptr;
  }
  g_overlay.screen_bgra.clear();
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
  int src_stride = g_overlay.virt_w * 4;
  int dst_stride = rw * 4;
  for (int row = 0; row < rh; ++row) {
    const uint8_t* s =
        g_overlay.screen_bgra.data() + (ry + row) * src_stride + rx * 4;
    uint8_t* d = cropped.data() + row * dst_stride;
    std::memcpy(d, s, dst_stride);
  }

  if (SaveBgraToPngFile(cropped.data(), rw, rh, dst_stride,
                        g_overlay.target_path)) {
    FinishOverlayWithString(WideToUtf8(g_overlay.target_path));
  } else {
    FinishOverlayCancelled();
  }
}

// Gene - Nov, 13, 2026: Emit full Snagit recording settings wire format in SettleOverlayRecord and support Snagit idle presets & pre-recording toolbar in OverlayWndProc/StartWin32InteractiveOverlay.
// Old implementation:
// void SettleOverlayRecord(RECT r) {
//   int rx = g_overlay.virt_x + std::clamp(static_cast<int>(r.left), 0, g_overlay.virt_w);
//   int ry = g_overlay.virt_y + std::clamp(static_cast<int>(r.top), 0, g_overlay.virt_h);
//   int rw = std::clamp(static_cast<int>(r.right - r.left), 16, g_overlay.virt_w);
//   int rh = std::clamp(static_cast<int>(r.bottom - r.top), 16, g_overlay.virt_h);
//   std::ostringstream oss;
//   oss << "record:" << rx << ":" << ry << ":" << rw << ":" << rh;
//   FinishOverlayWithString(oss.str());
// }
void SettleOverlayRecord(RECT r, bool full_screen_flag) {
  int rx = g_overlay.virt_x + std::clamp(static_cast<int>(r.left), 0, g_overlay.virt_w);
  int ry = g_overlay.virt_y + std::clamp(static_cast<int>(r.top), 0, g_overlay.virt_h);
  int rw = std::clamp(static_cast<int>(r.right - r.left), 16, g_overlay.virt_w);
  int rh = std::clamp(static_cast<int>(r.bottom - r.top), 16, g_overlay.virt_h);
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
  int rw = std::min(target_w, g_overlay.virt_w);
  int rh = std::min(target_h, g_overlay.virt_h);
  int left = std::max(0, (g_overlay.virt_w - rw) / 2);
  int top = std::max(0, (g_overlay.virt_h - rh) / 2);
  g_overlay.sel = {left, top, left + rw, top + rh};
  g_overlay.has_selection = true;
  g_overlay.is_full_screen_preset = full_screen;
  g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
  if (g_overlay.hwnd) {
    ::InvalidateRect(g_overlay.hwnd, nullptr, FALSE);
  }
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

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                LPARAM lparam) {
  switch (msg) {
    case WM_KEYDOWN: {
      if (wparam == VK_ESCAPE) {
        FinishOverlayCancelled();
        return 0;
      }
      if (wparam == VK_RETURN || wparam == VK_SPACE) {
        bool full = !g_overlay.has_selection || g_overlay.is_full_screen_preset;
        RECT target = g_overlay.has_selection
                          ? g_overlay.sel
                          : RECT{0, 0, g_overlay.virt_w, g_overlay.virt_h};
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
          ApplyOverlayPresetSize(g_overlay.virt_w, g_overlay.virt_h, true);
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
          if (::PtInRect(&g_overlay.record_btn, pt)) {
            SettleOverlayRecord(g_overlay.sel, false);
            return 0;
          }
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
        g_overlay.sel.left = std::min(g_overlay.drag_start.x, pt.x);
        g_overlay.sel.top = std::min(g_overlay.drag_start.y, pt.y);
        g_overlay.sel.right = std::max(g_overlay.drag_start.x, pt.x);
        g_overlay.sel.bottom = std::max(g_overlay.drag_start.y, pt.y);
        ::InvalidateRect(hwnd, nullptr, FALSE);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving) {
        int dx = pt.x - g_overlay.drag_start.x;
        int dy = pt.y - g_overlay.drag_start.y;
        RECT r = g_overlay.sel_at_start;
        ::OffsetRect(&r, dx, dy);
        g_overlay.sel = r;
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      ::ReleaseCapture();
      if (g_overlay.mode == InteractiveOverlayState::Mode::kDrawing) {
        int w = g_overlay.sel.right - g_overlay.sel.left;
        int h = g_overlay.sel.bottom - g_overlay.sel.top;
        if (w < 8 || h < 8) {
          RECT full = {0, 0, g_overlay.virt_w, g_overlay.virt_h};
          if (g_overlay.initial_mode == "record") {
            g_overlay.sel = full;
            g_overlay.has_selection = true;
            g_overlay.is_full_screen_preset = true;
            g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
            ::InvalidateRect(hwnd, nullptr, FALSE);
          } else {
            SettleOverlayCapture(full);
          }
          return 0;
        }
        g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
        ::InvalidateRect(hwnd, nullptr, FALSE);
      } else if (g_overlay.mode == InteractiveOverlayState::Mode::kMoving) {
        g_overlay.mode = InteractiveOverlayState::Mode::kAdjusting;
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = ::BeginPaint(hwnd, &ps);
      HDC mem_dc = ::CreateCompatibleDC(hdc);
      HBITMAP buf_bmp =
          ::CreateCompatibleBitmap(hdc, g_overlay.virt_w, g_overlay.virt_h);
      HGDIOBJ old_bmp = ::SelectObject(mem_dc, buf_bmp);

      if (g_overlay.screen_bitmap) {
        HDC scr_dc = ::CreateCompatibleDC(hdc);
        HGDIOBJ old_scr = ::SelectObject(scr_dc, g_overlay.screen_bitmap);
        ::BitBlt(mem_dc, 0, 0, g_overlay.virt_w, g_overlay.virt_h, scr_dc, 0, 0,
                 SRCCOPY);
        ::SelectObject(scr_dc, old_scr);
        ::DeleteDC(scr_dc);
      }

      // Draw translucent dim overlay outside selection using msimg32 AlphaBlend
      {
        HDC dim_dc = ::CreateCompatibleDC(hdc);
        HBITMAP dim_bmp = ::CreateCompatibleBitmap(hdc, 1, 1);
        HGDIOBJ old_dim = ::SelectObject(dim_dc, dim_bmp);
        ::SetPixel(dim_dc, 0, 0, RGB(0, 0, 0));
        BLENDFUNCTION bf = {};
        bf.BlendOp = AC_SRC_OVER;
        bf.SourceConstantAlpha = 95;
        bf.AlphaFormat = 0;

        if (!g_overlay.has_selection) {
          ::AlphaBlend(mem_dc, 0, 0, g_overlay.virt_w, g_overlay.virt_h, dim_dc,
                       0, 0, 1, 1, bf);
        } else {
          int sl = std::clamp(static_cast<int>(g_overlay.sel.left), 0, g_overlay.virt_w);
          int st = std::clamp(static_cast<int>(g_overlay.sel.top), 0, g_overlay.virt_h);
          int sr = std::clamp(static_cast<int>(g_overlay.sel.right), 0, g_overlay.virt_w);
          int sb = std::clamp(static_cast<int>(g_overlay.sel.bottom), 0, g_overlay.virt_h);
          if (st > 0) {
            ::AlphaBlend(mem_dc, 0, 0, g_overlay.virt_w, st, dim_dc, 0, 0, 1, 1, bf);
          }
          if (sb < g_overlay.virt_h) {
            ::AlphaBlend(mem_dc, 0, sb, g_overlay.virt_w, g_overlay.virt_h - sb,
                         dim_dc, 0, 0, 1, 1, bf);
          }
          if (sl > 0 && sb > st) {
            ::AlphaBlend(mem_dc, 0, st, sl, sb - st, dim_dc, 0, 0, 1, 1, bf);
          }
          if (sr < g_overlay.virt_w && sb > st) {
            ::AlphaBlend(mem_dc, sr, st, g_overlay.virt_w - sr, sb - st, dim_dc,
                         0, 0, 1, 1, bf);
          }
        }
        ::SelectObject(dim_dc, old_dim);
        ::DeleteObject(dim_bmp);
        ::DeleteDC(dim_dc);
      }

      if (!g_overlay.has_selection && g_overlay.initial_mode == "record") {
        int btn_h = 34;
        int w_full = 104;
        int w_1080 = 96;
        int w_720 = 92;
        int w_can = 76;
        int gap = 8;
        int total_w = w_full + w_1080 + w_720 + w_can + gap * 3;
        int bx = std::max(12, (g_overlay.virt_w - total_w) / 2);
        int by = std::max(12, g_overlay.virt_h - btn_h - 48);

        g_overlay.preset_full_btn = {bx, by, bx + w_full, by + btn_h};
        int x2 = bx + w_full + gap;
        g_overlay.preset_1080_btn = {x2, by, x2 + w_1080, by + btn_h};
        int x3 = x2 + w_1080 + gap;
        g_overlay.preset_720_btn = {x3, by, x3 + w_720, by + btn_h};
        int x4 = x3 + w_720 + gap;
        g_overlay.cancel_btn = {x4, by, x4 + w_can, by + btn_h};

        DrawRoundedPill(mem_dc, g_overlay.preset_full_btn, RGB(34, 30, 28),
                        RGB(140, 118, 102), L"Full Screen", RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_overlay.preset_1080_btn, RGB(34, 30, 28),
                        RGB(140, 118, 102), L"1920x1080", RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_overlay.preset_720_btn, RGB(34, 30, 28),
                        RGB(140, 118, 102), L"1280x720", RGB(255, 255, 255));
        DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(50, 32, 32),
                        RGB(185, 70, 70), L"Cancel", RGB(255, 220, 220));
      }

      if (g_overlay.has_selection &&
          (g_overlay.sel.right > g_overlay.sel.left) &&
          (g_overlay.sel.bottom > g_overlay.sel.top)) {
        HPEN pen = ::CreatePen(PS_SOLID, 2, RGB(215, 65, 55));
        HGDIOBJ old_pen = ::SelectObject(mem_dc, pen);
        HGDIOBJ old_brush =
            ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
        ::Rectangle(mem_dc, g_overlay.sel.left, g_overlay.sel.top,
                    g_overlay.sel.right, g_overlay.sel.bottom);
        ::SelectObject(mem_dc, old_brush);
        ::SelectObject(mem_dc, old_pen);
        ::DeleteObject(pen);

        int sel_w = static_cast<int>(g_overlay.sel.right - g_overlay.sel.left);
        int sel_h = static_cast<int>(g_overlay.sel.bottom - g_overlay.sel.top);
        std::wostringstream dim_oss;
        dim_oss << sel_w << L" x " << sel_h;
        RECT dim_badge = {
            static_cast<LONG>(std::clamp(static_cast<int>(g_overlay.sel.left), 8,
                                         std::max(8, g_overlay.virt_w - 110))),
            static_cast<LONG>(std::max(8, static_cast<int>(g_overlay.sel.top) - 28)),
            0, 0};
        dim_badge.right = dim_badge.left + 104;
        dim_badge.bottom = dim_badge.top + 22;
        DrawRoundedPill(mem_dc, dim_badge, RGB(28, 22, 18), RGB(111, 78, 55),
                        dim_oss.str(), RGB(255, 255, 255));

        if (g_overlay.mode == InteractiveOverlayState::Mode::kAdjusting ||
            g_overlay.mode == InteractiveOverlayState::Mode::kMoving) {
          if (g_overlay.initial_mode == "record") {
            int btn_h = 34;
            int w_fps = 64;
            int w_mic = 78;
            int w_sys = 96;
            int w_cur = 88;
            int w_snip = 58;
            int w_rec = 74;
            int w_can = 34;
            int gap = 6;
            int total_w = w_fps + w_mic + w_sys + w_cur + w_snip + w_rec +
                          w_can + gap * 6;
            int bx = std::clamp(
                (static_cast<int>(g_overlay.sel.left) +
                 static_cast<int>(g_overlay.sel.right) - total_w) /
                    2,
                8, std::max(8, g_overlay.virt_w - total_w - 8));
            int by = static_cast<int>(g_overlay.sel.bottom) + 10;
            if (by + btn_h > g_overlay.virt_h - 10) {
              by = std::max(10, static_cast<int>(g_overlay.sel.bottom) - btn_h - 18);
            }

            int cx = bx;
            g_overlay.fps_btn = {cx, by, cx + w_fps, by + btn_h};
            cx += w_fps + gap;
            g_overlay.mic_btn = {cx, by, cx + w_mic, by + btn_h};
            cx += w_mic + gap;
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
                mem_dc, g_overlay.fps_btn, RGB(38, 32, 28), RGB(120, 100, 86),
                g_overlay.selected_fps == 60 ? L"60 FPS" : L"30 FPS",
                RGB(255, 255, 255));
            DrawRoundedPill(
                mem_dc, g_overlay.mic_btn,
                g_overlay.record_mic ? RGB(46, 105, 62) : RGB(38, 32, 28),
                RGB(120, 100, 86),
                g_overlay.record_mic ? L"Mic: On" : L"Mic: Off",
                RGB(255, 255, 255));
            DrawRoundedPill(
                mem_dc, g_overlay.sys_audio_btn,
                g_overlay.record_sys_audio ? RGB(46, 105, 62) : RGB(38, 32, 28),
                RGB(120, 100, 86),
                g_overlay.record_sys_audio ? L"Sys: On" : L"Sys: Off",
                RGB(255, 255, 255));
            DrawRoundedPill(
                mem_dc, g_overlay.cursor_btn,
                g_overlay.record_cursor ? RGB(46, 105, 62) : RGB(38, 32, 28),
                RGB(120, 100, 86),
                g_overlay.record_cursor ? L"Cursor: On" : L"Cursor: Off",
                RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.mode_snip_btn, RGB(58, 46, 38),
                            RGB(130, 105, 88), L"Snip", RGB(240, 232, 224));
            DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(205, 42, 42),
                            RGB(240, 90, 90), L"Rec", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                            RGB(110, 90, 78), L"X", RGB(255, 255, 255));
          } else {
            int btn_h = 30;
            int cap_w = 88;
            int rec_w = 88;
            int can_w = 32;
            int gap = 6;
            int total_w = cap_w + gap + rec_w + gap + can_w;
            int bx = std::clamp(
                static_cast<int>(g_overlay.sel.right) - total_w, 8,
                std::max(8, g_overlay.virt_w - total_w - 8));
            int by = static_cast<int>(g_overlay.sel.bottom) + 8;
            if (by + btn_h > g_overlay.virt_h - 8) {
              by = std::max(8, static_cast<int>(g_overlay.sel.top) - btn_h - 8);
            }

            g_overlay.capture_btn = {bx, by, bx + cap_w, by + btn_h};
            g_overlay.record_btn = {bx + cap_w + gap, by,
                                    bx + cap_w + gap + rec_w, by + btn_h};
            g_overlay.cancel_btn = {bx + cap_w + gap + rec_w + gap, by,
                                    bx + total_w, by + btn_h};

            DrawRoundedPill(mem_dc, g_overlay.capture_btn, RGB(111, 78, 55),
                            RGB(160, 122, 92), L"Capture", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.record_btn, RGB(185, 45, 45),
                            RGB(230, 85, 85), L"Record", RGB(255, 255, 255));
            DrawRoundedPill(mem_dc, g_overlay.cancel_btn, RGB(35, 25, 18),
                            RGB(110, 90, 78), L"X", RGB(255, 255, 255));
          }
        }
      }

      ::BitBlt(hdc, 0, 0, g_overlay.virt_w, g_overlay.virt_h, mem_dc, 0, 0,
               SRCCOPY);
      ::SelectObject(mem_dc, old_bmp);
      ::DeleteObject(buf_bmp);
      ::DeleteDC(mem_dc);
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

  g_overlay.virt_x = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  g_overlay.virt_y = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  g_overlay.virt_w = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  g_overlay.virt_h = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);

  if (!CaptureScreenRectBgra(g_overlay.virt_x, g_overlay.virt_y,
                             g_overlay.virt_w, g_overlay.virt_h,
                             &g_overlay.screen_bgra)) {
    FinishOverlayCancelled();
    return;
  }

  HDC screen_dc = ::GetDC(nullptr);
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = g_overlay.virt_w;
  bmi.bmiHeader.biHeight = -g_overlay.virt_h;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  g_overlay.screen_bitmap =
      ::CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (g_overlay.screen_bitmap && bits) {
    std::memcpy(bits, g_overlay.screen_bgra.data(),
                g_overlay.screen_bgra.size());
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

struct WinScreenRecorder {
  std::atomic<bool> active{false};
  std::atomic<bool> paused{false};
  std::atomic<bool> cancelled{false};
  std::atomic<bool> mic_muted{false};
  std::atomic<int> countdown_remaining{0};
  std::atomic<int64_t> elapsed_ms{0};
  std::atomic<bool> actual_has_audio{false};
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

    case WM_TIMER: {
      if (wparam == kHudTimerId) {
        int rem = g_recorder.countdown_remaining.load();
        bool want_countdown = rem > 0;
        if (want_countdown != g_recorder.hud_in_countdown_mode) {
          g_recorder.hud_in_countdown_mode = want_countdown;
          int sw = ::GetSystemMetrics(SM_CXSCREEN);
          int sh = ::GetSystemMetrics(SM_CYSCREEN);
          if (want_countdown) {
            int cw = 140;
            int ch = 140;
            ::SetWindowPos(hwnd, HWND_TOPMOST, (sw - cw) / 2, (sh - ch) / 2, cw,
                           ch, SWP_NOACTIVATE | SWP_SHOWWINDOW);
          } else {
            int pw = 372;
            int ph = 46;
            ::SetWindowPos(hwnd, HWND_TOPMOST, (sw - pw) / 2, 24, pw, ph,
                           SWP_NOACTIVATE | SWP_SHOWWINDOW);
          }
        }
        ::InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }

    case WM_LBUTTONDOWN: {
      if (g_recorder.countdown_remaining.load() > 0) return 0;
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
        ::SetTextColor(mem_dc, RGB(255, 255, 255));
        std::wstring num = std::to_wstring(rem);
        HFONT big_font = ::CreateFontW(
            68, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
            OUT_OUTLINE_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            VARIABLE_PITCH, L"Segoe UI");
        HGDIOBJ old_f = ::SelectObject(mem_dc, big_font);
        ::DrawTextW(mem_dc, num.c_str(), -1, &client,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        ::SelectObject(mem_dc, old_f);
        ::DeleteObject(big_font);
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

    int sw = ::GetSystemMetrics(SM_CXSCREEN);
    int sh = ::GetSystemMetrics(SM_CYSCREEN);
    int win_w = countdown_seconds > 0 ? 140 : 372;
    int win_h = countdown_seconds > 0 ? 140 : 46;
    int win_x = (sw - win_w) / 2;
    int win_y = countdown_seconds > 0 ? (sh - win_h) / 2 : 24;

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

// Gene - Nov, 13, 2026: Updated StopWinRecordingSession and StartWinRecordingSession with HUD teardown, main-window restore, countdown wait, cursor/click overlay, and WASAPI loopback+mic AAC mixer.
// Old implementation:
// void StopWinRecordingSession(bool cancel,
//                              std::unique_ptr<CaptureMethodResult> result) {
//   if (!g_recorder.active.load()) {
//     if (result) result->Success(EncodableValue());
//     return;
//   }
//   if (cancel) g_recorder.cancelled.store(true);
//   g_recorder.active.store(false);
//   if (g_recorder.worker.joinable()) {
//     g_recorder.worker.join();
//   }
//
//   if (cancel || g_recorder.cancelled.load()) {
//     ::DeleteFileW(g_recorder.target_path.c_str());
//     ::DeleteFileW(g_recorder.thumbnail_path.c_str());
//     if (result) result->Success(EncodableValue());
//     return;
//   }
//
//   EncodableMap map;
//   map[EncodableValue("filePath")] =
//       EncodableValue(WideToUtf8(g_recorder.target_path));
//   map[EncodableValue("thumbnailPath")] =
//       EncodableValue(WideToUtf8(g_recorder.thumbnail_path));
//   map[EncodableValue("width")] = EncodableValue(g_recorder.rec_w);
//   map[EncodableValue("height")] = EncodableValue(g_recorder.rec_h);
//   map[EncodableValue("durationMs")] =
//       EncodableValue(static_cast<int64_t>(g_recorder.elapsed_ms.load()));
//   map[EncodableValue("hasAudio")] = EncodableValue(g_recorder.record_audio);
//   if (result) result->Success(EncodableValue(map));
// }
WinScreenRecorder g_recorder;

void StopWinRecordingSession(bool cancel,
                             std::unique_ptr<CaptureMethodResult> result) {
  if (!g_recorder.active.load()) {
    CloseRecordingHudWindow();
    SetMainWindowVisible(true);
    if (result) result->Success(EncodableValue());
    return;
  }
  if (cancel) g_recorder.cancelled.store(true);
  g_recorder.active.store(false);
  g_recorder.countdown_remaining.store(0);
  if (g_recorder.worker.joinable()) {
    g_recorder.worker.join();
  }
  CloseRecordingHudWindow();
  SetMainWindowVisible(true);

  if (cancel || g_recorder.cancelled.load()) {
    ::DeleteFileW(g_recorder.target_path.c_str());
    ::DeleteFileW(g_recorder.thumbnail_path.c_str());
    if (result) {
      result->Success(EncodableValue());
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
  if (result) {
    result->Success(EncodableValue(map));
  } else {
    InvokeDartMethod("onRecordingStopped", EncodableValue(map));
  }
}

bool StartWinRecordingSession(
    const std::wstring& target_path, const std::wstring& thumbnail_path, int x,
    int y, int width, int height, int fps, bool record_audio,
    const std::string& mic_device_id, bool record_system_audio,
    bool record_cursor, bool highlight_clicks, int countdown_seconds) {
  if (g_recorder.active.load()) return false;

  int even_w = (width % 2 == 0) ? width : (width - 1);
  int even_h = (height % 2 == 0) ? height : (height - 1);
  if (even_w < 16 || even_h < 16) return false;

  int clamped_countdown = std::clamp(countdown_seconds, 0, 10);
  g_recorder.target_path = target_path;
  g_recorder.thumbnail_path = thumbnail_path;
  g_recorder.mic_device_id = mic_device_id;
  g_recorder.rec_x = x;
  g_recorder.rec_y = y;
  g_recorder.rec_w = even_w;
  g_recorder.rec_h = even_h;
  g_recorder.fps = std::clamp(fps, 15, 60);
  g_recorder.record_audio = record_audio;
  g_recorder.record_system_audio = record_system_audio;
  g_recorder.record_cursor = record_cursor;
  g_recorder.highlight_clicks = highlight_clicks;
  g_recorder.paused.store(false);
  g_recorder.cancelled.store(false);
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
      ::MFSetAttributeSize(out_type.Get(), MF_MT_FRAME_SIZE, w, h);
      ::MFSetAttributeRatio(out_type.Get(), MF_MT_FRAME_RATE, rec_fps, 1);
      ::MFSetAttributeRatio(out_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
      hr = writer->AddStream(out_type.Get(), &video_stream_index);
    }

    if (SUCCEEDED(hr)) {
      ComPtr<IMFMediaType> in_type;
      ::MFCreateMediaType(&in_type);
      in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
      ::MFSetAttributeSize(in_type.Get(), MF_MT_FRAME_SIZE, w, h);
      ::MFSetAttributeRatio(in_type.Get(), MF_MT_FRAME_RATE, rec_fps, 1);
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

    if (writer && !g_recorder.cancelled.load()) {
      writer->Finalize();
    }
    writer.Reset();
    ::MFShutdown();
    ::CoUninitialize();
  });

  return true;
}

// Extracts a single video frame at `timestamp_ms` from `video_path` into `target_png_path`.
bool ExtractVideoFrameAtMs(const std::wstring& video_path, int64_t timestamp_ms,
                           const std::wstring& target_png_path) {
  ::MFStartup(MF_VERSION);
  ComPtr<IMFSourceReader> reader;
  HRESULT hr = ::MFCreateSourceReaderFromURL(video_path.c_str(), nullptr, &reader);
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
  if (actual_type) {
    ::MFGetAttributeSize(actual_type.Get(), MF_MT_FRAME_SIZE, &w, &h);
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
        if (w > 0 && h > 0 && len >= w * h * 4) {
          ok = SaveBgraToPngFile(data, static_cast<int>(w), static_cast<int>(h),
                                 static_cast<int>(w * 4), target_png_path);
        }
        buf->Unlock();
      }
    }
  }

  ::MFShutdown();
  return ok;
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
        if (need_clock_anchor) {
          wall_anchor = std::chrono::steady_clock::now();
          media_anchor_ms = frame_ms;
          need_clock_anchor = false;
        } else {
          float cur_spd = std::clamp(speed.load(), 0.25f, 4.0f);
          int64_t target_wall_ms = static_cast<int64_t>(
              static_cast<double>(frame_ms - media_anchor_ms) / cur_spd);
          auto due = wall_anchor + std::chrono::milliseconds(target_wall_ms);
          while (!disposed.load() && playing.load() &&
                 seek_request_ms.load() < 0 &&
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

  void Play() { playing.store(true); }
  void Pause() { playing.store(false); }
  void Seek(int64_t ms) { seek_request_ms.store(ms); }
  void SetVolume(float v) { volume.store(std::clamp(v, 0.0f, 1.0f)); }
  void SetMuted(bool m) { muted.store(m); }
  void SetSpeed(float s) { speed.store(std::clamp(s, 0.25f, 4.0f)); }

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
          int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
          int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
          int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
          int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
          std::vector<uint8_t> bgra;
          if (CaptureScreenRectBgra(vx, vy, vw, vh, &bgra) &&
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
          // Gene - Nov, 13, 2026: Replaced CopyFileW placeholder with real Media Foundation segment transcoder.
          // Old implementation:
          // std::string video_path = get_str("videoPath");
          // std::string target_path = get_str("targetPath");
          // if (!video_path.empty() && !target_path.empty() &&
          //     ::CopyFileW(Utf8ToWide(video_path).c_str(),
          //                 Utf8ToWide(target_path).c_str(), FALSE)) {
          //   result->Success(EncodableValue(target_path));
          // } else {
          //   result->Success(EncodableValue());
          // }
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t start_ms = std::max<int64_t>(0, get_int64("startMs", 0));
          int64_t end_ms = get_int64("endMs", 0);
          if (end_ms <= start_ms) {
            end_ms = QueryVideoDurationMs(Utf8ToWide(video_path));
          }
          int64_t out_dur = 0;
          if (!video_path.empty() && !target_path.empty() &&
              end_ms > start_ms &&
              TranscodeVideoSegments(Utf8ToWide(video_path),
                                     Utf8ToWide(target_path),
                                     {{start_ms, end_ms}}, &out_dur)) {
            result->Success(EncodableValue(target_path));
          } else {
            result->Success(EncodableValue());
          }
          return;
        }

        // Gene - Nov, 13, 2026: Added cutVideo and native PixelBufferTexture video player handlers.
        if (method == "cutVideo") {
          std::string video_path = get_str("videoPath");
          std::string target_path = get_str("targetPath");
          int64_t cut_start = std::max<int64_t>(0, get_int64("cutStartMs", 0));
          int64_t cut_end = std::max<int64_t>(cut_start, get_int64("cutEndMs", 0));
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
          if (!video_path.empty() && !target_path.empty() &&
              !keep_segments.empty() &&
              TranscodeVideoSegments(wide_src, Utf8ToWide(target_path),
                                     keep_segments, &out_dur)) {
            EncodableMap res;
            res[EncodableValue("filePath")] = EncodableValue(target_path);
            res[EncodableValue("durationMs")] = EncodableValue(out_dur);
            result->Success(EncodableValue(res));
          } else {
            result->Success(EncodableValue());
          }
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
  if (g_recorder.active.load()) {
    g_recorder.cancelled.store(true);
    g_recorder.active.store(false);
    g_recorder.countdown_remaining.store(0);
    if (g_recorder.worker.joinable()) {
      g_recorder.worker.join();
    }
  }
  CloseRecordingHudWindow();
  auto gate = Gate();
  if (!gate) return;
  std::lock_guard<std::mutex> lock(gate->mutex);
  gate->engine = nullptr;
  gate->registrar = nullptr;
  gate->texture_registrar = nullptr;
  gate->channel.reset();
}
