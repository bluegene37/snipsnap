// Gene - Nov, 24, 2026: Fast DXGI Desktop Duplication + Persistent GDI Screen Grabber for Windows capture and recording.
#ifndef RUNNER_DXGI_CAPTURE_H_
#define RUNNER_DXGI_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <vector>

struct CapturedMonitorFrame {
  HMONITOR hmon = nullptr;
  RECT monitor_rect = {0, 0, 0, 0};
  int width = 0;
  int height = 0;
  UINT dpi = 96;
  std::vector<uint8_t> bgra;
};

// Reuses a single compatible DC + top-down 32bpp DIBSection across frames so
// screen recording and GDI fallback never allocate bitmaps 60 times a second.
class PersistentGdiRectGrabber {
 public:
  PersistentGdiRectGrabber() = default;
  ~PersistentGdiRectGrabber();

  PersistentGdiRectGrabber(const PersistentGdiRectGrabber&) = delete;
  PersistentGdiRectGrabber& operator=(const PersistentGdiRectGrabber&) = delete;

  bool EnsureSize(int w, int h);
  bool Capture(int x, int y, int w, int h, bool draw_cursor,
               std::vector<uint8_t>* out_bgra);
  // Access internal DIB buffer to composite cursor after a DXGI copy.
  uint8_t* MutableBits() const { return bits_; }
  HDC MemoryDc() const { return mem_dc_; }
  void DrawCursorOnDib(int origin_x, int origin_y);
  void CopyDibToBgra(std::vector<uint8_t>* out_bgra);
  void Reset();

 private:
  HDC screen_dc_ = nullptr;
  HDC mem_dc_ = nullptr;
  HBITMAP dib_ = nullptr;
  HGDIOBJ old_bmp_ = nullptr;
  uint8_t* bits_ = nullptr;
  int width_ = 0;
  int height_ = 0;
};

// Enumerates active physical displays in virtual-screen coordinates.
std::vector<CapturedMonitorFrame> EnumeratePhysicalMonitors();

// Returns DPI (96 = 100%) for a monitor handle.
UINT GetMonitorDpi(HMONITOR hmon);

// Captures every active physical monitor cleanly (no dead-space padding between
// mismatched displays) using DXGI Desktop Duplication with GDI fallback.
bool CaptureAllMonitorsFast(std::vector<CapturedMonitorFrame>* out_monitors);

// Captures a single monitor's pixel buffer (top-down 32bpp BGRA, alpha 0xFF).
bool CaptureSingleMonitorFast(HMONITOR hmon, const RECT& mon_rect,
                              std::vector<uint8_t>* out_bgra);

// Captures an arbitrary virtual-screen rectangle via DXGI (when enclosed in a
// single monitor) or persistent GDI fallback, optionally compositing the cursor.
bool CaptureRectFast(int x, int y, int width, int height, bool draw_cursor,
                     bool allow_cached_frame,
                     PersistentGdiRectGrabber* gdi_scratch,
                     std::vector<uint8_t>* out_bgra);

// Releases cached DXGI/D3D11 duplicator resources on application shutdown.
void ResetDxgiCapture();

#endif  // RUNNER_DXGI_CAPTURE_H_
