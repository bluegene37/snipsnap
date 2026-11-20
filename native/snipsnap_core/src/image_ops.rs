// Gene - Nov, 20, 2026: Fast zero-dependency RGBA scanline flood fill and BGRA preview helpers in Rust.
#[derive(Clone, Copy)]
pub struct RgbaColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl RgbaColor {
    pub fn from_packed_rgba(packed: u32) -> Self {
        Self {
            r: ((packed >> 24) & 0xFF) as u8,
            g: ((packed >> 16) & 0xFF) as u8,
            b: ((packed >> 8) & 0xFF) as u8,
            a: (packed & 0xFF) as u8,
        }
    }
}

pub fn flood_fill_rgba(
    rgba: &mut [u8],
    width: usize,
    height: usize,
    start_x: usize,
    start_y: usize,
    fill_color: RgbaColor,
    tolerance_percent: f32,
    opacity: f32,
    is_global: bool,
) -> bool {
    if width == 0 || height == 0 || start_x >= width || start_y >= height {
        return false;
    }
    let expected_len = match width.checked_mul(height).and_then(|n| n.checked_mul(4)) {
        Some(len) => len,
        None => return false,
    };
    if rgba.len() < expected_len {
        return false;
    }

    let start_offset = (start_y * width + start_x) * 4;
    let src_r = rgba[start_offset] as i32;
    let src_g = rgba[start_offset + 1] as i32;
    let src_b = rgba[start_offset + 2] as i32;
    let src_a = rgba[start_offset + 3] as i32;

    let dest_a = ((fill_color.a as f32) * opacity.clamp(0.0, 1.0))
        .round()
        .clamp(0.0, 255.0) as u8;
    let dest_r = fill_color.r;
    let dest_g = fill_color.g;
    let dest_b = fill_color.b;

    if src_r == dest_r as i32
        && src_g == dest_g as i32
        && src_b == dest_b as i32
        && src_a == dest_a as i32
    {
        return false;
    }

    let tol_norm = (tolerance_percent / 100.0).clamp(0.0, 1.0);
    let is_src_transparent = src_a <= 10;
    let max_transparent_alpha = (tol_norm * 255.0).floor() as i32;
    let max_dist = tol_norm * 510.0;
    let max_dist_sq = (max_dist * max_dist) as i64;

    if is_global {
        for chunk in rgba[..expected_len].chunks_exact_mut(4) {
            if matches_px(
                chunk,
                src_r,
                src_g,
                src_b,
                src_a,
                is_src_transparent,
                max_transparent_alpha,
                max_dist_sq,
            ) {
                chunk[0] = dest_r;
                chunk[1] = dest_g;
                chunk[2] = dest_b;
                chunk[3] = dest_a;
            }
        }
        return true;
    }

    let mut visited = vec![0u8; width * height];
    let mut stack: Vec<(usize, usize)> = Vec::with_capacity(256);
    stack.push((start_x, start_y));
    let mut first_seed = true;

    while let Some((sx, sy)) = stack.pop() {
        let row_base = sy * width;
        let seed_idx = row_base + sx;
        if visited[seed_idx] != 0
            || (!first_seed
                && !matches_at(
                    rgba,
                    seed_idx * 4,
                    src_r,
                    src_g,
                    src_b,
                    src_a,
                    is_src_transparent,
                    max_transparent_alpha,
                    max_dist_sq,
                ))
        {
            first_seed = false;
            continue;
        }
        first_seed = false;

        let mut lx = sx;
        while lx > 0 {
            let prev = row_base + lx - 1;
            if visited[prev] != 0
                || !matches_at(
                    rgba,
                    prev * 4,
                    src_r,
                    src_g,
                    src_b,
                    src_a,
                    is_src_transparent,
                    max_transparent_alpha,
                    max_dist_sq,
                )
            {
                break;
            }
            lx -= 1;
        }
        let mut rx = sx;
        while rx + 1 < width {
            let next = row_base + rx + 1;
            if visited[next] != 0
                || !matches_at(
                    rgba,
                    next * 4,
                    src_r,
                    src_g,
                    src_b,
                    src_a,
                    is_src_transparent,
                    max_transparent_alpha,
                    max_dist_sq,
                )
            {
                break;
            }
            rx += 1;
        }

        for x in lx..=rx {
            let idx = row_base + x;
            visited[idx] = 1;
            let o = idx * 4;
            rgba[o] = dest_r;
            rgba[o + 1] = dest_g;
            rgba[o + 2] = dest_b;
            rgba[o + 3] = dest_a;
        }

        if sy > 0 {
            enqueue_runs(
                rgba,
                &visited,
                width,
                sy - 1,
                lx,
                rx,
                src_r,
                src_g,
                src_b,
                src_a,
                is_src_transparent,
                max_transparent_alpha,
                max_dist_sq,
                &mut stack,
            );
        }
        if sy + 1 < height {
            enqueue_runs(
                rgba,
                &visited,
                width,
                sy + 1,
                lx,
                rx,
                src_r,
                src_g,
                src_b,
                src_a,
                is_src_transparent,
                max_transparent_alpha,
                max_dist_sq,
                &mut stack,
            );
        }
    }

    true
}

#[inline(always)]
#[allow(clippy::too_many_arguments)]
fn matches_px(
    px: &[u8],
    src_r: i32,
    src_g: i32,
    src_b: i32,
    src_a: i32,
    is_src_transparent: bool,
    max_transparent_alpha: i32,
    max_dist_sq: i64,
) -> bool {
    let pa = px[3] as i32;
    if is_src_transparent {
        return pa <= max_transparent_alpha || (src_a == 0 && pa == 0);
    }
    let dr = px[0] as i64 - src_r as i64;
    let dg = px[1] as i64 - src_g as i64;
    let db = px[2] as i64 - src_b as i64;
    let da = pa as i64 - src_a as i64;
    (dr * dr + dg * dg + db * db + da * da) <= max_dist_sq
}

#[inline(always)]
#[allow(clippy::too_many_arguments)]
fn matches_at(
    rgba: &[u8],
    offset: usize,
    src_r: i32,
    src_g: i32,
    src_b: i32,
    src_a: i32,
    is_src_transparent: bool,
    max_transparent_alpha: i32,
    max_dist_sq: i64,
) -> bool {
    matches_px(
        &rgba[offset..offset + 4],
        src_r,
        src_g,
        src_b,
        src_a,
        is_src_transparent,
        max_transparent_alpha,
        max_dist_sq,
    )
}

#[allow(clippy::too_many_arguments)]
fn enqueue_runs(
    rgba: &[u8],
    visited: &[u8],
    width: usize,
    ny: usize,
    lx: usize,
    rx: usize,
    src_r: i32,
    src_g: i32,
    src_b: i32,
    src_a: i32,
    is_src_transparent: bool,
    max_transparent_alpha: i32,
    max_dist_sq: i64,
    stack: &mut Vec<(usize, usize)>,
) {
    let row_base = ny * width;
    let mut in_span = false;
    for x in lx..=rx {
        let idx = row_base + x;
        if visited[idx] == 0
            && matches_at(
                rgba,
                idx * 4,
                src_r,
                src_g,
                src_b,
                src_a,
                is_src_transparent,
                max_transparent_alpha,
                max_dist_sq,
            )
        {
            if !in_span {
                stack.push((x, ny));
                in_span = true;
            }
        } else {
            in_span = false;
        }
    }
}

// Gene - Nov, 20, 2026: Fast zero-dependency RGBA pixel operations (crop, erase, composite, resize, pixelate, box blur) for Dart FFI.

pub fn crop_rgba(
    src: &[u8],
    src_w: usize,
    src_h: usize,
    crop_x: usize,
    crop_y: usize,
    crop_w: usize,
    crop_h: usize,
    dst: &mut [u8],
) -> bool {
    if src_w == 0 || src_h == 0 || crop_w == 0 || crop_h == 0 {
        return false;
    }
    if crop_x + crop_w > src_w || crop_y + crop_h > src_h {
        return false;
    }
    let src_len = match src_w.checked_mul(src_h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    let dst_len = match crop_w.checked_mul(crop_h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    if src.len() < src_len || dst.len() < dst_len {
        return false;
    }

    let row_bytes = crop_w * 4;
    for row in 0..crop_h {
        let src_off = ((crop_y + row) * src_w + crop_x) * 4;
        let dst_off = row * row_bytes;
        dst[dst_off..dst_off + row_bytes].copy_from_slice(&src[src_off..src_off + row_bytes]);
    }
    true
}

pub fn erase_rect_rgba(
    rgba: &mut [u8],
    width: usize,
    height: usize,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
) -> bool {
    if width == 0 || height == 0 || rect_w <= 0 || rect_h <= 0 {
        return false;
    }
    let expected = match width.checked_mul(height).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    if rgba.len() < expected {
        return false;
    }

    let x0 = rect_x.max(0).min(width as i32) as usize;
    let y0 = rect_y.max(0).min(height as i32) as usize;
    let x1 = (rect_x as i64 + rect_w as i64)
        .max(0)
        .min(width as i64) as usize;
    let y1 = (rect_y as i64 + rect_h as i64)
        .max(0)
        .min(height as i64) as usize;
    if x1 <= x0 || y1 <= y0 {
        return true;
    }

    let span_bytes = (x1 - x0) * 4;
    for y in y0..y1 {
        let off = (y * width + x0) * 4;
        rgba[off..off + span_bytes].fill(0);
    }
    true
}

pub fn composite_rgba(
    dst: &mut [u8],
    dst_w: usize,
    dst_h: usize,
    src: &[u8],
    src_w: usize,
    src_h: usize,
    dst_x: i32,
    dst_y: i32,
) -> bool {
    if dst_w == 0 || dst_h == 0 || src_w == 0 || src_h == 0 {
        return false;
    }
    let dst_len = match dst_w.checked_mul(dst_h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    let src_len = match src_w.checked_mul(src_h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    if dst.len() < dst_len || src.len() < src_len {
        return false;
    }

    let x0 = dst_x.max(0).min(dst_w as i32) as usize;
    let y0 = dst_y.max(0).min(dst_h as i32) as usize;
    let x1 = (dst_x as i64 + src_w as i64).max(0).min(dst_w as i64) as usize;
    let y1 = (dst_y as i64 + src_h as i64).max(0).min(dst_h as i64) as usize;
    if x1 <= x0 || y1 <= y0 {
        return true;
    }

    for dy in y0..y1 {
        let sy = (dy as i64 - dst_y as i64) as usize;
        let dst_row = dy * dst_w;
        let src_row = sy * src_w;
        for dx in x0..x1 {
            let sx = (dx as i64 - dst_x as i64) as usize;
            let so = (src_row + sx) * 4;
            let sa = src[so + 3] as u32;
            if sa == 0 {
                continue;
            }
            let doff = (dst_row + dx) * 4;
            if sa == 255 {
                dst[doff..doff + 4].copy_from_slice(&src[so..so + 4]);
            } else {
                let da = dst[doff + 3] as u32;
                let inv_sa = 255 - sa;
                let out_a = sa + ((da * inv_sa + 127) / 255);
                if out_a == 0 {
                    dst[doff..doff + 4].fill(0);
                } else {
                    for c in 0..3 {
                        let num = src[so + c] as u32 * sa * 255
                            + dst[doff + c] as u32 * da * inv_sa;
                        let denom = out_a * 255;
                        dst[doff + c] = ((num + denom / 2) / denom).min(255) as u8;
                    }
                    dst[doff + 3] = out_a.min(255) as u8;
                }
            }
        }
    }
    true
}

pub fn resize_rgba(
    src: &[u8],
    src_w: usize,
    src_h: usize,
    dst: &mut [u8],
    dst_w: usize,
    dst_h: usize,
) -> bool {
    if src_w == 0 || src_h == 0 || dst_w == 0 || dst_h == 0 {
        return false;
    }
    let src_len = match src_w.checked_mul(src_h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    let dst_len = match dst_w.checked_mul(dst_h).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    if src.len() < src_len || dst.len() < dst_len {
        return false;
    }

    if src_w == dst_w && src_h == dst_h {
        dst[..dst_len].copy_from_slice(&src[..src_len]);
        return true;
    }

    let downscale_box = src_w >= dst_w * 2 || src_h >= dst_h * 2;
    if downscale_box {
        for dy in 0..dst_h {
            let y_start = (dy * src_h) / dst_h;
            let y_end = (((dy + 1) * src_h) / dst_h).max(y_start + 1).min(src_h);
            for dx in 0..dst_w {
                let x_start = (dx * src_w) / dst_w;
                let x_end = (((dx + 1) * src_w) / dst_w).max(x_start + 1).min(src_w);
                let mut sum_r = 0u64;
                let mut sum_g = 0u64;
                let mut sum_b = 0u64;
                let mut sum_a = 0u64;
                let mut count = 0u64;
                for sy in y_start..y_end {
                    let row_off = sy * src_w;
                    for sx in x_start..x_end {
                        let o = (row_off + sx) * 4;
                        sum_r += src[o] as u64;
                        sum_g += src[o + 1] as u64;
                        sum_b += src[o + 2] as u64;
                        sum_a += src[o + 3] as u64;
                        count += 1;
                    }
                }
                let out_off = (dy * dst_w + dx) * 4;
                let c = count.max(1);
                dst[out_off] = (sum_r / c) as u8;
                dst[out_off + 1] = (sum_g / c) as u8;
                dst[out_off + 2] = (sum_b / c) as u8;
                dst[out_off + 3] = (sum_a / c) as u8;
            }
        }
        return true;
    }

    let scale_x = if dst_w > 1 {
        (src_w - 1) as f32 / (dst_w - 1) as f32
    } else {
        0.0
    };
    let scale_y = if dst_h > 1 {
        (src_h - 1) as f32 / (dst_h - 1) as f32
    } else {
        0.0
    };
    for dy in 0..dst_h {
        let fy = dy as f32 * scale_y;
        let y0 = (fy.floor() as usize).min(src_h - 1);
        let y1 = (y0 + 1).min(src_h - 1);
        let wy = fy - y0 as f32;
        let wy0 = 1.0 - wy;
        for dx in 0..dst_w {
            let fx = dx as f32 * scale_x;
            let x0 = (fx.floor() as usize).min(src_w - 1);
            let x1 = (x0 + 1).min(src_w - 1);
            let wx = fx - x0 as f32;
            let wx0 = 1.0 - wx;

            let p00 = (y0 * src_w + x0) * 4;
            let p10 = (y0 * src_w + x1) * 4;
            let p01 = (y1 * src_w + x0) * 4;
            let p11 = (y1 * src_w + x1) * 4;
            let out = (dy * dst_w + dx) * 4;
            for c in 0..4 {
                let top = src[p00 + c] as f32 * wx0 + src[p10 + c] as f32 * wx;
                let bot = src[p01 + c] as f32 * wx0 + src[p11 + c] as f32 * wx;
                dst[out + c] = (top * wy0 + bot * wy).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    true
}

pub fn pixelate_region_rgba(
    rgba: &mut [u8],
    width: usize,
    height: usize,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    block_size: i32,
) -> bool {
    if width == 0 || height == 0 || rect_w <= 0 || rect_h <= 0 {
        return false;
    }
    let expected = match width.checked_mul(height).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    if rgba.len() < expected {
        return false;
    }

    let bs = block_size.max(2) as usize;
    let x0 = rect_x.max(0).min(width as i32) as usize;
    let y0 = rect_y.max(0).min(height as i32) as usize;
    let x1 = (rect_x as i64 + rect_w as i64).max(0).min(width as i64) as usize;
    let y1 = (rect_y as i64 + rect_h as i64).max(0).min(height as i64) as usize;
    if x1 <= x0 || y1 <= y0 {
        return true;
    }

    let mut by = y0;
    while by < y1 {
        let be = (by + bs).min(y1);
        let mut bx = x0;
        while bx < x1 {
            let re = (bx + bs).min(x1);
            let mut sr = 0u64;
            let mut sg = 0u64;
            let mut sb = 0u64;
            let mut sa = 0u64;
            let mut cnt = 0u64;
            for y in by..be {
                let row = y * width;
                for x in bx..re {
                    let o = (row + x) * 4;
                    sr += rgba[o] as u64;
                    sg += rgba[o + 1] as u64;
                    sb += rgba[o + 2] as u64;
                    sa += rgba[o + 3] as u64;
                    cnt += 1;
                }
            }
            let c = cnt.max(1);
            let ar = (sr / c) as u8;
            let ag = (sg / c) as u8;
            let ab = (sb / c) as u8;
            let aa = (sa / c) as u8;
            for y in by..be {
                let row = y * width;
                for x in bx..re {
                    let o = (row + x) * 4;
                    rgba[o] = ar;
                    rgba[o + 1] = ag;
                    rgba[o + 2] = ab;
                    rgba[o + 3] = aa;
                }
            }
            bx = re;
        }
        by = be;
    }
    true
}

pub fn box_blur_region_rgba(
    rgba: &mut [u8],
    width: usize,
    height: usize,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    radius: i32,
) -> bool {
    if width == 0 || height == 0 || rect_w <= 0 || rect_h <= 0 {
        return false;
    }
    let expected = match width.checked_mul(height).and_then(|n| n.checked_mul(4)) {
        Some(v) => v,
        None => return false,
    };
    if rgba.len() < expected {
        return false;
    }
    if radius <= 0 {
        return true;
    }

    let x0 = rect_x.max(0).min(width as i32) as usize;
    let y0 = rect_y.max(0).min(height as i32) as usize;
    let x1 = (rect_x as i64 + rect_w as i64).max(0).min(width as i64) as usize;
    let y1 = (rect_y as i64 + rect_h as i64).max(0).min(height as i64) as usize;
    let rw = x1.saturating_sub(x0);
    let rh = y1.saturating_sub(y0);
    if rw == 0 || rh == 0 {
        return true;
    }

    let r = (radius as usize).min(rw.max(rh));
    let mut patch = vec![0u8; rw * rh * 4];
    for row in 0..rh {
        let src_off = ((y0 + row) * width + x0) * 4;
        let dst_off = row * rw * 4;
        patch[dst_off..dst_off + rw * 4].copy_from_slice(&rgba[src_off..src_off + rw * 4]);
    }
    let mut temp = vec![0u8; rw * rh * 4];

    // 3-pass separable box blur approximates Gaussian smoothness in O(1)/px.
    for _pass in 0..3 {
        // Horizontal pass: patch -> temp
        for y in 0..rh {
            let row = y * rw;
            let mut sum = [0i32; 4];
            let win = (r * 2 + 1) as i32;
            for k in -(r as isize)..=(r as isize) {
                let sx = k.clamp(0, (rw - 1) as isize) as usize;
                let o = (row + sx) * 4;
                for c in 0..4 {
                    sum[c] += patch[o + c] as i32;
                }
            }
            for x in 0..rw {
                let out = (row + x) * 4;
                for c in 0..4 {
                    temp[out + c] = (sum[c] / win).clamp(0, 255) as u8;
                }
                let remove_x = (x as isize - r as isize).max(0) as usize;
                let add_x = (x + r + 1).min(rw - 1);
                let ro = (row + remove_x) * 4;
                let ao = (row + add_x) * 4;
                for c in 0..4 {
                    sum[c] += patch[ao + c] as i32 - patch[ro + c] as i32;
                }
            }
        }

        // Vertical pass: temp -> patch
        let win = (r * 2 + 1) as i32;
        for x in 0..rw {
            let mut sum = [0i32; 4];
            for k in -(r as isize)..=(r as isize) {
                let sy = k.clamp(0, (rh - 1) as isize) as usize;
                let o = (sy * rw + x) * 4;
                for c in 0..4 {
                    sum[c] += temp[o + c] as i32;
                }
            }
            for y in 0..rh {
                let out = (y * rw + x) * 4;
                for c in 0..4 {
                    patch[out + c] = (sum[c] / win).clamp(0, 255) as u8;
                }
                let remove_y = (y as isize - r as isize).max(0) as usize;
                let add_y = (y + r + 1).min(rh - 1);
                let ro = (remove_y * rw + x) * 4;
                let ao = (add_y * rw + x) * 4;
                for c in 0..4 {
                    sum[c] += temp[ao + c] as i32 - temp[ro + c] as i32;
                }
            }
        }
    }

    for row in 0..rh {
        let dst_off = ((y0 + row) * width + x0) * 4;
        let src_off = row * rw * 4;
        rgba[dst_off..dst_off + rw * 4].copy_from_slice(&patch[src_off..src_off + rw * 4]);
    }
    true
}
