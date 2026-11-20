// Gene - Nov, 20, 2026: Windows scrolling capture implementation backed by Rust snipsnap_core staticlib,
// Windows.Graphics.Capture (D3D11) with persistent-DC GDI fallback, and WDA_EXCLUDEFROMCAPTURE floating HUD.
#include "scrolling_capture_engine.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <windowsx.h>
#include <unknwn.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <inspectable.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "snipsnap_core.h"

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

#ifndef LLMHF_INJECTED
#define LLMHF_INJECTED 0x00000001
#endif

namespace {

constexpr UINT kMsgUpdateHud = WM_APP + 101;
constexpr UINT kMsgCloseWindows = WM_APP + 102;
constexpr UINT_PTR kAutoScrollTimerId = 1;

std::wstring Utf8ToWideLocal(const std::string& utf8) {
  if (utf8.empty()) return {};
  int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) return {};
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), out.data(), len);
  return out;
}

void DrawHudPill(HDC hdc,
                 const RECT& r,
                 COLORREF fill,
                 COLORREF border,
                 const std::wstring& label,
                 COLORREF text_color) {
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

// Persistent GDI screen region grabber used as fallback when WGC is unavailable.
struct PersistentGdiGrabber {
  HDC screen_dc = nullptr;
  HDC mem_dc = nullptr;
  HBITMAP dib = nullptr;
  HGDIOBJ old_bmp = nullptr;
  uint8_t* bits = nullptr;
  int width = 0;
  int height = 0;

  ~PersistentGdiGrabber() { Reset(); }

  void Reset() {
    if (mem_dc && old_bmp) {
      ::SelectObject(mem_dc, old_bmp);
      old_bmp = nullptr;
    }
    if (dib) {
      ::DeleteObject(dib);
      dib = nullptr;
    }
    if (mem_dc) {
      ::DeleteDC(mem_dc);
      mem_dc = nullptr;
    }
    if (screen_dc) {
      ::ReleaseDC(nullptr, screen_dc);
      screen_dc = nullptr;
    }
    bits = nullptr;
    width = 0;
    height = 0;
  }

  bool EnsureSize(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    if (bits && w == width && h == height) return true;
    Reset();
    screen_dc = ::GetDC(nullptr);
    if (!screen_dc) return false;
    mem_dc = ::CreateCompatibleDC(screen_dc);
    if (!mem_dc) {
      Reset();
      return false;
    }
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;  // Top-down BGRA
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* raw = nullptr;
    dib = ::CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &raw, nullptr, 0);
    if (!dib || !raw) {
      Reset();
      return false;
    }
    old_bmp = ::SelectObject(mem_dc, dib);
    bits = static_cast<uint8_t*>(raw);
    width = w;
    height = h;
    return true;
  }

  const uint8_t* Capture(int x, int y, int w, int h, int* out_stride) {
    if (!EnsureSize(w, h)) return nullptr;
    if (!::BitBlt(mem_dc, 0, 0, w, h, screen_dc, x, y, SRCCOPY)) {
      return nullptr;
    }
    if (out_stride) *out_stride = w * 4;
    return bits;
  }
};

struct WgcMonitorSession {
  winrt::com_ptr<ID3D11Device> d3d_device;
  winrt::com_ptr<ID3D11DeviceContext> d3d_ctx;
  winrt::com_ptr<ID3D11Texture2D> staging;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device{
      nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureItem item{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool{
      nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession session{nullptr};
  int local_x = 0;
  int local_y = 0;
  int crop_w = 0;
  int crop_h = 0;
  int monitor_w = 0;
  int monitor_h = 0;

  void Close() {
    try {
      if (session) session.Close();
    } catch (...) {
    }
    try {
      if (frame_pool) frame_pool.Close();
    } catch (...) {
    }
    session = nullptr;
    frame_pool = nullptr;
    item = nullptr;
    winrt_device = nullptr;
    staging = nullptr;
    d3d_ctx = nullptr;
    d3d_device = nullptr;
  }

  bool Init(HMONITOR hmon, int lx, int ly, int cw, int ch, int mw, int mh) {
    try {
      if (!winrt::Windows::Graphics::Capture::GraphicsCaptureSession::
              IsSupported()) {
        return false;
      }

      UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
      D3D_FEATURE_LEVEL levels[] = {
          D3D_FEATURE_LEVEL_11_1,
          D3D_FEATURE_LEVEL_11_0,
          D3D_FEATURE_LEVEL_10_0,
      };
      D3D_FEATURE_LEVEL chosen{};
      HRESULT hr = ::D3D11CreateDevice(
          nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels,
          static_cast<UINT>(sizeof(levels) / sizeof(levels[0])),
          D3D11_SDK_VERSION, d3d_device.put(), &chosen, d3d_ctx.put());
      if (FAILED(hr) || !d3d_device || !d3d_ctx) {
        return false;
      }

      winrt::com_ptr<IDXGIDevice> dxgi_dev;
      hr = d3d_device->QueryInterface(IID_PPV_ARGS(dxgi_dev.put()));
      if (FAILED(hr) || !dxgi_dev) return false;

      winrt::com_ptr<::IInspectable> insp;
      hr = ::CreateDirect3D11DeviceFromDXGIDevice(dxgi_dev.get(), insp.put());
      if (FAILED(hr) || !insp) return false;
      // Gene - Nov, 20, 2026: Use explicit QueryInterface to avoid ::IInspectable vs winrt::IInspectable ambiguity under C++20.
      // winrt_device = insp.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
      hr = insp->QueryInterface(
          winrt::guid_of<
              winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>(),
          winrt::put_abi(winrt_device));
      if (FAILED(hr) || !winrt_device) return false;

      auto factory = winrt::get_activation_factory<
          winrt::Windows::Graphics::Capture::GraphicsCaptureItem,
          IGraphicsCaptureItemInterop>();
      if (!factory) return false;

      hr = factory->CreateForMonitor(
          hmon,
          winrt::guid_of<
              winrt::Windows::Graphics::Capture::GraphicsCaptureItem>(),
          winrt::put_abi(item));
      if (FAILED(hr) || !item) return false;

      auto sz = item.Size();
      monitor_w = sz.Width;
      monitor_h = sz.Height;
      // Gene - Nov, 20, 2026: Fall back cleanly to virtual-desktop GDI when selection crosses monitor edges.
      if (lx < 0 || ly < 0 || lx + cw > monitor_w || ly + ch > monitor_h) {
        Close();
        return false;
      }
      local_x = lx;
      local_y = ly;
      crop_w = cw;
      crop_h = ch;

      D3D11_TEXTURE2D_DESC desc = {};
      desc.Width = static_cast<UINT>(crop_w);
      desc.Height = static_cast<UINT>(crop_h);
      desc.MipLevels = 1;
      desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      hr = d3d_device->CreateTexture2D(&desc, nullptr, staging.put());
      if (FAILED(hr) || !staging) return false;

      frame_pool = winrt::Windows::Graphics::Capture::
          Direct3D11CaptureFramePool::CreateFreeThreaded(
              winrt_device,
              winrt::Windows::Graphics::DirectX::DirectXPixelFormat::
                  B8G8R8A8UIntNormalized,
              2, sz);
      if (!frame_pool) return false;

      session = frame_pool.CreateCaptureSession(item);
      if (!session) return false;

      try {
        session.IsCursorCaptureEnabled(false);
      } catch (...) {
      }
      session.StartCapture();
      return true;
    } catch (...) {
      Close();
      return false;
    }
  }

  template <typename Fn>
  bool TryGrabFrame(Fn&& on_pixels) {
    try {
      if (!frame_pool || !staging || !d3d_ctx) return false;
      auto frame = frame_pool.TryGetNextFrame();
      if (!frame) return false;

      auto surface = frame.Surface();
      if (!surface) return false;

      winrt::com_ptr<Windows::Graphics::DirectX::Direct3D11::
                         IDirect3DDxgiInterfaceAccess>
          access = surface.as<Windows::Graphics::DirectX::Direct3D11::
                                  IDirect3DDxgiInterfaceAccess>();
      winrt::com_ptr<ID3D11Texture2D> src_tex;
      // Gene - Nov, 20, 2026: Use __uuidof(ID3D11Texture2D) for raw COM interface retrieval.
      // HRESULT hr = access->GetInterface(winrt::guid_of<ID3D11Texture2D>(),
      //                                   src_tex.put_void());
      HRESULT hr = access->GetInterface(__uuidof(ID3D11Texture2D),
                                        src_tex.put_void());
      if (FAILED(hr) || !src_tex) return false;

      D3D11_TEXTURE2D_DESC src_desc = {};
      src_tex->GetDesc(&src_desc);
      if (static_cast<int>(src_desc.Width) < local_x + crop_w ||
          static_cast<int>(src_desc.Height) < local_y + crop_h) {
        return false;
      }

      D3D11_BOX box = {};
      box.left = static_cast<UINT>(local_x);
      box.top = static_cast<UINT>(local_y);
      box.front = 0;
      box.right = static_cast<UINT>(local_x + crop_w);
      box.bottom = static_cast<UINT>(local_y + crop_h);
      box.back = 1;
      d3d_ctx->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, src_tex.get(),
                                     0, &box);

      D3D11_MAPPED_SUBRESOURCE mapped = {};
      hr = d3d_ctx->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped);
      if (FAILED(hr) || !mapped.pData) return false;
      on_pixels(static_cast<const uint8_t*>(mapped.pData), crop_w, crop_h,
                static_cast<int>(mapped.RowPitch));
      d3d_ctx->Unmap(staging.get(), 0);
      return true;
    } catch (...) {
      return false;
    }
  }
};

}  // namespace

struct ScrollingCaptureEngine::Impl {
  ScrollingCaptureConfig config;
  ScrollingCaptureCallbacks callbacks;

  std::atomic<bool> active{false};
  std::atomic<bool> paused{false};
  std::atomic<bool> auto_scroll{false};
  std::atomic<bool> finish_requested{false};
  std::atomic<bool> cancel_requested{false};
  std::atomic<bool> has_moved_content{false};

  std::mutex stitch_mutex;
  SnipSnapStitcher* stitcher = nullptr;

  std::mutex state_mutex;
  int latest_width = 0;
  int latest_height = 0;
  int latest_frames = 0;
  int latest_axis = SNIPSNAP_AXIS_VERTICAL;
  int latest_status = SNIPSNAP_STITCH_OK;
  std::string latest_warning;
  std::vector<uint8_t> preview_bgra;
  int preview_w = 0;
  int preview_h = 0;

  std::mutex hook_mutex;
  HHOOK mouse_hook = nullptr;
  HHOOK key_hook = nullptr;

  HWND guide_hwnd = nullptr;
  HWND hud_hwnd = nullptr;
  RECT btn_auto = {};
  RECT btn_pause = {};
  RECT btn_done = {};
  RECT btn_cancel = {};

  std::thread worker_thread;
  std::thread ui_thread;

  static Impl* s_hook_instance;
  static std::mutex s_hook_instance_mutex;

  ~Impl() { Shutdown(); }

  void Shutdown() {
    cancel_requested.store(true);
    active.store(false);
    auto_scroll.store(false);

    if (hud_hwnd && ::IsWindow(hud_hwnd)) {
      ::PostMessageW(hud_hwnd, kMsgCloseWindows, 0, 0);
    }
    if (worker_thread.joinable()) {
      worker_thread.join();
    }
    if (ui_thread.joinable()) {
      ui_thread.join();
    }
    UninstallHooks();
    FreeStitcher();
  }

  void FreeStitcher() {
    std::lock_guard<std::mutex> lock(stitch_mutex);
    if (stitcher) {
      snipsnap_stitcher_free(stitcher);
      stitcher = nullptr;
    }
  }

  static LRESULT CALLBACK LowLevelMouseProc(int ncode,
                                            WPARAM wparam,
                                            LPARAM lparam) {
    if (ncode == HC_ACTION &&
        (wparam == WM_MOUSEWHEEL || wparam == WM_MOUSEHWHEEL)) {
      const auto* ms = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
      if (ms && (ms->flags & LLMHF_INJECTED) == 0) {
        Impl* self = nullptr;
        {
          std::lock_guard<std::mutex> lk(s_hook_instance_mutex);
          self = s_hook_instance;
        }
        if (self && self->auto_scroll.load()) {
          self->auto_scroll.store(false);
          {
            std::lock_guard<std::mutex> lk(self->state_mutex);
            self->latest_warning = "Manual scroll detected - Auto-Scroll paused";
          }
          self->NotifyHudAndProgress();
        }
      }
    }
    return ::CallNextHookEx(nullptr, ncode, wparam, lparam);
  }

  static LRESULT CALLBACK LowLevelKeyboardProc(int ncode,
                                               WPARAM wparam,
                                               LPARAM lparam) {
    if (ncode == HC_ACTION && (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)) {
      const auto* kb = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
      Impl* self = nullptr;
      {
        std::lock_guard<std::mutex> lk(s_hook_instance_mutex);
        self = s_hook_instance;
      }
      if (self && kb && self->active.load()) {
        if (kb->vkCode == VK_ESCAPE) {
          self->RequestCancel();
          return 1;
        }
        if (kb->vkCode == VK_RETURN) {
          self->RequestFinish();
          return 1;
        }
      }
    }
    return ::CallNextHookEx(nullptr, ncode, wparam, lparam);
  }

  void InstallHooks() {
    std::lock_guard<std::mutex> lk(hook_mutex);
    {
      std::lock_guard<std::mutex> il(s_hook_instance_mutex);
      s_hook_instance = this;
    }
    HINSTANCE mod = ::GetModuleHandleW(nullptr);
    if (!mouse_hook) {
      mouse_hook = ::SetWindowsHookExW(WH_MOUSE_LL, LowLevelMouseProc, mod, 0);
    }
    if (!key_hook) {
      key_hook = ::SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc, mod, 0);
    }
  }

  void UninstallHooks() {
    std::lock_guard<std::mutex> lk(hook_mutex);
    if (mouse_hook) {
      ::UnhookWindowsHookEx(mouse_hook);
      mouse_hook = nullptr;
    }
    if (key_hook) {
      ::UnhookWindowsHookEx(key_hook);
      key_hook = nullptr;
    }
    std::lock_guard<std::mutex> il(s_hook_instance_mutex);
    if (s_hook_instance == this) {
      s_hook_instance = nullptr;
    }
  }

  void RequestFinish() {
    if (!active.load() || finish_requested.exchange(true)) return;
    auto_scroll.store(false);
    active.store(false);
  }

  void RequestCancel() {
    if (cancel_requested.exchange(true)) return;
    auto_scroll.store(false);
    active.store(false);
  }

  void NotifyHudAndProgress() {
    int w = 0, h = 0, frames = 0, axis = 0, st = 0;
    bool p = paused.load();
    bool a = auto_scroll.load();
    std::string warn;
    {
      std::lock_guard<std::mutex> lk(state_mutex);
      w = latest_width;
      h = latest_height;
      frames = latest_frames;
      axis = latest_axis;
      st = latest_status;
      warn = latest_warning;
    }
    if (hud_hwnd && ::IsWindow(hud_hwnd)) {
      ::PostMessageW(hud_hwnd, kMsgUpdateHud, 0, 0);
    }
    if (callbacks.on_progress) {
      callbacks.on_progress(w, h, frames, axis, st, p, a, warn);
    }
  }

  void PerformAutoScrollStep() {
    if (!active.load() || paused.load() || !auto_scroll.load()) return;

    int cx = config.x + config.width / 2;
    int cy = config.y + config.height / 2;
    POINT cur = {};
    if (::GetCursorPos(&cur)) {
      if (cur.x < config.x || cur.x > config.x + config.width ||
          cur.y < config.y || cur.y > config.y + config.height) {
        ::SetCursorPos(cx, cy);
      }
    }

    int axis = SNIPSNAP_AXIS_VERTICAL;
    {
      std::lock_guard<std::mutex> lk(state_mutex);
      axis = latest_axis;
    }

    INPUT input = {};
    input.type = INPUT_MOUSE;
    if (axis == SNIPSNAP_AXIS_HORIZONTAL) {
      input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
      input.mi.mouseData = static_cast<DWORD>(60);
    } else {
      input.mi.dwFlags = MOUSEEVENTF_WHEEL;
      input.mi.mouseData = static_cast<DWORD>(-60);
    }
    ::SendInput(1, &input, sizeof(INPUT));
  }

  void PaintHud(HWND hwnd) {
    PAINTSTRUCT ps = {};
    HDC hdc = ::BeginPaint(hwnd, &ps);
    RECT rc = {};
    ::GetClientRect(hwnd, &rc);
    int cw = rc.right - rc.left;
    int ch = rc.bottom - rc.top;

    HDC mem_dc = ::CreateCompatibleDC(hdc);
    HBITMAP bmp = ::CreateCompatibleBitmap(hdc, cw, ch);
    HGDIOBJ old_bmp = ::SelectObject(mem_dc, bmp);

    HBRUSH bg = ::CreateSolidBrush(RGB(28, 19, 13));
    ::FillRect(mem_dc, &rc, bg);
    ::DeleteObject(bg);
    HPEN border_pen = ::CreatePen(PS_SOLID, 1, RGB(96, 74, 58));
    HGDIOBJ old_pen = ::SelectObject(mem_dc, border_pen);
    HGDIOBJ old_br = ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
    ::Rectangle(mem_dc, 0, 0, cw, ch);
    ::SelectObject(mem_dc, old_br);
    ::SelectObject(mem_dc, old_pen);
    ::DeleteObject(border_pen);

    int w = 0, h = 0, frames = 0, axis = 0, status = 0, pw = 0, ph = 0;
    std::string warn;
    std::vector<uint8_t> preview_copy;
    {
      std::lock_guard<std::mutex> lk(state_mutex);
      w = latest_width;
      h = latest_height;
      frames = latest_frames;
      axis = latest_axis;
      status = latest_status;
      warn = latest_warning;
      preview_copy = preview_bgra;
      pw = preview_w;
      ph = preview_h;
    }
    bool is_paused = paused.load();
    bool is_auto = auto_scroll.load();

    HFONT font = ::CreateFontW(
        -13, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HFONT small_font = ::CreateFontW(
        -11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HGDIOBJ old_font = ::SelectObject(mem_dc, font);

    // Status dot
    COLORREF dot_col = is_paused ? RGB(240, 155, 40) : RGB(235, 68, 56);
    HBRUSH dot_br = ::CreateSolidBrush(dot_col);
    HGDIOBJ old_dot_br = ::SelectObject(mem_dc, dot_br);
    ::Ellipse(mem_dc, 14, 15, 24, 25);
    ::SelectObject(mem_dc, old_dot_br);
    ::DeleteObject(dot_br);

    ::SetBkMode(mem_dc, TRANSPARENT);
    ::SetTextColor(mem_dc, RGB(255, 255, 255));
    std::wostringstream hdr;
    hdr << w << L" x " << h << L" px  (" << frames << L" frames)";
    RECT hdr_rc = {32, 10, cw - 92, 30};
    ::DrawTextW(mem_dc, hdr.str().c_str(), -1, &hdr_rc,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    std::wstring axis_lbl =
        axis == SNIPSNAP_AXIS_HORIZONTAL
            ? L"Horizontal"
            : (axis == SNIPSNAP_AXIS_VERTICAL ? L"Vertical" : L"Auto");
    ::SelectObject(mem_dc, small_font);
    ::SetTextColor(mem_dc, RGB(222, 188, 150));
    RECT axis_rc = {cw - 92, 10, cw - 12, 30};
    ::DrawTextW(mem_dc, axis_lbl.c_str(), -1, &axis_rc,
                DT_RIGHT | DT_VCENTER | DT_SINGLELINE);

    // Live thumbnail box
    RECT box = {14, 38, 108, 108};
    HBRUSH pv_bg = ::CreateSolidBrush(RGB(15, 11, 8));
    ::FillRect(mem_dc, &box, pv_bg);
    ::DeleteObject(pv_bg);
    ::DrawEdge(mem_dc, &box, EDGE_ETCHED, BF_RECT);

    if (!preview_copy.empty() && pw > 0 && ph > 0) {
      int max_w = (box.right - box.left) - 4;
      int max_h = (box.bottom - box.top) - 4;
      double sc = std::min(static_cast<double>(max_w) / pw,
                           static_cast<double>(max_h) / ph);
      int dw = std::max(1, static_cast<int>(std::round(pw * sc)));
      int dh = std::max(1, static_cast<int>(std::round(ph * sc)));
      int dx = box.left + 2 + (max_w - dw) / 2;
      int dy = box.top + 2 + (max_h - dh) / 2;

      BITMAPINFO bmi = {};
      bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      bmi.bmiHeader.biWidth = pw;
      bmi.bmiHeader.biHeight = -ph;
      bmi.bmiHeader.biPlanes = 1;
      bmi.bmiHeader.biBitCount = 32;
      bmi.bmiHeader.biCompression = BI_RGB;
      ::SetStretchBltMode(mem_dc, HALFTONE);
      ::StretchDIBits(mem_dc, dx, dy, dw, dh, 0, 0, pw, ph,
                      preview_copy.data(), &bmi, DIB_RGB_COLORS, SRCCOPY);
    } else {
      ::SetTextColor(mem_dc, RGB(140, 128, 118));
      ::DrawTextW(mem_dc, L"Preview", -1, &box,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }

    // Status message
    std::wstring msg;
    COLORREF msg_col = RGB(226, 218, 210);
    if (!warn.empty()) {
      msg = Utf8ToWideLocal(warn);
      msg_col = RGB(250, 196, 105);
    } else if (is_paused) {
      msg = L"Paused - scroll freely or click Resume / Done.";
    } else if (is_auto) {
      msg = L"Auto-scrolling... scroll manually to pause.";
      msg_col = RGB(165, 232, 185);
    } else if (status == SNIPSNAP_STITCH_TRACKING_LOST) {
      msg = L"Tracking lost - scroll slightly slower.";
      msg_col = RGB(250, 196, 105);
    } else {
      msg = frames <= 1
                ? L"Ready - scroll region manually or click Auto-Scroll."
                : L"Capturing stitch... press Enter or Done to finish.";
    }
    ::SetTextColor(mem_dc, msg_col);
    RECT msg_rc = {118, 42, cw - 12, 108};
    ::DrawTextW(mem_dc, msg.c_str(), -1, &msg_rc, DT_LEFT | DT_WORDBREAK);

    // Action buttons row
    ::SelectObject(mem_dc, font);
    int by = ch - 40;
    int bh = 28;
    btn_auto = {14, by, 106, by + bh};
    btn_pause = {112, by, 184, by + bh};
    btn_done = {190, by, 276, by + bh};
    btn_cancel = {cw - 92, by, cw - 14, by + bh};

    DrawHudPill(mem_dc, btn_auto,
                is_auto ? RGB(52, 138, 88) : RGB(56, 44, 36),
                RGB(115, 96, 82), is_auto ? L"Auto On" : L"Auto-Scroll",
                RGB(255, 255, 255));
    DrawHudPill(mem_dc, btn_pause,
                is_paused ? RGB(111, 78, 55) : RGB(56, 44, 36),
                RGB(115, 96, 82), is_paused ? L"Resume" : L"Pause",
                RGB(255, 255, 255));
    DrawHudPill(mem_dc, btn_done, RGB(111, 78, 55), RGB(178, 136, 102),
                L"Done", RGB(255, 255, 255));
    DrawHudPill(mem_dc, btn_cancel, RGB(48, 34, 30), RGB(130, 80, 74),
                L"Cancel", RGB(255, 255, 255));

    ::BitBlt(hdc, 0, 0, cw, ch, mem_dc, 0, 0, SRCCOPY);
    ::SelectObject(mem_dc, old_font);
    ::DeleteObject(font);
    ::DeleteObject(small_font);
    ::SelectObject(mem_dc, old_bmp);
    ::DeleteObject(bmp);
    ::DeleteDC(mem_dc);
    ::EndPaint(hwnd, &ps);
  }

  static LRESULT CALLBACK GuideWndProc(HWND hwnd,
                                       UINT msg,
                                       WPARAM wparam,
                                       LPARAM lparam) {
    if (msg == WM_PAINT) {
      PAINTSTRUCT ps = {};
      HDC hdc = ::BeginPaint(hwnd, &ps);
      RECT rc = {};
      ::GetClientRect(hwnd, &rc);
      HBRUSH black = ::CreateSolidBrush(RGB(0, 0, 0));
      ::FillRect(hdc, &rc, black);
      ::DeleteObject(black);

      HPEN outer_pen = ::CreatePen(PS_SOLID, 2, RGB(240, 232, 224));
      HPEN inner_pen = ::CreatePen(PS_SOLID, 2, RGB(200, 162, 122));
      HGDIOBJ old_br = ::SelectObject(hdc, ::GetStockObject(NULL_BRUSH));
      HGDIOBJ old_pen = ::SelectObject(hdc, outer_pen);
      ::Rectangle(hdc, 0, 0, rc.right, rc.bottom);
      ::SelectObject(hdc, inner_pen);
      ::Rectangle(hdc, 2, 2, rc.right - 2, rc.bottom - 2);
      ::SelectObject(hdc, old_br);
      ::SelectObject(hdc, old_pen);
      ::DeleteObject(outer_pen);
      ::DeleteObject(inner_pen);
      ::EndPaint(hwnd, &ps);
      return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  static LRESULT CALLBACK HudWndProc(HWND hwnd,
                                     UINT msg,
                                     WPARAM wparam,
                                     LPARAM lparam) {
    Impl* self = reinterpret_cast<Impl*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
      case WM_CREATE: {
        auto* cs = reinterpret_cast<const CREATESTRUCTW*>(lparam);
        ::SetWindowLongPtrW(
            hwnd, GWLP_USERDATA,
            reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return 0;
      }
      case WM_ERASEBKGND:
        return 1;
      case WM_PAINT:
        if (self) {
          self->PaintHud(hwnd);
          return 0;
        }
        break;
      case WM_NCHITTEST: {
        if (self) {
          POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
          ::ScreenToClient(hwnd, &pt);
          if (::PtInRect(&self->btn_auto, pt) ||
              ::PtInRect(&self->btn_pause, pt) ||
              ::PtInRect(&self->btn_done, pt) ||
              ::PtInRect(&self->btn_cancel, pt)) {
            return HTCLIENT;
          }
          return HTCAPTION;
        }
        break;
      }
      case WM_SETCURSOR:
        if (LOWORD(lparam) == HTCLIENT) {
          ::SetCursor(::LoadCursorW(nullptr, IDC_HAND));
          return TRUE;
        }
        break;
      case WM_LBUTTONUP:
        if (self) {
          POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
          if (::PtInRect(&self->btn_done, pt)) {
            self->RequestFinish();
            return 0;
          }
          if (::PtInRect(&self->btn_cancel, pt)) {
            self->RequestCancel();
            return 0;
          }
          if (::PtInRect(&self->btn_pause, pt)) {
            bool next = !self->paused.load();
            self->paused.store(next);
            if (next) self->auto_scroll.store(false);
            self->NotifyHudAndProgress();
            return 0;
          }
          if (::PtInRect(&self->btn_auto, pt)) {
            bool next = !self->auto_scroll.load();
            if (next) self->paused.store(false);
            self->auto_scroll.store(next);
            self->NotifyHudAndProgress();
            return 0;
          }
        }
        break;
      case WM_TIMER:
        if (self && wparam == kAutoScrollTimerId) {
          self->PerformAutoScrollStep();
          return 0;
        }
        break;
      case kMsgUpdateHud:
        ::InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      case kMsgCloseWindows:
        ::KillTimer(hwnd, kAutoScrollTimerId);
        if (self && self->guide_hwnd && ::IsWindow(self->guide_hwnd)) {
          ::DestroyWindow(self->guide_hwnd);
          self->guide_hwnd = nullptr;
        }
        ::DestroyWindow(hwnd);
        return 0;
      case WM_DESTROY:
        if (self) {
          self->UninstallHooks();
          self->hud_hwnd = nullptr;
        }
        ::PostQuitMessage(0);
        return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  void RunUiThread() {
    static const wchar_t* kGuideClass = L"SnipSnapScrollGuideClass";
    static const wchar_t* kHudClass = L"SnipSnapScrollHudClass";
    static std::atomic<bool> classes_registered{false};
    HINSTANCE hinst = ::GetModuleHandleW(nullptr);
    if (!classes_registered.exchange(true)) {
      WNDCLASSEXW gwc = {};
      gwc.cbSize = sizeof(WNDCLASSEXW);
      gwc.lpfnWndProc = GuideWndProc;
      gwc.hInstance = hinst;
      gwc.lpszClassName = kGuideClass;
      ::RegisterClassExW(&gwc);

      WNDCLASSEXW hwc = {};
      hwc.cbSize = sizeof(WNDCLASSEXW);
      hwc.lpfnWndProc = HudWndProc;
      hwc.hInstance = hinst;
      hwc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
      hwc.lpszClassName = kHudClass;
      ::RegisterClassExW(&hwc);
    }

    guide_hwnd = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT |
            WS_EX_NOACTIVATE | WS_EX_LAYERED,
        kGuideClass, L"", WS_POPUP | WS_VISIBLE, config.x - 4, config.y - 4,
        config.width + 8, config.height + 8, nullptr, nullptr, hinst, nullptr);
    if (guide_hwnd) {
      ::SetLayeredWindowAttributes(guide_hwnd, RGB(0, 0, 0), 255, LWA_COLORKEY);
      ::SetWindowDisplayAffinity(guide_hwnd, WDA_EXCLUDEFROMCAPTURE);
    }

    POINT center_pt = {config.x + config.width / 2,
                       config.y + config.height / 2};
    HMONITOR hmon = ::MonitorFromPoint(center_pt, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    RECT work = {0, 0, 1920, 1080};
    if (::GetMonitorInfoW(hmon, &mi)) {
      work = mi.rcWork;
    }

    const int hud_w = 384;
    const int hud_h = 160;
    int hud_x = std::clamp(config.x + (config.width - hud_w) / 2,
                           static_cast<int>(work.left + 8),
                           static_cast<int>(work.right - hud_w - 8));
    int hud_y = config.y + config.height + 12;
    if (hud_y + hud_h > work.bottom - 8) {
      int above = config.y - hud_h - 12;
      hud_y = (above >= work.top + 8)
                  ? above
                  : std::max(static_cast<int>(work.top + 14),
                             static_cast<int>(work.bottom - hud_h - 14));
    }

    hud_hwnd = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kHudClass,
        L"SnipSnap Scrolling Capture", WS_POPUP | WS_VISIBLE, hud_x, hud_y,
        hud_w, hud_h, nullptr, nullptr, hinst, this);
    if (hud_hwnd) {
      ::SetWindowDisplayAffinity(hud_hwnd, WDA_EXCLUDEFROMCAPTURE);
      ::SetTimer(hud_hwnd, kAutoScrollTimerId, 70, nullptr);
    }

    InstallHooks();

    MSG msg = {};
    while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    UninstallHooks();
  }

  void RunCaptureThread() {
    HRESULT co_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool did_co_init = SUCCEEDED(co_hr);

    POINT center_pt = {config.x + config.width / 2,
                       config.y + config.height / 2};
    HMONITOR hmon = ::MonitorFromPoint(center_pt, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    ::GetMonitorInfoW(hmon, &mi);
    int local_x = config.x - mi.rcMonitor.left;
    int local_y = config.y - mi.rcMonitor.top;
    int mon_w = std::max(1, static_cast<int>(mi.rcMonitor.right - mi.rcMonitor.left));
    int mon_h = std::max(1, static_cast<int>(mi.rcMonitor.bottom - mi.rcMonitor.top));

    WgcMonitorSession wgc;
    bool using_wgc = wgc.Init(hmon, local_x, local_y, config.width,
                              config.height, mon_w, mon_h);
    PersistentGdiGrabber gdi;

    auto wgc_start = std::chrono::steady_clock::now();
    bool got_any_wgc_frame = false;
    auto last_hud_refresh = std::chrono::steady_clock::now();

    auto process_frame = [&](const uint8_t* bgra, int fw, int fh, int stride) {
      if (!bgra || paused.load()) return;

      SnipSnapPushResult res = {};
      bool stop_auto = false;
      bool auto_finish = false;
      bool need_preview = false;
      {
        std::lock_guard<std::mutex> lk(stitch_mutex);
        if (!stitcher) return;
        res = snipsnap_stitcher_push_bgra(stitcher, bgra, fw, fh, stride);

        if (res.status == SNIPSNAP_STITCH_OK && res.frame_count > 1 &&
            std::abs(res.delta) > 0) {
          has_moved_content.store(true);
        }

        std::string warn;
        bool auto_now = auto_scroll.load();
        if (res.status == SNIPSNAP_STITCH_TRACKING_LOST) {
          warn = "Tracking lost - scroll slower so content overlaps";
        } else if (res.status == SNIPSNAP_STITCH_MAX_LIMIT_REACHED) {
          warn = "Max dimension reached - click Done";
          stop_auto = true;
          auto_finish = auto_now;
        } else if (auto_now) {
          bool moved = has_moved_content.load();
          if ((moved && res.identical_streak >= 4) ||
              (!moved && res.identical_streak >= 16)) {
            stop_auto = true;
            auto_finish = moved;
            if (!moved) {
              warn = "End of scrollable area reached";
            }
          }
        }

        auto now = std::chrono::steady_clock::now();
        need_preview =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                now - last_hud_refresh)
                    .count() >= 95 ||
            res.status == SNIPSNAP_STITCH_TRACKING_LOST ||
            res.status == SNIPSNAP_STITCH_MAX_LIMIT_REACHED;

        std::vector<uint8_t> new_preview;
        int npw = 0;
        int nph = 0;
        if (need_preview) {
          last_hud_refresh = now;
          SnipSnapImageBuffer pv = {};
          if (snipsnap_stitcher_get_preview_bgra(stitcher, 180, 128, &pv) &&
              pv.data && pv.len > 0) {
            new_preview.assign(pv.data, pv.data + pv.len);
            npw = pv.width;
            nph = pv.height;
          }
          snipsnap_buffer_free(&pv);
        }

        {
          std::lock_guard<std::mutex> slk(state_mutex);
          latest_width = res.total_width;
          latest_height = res.total_height;
          latest_frames = res.frame_count;
          latest_axis = res.active_axis;
          latest_status = res.status;
          if (!warn.empty()) {
            latest_warning = warn;
          } else if (res.status == SNIPSNAP_STITCH_OK && res.delta != 0) {
            latest_warning.clear();
          }
          if (!new_preview.empty()) {
            preview_bgra = std::move(new_preview);
            preview_w = npw;
            preview_h = nph;
          }
        }
      }

      if (stop_auto) {
        auto_scroll.store(false);
      }
      if (auto_finish) {
        finish_requested.store(true);
        active.store(false);
        return;
      }
      if (need_preview) {
        NotifyHudAndProgress();
      }
    };

    while (active.load() && !finish_requested.load() &&
           !cancel_requested.load()) {
      auto iter_start = std::chrono::steady_clock::now();
      if (!paused.load()) {
        if (using_wgc) {
          bool grabbed = wgc.TryGrabFrame(
              [&](const uint8_t* ptr, int fw, int fh, int stride) {
                got_any_wgc_frame = true;
                process_frame(ptr, fw, fh, stride);
              });
          if (!grabbed && !got_any_wgc_frame) {
            auto elapsed_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    iter_start - wgc_start)
                    .count();
            if (elapsed_ms > 600) {
              wgc.Close();
              using_wgc = false;
            }
          }
        }
        if (!using_wgc) {
          int stride = 0;
          const uint8_t* bgra = gdi.Capture(config.x, config.y, config.width,
                                            config.height, &stride);
          process_frame(bgra, config.width, config.height, stride);
        }
      }

      auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::steady_clock::now() - iter_start)
                         .count();
      if (elapsed < 33) {
        std::this_thread::sleep_for(std::chrono::milliseconds(33 - elapsed));
      }
    }

    wgc.Close();
    gdi.Reset();

    if (hud_hwnd && ::IsWindow(hud_hwnd)) {
      ::PostMessageW(hud_hwnd, kMsgCloseWindows, 0, 0);
    }

    if (cancel_requested.load() || !finish_requested.load()) {
      FreeStitcher();
      if (did_co_init) ::CoUninitialize();
      if (callbacks.on_cancel) {
        callbacks.on_cancel();
      }
      return;
    }

    // Single-pass assembly & WIC PNG encoding
    SnipSnapImageBuffer full = {};
    bool assembled = false;
    int out_frames = 0;
    int out_axis = SNIPSNAP_AXIS_VERTICAL;
    bool truncated = false;
    {
      std::lock_guard<std::mutex> lk(stitch_mutex);
      if (stitcher) {
        assembled = snipsnap_stitcher_assemble_bgra(stitcher, &full);
        snipsnap_stitcher_free(stitcher);
        stitcher = nullptr;
      }
    }
    {
      std::lock_guard<std::mutex> slk(state_mutex);
      out_frames = latest_frames;
      out_axis = latest_axis;
      truncated = (latest_status == SNIPSNAP_STITCH_MAX_LIMIT_REACHED);
    }

    bool wrote_ok = false;
    int out_w = full.width;
    int out_h = full.height;
    if (assembled && full.data && full.len > 0 && callbacks.save_png) {
      wrote_ok = callbacks.save_png(full.data, full.width, full.height,
                                    full.stride, config.target_path);
    }
    snipsnap_buffer_free(&full);
    if (did_co_init) ::CoUninitialize();

    if (wrote_ok) {
      if (callbacks.on_completed) {
        callbacks.on_completed(config.target_path_utf8, out_w, out_h,
                               out_frames, out_axis, truncated);
      }
    } else {
      if (callbacks.on_error) {
        callbacks.on_error("Failed to assemble or encode scrolling PNG.");
      }
    }
  }
};

ScrollingCaptureEngine::Impl* ScrollingCaptureEngine::Impl::s_hook_instance =
    nullptr;
std::mutex ScrollingCaptureEngine::Impl::s_hook_instance_mutex;

ScrollingCaptureEngine::ScrollingCaptureEngine() : impl_(new Impl()) {}

ScrollingCaptureEngine::~ScrollingCaptureEngine() {
  delete impl_;
  impl_ = nullptr;
}

bool ScrollingCaptureEngine::Start(const ScrollingCaptureConfig& config,
                                   const ScrollingCaptureCallbacks& callbacks) {
  impl_->Shutdown();
  if (config.width < 24 || config.height < 24 || config.target_path.empty()) {
    return false;
  }

  SnipSnapStitcher* handle = snipsnap_stitcher_create(
      config.width, config.height, std::max(1024, config.max_dimension),
      config.axis_mode);
  if (!handle) {
    return false;
  }

  impl_->config = config;
  impl_->callbacks = callbacks;
  impl_->paused.store(false);
  impl_->auto_scroll.store(false);
  impl_->finish_requested.store(false);
  impl_->cancel_requested.store(false);
  impl_->has_moved_content.store(false);
  impl_->active.store(true);

  {
    std::lock_guard<std::mutex> lk(impl_->stitch_mutex);
    impl_->stitcher = handle;
  }
  {
    std::lock_guard<std::mutex> slk(impl_->state_mutex);
    impl_->latest_width = config.width;
    impl_->latest_height = config.height;
    impl_->latest_frames = 0;
    impl_->latest_axis =
        (config.axis_mode == SNIPSNAP_AXIS_HORIZONTAL)
            ? SNIPSNAP_AXIS_HORIZONTAL
            : SNIPSNAP_AXIS_VERTICAL;
    impl_->latest_status = SNIPSNAP_STITCH_OK;
    impl_->latest_warning.clear();
    impl_->preview_bgra.clear();
    impl_->preview_w = 0;
    impl_->preview_h = 0;
  }

  impl_->ui_thread = std::thread([this]() { impl_->RunUiThread(); });
  impl_->worker_thread = std::thread([this]() { impl_->RunCaptureThread(); });
  return true;
}

void ScrollingCaptureEngine::SetAutoScroll(bool enabled) {
  if (!impl_->active.load()) return;
  if (enabled) {
    impl_->paused.store(false);
  }
  impl_->auto_scroll.store(enabled);
  {
    std::lock_guard<std::mutex> lk(impl_->state_mutex);
    impl_->latest_warning.clear();
  }
  impl_->NotifyHudAndProgress();
}

void ScrollingCaptureEngine::Pause() {
  if (!impl_->active.load()) return;
  impl_->paused.store(true);
  impl_->auto_scroll.store(false);
  impl_->NotifyHudAndProgress();
}

void ScrollingCaptureEngine::Resume() {
  if (!impl_->active.load()) return;
  impl_->paused.store(false);
  impl_->NotifyHudAndProgress();
}

void ScrollingCaptureEngine::Finish() { impl_->RequestFinish(); }

void ScrollingCaptureEngine::Cancel() { impl_->RequestCancel(); }

bool ScrollingCaptureEngine::IsActive() const { return impl_->active.load(); }
