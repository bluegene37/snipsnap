// Gene - Nov, 20, 2026: Native Windows WGC (D3D11) / persistent-DC GDI + Rust snipsnap_core scrolling capture engine.
#ifndef RUNNER_SCROLLING_CAPTURE_ENGINE_H_
#define RUNNER_SCROLLING_CAPTURE_ENGINE_H_

#include <cstdint>
#include <functional>
#include <string>

struct ScrollingCaptureConfig {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  int max_dimension = 16000;
  int axis_mode = 0;
  std::wstring target_path;
  std::string target_path_utf8;
};

struct ScrollingCaptureCallbacks {
  std::function<void(int width,
                     int height,
                     int frame_count,
                     int axis,
                     int status,
                     bool paused,
                     bool auto_scrolling,
                     const std::string& warning)>
      on_progress;
  std::function<void(const std::string& path,
                     int width,
                     int height,
                     int frame_count,
                     int axis,
                     bool truncated)>
      on_completed;
  std::function<void()> on_cancel;
  std::function<void(const std::string& message)> on_error;
  std::function<bool(const uint8_t* bgra,
                     int width,
                     int height,
                     int stride,
                     const std::wstring& path)>
      save_png;
};

class ScrollingCaptureEngine {
 public:
  ScrollingCaptureEngine();
  ~ScrollingCaptureEngine();

  ScrollingCaptureEngine(const ScrollingCaptureEngine&) = delete;
  ScrollingCaptureEngine& operator=(const ScrollingCaptureEngine&) = delete;

  bool Start(const ScrollingCaptureConfig& config,
             const ScrollingCaptureCallbacks& callbacks);
  void SetAutoScroll(bool enabled);
  void Pause();
  void Resume();
  void Finish();
  void Cancel();
  bool IsActive() const;

 private:
  struct Impl;
  Impl* impl_;
};

#endif  // RUNNER_SCROLLING_CAPTURE_ENGINE_H_
