// Gene - Nov, 20, 2026: Panic-safe C ABI entry points for SnipSnap Rust native core.
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::image_ops::{flood_fill_rgba, RgbaColor};
use crate::stitcher::{PushResult, ScrollAxis, ScrollStitcher, StitchStatus};

#[repr(C)]
pub struct SnipSnapImageBuffer {
    pub data: *mut u8,
    pub width: i32,
    pub height: i32,
    pub stride: i32,
    pub len: usize,
}

fn empty_image_buffer() -> SnipSnapImageBuffer {
    SnipSnapImageBuffer {
        data: std::ptr::null_mut(),
        width: 0,
        height: 0,
        stride: 0,
        len: 0,
    }
}

fn into_image_buffer(mut pixels: Vec<u8>, width: usize, height: usize) -> SnipSnapImageBuffer {
    let len = pixels.len();
    let stride = (width * 4) as i32;
    let ptr = pixels.as_mut_ptr();
    std::mem::forget(pixels);
    SnipSnapImageBuffer {
        data: ptr,
        width: width as i32,
        height: height as i32,
        stride,
        len,
    }
}

#[no_mangle]
pub extern "C" fn snipsnap_stitcher_create(
    frame_width: i32,
    frame_height: i32,
    max_dimension: i32,
    axis_mode: i32,
) -> *mut ScrollStitcher {
    if frame_width <= 0 || frame_height <= 0 {
        return std::ptr::null_mut();
    }
    let axis = match axis_mode {
        1 => ScrollAxis::Vertical,
        2 => ScrollAxis::Horizontal,
        _ => ScrollAxis::Auto,
    };
    let max_dim = if max_dimension > 0 {
        max_dimension as usize
    } else {
        16000
    };
    let res = catch_unwind(|| {
        Box::into_raw(Box::new(ScrollStitcher::new(
            frame_width as usize,
            frame_height as usize,
            max_dim,
            axis,
        )))
    });
    res.unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn snipsnap_stitcher_free(handle: *mut ScrollStitcher) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(handle));
    }));
}

#[no_mangle]
pub extern "C" fn snipsnap_stitcher_push_bgra(
    handle: *mut ScrollStitcher,
    bgra: *const u8,
    width: i32,
    height: i32,
    stride: i32,
) -> PushResult {
    let invalid = PushResult {
        status: StitchStatus::InvalidInput as i32,
        delta: 0,
        active_axis: 0,
        total_width: 0,
        total_height: 0,
        frame_count: 0,
        identical_streak: 0,
        confidence: 0.0,
        sticky_start_px: 0,
        sticky_end_px: 0,
    };
    if handle.is_null() || bgra.is_null() || width <= 0 || height <= 0 || stride < width * 4 {
        return invalid;
    }

    let w = width as usize;
    let h = height as usize;
    let s = stride as usize;
    let byte_len = match (h - 1).checked_mul(s).and_then(|o| o.checked_add(w * 4)) {
        Some(len) => len,
        None => return invalid,
    };

    let res = catch_unwind(AssertUnwindSafe(|| {
        let stitcher = unsafe { &mut *handle };
        let slice = unsafe { std::slice::from_raw_parts(bgra, byte_len) };
        stitcher.push_bgra(slice, w, h, s)
    }));
    res.unwrap_or(invalid)
}

#[no_mangle]
pub extern "C" fn snipsnap_stitcher_get_preview_bgra(
    handle: *const ScrollStitcher,
    max_preview_width: i32,
    max_preview_height: i32,
    out_buf: *mut SnipSnapImageBuffer,
) -> bool {
    if handle.is_null() || out_buf.is_null() || max_preview_width <= 0 || max_preview_height <= 0 {
        return false;
    }
    let res = catch_unwind(AssertUnwindSafe(|| {
        let stitcher = unsafe { &*handle };
        if let Some((pixels, w, h)) =
            stitcher.generate_preview_bgra(max_preview_width as usize, max_preview_height as usize)
        {
            unsafe {
                *out_buf = into_image_buffer(pixels, w, h);
            }
            true
        } else {
            unsafe {
                *out_buf = empty_image_buffer();
            }
            false
        }
    }));
    res.unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_stitcher_assemble_bgra(
    handle: *const ScrollStitcher,
    out_buf: *mut SnipSnapImageBuffer,
) -> bool {
    if handle.is_null() || out_buf.is_null() {
        return false;
    }
    let res = catch_unwind(AssertUnwindSafe(|| {
        let stitcher = unsafe { &*handle };
        if let Some((pixels, w, h)) = stitcher.assemble_bgra() {
            unsafe {
                *out_buf = into_image_buffer(pixels, w, h);
            }
            true
        } else {
            unsafe {
                *out_buf = empty_image_buffer();
            }
            false
        }
    }));
    res.unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_buffer_free(buf: *mut SnipSnapImageBuffer) {
    if buf.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let b = &mut *buf;
        if !b.data.is_null() && b.len > 0 {
            let _ = Vec::from_raw_parts(b.data, b.len, b.len);
        }
        *b = empty_image_buffer();
    }));
}

#[no_mangle]
pub extern "C" fn snipsnap_flood_fill_rgba(
    rgba: *mut u8,
    width: i32,
    height: i32,
    start_x: i32,
    start_y: i32,
    fill_rgba: u32,
    tolerance_percent: f32,
    opacity: f32,
    is_global: bool,
) -> bool {
    if rgba.is_null() || width <= 0 || height <= 0 || start_x < 0 || start_y < 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let len = match w.checked_mul(h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    let res = catch_unwind(AssertUnwindSafe(|| {
        let slice = unsafe { std::slice::from_raw_parts_mut(rgba, len) };
        flood_fill_rgba(
            slice,
            w,
            h,
            start_x as usize,
            start_y as usize,
            RgbaColor::from_packed_rgba(fill_rgba),
            tolerance_percent,
            opacity,
            is_global,
        )
    }));
    res.unwrap_or(false)
}
