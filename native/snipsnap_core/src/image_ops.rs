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
