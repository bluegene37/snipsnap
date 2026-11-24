// Gene - Nov, 20, 2026: Panic-safe C ABI entry points for SnipSnap Rust native core.
use std::panic::{catch_unwind, AssertUnwindSafe};

// Gene - Nov, 24, 2026: Added capture_ops imports for dim, BGRX/RGBA format conversion, DIB decoding, click ring compositing, and PCM resampling.
// Old implementation:
// use crate::image_ops::{
//     box_blur_region_rgba, composite_rgba, crop_rgba, erase_rect_rgba, flood_fill_rgba,
//     pixelate_region_rgba, resize_rgba, RgbaColor,
// };
use crate::capture_ops::{
    bgra_to_bottom_up_bgrx, bgra_to_rgba_top_down, composite_click_ring_bgra, decode_dib_to_bgra,
    dim_bgra, pcm_to_f32_stereo_48k,
};
use crate::image_ops::{
    box_blur_region_rgba, composite_rgba, crop_rgba, erase_rect_rgba, flood_fill_rgba,
    pixelate_region_rgba, resize_rgba, RgbaColor,
};
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

// Gene - Nov, 22, 2026: Convert pixel Vec into an exact-capacity Box<[u8]> slice before forgetting so snipsnap_buffer_free never faces Vec capacity mismatch UB.
// Old implementation:
// fn into_image_buffer(mut pixels: Vec<u8>, width: usize, height: usize) -> SnipSnapImageBuffer {
//     let len = pixels.len();
//     let stride = (width * 4) as i32;
//     let ptr = pixels.as_mut_ptr();
//     std::mem::forget(pixels);
//     SnipSnapImageBuffer {
//         data: ptr,
//         width: width as i32,
//         height: height as i32,
//         stride,
//         len,
//     }
// }
fn into_image_buffer(pixels: Vec<u8>, width: usize, height: usize) -> SnipSnapImageBuffer {
    let mut boxed = pixels.into_boxed_slice();
    let len = boxed.len();
    let stride = (width * 4) as i32;
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
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
        // Gene - Nov, 22, 2026: Reclaim Box<[u8]> allocated by into_image_buffer instead of Vec::from_raw_parts(len, len) which is UB if capacity != len.
        // Old implementation:
        // if !b.data.is_null() && b.len > 0 {
        //     let _ = Vec::from_raw_parts(b.data, b.len, b.len);
        // }
        if !b.data.is_null() && b.len > 0 {
            let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(b.data, b.len));
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

// Gene - Nov, 20, 2026: Panic-safe FFI wrappers for Rust crop, erase, composite, resize, pixelate, and box blur.

#[no_mangle]
pub extern "C" fn snipsnap_crop_rgba(
    src: *const u8,
    src_w: i32,
    src_h: i32,
    crop_x: i32,
    crop_y: i32,
    crop_w: i32,
    crop_h: i32,
    dst: *mut u8,
) -> bool {
    if src.is_null()
        || dst.is_null()
        || src_w <= 0
        || src_h <= 0
        || crop_x < 0
        || crop_y < 0
        || crop_w <= 0
        || crop_h <= 0
    {
        return false;
    }
    let sw = src_w as usize;
    let sh = src_h as usize;
    let cx = crop_x as usize;
    let cy = crop_y as usize;
    let cw = crop_w as usize;
    let ch = crop_h as usize;
    let Some(src_len) = sw.checked_mul(sh).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    let Some(dst_len) = cw.checked_mul(ch).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
        crop_rgba(src_slice, sw, sh, cx, cy, cw, ch, dst_slice)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_erase_rect_rgba(
    rgba: *mut u8,
    width: i32,
    height: i32,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
) -> bool {
    if rgba.is_null() || width <= 0 || height <= 0 || rect_w <= 0 || rect_h <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let Some(len) = w.checked_mul(h).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let slice = unsafe { std::slice::from_raw_parts_mut(rgba, len) };
        erase_rect_rgba(slice, w, h, rect_x, rect_y, rect_w, rect_h)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_composite_rgba(
    dst: *mut u8,
    dst_w: i32,
    dst_h: i32,
    src: *const u8,
    src_w: i32,
    src_h: i32,
    dst_x: i32,
    dst_y: i32,
) -> bool {
    if dst.is_null() || src.is_null() || dst_w <= 0 || dst_h <= 0 || src_w <= 0 || src_h <= 0 {
        return false;
    }
    let dw = dst_w as usize;
    let dh = dst_h as usize;
    let sw = src_w as usize;
    let sh = src_h as usize;
    let Some(dst_len) = dw.checked_mul(dh).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    let Some(src_len) = sw.checked_mul(sh).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        composite_rgba(dst_slice, dw, dh, src_slice, sw, sh, dst_x, dst_y)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_resize_rgba(
    src: *const u8,
    src_w: i32,
    src_h: i32,
    dst: *mut u8,
    dst_w: i32,
    dst_h: i32,
) -> bool {
    if src.is_null() || dst.is_null() || src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0 {
        return false;
    }
    let sw = src_w as usize;
    let sh = src_h as usize;
    let dw = dst_w as usize;
    let dh = dst_h as usize;
    let Some(src_len) = sw.checked_mul(sh).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    let Some(dst_len) = dw.checked_mul(dh).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
        resize_rgba(src_slice, sw, sh, dst_slice, dw, dh)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_pixelate_region_rgba(
    rgba: *mut u8,
    width: i32,
    height: i32,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    block_size: i32,
) -> bool {
    if rgba.is_null() || width <= 0 || height <= 0 || rect_w <= 0 || rect_h <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let Some(len) = w.checked_mul(h).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let slice = unsafe { std::slice::from_raw_parts_mut(rgba, len) };
        pixelate_region_rgba(slice, w, h, rect_x, rect_y, rect_w, rect_h, block_size)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_box_blur_region_rgba(
    rgba: *mut u8,
    width: i32,
    height: i32,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    radius: i32,
) -> bool {
    if rgba.is_null() || width <= 0 || height <= 0 || rect_w <= 0 || rect_h <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let Some(len) = w.checked_mul(h).and_then(|n| n.checked_mul(4)) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let slice = unsafe { std::slice::from_raw_parts_mut(rgba, len) };
        box_blur_region_rgba(slice, w, h, rect_x, rect_y, rect_w, rect_h, radius)
    }))
    .unwrap_or(false)
}

// Gene - Nov, 24, 2026: Exported capture_ops C ABI entrypoints (dim, BGRX/RGBA conversion, CF_DIB decoder, click-ring compositor, WASAPI PCM resampler).
#[no_mangle]
pub extern "C" fn snipsnap_dim_bgra(
    src: *const u8,
    dst: *mut u8,
    width: i32,
    height: i32,
    src_stride: i32,
    dst_stride: i32,
    dim_factor: u8,
) -> bool {
    if src.is_null() || dst.is_null() || width <= 0 || height <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let ss = src_stride.max(0) as usize;
    let ds = dst_stride.max(0) as usize;
    let Some(row_bytes) = w.checked_mul(4) else {
        return false;
    };
    if ss < row_bytes || ds < row_bytes {
        return false;
    }
    let Some(src_len) = h
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(ss))
        .and_then(|o| o.checked_add(row_bytes))
    else {
        return false;
    };
    let Some(dst_len) = h
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(ds))
        .and_then(|o| o.checked_add(row_bytes))
    else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
        dim_bgra(src_slice, dst_slice, w, h, ss, ds, dim_factor)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_bgra_to_bottom_up_bgrx(
    src: *const u8,
    width: i32,
    height: i32,
    src_stride: i32,
    dst: *mut u8,
    dst_stride: i32,
) -> bool {
    if src.is_null() || dst.is_null() || width <= 0 || height <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let ss = src_stride.max(0) as usize;
    let ds = dst_stride.max(0) as usize;
    let Some(row_bytes) = w.checked_mul(4) else {
        return false;
    };
    if ss < row_bytes || ds < row_bytes {
        return false;
    }
    let Some(src_len) = h
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(ss))
        .and_then(|o| o.checked_add(row_bytes))
    else {
        return false;
    };
    let Some(dst_len) = h
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(ds))
        .and_then(|o| o.checked_add(row_bytes))
    else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
        bgra_to_bottom_up_bgrx(src_slice, w, h, ss, dst_slice, ds)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_bgra_to_rgba_top_down(
    src: *const u8,
    width: i32,
    height: i32,
    src_stride: i32,
    flip_vertical: bool,
    dst: *mut u8,
) -> bool {
    if src.is_null() || dst.is_null() || width <= 0 || height <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let ss = src_stride.max(0) as usize;
    let Some(row_bytes) = w.checked_mul(4) else {
        return false;
    };
    if ss < row_bytes {
        return false;
    }
    let Some(src_len) = h
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(ss))
        .and_then(|o| o.checked_add(row_bytes))
    else {
        return false;
    };
    let Some(dst_len) = h.checked_mul(row_bytes) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
        bgra_to_rgba_top_down(src_slice, w, h, ss, flip_vertical, dst_slice)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_decode_dib_to_bgra(
    dib_bytes: *const u8,
    dib_len: usize,
    out_buf: *mut SnipSnapImageBuffer,
) -> bool {
    if out_buf.is_null() {
        return false;
    }
    unsafe {
        *out_buf = empty_image_buffer();
    }
    if dib_bytes.is_null() || dib_len < 40 {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let dib_slice = unsafe { std::slice::from_raw_parts(dib_bytes, dib_len) };
        if let Some((bgra, w, h)) = decode_dib_to_bgra(dib_slice) {
            unsafe {
                *out_buf = into_image_buffer(bgra, w, h);
            }
            true
        } else {
            false
        }
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_composite_click_ring_bgra(
    bgra: *mut u8,
    width: i32,
    height: i32,
    stride: i32,
    cx: i32,
    cy: i32,
    progress: f32,
    is_right_click: bool,
) -> bool {
    if bgra.is_null() || width <= 0 || height <= 0 {
        return false;
    }
    let w = width as usize;
    let h = height as usize;
    let s = stride.max(0) as usize;
    let Some(row_bytes) = w.checked_mul(4) else {
        return false;
    };
    if s < row_bytes {
        return false;
    }
    let Some(len) = h
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(s))
        .and_then(|o| o.checked_add(row_bytes))
    else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let slice = unsafe { std::slice::from_raw_parts_mut(bgra, len) };
        composite_click_ring_bgra(slice, w, h, s, cx, cy, progress, is_right_click)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub extern "C" fn snipsnap_pcm_to_f32_stereo_48k(
    src: *const u8,
    src_len: usize,
    num_frames: u32,
    channels: u32,
    bits_per_sample: u32,
    is_float: bool,
    sample_rate: u32,
    io_phase: *mut f64,
    out_stereo: *mut f32,
    out_cap_floats: usize,
    out_written_floats: *mut usize,
) -> bool {
    if !out_written_floats.is_null() {
        unsafe {
            *out_written_floats = 0;
        }
    }
    if src.is_null()
        || io_phase.is_null()
        || out_stereo.is_null()
        || out_written_floats.is_null()
        || src_len == 0
        || num_frames == 0
        || channels == 0
        || sample_rate == 0
    {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let src_slice = unsafe { std::slice::from_raw_parts(src, src_len) };
        let mut phase = unsafe { *io_phase };
        let mut tmp = Vec::new();
        if !pcm_to_f32_stereo_48k(
            src_slice,
            num_frames as usize,
            channels as usize,
            bits_per_sample as usize,
            is_float,
            sample_rate,
            &mut phase,
            &mut tmp,
        ) {
            return false;
        }
        if tmp.len() > out_cap_floats {
            return false;
        }
        let dst = unsafe { std::slice::from_raw_parts_mut(out_stereo, out_cap_floats) };
        dst[..tmp.len()].copy_from_slice(&tmp);
        unsafe {
            *io_phase = phase;
            *out_written_floats = tmp.len();
        }
        true
    }))
    .unwrap_or(false)
}
