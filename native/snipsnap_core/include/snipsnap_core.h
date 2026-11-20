// Gene - Nov, 20, 2026: C ABI header for SnipSnap Rust native core (shared across macOS Swift and Windows C++).
#ifndef SNIPSNAP_CORE_H
#define SNIPSNAP_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SnipSnapStitcher SnipSnapStitcher;

typedef enum SnipSnapScrollAxis {
  SNIPSNAP_AXIS_AUTO = 0,
  SNIPSNAP_AXIS_VERTICAL = 1,
  SNIPSNAP_AXIS_HORIZONTAL = 2,
} SnipSnapScrollAxis;

typedef enum SnipSnapStitchStatus {
  SNIPSNAP_STITCH_OK = 0,
  SNIPSNAP_STITCH_DUPLICATE = 1,
  SNIPSNAP_STITCH_TRACKING_LOST = 2,
  SNIPSNAP_STITCH_MAX_LIMIT_REACHED = 3,
  SNIPSNAP_STITCH_ROLLED_BACK = 4,
  SNIPSNAP_STITCH_INVALID_INPUT = 5,
} SnipSnapStitchStatus;

typedef struct SnipSnapPushResult {
  int32_t status;
  int32_t delta;
  int32_t active_axis;
  int32_t total_width;
  int32_t total_height;
  int32_t frame_count;
  int32_t identical_streak;
  float confidence;
  int32_t sticky_start_px;
  int32_t sticky_end_px;
} SnipSnapPushResult;

typedef struct SnipSnapImageBuffer {
  uint8_t* data;
  int32_t width;
  int32_t height;
  int32_t stride;
  size_t len;
} SnipSnapImageBuffer;

SnipSnapStitcher* snipsnap_stitcher_create(int32_t frame_width,
                                           int32_t frame_height,
                                           int32_t max_dimension,
                                           int32_t axis_mode);

void snipsnap_stitcher_free(SnipSnapStitcher* handle);

SnipSnapPushResult snipsnap_stitcher_push_bgra(SnipSnapStitcher* handle,
                                               const uint8_t* bgra,
                                               int32_t width,
                                               int32_t height,
                                               int32_t stride);

bool snipsnap_stitcher_get_preview_bgra(const SnipSnapStitcher* handle,
                                        int32_t max_preview_width,
                                        int32_t max_preview_height,
                                        SnipSnapImageBuffer* out_buf);

bool snipsnap_stitcher_assemble_bgra(const SnipSnapStitcher* handle,
                                     SnipSnapImageBuffer* out_buf);

void snipsnap_buffer_free(SnipSnapImageBuffer* buf);

bool snipsnap_flood_fill_rgba(uint8_t* rgba,
                              int32_t width,
                              int32_t height,
                              int32_t start_x,
                              int32_t start_y,
                              uint32_t fill_rgba,
                              float tolerance_percent,
                              float opacity,
                              bool is_global);

// Gene - Nov, 20, 2026: Fast Rust pixel manipulation operations exported for Dart FFI across desktop platforms.
bool snipsnap_crop_rgba(const uint8_t* src,
                        int32_t src_w,
                        int32_t src_h,
                        int32_t crop_x,
                        int32_t crop_y,
                        int32_t crop_w,
                        int32_t crop_h,
                        uint8_t* dst);

bool snipsnap_erase_rect_rgba(uint8_t* rgba,
                              int32_t width,
                              int32_t height,
                              int32_t rect_x,
                              int32_t rect_y,
                              int32_t rect_w,
                              int32_t rect_h);

bool snipsnap_composite_rgba(uint8_t* dst,
                             int32_t dst_w,
                             int32_t dst_h,
                             const uint8_t* src,
                             int32_t src_w,
                             int32_t src_h,
                             int32_t dst_x,
                             int32_t dst_y);

bool snipsnap_resize_rgba(const uint8_t* src,
                          int32_t src_w,
                          int32_t src_h,
                          uint8_t* dst,
                          int32_t dst_w,
                          int32_t dst_h);

bool snipsnap_pixelate_region_rgba(uint8_t* rgba,
                                   int32_t width,
                                   int32_t height,
                                   int32_t rect_x,
                                   int32_t rect_y,
                                   int32_t rect_w,
                                   int32_t rect_h,
                                   int32_t block_size);

bool snipsnap_box_blur_region_rgba(uint8_t* rgba,
                                   int32_t width,
                                   int32_t height,
                                   int32_t rect_x,
                                   int32_t rect_y,
                                   int32_t rect_w,
                                   int32_t rect_h,
                                   int32_t radius);

#ifdef __cplusplus
}
#endif

#endif  // SNIPSNAP_CORE_H
