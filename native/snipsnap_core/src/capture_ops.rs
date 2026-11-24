// Gene - Nov, 24, 2026: Zero-dependency Rust native capture pixel transforms, Win32 CF_DIB decoder, click-highlight compositor, and WASAPI PCM resampler.

fn read_u16_le(buf: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([buf[off], buf[off + 1]])
}

fn read_u32_le(buf: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]])
}

fn read_i32_le(buf: &[u8], off: usize) -> i32 {
    i32::from_le_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]])
}

/// Dims top-down BGRA `src` into `dst` by `dim_factor / 256` and forces opaque alpha (0xFF).
pub fn dim_bgra(
    src: &[u8],
    dst: &mut [u8],
    width: usize,
    height: usize,
    src_stride: usize,
    dst_stride: usize,
    dim_factor: u8,
) -> bool {
    if width == 0 || height == 0 {
        return false;
    }
    let row_bytes = match width.checked_mul(4) {
        Some(r) => r,
        None => return false,
    };
    if src_stride < row_bytes || dst_stride < row_bytes {
        return false;
    }
    let src_needed = match height
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(src_stride))
        .and_then(|o| o.checked_add(row_bytes))
    {
        Some(n) => n,
        None => return false,
    };
    let dst_needed = match height
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(dst_stride))
        .and_then(|o| o.checked_add(row_bytes))
    {
        Some(n) => n,
        None => return false,
    };
    if src.len() < src_needed || dst.len() < dst_needed {
        return false;
    }

    let factor = dim_factor as u32;
    for y in 0..height {
        let srow = &src[y * src_stride..y * src_stride + row_bytes];
        let drow = &mut dst[y * dst_stride..y * dst_stride + row_bytes];
        for (sp, dp) in srow.chunks_exact(4).zip(drow.chunks_exact_mut(4)) {
            dp[0] = ((sp[0] as u32 * factor) >> 8) as u8;
            dp[1] = ((sp[1] as u32 * factor) >> 8) as u8;
            dp[2] = ((sp[2] as u32 * factor) >> 8) as u8;
            dp[3] = 0xFF;
        }
    }
    true
}

/// Converts top-down BGRA into bottom-up 32bpp BGRX (with alpha set to 0xFF)
/// suitable for Media Foundation `MFVideoFormat_RGB32` and Win32 `CF_DIB`.
pub fn bgra_to_bottom_up_bgrx(
    src: &[u8],
    width: usize,
    height: usize,
    src_stride: usize,
    dst: &mut [u8],
    dst_stride: usize,
) -> bool {
    if width == 0 || height == 0 {
        return false;
    }
    let row_bytes = match width.checked_mul(4) {
        Some(r) => r,
        None => return false,
    };
    if src_stride < row_bytes || dst_stride < row_bytes {
        return false;
    }
    let src_needed = match height
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(src_stride))
        .and_then(|o| o.checked_add(row_bytes))
    {
        Some(n) => n,
        None => return false,
    };
    let dst_needed = match height
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(dst_stride))
        .and_then(|o| o.checked_add(row_bytes))
    {
        Some(n) => n,
        None => return false,
    };
    if src.len() < src_needed || dst.len() < dst_needed {
        return false;
    }

    for y in 0..height {
        let sy = height - 1 - y;
        let srow = &src[sy * src_stride..sy * src_stride + row_bytes];
        let drow = &mut dst[y * dst_stride..y * dst_stride + row_bytes];
        for (sp, dp) in srow.chunks_exact(4).zip(drow.chunks_exact_mut(4)) {
            dp[0] = sp[0];
            dp[1] = sp[1];
            dp[2] = sp[2];
            dp[3] = 0xFF;
        }
    }
    true
}

/// Converts strided BGRA/RGB32 (top-down or bottom-up) into tightly packed top-down RGBA (`alpha = 0xFF`).
pub fn bgra_to_rgba_top_down(
    src: &[u8],
    width: usize,
    height: usize,
    src_stride: usize,
    flip_vertical: bool,
    dst: &mut [u8],
) -> bool {
    if width == 0 || height == 0 {
        return false;
    }
    let row_bytes = match width.checked_mul(4) {
        Some(r) => r,
        None => return false,
    };
    if src_stride < row_bytes {
        return false;
    }
    let src_needed = match height
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(src_stride))
        .and_then(|o| o.checked_add(row_bytes))
    {
        Some(n) => n,
        None => return false,
    };
    let dst_needed = match height.checked_mul(row_bytes) {
        Some(n) => n,
        None => return false,
    };
    if src.len() < src_needed || dst.len() < dst_needed {
        return false;
    }

    for y in 0..height {
        let sy = if flip_vertical { height - 1 - y } else { y };
        let srow = &src[sy * src_stride..sy * src_stride + row_bytes];
        let drow = &mut dst[y * row_bytes..(y + 1) * row_bytes];
        for (sp, dp) in srow.chunks_exact(4).zip(drow.chunks_exact_mut(4)) {
            dp[0] = sp[2];
            dp[1] = sp[1];
            dp[2] = sp[0];
            dp[3] = 0xFF;
        }
    }
    true
}

#[inline]
fn extract_channel(pixel: u32, mask: u32) -> u8 {
    if mask == 0 {
        return 0;
    }
    let shift = mask.trailing_zeros();
    let shifted = mask >> shift;
    let bits = shifted.count_ones();
    let val = (pixel & mask) >> shift;
    if bits == 8 {
        val as u8
    } else if bits == 0 {
        0
    } else if bits > 8 {
        (val >> (bits - 8)) as u8
    } else {
        let max_val = shifted;
        ((val * 255 + (max_val / 2)) / max_val) as u8
    }
}

/// Parses Win32 `CF_DIB` / `CF_DIBV5` bytes safely into top-down 32-bit BGRA.
/// Handles `BITMAPINFOHEADER`, `BITMAPV4HEADER`, `BITMAPV5HEADER`, `BI_RGB` & `BI_BITFIELDS`,
/// 24-bpp & 32-bpp, top-down & bottom-up, and promotes all-zero `BGRX` alpha to `0xFF`.
pub fn decode_dib_to_bgra(dib: &[u8]) -> Option<(Vec<u8>, usize, usize)> {
    if dib.len() < 40 {
        return None;
    }
    let bi_size = read_u32_le(dib, 0) as usize;
    if bi_size < 40 || bi_size > dib.len() {
        return None;
    }
    let width_i32 = read_i32_le(dib, 4);
    let height_i32 = read_i32_le(dib, 8);
    if width_i32 <= 0 || height_i32 == 0 || height_i32 == i32::MIN {
        return None;
    }
    let width = width_i32 as usize;
    let height = height_i32.unsigned_abs() as usize;
    let top_down = height_i32 < 0;

    let planes = read_u16_le(dib, 12);
    let bpp = read_u16_le(dib, 14) as usize;
    let compression = read_u32_le(dib, 16);
    let clr_used = read_u32_le(dib, 32) as usize;

    if planes != 1 || (bpp != 24 && bpp != 32) {
        return None;
    }
    // BI_RGB = 0, BI_BITFIELDS = 3
    if compression != 0 && compression != 3 {
        return None;
    }
    if clr_used > 1024 {
        return None;
    }

    let mut r_mask: u32 = 0x00FF_0000;
    let mut g_mask: u32 = 0x0000_FF00;
    let mut b_mask: u32 = 0x0000_00FF;
    let mut a_mask: u32 = 0xFF00_0000;
    let mut extra_masks_bytes: usize = 0;

    if compression == 3 {
        if bi_size == 40 {
            if dib.len() < 40 + 12 {
                return None;
            }
            r_mask = read_u32_le(dib, 40);
            g_mask = read_u32_le(dib, 44);
            b_mask = read_u32_le(dib, 48);
            a_mask = !(r_mask | g_mask | b_mask);
            extra_masks_bytes = 12;
        } else if bi_size >= 52 {
            r_mask = read_u32_le(dib, 40);
            g_mask = read_u32_le(dib, 44);
            b_mask = read_u32_le(dib, 48);
            a_mask = if bi_size >= 56 {
                read_u32_le(dib, 52)
            } else {
                !(r_mask | g_mask | b_mask)
            };
        }
    } else if bi_size >= 56 {
        let hdr_a = read_u32_le(dib, 52);
        if hdr_a != 0 {
            a_mask = hdr_a;
        }
    }

    let palette_bytes = clr_used.checked_mul(4)?;
    let pixel_offset = bi_size
        .checked_add(extra_masks_bytes)?
        .checked_add(palette_bytes)?;
    if pixel_offset > dib.len() {
        return None;
    }

    let src_stride = width
        .checked_mul(bpp)?
        .checked_add(31)?
        .checked_div(32)?
        .checked_mul(4)?;
    let src_total = src_stride.checked_mul(height)?;
    if dib.len() - pixel_offset < src_total {
        return None;
    }

    let out_len = width.checked_mul(height)?.checked_mul(4)?;
    let mut out = vec![0u8; out_len];
    let src_pixels = &dib[pixel_offset..pixel_offset + src_total];

    let is_standard_bgra = bpp == 32
        && r_mask == 0x00FF_0000
        && g_mask == 0x0000_FF00
        && b_mask == 0x0000_00FF
        && (a_mask == 0xFF00_0000 || a_mask == 0);

    let mut any_nonzero_alpha = false;
    for y in 0..height {
        let sy = if top_down { y } else { height - 1 - y };
        let srow = &src_pixels[sy * src_stride..sy * src_stride + width * (bpp / 8)];
        let drow = &mut out[y * width * 4..(y + 1) * width * 4];
        if bpp == 24 {
            for x in 0..width {
                drow[x * 4] = srow[x * 3];
                drow[x * 4 + 1] = srow[x * 3 + 1];
                drow[x * 4 + 2] = srow[x * 3 + 2];
                drow[x * 4 + 3] = 0xFF;
            }
        } else if is_standard_bgra {
            drow.copy_from_slice(srow);
            if !any_nonzero_alpha {
                for px in drow.chunks_exact(4) {
                    if px[3] != 0 {
                        any_nonzero_alpha = true;
                        break;
                    }
                }
            }
        } else {
            for x in 0..width {
                let p = read_u32_le(srow, x * 4);
                let a = if a_mask == 0 {
                    0xFF
                } else {
                    extract_channel(p, a_mask)
                };
                if a != 0 {
                    any_nonzero_alpha = true;
                }
                drow[x * 4] = extract_channel(p, b_mask);
                drow[x * 4 + 1] = extract_channel(p, g_mask);
                drow[x * 4 + 2] = extract_channel(p, r_mask);
                drow[x * 4 + 3] = a;
            }
        }
    }

    if bpp == 32 && !any_nonzero_alpha {
        for px in out.chunks_exact_mut(4) {
            px[3] = 0xFF;
        }
    }

    Some((out, width, height))
}

/// Composites an anti-aliased expanding click pulse ring onto a top-down BGRA buffer.
/// Left click: cyan/sky-blue (B=255, G=195, R=40); Right click: warm gold (B=70, G=205, R=255).
pub fn composite_click_ring_bgra(
    bgra: &mut [u8],
    width: usize,
    height: usize,
    stride: usize,
    cx: i32,
    cy: i32,
    progress: f32,
    is_right_click: bool,
) -> bool {
    if width == 0 || height == 0 {
        return false;
    }
    let row_bytes = match width.checked_mul(4) {
        Some(r) => r,
        None => return false,
    };
    if stride < row_bytes {
        return false;
    }
    let needed = match height
        .checked_sub(1)
        .and_then(|h1| h1.checked_mul(stride))
        .and_then(|o| o.checked_add(row_bytes))
    {
        Some(n) => n,
        None => return false,
    };
    if bgra.len() < needed {
        return false;
    }

    let p = progress.clamp(0.0, 1.0);
    let radius = 8.0_f32 + p * 22.0_f32;
    let half_thick = 2.2_f32;
    let alpha_scale = (1.0_f32 - p) * 0.85_f32;
    if alpha_scale <= 0.001 {
        return true;
    }

    let (blue, green, red): (f32, f32, f32) = if is_right_click {
        (70.0, 205.0, 255.0)
    } else {
        (255.0, 195.0, 40.0)
    };

    let max_r = (radius + half_thick).ceil() as i32 + 1;
    let min_py = (cy - max_r).max(0);
    let max_py = (cy + max_r).min(height as i32 - 1);
    let min_px = (cx - max_r).max(0);
    let max_px = (cx + max_r).min(width as i32 - 1);

    if min_py > max_py || min_px > max_px {
        return true;
    }

    for py in min_py..=max_py {
        let dy = (py - cy) as f32;
        let row_off = (py as usize) * stride;
        for px in min_px..=max_px {
            let dx = (px - cx) as f32;
            let dist = (dx * dx + dy * dy).sqrt();
            let diff = (dist - radius).abs();
            if diff <= half_thick {
                let coverage = (1.0_f32 - diff / half_thick) * alpha_scale;
                let inv = 1.0_f32 - coverage;
                let idx = row_off + (px as usize) * 4;
                bgra[idx] = (bgra[idx] as f32 * inv + blue * coverage).clamp(0.0, 255.0) as u8;
                bgra[idx + 1] =
                    (bgra[idx + 1] as f32 * inv + green * coverage).clamp(0.0, 255.0) as u8;
                bgra[idx + 2] =
                    (bgra[idx + 2] as f32 * inv + red * coverage).clamp(0.0, 255.0) as u8;
                bgra[idx + 3] = 0xFF;
            }
        }
    }
    true
}

#[inline]
fn decode_pcm_sample(frame_bytes: &[u8], ch_idx: usize, bits: usize, is_float: bool) -> f32 {
    let bps = bits / 8;
    let off = ch_idx * bps;
    if off + bps > frame_bytes.len() {
        return 0.0;
    }
    if is_float && bits == 32 {
        let v = f32::from_le_bytes([
            frame_bytes[off],
            frame_bytes[off + 1],
            frame_bytes[off + 2],
            frame_bytes[off + 3],
        ]);
        if v.is_finite() {
            v.clamp(-1.0, 1.0)
        } else {
            0.0
        }
    } else if !is_float && bits == 16 {
        let v = i16::from_le_bytes([frame_bytes[off], frame_bytes[off + 1]]);
        (v as f32) / 32768.0
    } else if !is_float && bits == 24 {
        let raw = (frame_bytes[off] as i32)
            | ((frame_bytes[off + 1] as i32) << 8)
            | (((frame_bytes[off + 2] as i8) as i32) << 16);
        (raw as f32) / 8_388_608.0
    } else if !is_float && bits == 32 {
        let v = i32::from_le_bytes([
            frame_bytes[off],
            frame_bytes[off + 1],
            frame_bytes[off + 2],
            frame_bytes[off + 3],
        ]);
        ((v as f64) / 2_147_483_648.0) as f32
    } else {
        0.0
    }
}

/// Decodes arbitrary WASAPI PCM (`32f`, `16i`, `24i`, `32i`, any channel count >= 1)
/// and linearly resamples to interleaved 48 kHz stereo `f32`, preserving fractional phase.
#[allow(clippy::too_many_arguments)]
pub fn pcm_to_f32_stereo_48k(
    src: &[u8],
    num_frames: usize,
    channels: usize,
    bits_per_sample: usize,
    is_float: bool,
    sample_rate: u32,
    resample_phase: &mut f64,
    out_stereo: &mut Vec<f32>,
) -> bool {
    if num_frames == 0 || channels == 0 || sample_rate == 0 {
        return false;
    }
    let supported = (is_float && bits_per_sample == 32)
        || (!is_float
            && (bits_per_sample == 16 || bits_per_sample == 24 || bits_per_sample == 32));
    if !supported {
        return false;
    }
    let frame_stride = match channels.checked_mul(bits_per_sample / 8) {
        Some(s) if s > 0 => s,
        _ => return false,
    };
    let needed = match num_frames.checked_mul(frame_stride) {
        Some(n) => n,
        None => return false,
    };
    if src.len() < needed {
        return false;
    }

    let read_lr = |frame_idx: usize| -> (f32, f32) {
        let f_slice = &src[frame_idx * frame_stride..(frame_idx + 1) * frame_stride];
        let l = decode_pcm_sample(f_slice, 0, bits_per_sample, is_float);
        let r = if channels >= 2 {
            decode_pcm_sample(f_slice, 1, bits_per_sample, is_float)
        } else {
            l
        };
        (l, r)
    };

    if sample_rate == 48_000 {
        out_stereo.reserve(num_frames * 2);
        for f in 0..num_frames {
            let (l, r) = read_lr(f);
            out_stereo.push(l);
            out_stereo.push(r);
        }
        *resample_phase = 0.0;
        return true;
    }

    let step = (sample_rate as f64) / 48_000.0;
    let est_out = (((num_frames as f64) / step).ceil() as usize + 4) * 2;
    out_stereo.reserve(est_out);

    let mut phase = if resample_phase.is_finite() && *resample_phase >= 0.0 {
        *resample_phase
    } else {
        0.0
    };
    let nf = num_frames as f64;
    while phase < nf {
        let idx0 = (phase as usize).min(num_frames - 1);
        let idx1 = (idx0 + 1).min(num_frames - 1);
        let frac = (phase - idx0 as f64) as f32;
        let (l0, r0) = read_lr(idx0);
        let (l1, r1) = read_lr(idx1);
        out_stereo.push(l0 + (l1 - l0) * frac);
        out_stereo.push(r0 + (r1 - r0) * frac);
        phase += step;
    }
    *resample_phase = phase - nf;
    true
}
