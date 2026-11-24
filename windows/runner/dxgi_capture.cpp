// Gene - Nov, 24, 2026: Fast DXGI Desktop Duplication + Persistent GDI Screen Grabber implementation.
#include "dxgi_capture.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

// ---------------------------------------------------------------------------
// Monitor Enumeration & DPI Helpers
// ---------------------------------------------------------------------------

// Gene - Nov, 24, 2026: Fix LONG cast in monitor enumeration, retry once on DXGI LastPresentTime==0 blank frames, and cache shcore GetDpiForMonitor once.
// Old implementation (EnumMonitorRectsProc width/height, TryCaptureSubRect AcquireNextFrame single-shot, GetMonitorDpi LoadLibrary per call):
//   info.width = std::max(0L, mi.rcMonitor.right - mi.rcMonitor.left);
//   info.height = std::max(0L, mi.rcMonitor.bottom - mi.rcMonitor.top);
//   HRESULT hr = slot->duplication->AcquireNextFrame(timeout_ms, &frame_info, &desktop_res); ...
//   HMODULE shcore = ::LoadLibraryW(L"shcore.dll"); ... ::FreeLibrary(shcore);
BOOL CALLBACK EnumMonitorRectsProc(HMONITOR hmon, HDC, LPRECT, LPARAM data) {
  auto* out = reinterpret_cast<std::vector<CapturedMonitorFrame>*>(data);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (::GetMonitorInfoW(hmon, &mi)) {
    CapturedMonitorFrame info;
    info.hmon = hmon;
    info.monitor_rect = mi.rcMonitor;
    info.width =
        static_cast<int>(std::max<LONG>(0L, mi.rcMonitor.right - mi.rcMonitor.left));
    info.height =
        static_cast<int>(std::max<LONG>(0L, mi.rcMonitor.bottom - mi.rcMonitor.top));
    info.dpi = GetMonitorDpi(hmon);
    if (info.width > 0 && info.height > 0) {
      out->push_back(std::move(info));
    }
  }
  return TRUE;
}

void ForceOpaqueAlphaInPlace(uint8_t* bgra, size_t byte_count) {
  for (size_t i = 3; i < byte_count; i += 4) {
    bgra[i] = 0xFF;
  }
}

void DrawCursorOntoDc(HDC mem_dc, int origin_x, int origin_y) {
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
    ::DrawIconEx(mem_dc, ci.ptScreenPos.x - origin_x - hot_x,
                 ci.ptScreenPos.y - origin_y - hot_y, ci.hCursor, 0, 0, 0,
                 nullptr, DI_NORMAL);
  }
}

// ---------------------------------------------------------------------------
// Per-Monitor DXGI Desktop Duplication Cache
// ---------------------------------------------------------------------------

struct DxgiOutputSlot {
  HMONITOR hmon = nullptr;
  RECT monitor_rect = {0, 0, 0, 0};
  int width = 0;
  int height = 0;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> ctx;
  ComPtr<IDXGIOutputDuplication> duplication;
  ComPtr<ID3D11Texture2D> staging;
  bool has_valid_frame = false;

  void Reset() {
    has_valid_frame = false;
    staging.Reset();
    duplication.Reset();
    ctx.Reset();
    device.Reset();
    hmon = nullptr;
    monitor_rect = {0, 0, 0, 0};
    width = 0;
    height = 0;
  }
};

class DxgiDuplicatorManager {
 public:
  void Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& slot : slots_) {
      slot.Reset();
    }
    slots_.clear();
  }

  bool TryCaptureSubRect(HMONITOR hmon, const RECT& mon_rect, int crop_x,
                         int crop_y, int crop_w, int crop_h,
                         bool allow_cached_frame, uint8_t* opt_dst_bgra,
                         int opt_dst_stride, std::vector<uint8_t>* out_vec) {
    if (!hmon || crop_w <= 0 || crop_h <= 0) return false;
    std::lock_guard<std::mutex> lock(mutex_);

    DxgiOutputSlot* slot = FindOrCreateSlot(hmon, mon_rect);
    if (!slot || !slot->duplication || !slot->staging || !slot->ctx) {
      return false;
    }
    if (crop_x < 0 || crop_y < 0 || crop_x + crop_w > slot->width ||
        crop_y + crop_h > slot->height) {
      return false;
    }

    // Gene - Nov, 24, 2026: Retry once on initial pointer-only/blank DXGI frames (LastPresentTime == 0) and return false cleanly on timeout without waiting 8ms when staging already holds pixels.
    // Old implementation:
    // DXGI_OUTDUPL_FRAME_INFO frame_info = {};
    // ComPtr<IDXGIResource> desktop_res;
    // UINT timeout_ms = allow_cached_frame ? 0 : 8;
    // HRESULT hr = slot->duplication->AcquireNextFrame(timeout_ms, &frame_info,
    //                                                  &desktop_res);
    // if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
    //   if (!allow_cached_frame || !slot->has_valid_frame) {
    //     return false;
    //   }
    //   return ReadStagingSubRect(slot, crop_x, crop_y, crop_w, crop_h,
    //                             opt_dst_bgra, opt_dst_stride, out_vec);
    // }
    // if (hr == DXGI_ERROR_ACCESS_LOST || hr == DXGI_ERROR_INVALID_CALL) {
    //   slot->Reset();
    //   return false;
    // }
    // if (FAILED(hr) || !desktop_res) {
    //   return false;
    // }
    // ComPtr<ID3D11Texture2D> desktop_tex;
    // hr = desktop_res->QueryInterface(IID_PPV_ARGS(&desktop_tex));
    // if (SUCCEEDED(hr) && desktop_tex) {
    //   D3D11_TEXTURE2D_DESC desc = {};
    //   desktop_tex->GetDesc(&desc);
    //   if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
    //       static_cast<int>(desc.Width) != slot->width ||
    //       static_cast<int>(desc.Height) != slot->height) {
    //     slot->duplication->ReleaseFrame();
    //     slot->Reset();
    //     return false;
    //   }
    //   slot->ctx->CopyResource(slot->staging.Get(), desktop_tex.Get());
    //   slot->has_valid_frame = true;
    // }
    // slot->duplication->ReleaseFrame();
    for (int attempt = 0; attempt < 2; ++attempt) {
      DXGI_OUTDUPL_FRAME_INFO frame_info = {};
      ComPtr<IDXGIResource> desktop_res;
      UINT timeout_ms = slot->has_valid_frame ? 0 : 16;
      HRESULT hr = slot->duplication->AcquireNextFrame(timeout_ms, &frame_info,
                                                       &desktop_res);
      if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        if (!allow_cached_frame || !slot->has_valid_frame) {
          return false;
        }
        return ReadStagingSubRect(slot, crop_x, crop_y, crop_w, crop_h,
                                  opt_dst_bgra, opt_dst_stride, out_vec);
      }

      if (hr == DXGI_ERROR_ACCESS_LOST || hr == DXGI_ERROR_INVALID_CALL) {
        slot->Reset();
        return false;
      }
      if (FAILED(hr) || !desktop_res) {
        return false;
      }

      if (frame_info.LastPresentTime.QuadPart == 0) {
        slot->duplication->ReleaseFrame();
        if (slot->has_valid_frame) {
          break;
        }
        continue;
      }

      ComPtr<ID3D11Texture2D> desktop_tex;
      hr = desktop_res->QueryInterface(IID_PPV_ARGS(&desktop_tex));
      if (SUCCEEDED(hr) && desktop_tex) {
        D3D11_TEXTURE2D_DESC desc = {};
        desktop_tex->GetDesc(&desc);
        // Skip non-BGRA8 (e.g. 10-bit/16-bit HDR) so GDI DWM tone-maps cleanly.
        if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
            static_cast<int>(desc.Width) != slot->width ||
            static_cast<int>(desc.Height) != slot->height) {
          slot->duplication->ReleaseFrame();
          slot->Reset();
          return false;
        }
        slot->ctx->CopyResource(slot->staging.Get(), desktop_tex.Get());
        slot->has_valid_frame = true;
      }
      slot->duplication->ReleaseFrame();
      break;
    }

    if (!slot->has_valid_frame) return false;
    return ReadStagingSubRect(slot, crop_x, crop_y, crop_w, crop_h,
                              opt_dst_bgra, opt_dst_stride, out_vec);
  }

 private:
  std::mutex mutex_;
  std::vector<DxgiOutputSlot> slots_;

  static bool ReadStagingSubRect(DxgiOutputSlot* slot, int crop_x, int crop_y,
                                 int crop_w, int crop_h, uint8_t* opt_dst_bgra,
                                 int opt_dst_stride,
                                 std::vector<uint8_t>* out_vec) {
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    HRESULT hr =
        slot->ctx->Map(slot->staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr) || !mapped.pData) {
      return false;
    }

    const size_t row_bytes = static_cast<size_t>(crop_w) * 4;
    uint8_t* dst_ptr = opt_dst_bgra;
    size_t dst_stride = static_cast<size_t>(opt_dst_stride);
    if (!dst_ptr) {
      if (!out_vec) {
        slot->ctx->Unmap(slot->staging.Get(), 0);
        return false;
      }
      out_vec->resize(row_bytes * static_cast<size_t>(crop_h));
      dst_ptr = out_vec->data();
      dst_stride = row_bytes;
    }

    const uint8_t* src_base = static_cast<const uint8_t*>(mapped.pData);
    for (int y = 0; y < crop_h; ++y) {
      const uint8_t* srow =
          src_base +
          static_cast<size_t>(crop_y + y) * static_cast<size_t>(mapped.RowPitch) +
          static_cast<size_t>(crop_x) * 4;
      uint8_t* drow = dst_ptr + static_cast<size_t>(y) * dst_stride;
      std::memcpy(drow, srow, row_bytes);
      ForceOpaqueAlphaInPlace(drow, row_bytes);
    }

    slot->ctx->Unmap(slot->staging.Get(), 0);
    return true;
  }

  DxgiOutputSlot* FindOrCreateSlot(HMONITOR hmon, const RECT& mon_rect) {
    int mon_w = static_cast<int>(mon_rect.right - mon_rect.left);
    int mon_h = static_cast<int>(mon_rect.bottom - mon_rect.top);
    for (auto& s : slots_) {
      if (s.hmon == hmon) {
        if (s.width == mon_w && s.height == mon_h &&
            s.monitor_rect.left == mon_rect.left &&
            s.monitor_rect.top == mon_rect.top && s.duplication) {
          return &s;
        }
        s.Reset();
        if (InitSlotForMonitor(hmon, mon_rect, &s)) {
          return &s;
        }
        return nullptr;
      }
    }

    DxgiOutputSlot fresh;
    if (!InitSlotForMonitor(hmon, mon_rect, &fresh)) {
      return nullptr;
    }
    slots_.push_back(std::move(fresh));
    return &slots_.back();
  }

  static bool InitSlotForMonitor(HMONITOR hmon, const RECT& mon_rect,
                                 DxgiOutputSlot* out_slot) {
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory))) || !factory) {
      return false;
    }

    ComPtr<IDXGIAdapter1> matched_adapter;
    ComPtr<IDXGIOutput> matched_output;
    DXGI_OUTPUT_DESC matched_desc = {};

    for (UINT a = 0;; ++a) {
      ComPtr<IDXGIAdapter1> adapter;
      if (factory->EnumAdapters1(a, &adapter) == DXGI_ERROR_NOT_FOUND) break;
      if (!adapter) continue;

      for (UINT o = 0;; ++o) {
        ComPtr<IDXGIOutput> output;
        if (adapter->EnumOutputs(o, &output) == DXGI_ERROR_NOT_FOUND) break;
        if (!output) continue;
        DXGI_OUTPUT_DESC desc = {};
        if (SUCCEEDED(output->GetDesc(&desc)) && desc.Monitor == hmon) {
          matched_adapter = adapter;
          matched_output = output;
          matched_desc = desc;
          break;
        }
      }
      if (matched_output) break;
    }

    if (!matched_adapter || !matched_output) return false;
    if (matched_desc.Rotation != DXGI_MODE_ROTATION_IDENTITY &&
        matched_desc.Rotation != DXGI_MODE_ROTATION_UNSPECIFIED) {
      return false;
    }

    int w = static_cast<int>(mon_rect.right - mon_rect.left);
    int h = static_cast<int>(mon_rect.bottom - mon_rect.top);
    if (w <= 0 || h <= 0) return false;

    D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_0,
    };
    D3D_FEATURE_LEVEL chosen = D3D_FEATURE_LEVEL_11_0;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> ctx;
    HRESULT hr = ::D3D11CreateDevice(
        matched_adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
        static_cast<UINT>(sizeof(levels) / sizeof(levels[0])),
        D3D11_SDK_VERSION, &device, &chosen, &ctx);
    if (FAILED(hr) || !device || !ctx) return false;

    ComPtr<IDXGIOutput1> output1;
    hr = matched_output.As(&output1);
    if (FAILED(hr) || !output1) return false;

    ComPtr<IDXGIOutputDuplication> duplication;
    hr = output1->DuplicateOutput(device.Get(), &duplication);
    if (FAILED(hr) || !duplication) return false;

    DXGI_OUTDUPL_DESC dupl_desc = {};
    duplication->GetDesc(&dupl_desc);
    if (static_cast<int>(dupl_desc.ModeDesc.Width) != w ||
        static_cast<int>(dupl_desc.ModeDesc.Height) != h ||
        dupl_desc.ModeDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
      return false;
    }

    D3D11_TEXTURE2D_DESC st_desc = {};
    st_desc.Width = static_cast<UINT>(w);
    st_desc.Height = static_cast<UINT>(h);
    st_desc.MipLevels = 1;
    st_desc.ArraySize = 1;
    st_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    st_desc.SampleDesc.Count = 1;
    st_desc.Usage = D3D11_USAGE_STAGING;
    st_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    ComPtr<ID3D11Texture2D> staging;
    hr = device->CreateTexture2D(&st_desc, nullptr, &staging);
    if (FAILED(hr) || !staging) return false;

    out_slot->hmon = hmon;
    out_slot->monitor_rect = mon_rect;
    out_slot->width = w;
    out_slot->height = h;
    out_slot->device = device;
    out_slot->ctx = ctx;
    out_slot->duplication = duplication;
    out_slot->staging = staging;
    out_slot->has_valid_frame = false;
    return true;
  }
};

DxgiDuplicatorManager& Duplicator() {
  static DxgiDuplicatorManager mgr;
  return mgr;
}

}  // namespace

// ---------------------------------------------------------------------------
// PersistentGdiRectGrabber
// ---------------------------------------------------------------------------

PersistentGdiRectGrabber::~PersistentGdiRectGrabber() { Reset(); }

void PersistentGdiRectGrabber::Reset() {
  if (mem_dc_ && old_bmp_) {
    ::SelectObject(mem_dc_, old_bmp_);
    old_bmp_ = nullptr;
  }
  if (dib_) {
    ::DeleteObject(dib_);
    dib_ = nullptr;
  }
  if (mem_dc_) {
    ::DeleteDC(mem_dc_);
    mem_dc_ = nullptr;
  }
  if (screen_dc_) {
    ::ReleaseDC(nullptr, screen_dc_);
    screen_dc_ = nullptr;
  }
  bits_ = nullptr;
  width_ = 0;
  height_ = 0;
}

bool PersistentGdiRectGrabber::EnsureSize(int w, int h) {
  if (w <= 0 || h <= 0) return false;
  if (bits_ && w == width_ && h == height_) return true;
  Reset();

  screen_dc_ = ::GetDC(nullptr);
  if (!screen_dc_) return false;
  mem_dc_ = ::CreateCompatibleDC(screen_dc_);
  if (!mem_dc_) {
    Reset();
    return false;
  }

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = w;
  bmi.bmiHeader.biHeight = -h;  // Top-down 32bpp BGRA
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* raw = nullptr;
  dib_ =
      ::CreateDIBSection(mem_dc_, &bmi, DIB_RGB_COLORS, &raw, nullptr, 0);
  if (!dib_ || !raw) {
    Reset();
    return false;
  }
  old_bmp_ = ::SelectObject(mem_dc_, dib_);
  bits_ = static_cast<uint8_t*>(raw);
  width_ = w;
  height_ = h;
  return true;
}

void PersistentGdiRectGrabber::DrawCursorOnDib(int origin_x, int origin_y) {
  if (!mem_dc_) return;
  DrawCursorOntoDc(mem_dc_, origin_x, origin_y);
}

void PersistentGdiRectGrabber::CopyDibToBgra(std::vector<uint8_t>* out_bgra) {
  if (!out_bgra || !bits_ || width_ <= 0 || height_ <= 0) return;
  ::GdiFlush();
  size_t byte_count =
      static_cast<size_t>(width_) * static_cast<size_t>(height_) * 4;
  out_bgra->resize(byte_count);
  std::memcpy(out_bgra->data(), bits_, byte_count);
  ForceOpaqueAlphaInPlace(out_bgra->data(), byte_count);
}

bool PersistentGdiRectGrabber::Capture(int x, int y, int w, int h,
                                       bool draw_cursor,
                                       std::vector<uint8_t>* out_bgra) {
  if (!out_bgra || !EnsureSize(w, h)) return false;
  if (!::BitBlt(mem_dc_, 0, 0, w, h, screen_dc_, x, y, SRCCOPY)) {
    return false;
  }
  if (draw_cursor) {
    DrawCursorOntoDc(mem_dc_, x, y);
  }
  CopyDibToBgra(out_bgra);
  return true;
}

// ---------------------------------------------------------------------------
// Public Capture Helpers
// ---------------------------------------------------------------------------

// Gene - Nov, 24, 2026: Cache shcore GetDpiForMonitor lookup once instead of loading/freeing per call.
// Old implementation:
// UINT GetMonitorDpi(HMONITOR hmon) {
//   if (hmon) {
//     HMODULE shcore = ::LoadLibraryW(L"shcore.dll");
//     if (shcore) {
//       ...
//       ::FreeLibrary(shcore);
//     }
//   }
//   ...
// }
UINT GetMonitorDpi(HMONITOR hmon) {
  using GetDpiForMonitorFn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
  static GetDpiForMonitorFn cached_fn = []() -> GetDpiForMonitorFn {
    static HMODULE shcore = ::LoadLibraryW(L"shcore.dll");
    if (!shcore) return nullptr;
    return reinterpret_cast<GetDpiForMonitorFn>(
        ::GetProcAddress(shcore, "GetDpiForMonitor"));
  }();
  if (hmon && cached_fn) {
    UINT dpi_x = 96;
    UINT dpi_y = 96;
    if (SUCCEEDED(cached_fn(hmon, 0 /* MDT_EFFECTIVE_DPI */, &dpi_x, &dpi_y)) &&
        dpi_x > 0) {
      return dpi_x;
    }
  }
  HDC dc = ::GetDC(nullptr);
  UINT dpi = dc ? static_cast<UINT>(::GetDeviceCaps(dc, LOGPIXELSX)) : 96u;
  if (dc) ::ReleaseDC(nullptr, dc);
  return dpi > 0 ? dpi : 96u;
}

std::vector<CapturedMonitorFrame> EnumeratePhysicalMonitors() {
  std::vector<CapturedMonitorFrame> monitors;
  ::EnumDisplayMonitors(nullptr, nullptr, EnumMonitorRectsProc,
                        reinterpret_cast<LPARAM>(&monitors));
  return monitors;
}

bool CaptureSingleMonitorFast(HMONITOR hmon, const RECT& mon_rect,
                              std::vector<uint8_t>* out_bgra) {
  if (!out_bgra) return false;
  int w = static_cast<int>(mon_rect.right - mon_rect.left);
  int h = static_cast<int>(mon_rect.bottom - mon_rect.top);
  if (w <= 0 || h <= 0) return false;

  if (hmon && Duplicator().TryCaptureSubRect(hmon, mon_rect, 0, 0, w, h, false,
                                             nullptr, 0, out_bgra)) {
    return true;
  }

  PersistentGdiRectGrabber gdi;
  return gdi.Capture(static_cast<int>(mon_rect.left),
                     static_cast<int>(mon_rect.top), w, h, false, out_bgra);
}

bool CaptureAllMonitorsFast(std::vector<CapturedMonitorFrame>* out_monitors) {
  if (!out_monitors) return false;
  *out_monitors = EnumeratePhysicalMonitors();
  if (out_monitors->empty()) return false;

  PersistentGdiRectGrabber gdi;
  bool any_ok = false;
  for (auto& mon : *out_monitors) {
    if (Duplicator().TryCaptureSubRect(mon.hmon, mon.monitor_rect, 0, 0,
                                       mon.width, mon.height, false, nullptr, 0,
                                       &mon.bgra)) {
      any_ok = true;
    } else if (gdi.Capture(static_cast<int>(mon.monitor_rect.left),
                           static_cast<int>(mon.monitor_rect.top), mon.width,
                           mon.height, false, &mon.bgra)) {
      any_ok = true;
    }
  }
  return any_ok;
}

bool CaptureRectFast(int x, int y, int width, int height, bool draw_cursor,
                     bool allow_cached_frame,
                     PersistentGdiRectGrabber* gdi_scratch,
                     std::vector<uint8_t>* out_bgra) {
  if (width <= 0 || height <= 0 || !out_bgra) return false;

  RECT req_rect = {x, y, x + width, y + height};
  HMONITOR hmon = ::MonitorFromRect(&req_rect, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (hmon && ::GetMonitorInfoW(hmon, &mi)) {
    const RECT& mr = mi.rcMonitor;
    if (req_rect.left >= mr.left && req_rect.top >= mr.top &&
        req_rect.right <= mr.right && req_rect.bottom <= mr.bottom) {
      int lx = static_cast<int>(req_rect.left - mr.left);
      int ly = static_cast<int>(req_rect.top - mr.top);
      if (draw_cursor && gdi_scratch && gdi_scratch->EnsureSize(width, height)) {
        if (Duplicator().TryCaptureSubRect(
                hmon, mr, lx, ly, width, height, allow_cached_frame,
                gdi_scratch->MutableBits(), width * 4, nullptr)) {
          gdi_scratch->DrawCursorOnDib(x, y);
          gdi_scratch->CopyDibToBgra(out_bgra);
          return true;
        }
      } else if (!draw_cursor) {
        if (Duplicator().TryCaptureSubRect(hmon, mr, lx, ly, width, height,
                                           allow_cached_frame, nullptr, 0,
                                           out_bgra)) {
          return true;
        }
      }
    }
  }

  if (gdi_scratch) {
    return gdi_scratch->Capture(x, y, width, height, draw_cursor, out_bgra);
  }
  PersistentGdiRectGrabber temp_gdi;
  return temp_gdi.Capture(x, y, width, height, draw_cursor, out_bgra);
}

void ResetDxgiCapture() { Duplicator().Reset(); }
