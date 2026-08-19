#include "ocr_handler.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

// C++/WinRT projections. `winrt/base.h` comes in via any of these; it is not
// included directly on purpose, since including it *after* a projection header
// is what produces the "you must include winrt/base.h first" style errors.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

// For CoIncrementMTAUsage. Reached via windows.h in practice, but named
// explicitly so the dependency is not silently lost to a WIN32_LEAN_AND_MEAN.
#include <combaseapi.h>

#include <algorithm>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace {

namespace wf = winrt::Windows::Foundation;
namespace wgi = winrt::Windows::Graphics::Imaging;
namespace wmo = winrt::Windows::Media::Ocr;
namespace wss = winrt::Windows::Storage::Streams;

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

using OcrMethodResult = flutter::MethodResult<EncodableValue>;

constexpr char kChannelName[] = "snipsnap/ocr";

// The common failure on Windows: OCR is a per-language optional feature, and a
// stock install of Windows often has none. The message names where to fix it.
constexpr char kNoLanguagePackReason[] =
    "No OCR language pack is installed. Add one in Settings > Time & language "
    "> Language & region: pick a language, choose Language options, and "
    "install its Optical character recognition feature.";

std::string ToUtf8(winrt::hstring const& value) {
  return winrt::to_string(value);
}

// ---------------------------------------------------------------------------
// Engine lifetime
// ---------------------------------------------------------------------------

// Guards the engine pointer against use after `FlutterWindow::OnDestroy` has
// torn the engine down.
//
// Workers run on detached threads and post their replies back through the
// engine. Without this gate, an OCR call still in flight when the window closes
// would call `PostPlatformThreadTask` on freed memory. `ShutdownOcrHandler`
// nulls `engine` under the mutex, and every post takes the same mutex, so a
// worker either posts to a live engine or sees null and drops the reply.
//
// Taking the mutex around the post cannot deadlock: `PostPlatformThreadTask`
// only queues a task, it never waits on the platform thread.
struct EngineGate {
  std::mutex mutex;
  flutter::FlutterEngine* engine = nullptr;
};

// Written and read only on the platform thread (registration and teardown).
// Workers hold their own `shared_ptr` copy, so the gate outlives them.
std::shared_ptr<EngineGate>& Gate() {
  static std::shared_ptr<EngineGate> gate;
  return gate;
}

// Keeps the process-wide multi-threaded apartment alive for the process's
// lifetime.
//
// Each worker calls `init_apartment(multi_threaded)` / `uninit_apartment()`
// around its work. Since nothing else in this process joins the MTA, that pair
// is the *only* thing holding the process MTA open — so the last uninit tears
// it down again, and the OCR runtime's COM servers get unloaded and reloaded on
// every single call. That is not a correctness bug; it presents purely as
// "Windows OCR is slow", with a cause that profiling will not point at.
//
// `CoIncrementMTAUsage` pins the MTA *without* making the calling thread a
// member of it, which is exactly what is wanted: the platform thread stays an
// STA. The cookie is deliberately never released — the pin is meant to last as
// long as the process.
void PinProcessMta() {
  static CO_MTA_USAGE_COOKIE cookie = nullptr;
  if (cookie) return;
  HRESULT const result = ::CoIncrementMTAUsage(&cookie);
  if (FAILED(result)) {
    // Non-fatal: workers still create the MTA themselves, they just pay to
    // rebuild it on each call.
    cookie = nullptr;
  }
}

// ---------------------------------------------------------------------------
// Replying exactly once, on the platform thread
// ---------------------------------------------------------------------------

// Delivers a `MethodResult` exactly once, always on the platform thread.
//
// Two distinct hazards are handled here.
//
// *Delivery.* If a `MethodResult` is destroyed without `Success`/`Error` having
// been called, the Flutter client wrapper merely prints "Failed to respond to a
// message" and the Dart `Future` never completes. Nothing in the Dart OCR path
// has a timeout, so the result panel would spin forever with no recovery. The
// destructor below is therefore a last-resort error reply; every normal path
// drains the sink first, which makes it a no-op there. This mirrors the
// drain-once `ResultSink` in `macos/Runner/OcrPlugin.swift`.
//
// *Thread affinity.* All the WinRT work happens on a worker thread (see
// `RunOnWorker`), but a `MethodResult` must be answered on the platform thread,
// so every reply is bounced back through `FlutterEngine::PostPlatformThreadTask`
// — documented as callable from any thread and as running the callback exactly
// once on the platform thread.
//
// Only one thread ever touches a given sink (the worker it was moved into), so
// its own state needs no lock; the lock inside `Deliver` protects the *engine*,
// not the sink.
class ResultSink {
 public:
  ResultSink(std::shared_ptr<EngineGate> gate,
             std::shared_ptr<OcrMethodResult> result)
      : gate_(std::move(gate)), result_(std::move(result)) {}

  ~ResultSink() {
    Error("ocr_failed", "The OCR handler finished without producing a result.");
  }

  ResultSink(ResultSink const&) = delete;
  ResultSink& operator=(ResultSink const&) = delete;

  void Success(EncodableValue value) {
    Deliver([value](OcrMethodResult& result) { result.Success(value); });
  }

  void Error(std::string code, std::string message) {
    Deliver([code, message](OcrMethodResult& result) {
      result.Error(code, message);
    });
  }

  void NotImplemented() {
    Deliver([](OcrMethodResult& result) { result.NotImplemented(); });
  }

 private:
  void Deliver(std::function<void(OcrMethodResult&)> send) {
    // Drain first: whatever happens next, this sink is spent.
    std::shared_ptr<OcrMethodResult> result = std::move(result_);
    result_.reset();
    if (!result) return;

    std::lock_guard<std::mutex> lock(gate_->mutex);
    // Null once the engine has been torn down. Dropping the reply is the only
    // safe move then — the Dart isolate is going away with it.
    if (!gate_->engine) return;

    // `PostPlatformThreadTask` takes a `std::function`, which must be
    // copy-constructible. That is why `result` is a `shared_ptr` rather than
    // the `unique_ptr` the channel handed us: a move-only capture would not
    // fit in a `std::function`.
    gate_->engine->PostPlatformThreadTask(
        [result, send]() { send(*result); });
  }

  std::shared_ptr<EngineGate> gate_;
  std::shared_ptr<OcrMethodResult> result_;
};

// Runs |work| on a detached worker thread inside a multi-threaded apartment.
//
// This cannot run on the platform thread, for two independent reasons:
//
//  * The platform thread is a single-threaded apartment — `main.cpp` calls
//    `CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)` before the message
//    loop. C++/WinRT forbids blocking `.get()` on an async operation from an
//    STA thread: it asserts in debug builds and risks deadlocking the message
//    pump in release ones. Every WinRT call below is a blocking `.get()`.
//  * OCR on a full-screen capture takes long enough to visibly stall the UI.
//
// The worker initialises its own apartment because a fresh thread has none, and
// any WinRT call without one fails with CO_E_NOTINITIALIZED. Multi-threaded is
// both the correct choice for a worker and the one that makes `.get()` legal.
// `PinProcessMta` (called once at registration) stops that apartment from being
// torn down and rebuilt between calls.
//
// |sink| is a `shared_ptr` rather than a `unique_ptr` specifically so that a
// failure to *start* the thread still leaves this function holding a live sink
// to answer with.
void RunOnWorker(std::shared_ptr<ResultSink> sink,
                 std::function<void(ResultSink&)> work) {
  try {
    std::thread([sink, work = std::move(work)]() mutable {
      bool apartment_ready = false;
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        apartment_ready = true;
        work(*sink);
      } catch (winrt::hresult_error const& error) {
        sink->Error("winrt_error", ToUtf8(error.message()));
      } catch (...) {
        sink->Error("ocr_failed",
                    "The OCR worker failed with an unknown error.");
      }
      // Drain the sink (and thus release everything it holds) *before* tearing
      // the apartment down. The sink itself holds no WinRT objects, but
      // anything `work` created must already be gone by this point — it is,
      // since `work` has returned and its locals were scoped to it.
      sink.reset();
      if (apartment_ready) winrt::uninit_apartment();
    }).detach();
  } catch (...) {
    // The thread never started, so no worker will ever drain the sink. Answer
    // it here rather than letting the exception unwind into Flutter's C
    // boundary, which is undefined behaviour.
    //
    // Note this catch only helps if the runner is ever built with STL
    // exceptions enabled: under the `_HAS_EXCEPTIONS=0` that
    // APPLY_STANDARD_SETTINGS currently sets, a failed `std::thread`
    // construction calls std::terminate instead of throwing, and nothing can
    // intercept it. Cheap either way, and correct if that flag ever changes.
    sink->Error("ocr_failed", "Could not start the OCR worker thread.");
  }
}

// ---------------------------------------------------------------------------
// Windows.Media.Ocr
// ---------------------------------------------------------------------------

// Builds an OCR engine, or a null engine when no language pack is installed.
//
// `TryCreateFromUserProfileLanguages` is the good path, but it returns null
// whenever none of the user's own display languages has its OCR feature
// installed — which is common. Falling back to any installed recognizer is
// better than refusing outright.
wmo::OcrEngine CreateEngine() {
  if (auto engine = wmo::OcrEngine::TryCreateFromUserProfileLanguages()) {
    return engine;
  }

  auto languages = wmo::OcrEngine::AvailableRecognizerLanguages();
  if (languages.Size() == 0) return nullptr;
  return wmo::OcrEngine::TryCreateFromLanguage(languages.GetAt(0));
}

EncodableList AvailableLanguageTags() {
  EncodableList tags;
  for (auto const& language : wmo::OcrEngine::AvailableRecognizerLanguages()) {
    tags.push_back(EncodableValue(ToUtf8(language.LanguageTag())));
  }
  return tags;
}

void HandleAvailability(ResultSink& sink) {
  EncodableList languages = AvailableLanguageTags();

  // Availability is decided by actually building the engine `recognize` would
  // build, not just by the language list, so what we advertise cannot drift
  // from what we attempt. Same rule as the macOS plugin's single
  // configuration point.
  if (languages.empty() || !CreateEngine()) {
    sink.Success(EncodableValue(EncodableMap{
        {EncodableValue("available"), EncodableValue(false)},
        {EncodableValue("reason"),
         EncodableValue(std::string(kNoLanguagePackReason))},
        {EncodableValue("languages"), EncodableValue(EncodableList{})},
    }));
    return;
  }

  // `reason` is omitted when available; Dart reads it as `String?` and gets
  // null, exactly as it does from macOS.
  sink.Success(EncodableValue(EncodableMap{
      {EncodableValue("available"), EncodableValue(true)},
      {EncodableValue("languages"), EncodableValue(languages)},
  }));
}

// Builds the `{text, x, y, w, h, confidence}` map both lines and words use.
//
// COORDINATES: Windows.Media.Ocr reports `OcrWord::BoundingRect` in image
// PIXELS with a TOP-LEFT origin — precisely the convention Dart expects — so
// nothing is flipped, scaled or normalised here. This differs from
// `macos/Runner/OcrPlugin.swift`, which *does* convert, because Vision reports
// normalised boxes with a bottom-left origin. Do not "align" this file with the
// Swift by adding a flip; the two are correct in different ways.
//
// ROTATION: `OcrResult::TextAngle` is deliberately ignored. Windows de-skews
// internally, so when it detects rotated text the word rects come back in the
// *de-rotated* frame; landing them on source pixels would mean rotating each
// box by `TextAngle` about the image centre. SnipSnap OCRs screen regions,
// which are axis-aligned, so `TextAngle` is null in practice and the impact
// today is nil. Revisit only if OCR is ever pointed at photographed or scanned
// input.
//
// CONFIDENCE: Windows OCR exposes no per-line or per-word score, so a constant
// 1.0 stands in. Dart only carries the value through — nothing filters or
// renders on it — so the constant cannot change what the user sees. macOS
// reports Vision's real score; the platforms deliberately differ here.
EncodableMap RectPayload(std::string text, wf::Rect const& rect) {
  return EncodableMap{
      {EncodableValue("text"), EncodableValue(text)},
      {EncodableValue("x"), EncodableValue(static_cast<double>(rect.X))},
      {EncodableValue("y"), EncodableValue(static_cast<double>(rect.Y))},
      {EncodableValue("w"), EncodableValue(static_cast<double>(rect.Width))},
      {EncodableValue("h"), EncodableValue(static_cast<double>(rect.Height))},
      {EncodableValue("confidence"), EncodableValue(1.0)},
  };
}

// Decodes |png| into a SoftwareBitmap that `RecognizeAsync` will accept.
wgi::SoftwareBitmap DecodePng(std::vector<uint8_t> const& png) {
  wss::InMemoryRandomAccessStream stream;
  {
    wss::DataWriter writer(stream);
    writer.WriteBytes(
        winrt::array_view<uint8_t const>(png.data(), png.data() + png.size()));
    writer.StoreAsync().get();
    // A DataWriter closes the stream it wraps when it is destroyed, which would
    // leave BitmapDecoder with nothing to read. Detaching hands the stream back
    // to us intact, so the writer's destructor has nothing to close.
    writer.DetachStream();
  }
  stream.Seek(0);

  auto decoder = wgi::BitmapDecoder::CreateAsync(stream).get();
  auto bitmap = decoder.GetSoftwareBitmapAsync().get();

  // `RecognizeAsync` only accepts a narrow set of pixel formats. The
  // parameterless `GetSoftwareBitmapAsync` is documented to return
  // Bgra8/Premultiplied, so this conversion is expected to be a no-op — it is
  // here as cheap insurance against an E_INVALIDARG that cannot be reproduced
  // off Windows.
  if (bitmap.BitmapPixelFormat() != wgi::BitmapPixelFormat::Bgra8 ||
      bitmap.BitmapAlphaMode() == wgi::BitmapAlphaMode::Straight) {
    bitmap = wgi::SoftwareBitmap::Convert(bitmap, wgi::BitmapPixelFormat::Bgra8,
                                          wgi::BitmapAlphaMode::Premultiplied);
  }
  return bitmap;
}

void HandleRecognize(std::vector<uint8_t> const& png, ResultSink& sink) {
  auto engine = CreateEngine();
  if (!engine) {
    sink.Error("no_engine", kNoLanguagePackReason);
    return;
  }

  if (png.empty()) {
    sink.Error("decode_failed", "Received no PNG bytes to recognise.");
    return;
  }

  wgi::SoftwareBitmap bitmap = DecodePng(png);

  // `RecognizeAsync` throws on images past the engine's limit (10000px at time
  // of writing). Reporting it is friendlier than surfacing the raw HRESULT.
  uint32_t const max_dimension = wmo::OcrEngine::MaxImageDimension();
  int32_t const width = bitmap.PixelWidth();
  int32_t const height = bitmap.PixelHeight();
  if (width < 1 || height < 1) {
    sink.Error("decode_failed", "The decoded image was empty.");
    return;
  }
  // Cast rather than compare signed against unsigned: /W4 /WX is on.
  if (static_cast<uint32_t>(width) > max_dimension ||
      static_cast<uint32_t>(height) > max_dimension) {
    sink.Error("image_too_large",
               "The image is larger than Windows OCR can process (" +
                   std::to_string(max_dimension) + "px per side).");
    return;
  }

  auto recognized = engine.RecognizeAsync(bitmap).get();

  EncodableList lines;
  for (auto const& line : recognized.Lines()) {
    EncodableList words;

    bool has_box = false;
    float left = 0.0f;
    float top = 0.0f;
    float right = 0.0f;
    float bottom = 0.0f;

    for (auto const& word : line.Words()) {
      wf::Rect const box = word.BoundingRect();
      words.push_back(EncodableValue(RectPayload(ToUtf8(word.Text()), box)));

      if (!has_box) {
        left = box.X;
        top = box.Y;
        right = box.X + box.Width;
        bottom = box.Y + box.Height;
        has_box = true;
      } else {
        // Parenthesised so the NOMINMAX-disabled windows.h macros cannot be
        // reintroduced by a future include and hijack these calls.
        left = (std::min)(left, box.X);
        top = (std::min)(top, box.Y);
        right = (std::max)(right, box.X + box.Width);
        bottom = (std::max)(bottom, box.Y + box.Height);
      }
    }

    // `OcrLine` has no bounding rect of its own in the Windows API — only its
    // words do — so the line box is the union of the word boxes.
    //
    // A line with zero words yields an explicit {0,0,0,0} rather than a rect
    // built from uninitialised or sentinel bounds. That is the same value the
    // Dart parser already falls back to for a missing box (`_rect` defaults
    // every component to 0.0), so an empty union lands on a value the rest of
    // the app already handles instead of a garbage one such as
    // {FLT_MAX, FLT_MAX, -FLT_MAX, -FLT_MAX}.
    wf::Rect const line_box =
        has_box ? wf::Rect{left, top, (std::max)(0.0f, right - left),
                           (std::max)(0.0f, bottom - top)}
                : wf::Rect{0.0f, 0.0f, 0.0f, 0.0f};

    EncodableMap payload = RectPayload(ToUtf8(line.Text()), line_box);
    payload[EncodableValue("words")] = EncodableValue(words);
    lines.push_back(EncodableValue(payload));
  }

  // No text in the image is a normal outcome: `lines` is simply empty, which
  // Dart turns into an empty `OcrResult`.
  sink.Success(EncodableValue(EncodableMap{
      {EncodableValue("width"), EncodableValue(width)},
      {EncodableValue("height"), EncodableValue(height)},
      {EncodableValue("lines"), EncodableValue(lines)},
  }));
}

}  // namespace

void RegisterOcrHandler(flutter::FlutterEngine* engine) {
  if (!engine) return;

  // A second registration would orphan the previous gate with a stale but
  // non-null engine pointer, and any worker still holding that gate would post
  // to freed memory. Retiring the old gate first makes re-registration safe by
  // construction. (Unreachable in this runner — OnCreate runs once.)
  ShutdownOcrHandler();

  // Pin the process MTA before any worker exists, so the apartment is not torn
  // down and rebuilt between calls. See PinProcessMta.
  PinProcessMta();

  auto gate = std::make_shared<EngineGate>();
  gate->engine = engine;
  Gate() = gate;

  // Deliberately leaked. The channel must outlive every in-flight call, and a
  // static `unique_ptr` would instead destroy it during static teardown, at an
  // unspecified point relative to the engine's own destruction.
  auto* channel = new flutter::MethodChannel<EncodableValue>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [gate](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<OcrMethodResult> result) {
        // The channel hands us a move-only `unique_ptr`, but the reply has to
        // travel inside a `std::function` (see `ResultSink::Deliver`), which
        // requires a copyable capture. Convert once, here.
        auto shared = std::shared_ptr<OcrMethodResult>(std::move(result));
        auto sink = std::make_shared<ResultSink>(gate, std::move(shared));

        if (call.method_name() == "availability") {
          RunOnWorker(std::move(sink),
                      [](ResultSink& s) { HandleAvailability(s); });
          return;
        }

        if (call.method_name() == "recognize") {
          // `get_if` rather than `get`: the runner is built with
          // _HAS_EXCEPTIONS=0, under which a bad `std::get` on a variant
          // terminates the process instead of throwing.
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          if (!args) {
            sink->Error("bad_args", "Expected a map of arguments.");
            return;
          }
          const auto entry = args->find(EncodableValue("png"));
          if (entry == args->end()) {
            sink->Error("bad_args", "png bytes missing");
            return;
          }
          const auto* png = std::get_if<std::vector<uint8_t>>(&entry->second);
          if (!png) {
            sink->Error("bad_args", "png must be a Uint8List");
            return;
          }

          // Copied into the worker: the EncodableValue behind `png` belongs to
          // the method call and dies when this handler returns.
          RunOnWorker(std::move(sink), [bytes = *png](ResultSink& s) {
            HandleRecognize(bytes, s);
          });
          return;
        }

        sink->NotImplemented();
      });
}

void ShutdownOcrHandler() {
  auto gate = Gate();
  if (!gate) return;
  std::lock_guard<std::mutex> lock(gate->mutex);
  gate->engine = nullptr;
}
