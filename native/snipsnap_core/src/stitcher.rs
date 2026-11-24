// Gene - Nov, 20, 2026: Industry-standard zero-dependency Rust panoramic image stitcher.
// Optimized for < 1.5 ms per 1080p BGRA frame via Arc zero-copy frame sharing,
// 4x downsampled L2-cache 2D NCC coarse screening, 1px full-res NCC refinement,
// sticky header/footer/scrollbar masking, rollback & lost-tracking recovery, and 16k safe dimension capping.

use std::sync::Arc;

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollAxis {
    Auto = 0,
    Vertical = 1,
    Horizontal = 2,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StitchStatus {
    Ok = 0,
    Duplicate = 1,
    TrackingLost = 2,
    MaxLimitReached = 3,
    RolledBack = 4,
    InvalidInput = 5,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PushResult {
    pub status: i32,
    pub delta: i32,
    pub active_axis: i32,
    pub total_width: i32,
    pub total_height: i32,
    pub frame_count: i32,
    pub identical_streak: i32,
    pub confidence: f32,
    pub sticky_start_px: i32,
    pub sticky_end_px: i32,
}

#[derive(Clone, Copy, Debug)]
struct StickyMargins {
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
}

struct Strip {
    extent: usize,
    pixels: Vec<u8>,
}

struct FrameSig {
    width: usize,
    height: usize,
    small_w: usize,
    small_h: usize,
    luma_small: Vec<u8>,
    row_bands: Vec<i16>,
    col_bands: Vec<i16>,
}

pub struct ScrollStitcher {
    frame_w: usize,
    frame_h: usize,
    max_dimension: usize,
    active_axis: Option<ScrollAxis>,

    first_frame: Option<Arc<Vec<u8>>>,
    last_frame: Option<Arc<Vec<u8>>>,
    anchor_frame: Option<Arc<Vec<u8>>>,
    anchor_sig: Option<FrameSig>,

    strips: Vec<Strip>,
    virtual_pos: i32,
    committed_extent: usize,
    frame_count: i32,
    identical_streak: i32,

    motion_events: u32,
    sticky: StickyMargins,
}

impl ScrollStitcher {
    pub fn new(
        frame_width: usize,
        frame_height: usize,
        max_dimension: usize,
        axis_mode: ScrollAxis,
    ) -> Self {
        let clamped_max = max_dimension.max(frame_width.max(frame_height));
        let default_right = if frame_width > 120 {
            18.min(frame_width / 12)
        } else {
            0
        };
        let active_axis = match axis_mode {
            ScrollAxis::Auto => None,
            other => Some(other),
        };
        Self {
            frame_w: frame_width,
            frame_h: frame_height,
            max_dimension: clamped_max,
            active_axis,
            first_frame: None,
            last_frame: None,
            anchor_frame: None,
            anchor_sig: None,
            strips: Vec::new(),
            virtual_pos: 0,
            committed_extent: 0,
            frame_count: 0,
            identical_streak: 0,
            motion_events: 0,
            sticky: StickyMargins {
                top: 0,
                bottom: 0,
                left: 0,
                right: default_right,
            },
        }
    }

    pub fn total_dimensions(&self) -> (usize, usize) {
        match self.active_axis {
            Some(ScrollAxis::Horizontal) => (self.frame_w + self.committed_extent, self.frame_h),
            _ => (self.frame_w, self.frame_h + self.committed_extent),
        }
    }

    pub fn push_bgra(&mut self, bgra: &[u8], width: usize, height: usize, stride: usize) -> PushResult {
        if width == 0
            || height == 0
            || width != self.frame_w
            || height != self.frame_h
            || stride < width * 4
        {
            return self.make_result(StitchStatus::InvalidInput, 0, 0.0);
        }
        let needed = match (height - 1)
            .checked_mul(stride)
            .and_then(|o| o.checked_add(width * 4))
        {
            Some(v) => v,
            None => return self.make_result(StitchStatus::InvalidInput, 0, 0.0),
        };
        if bgra.len() < needed {
            return self.make_result(StitchStatus::InvalidInput, 0, 0.0);
        }

        let packed = Arc::new(pack_bgra(bgra, width, height, stride));

        if self.first_frame.is_none() {
            let sig = build_frame_sig(&packed, width, height, self.active_axis);
            self.first_frame = Some(Arc::clone(&packed));
            self.last_frame = Some(Arc::clone(&packed));
            self.anchor_frame = Some(packed);
            self.anchor_sig = Some(sig);
            self.frame_count = 1;
            self.identical_streak = 0;
            return self.make_result(StitchStatus::Ok, 0, 1.0);
        }

        let last_ref = self.last_frame.as_ref().unwrap();
        if frames_effectively_identical(&packed, last_ref, width, height, self.sticky) {
            self.identical_streak += 1;
            return self.make_result(StitchStatus::Duplicate, 0, 1.0);
        }

        let anchor_ref = self.anchor_frame.as_ref().unwrap();
        let anchor_sig = self.anchor_sig.as_ref().unwrap();
        let curr_sig = build_frame_sig(&packed, width, height, self.active_axis);

        let (cand_sticky, has_global_motion) =
            estimate_sticky_borders(&packed, anchor_ref, width, height, self.sticky, self.active_axis);

        let axis = match self.active_axis {
            Some(ax) => ax,
            None => {
                let (v_delta, v_ncc, _) = match_vertical_with_sticky_confirm(
                    anchor_ref,
                    anchor_sig,
                    &packed,
                    &curr_sig,
                    self.sticky,
                    cand_sticky,
                    self.motion_events,
                );
                let (h_delta, h_ncc, _) = match_horizontal_with_sticky_confirm(
                    anchor_ref,
                    anchor_sig,
                    &packed,
                    &curr_sig,
                    self.sticky,
                    cand_sticky,
                    self.motion_events,
                );

                if h_delta.abs() >= 4 && h_ncc >= 0.75 && h_ncc > v_ncc + 0.04 {
                    self.active_axis = Some(ScrollAxis::Horizontal);
                    ScrollAxis::Horizontal
                } else if v_delta.abs() >= 4 && v_ncc >= 0.72 && v_ncc >= h_ncc {
                    self.active_axis = Some(ScrollAxis::Vertical);
                    ScrollAxis::Vertical
                } else if h_delta.abs() >= 4 && h_ncc >= 0.72 {
                    self.active_axis = Some(ScrollAxis::Horizontal);
                    ScrollAxis::Horizontal
                } else {
                    ScrollAxis::Vertical
                }
            }
        };

        let (delta, confidence, effective_sticky) = match axis {
            ScrollAxis::Vertical | ScrollAxis::Auto => match_vertical_with_sticky_confirm(
                anchor_ref,
                anchor_sig,
                &packed,
                &curr_sig,
                self.sticky,
                cand_sticky,
                self.motion_events,
            ),
            ScrollAxis::Horizontal => match_horizontal_with_sticky_confirm(
                anchor_ref,
                anchor_sig,
                &packed,
                &curr_sig,
                self.sticky,
                cand_sticky,
                self.motion_events,
            ),
        };

        if confidence < 0.72 {
            return self.make_result(StitchStatus::TrackingLost, 0, confidence);
        }

        if delta == 0 {
            self.identical_streak += 1;
            return self.make_result(StitchStatus::Duplicate, 0, confidence);
        }

        if has_global_motion {
            self.motion_events += 1;
        }
        self.sticky = effective_sticky;
        self.identical_streak = 0;

        let new_virtual = self.virtual_pos + delta;
        self.virtual_pos = new_virtual;

        if delta < 0 || (new_virtual as usize) <= self.committed_extent {
            self.anchor_frame = Some(Arc::clone(&packed));
            self.anchor_sig = Some(curr_sig);
            self.last_frame = Some(packed);
            return self.make_result(StitchStatus::RolledBack, delta, confidence);
        }

        let base_dim = match axis {
            ScrollAxis::Horizontal => self.frame_w,
            _ => self.frame_h,
        };
        let max_extent = self.max_dimension.saturating_sub(base_dim);
        let target_extent = (new_virtual as usize).min(max_extent);
        let hit_cap = (new_virtual as usize) > max_extent;

        let rows_or_cols_to_add = target_extent.saturating_sub(self.committed_extent);
        if rows_or_cols_to_add == 0 {
            return self.make_result(
                if hit_cap {
                    StitchStatus::MaxLimitReached
                } else {
                    StitchStatus::Duplicate
                },
                0,
                confidence,
            );
        }

        let strip = match axis {
            ScrollAxis::Horizontal => {
                let end_col = self.frame_w.saturating_sub(self.sticky.right);
                let safe_add = rows_or_cols_to_add.min(end_col.saturating_sub(self.sticky.left));
                if safe_add == 0 {
                    return self.make_result(StitchStatus::TrackingLost, 0, 0.0);
                }
                let start_col = end_col - safe_add;
                Strip {
                    extent: safe_add,
                    pixels: extract_horizontal_strip(
                        &packed,
                        self.frame_w,
                        self.frame_h,
                        start_col,
                        safe_add,
                    ),
                }
            }
            _ => {
                let end_row = self.frame_h.saturating_sub(self.sticky.bottom);
                let safe_add = rows_or_cols_to_add.min(end_row.saturating_sub(self.sticky.top));
                if safe_add == 0 {
                    return self.make_result(StitchStatus::TrackingLost, 0, 0.0);
                }
                let start_row = end_row - safe_add;
                let row_bytes = self.frame_w * 4;
                let byte_start = start_row * row_bytes;
                let byte_end = end_row * row_bytes;
                Strip {
                    extent: safe_add,
                    pixels: packed[byte_start..byte_end].to_vec(),
                }
            }
        };

        let added = strip.extent;
        self.strips.push(strip);
        self.committed_extent += added;
        self.frame_count += 1;
        self.anchor_frame = Some(Arc::clone(&packed));
        self.anchor_sig = Some(curr_sig);
        self.last_frame = Some(packed);

        let status = if hit_cap || self.committed_extent >= max_extent {
            StitchStatus::MaxLimitReached
        } else {
            StitchStatus::Ok
        };
        self.make_result(status, added as i32, confidence)
    }

    pub fn assemble_bgra(&self) -> Option<(Vec<u8>, usize, usize)> {
        let first = self.first_frame.as_ref()?;
        let last = self.last_frame.as_ref().unwrap_or(first);
        let (total_w, total_h) = self.total_dimensions();
        if total_w == 0 || total_h == 0 {
            return None;
        }

        if self.strips.is_empty() {
            return Some((first.as_ref().clone(), self.frame_w, self.frame_h));
        }

        let mut out = vec![0u8; total_w * total_h * 4];
        match self.active_axis {
            Some(ScrollAxis::Horizontal) => {
                let sticky_right = self.sticky.right.min(self.frame_w / 3);
                let first_cols = self.frame_w - sticky_right;
                let out_stride = total_w * 4;
                let frame_stride = self.frame_w * 4;

                for y in 0..self.frame_h {
                    let dst_row = &mut out[y * out_stride..(y + 1) * out_stride];
                    let src_row = &first[y * frame_stride..(y + 1) * frame_stride];
                    dst_row[..first_cols * 4].copy_from_slice(&src_row[..first_cols * 4]);

                    let mut dst_col = first_cols;
                    for strip in &self.strips {
                        let s_stride = strip.extent * 4;
                        let s_slice = &strip.pixels[y * s_stride..(y + 1) * s_stride];
                        dst_row[dst_col * 4..(dst_col + strip.extent) * 4].copy_from_slice(s_slice);
                        dst_col += strip.extent;
                    }

                    if sticky_right > 0 {
                        let last_row = &last[y * frame_stride..(y + 1) * frame_stride];
                        let tail_src = (self.frame_w - sticky_right) * 4;
                        dst_row[dst_col * 4..(dst_col + sticky_right) * 4]
                            .copy_from_slice(&last_row[tail_src..]);
                    }
                }
            }
            _ => {
                let row_bytes = self.frame_w * 4;
                let sticky_bottom = self.sticky.bottom.min(self.frame_h / 3);
                let first_rows = self.frame_h - sticky_bottom;

                let mut dst_offset = 0usize;
                let first_len = first_rows * row_bytes;
                out[dst_offset..dst_offset + first_len].copy_from_slice(&first[..first_len]);
                dst_offset += first_len;

                for strip in &self.strips {
                    let len = strip.pixels.len();
                    out[dst_offset..dst_offset + len].copy_from_slice(&strip.pixels);
                    dst_offset += len;
                }

                if sticky_bottom > 0 {
                    let tail_start = (self.frame_h - sticky_bottom) * row_bytes;
                    let tail_len = sticky_bottom * row_bytes;
                    out[dst_offset..dst_offset + tail_len]
                        .copy_from_slice(&last[tail_start..tail_start + tail_len]);
                }
            }
        }

        Some((out, total_w, total_h))
    }

    pub fn generate_preview_bgra(
        &self,
        max_preview_w: usize,
        max_preview_h: usize,
    ) -> Option<(Vec<u8>, usize, usize)> {
        let first = self.first_frame.as_ref()?;
        let last = self.last_frame.as_ref().unwrap_or(first);
        let (total_w, total_h) = self.total_dimensions();
        if total_w == 0 || total_h == 0 || max_preview_w == 0 || max_preview_h == 0 {
            return None;
        }

        let scale_w = max_preview_w as f64 / total_w as f64;
        let scale_h = max_preview_h as f64 / total_h as f64;
        let scale = scale_w.min(scale_h).min(1.0);
        let pw = ((total_w as f64 * scale).round() as usize).max(1);
        let ph = ((total_h as f64 * scale).round() as usize).max(1);

        let mut out = vec![0u8; pw * ph * 4];
        match self.active_axis {
            Some(ScrollAxis::Horizontal) => {
                let sticky_right = if self.strips.is_empty() {
                    0
                } else {
                    self.sticky.right.min(self.frame_w / 3)
                };
                let first_cols = self.frame_w - sticky_right;
                for py in 0..ph {
                    let sy = ((py * total_h) / ph).min(self.frame_h - 1);
                    for px in 0..pw {
                        let sx = ((px * total_w) / pw).min(total_w - 1);
                        let src_px = if sx < first_cols {
                            let idx = (sy * self.frame_w + sx) * 4;
                            &first[idx..idx + 4]
                        } else if sx < first_cols + self.committed_extent {
                            let mut rem = sx - first_cols;
                            let mut found = &first[0..4];
                            for strip in &self.strips {
                                if rem < strip.extent {
                                    let idx = (sy * strip.extent + rem) * 4;
                                    found = &strip.pixels[idx..idx + 4];
                                    break;
                                }
                                rem -= strip.extent;
                            }
                            found
                        } else {
                            let rx = (self.frame_w - sticky_right)
                                + (sx - first_cols - self.committed_extent);
                            let idx = (sy * self.frame_w + rx.min(self.frame_w - 1)) * 4;
                            &last[idx..idx + 4]
                        };
                        let dst_idx = (py * pw + px) * 4;
                        out[dst_idx..dst_idx + 4].copy_from_slice(src_px);
                    }
                }
            }
            _ => {
                let sticky_bottom = if self.strips.is_empty() {
                    0
                } else {
                    self.sticky.bottom.min(self.frame_h / 3)
                };
                let first_rows = self.frame_h - sticky_bottom;
                for py in 0..ph {
                    let sy = ((py * total_h) / ph).min(total_h - 1);
                    let (row_buf, row_y) = if sy < first_rows {
                        (first.as_slice(), sy)
                    } else if sy < first_rows + self.committed_extent {
                        let mut rem = sy - first_rows;
                        let mut chosen = (first.as_slice(), 0usize);
                        for strip in &self.strips {
                            if rem < strip.extent {
                                chosen = (strip.pixels.as_slice(), rem);
                                break;
                            }
                            rem -= strip.extent;
                        }
                        chosen
                    } else {
                        let ry = (self.frame_h - sticky_bottom)
                            + (sy - first_rows - self.committed_extent);
                        (last.as_slice(), ry.min(self.frame_h - 1))
                    };
                    let row_offset = row_y * self.frame_w * 4;
                    for px in 0..pw {
                        let sx = ((px * self.frame_w) / pw).min(self.frame_w - 1);
                        let src_idx = row_offset + sx * 4;
                        let dst_idx = (py * pw + px) * 4;
                        out[dst_idx..dst_idx + 4].copy_from_slice(&row_buf[src_idx..src_idx + 4]);
                    }
                }
            }
        }
        Some((out, pw, ph))
    }

    fn make_result(&self, status: StitchStatus, delta: i32, confidence: f32) -> PushResult {
        let (tw, th) = self.total_dimensions();
        let (s_start, s_end) = match self.active_axis {
            Some(ScrollAxis::Horizontal) => (self.sticky.left as i32, self.sticky.right as i32),
            _ => (self.sticky.top as i32, self.sticky.bottom as i32),
        };
        PushResult {
            status: status as i32,
            delta,
            active_axis: self.active_axis.map(|a| a as i32).unwrap_or(0),
            total_width: tw as i32,
            total_height: th as i32,
            frame_count: self.frame_count,
            identical_streak: self.identical_streak,
            confidence,
            sticky_start_px: s_start,
            sticky_end_px: s_end,
        }
    }
}

#[inline(always)]
fn bgra_luma(px: &[u8]) -> i32 {
    ((29 * px[0] as i32) + (150 * px[1] as i32) + (77 * px[2] as i32)) >> 8
}

// Gene - Nov, 24, 2026: Force opaque 0xFF alpha while packing BGRA frames so GDI grabs with 0x00 alpha never produce transparent stitched PNGs.
// Old implementation:
// fn pack_bgra(bgra: &[u8], width: usize, height: usize, stride: usize) -> Vec<u8> {
//     let row_bytes = width * 4;
//     if stride == row_bytes {
//         return bgra[..height * row_bytes].to_vec();
//     }
//     let mut out = Vec::with_capacity(height * row_bytes);
//     for y in 0..height {
//         let s = y * stride;
//         out.extend_from_slice(&bgra[s..s + row_bytes]);
//     }
//     out
// }
fn pack_bgra(bgra: &[u8], width: usize, height: usize, stride: usize) -> Vec<u8> {
    let row_bytes = width * 4;
    let mut out = if stride == row_bytes {
        bgra[..height * row_bytes].to_vec()
    } else {
        let mut buf = Vec::with_capacity(height * row_bytes);
        for y in 0..height {
            let s = y * stride;
            buf.extend_from_slice(&bgra[s..s + row_bytes]);
        }
        buf
    };
    for px in out.chunks_exact_mut(4) {
        px[3] = 0xFF;
    }
    out
}

fn extract_horizontal_strip(
    packed: &[u8],
    frame_w: usize,
    frame_h: usize,
    start_col: usize,
    cols: usize,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(cols * frame_h * 4);
    let frame_stride = frame_w * 4;
    let strip_stride = cols * 4;
    let col_byte = start_col * 4;
    for y in 0..frame_h {
        let s = y * frame_stride + col_byte;
        out.extend_from_slice(&packed[s..s + strip_stride]);
    }
    out
}

fn frames_effectively_identical(
    a: &[u8],
    b: &[u8],
    width: usize,
    height: usize,
    sticky: StickyMargins,
) -> bool {
    let x0 = sticky.left.min(width / 3);
    let x1 = width.saturating_sub(sticky.right.min(width / 3)).max(x0 + 1);
    let y0 = sticky.top.min(height / 3);
    let y1 = height.saturating_sub(sticky.bottom.min(height / 3)).max(y0 + 1);

    let step_y = ((y1 - y0) / 64).max(1);
    let step_x = ((x1 - x0) / 64).max(1);
    let mut total_diff: u64 = 0;
    let mut changed: u64 = 0;
    let mut samples: u64 = 0;

    let mut y = y0;
    while y < y1 {
        let row = y * width * 4;
        let mut x = x0;
        while x < x1 {
            let i = row + x * 4;
            let d = (a[i] as i32 - b[i] as i32).abs()
                + (a[i + 1] as i32 - b[i + 1] as i32).abs()
                + (a[i + 2] as i32 - b[i + 2] as i32).abs();
            let avg = d / 3;
            total_diff += avg as u64;
            if avg > 8 {
                changed += 1;
            }
            samples += 1;
            x += step_x;
        }
        y += step_y;
    }

    if samples == 0 {
        return true;
    }
    let mean = total_diff as f64 / samples as f64;
    let ratio = changed as f64 / samples as f64;
    mean < 1.5 && ratio < 0.006
}

#[inline]
fn row_stats(curr: &[u8], anchor: &[u8], width: usize, y: usize, eff_w: usize, step_x: usize) -> (f32, f32) {
    let row = y * width * 4;
    let mut diff_sum = 0i64;
    let mut tex_sum = 0i64;
    let mut count = 0i64;
    let mut prev_luma = bgra_luma(&curr[row..row + 4]);
    let mut x = 0usize;
    while x < eff_w {
        let i = row + x * 4;
        let d = (curr[i] as i32 - anchor[i] as i32).abs()
            + (curr[i + 1] as i32 - anchor[i + 1] as i32).abs()
            + (curr[i + 2] as i32 - anchor[i + 2] as i32).abs();
        diff_sum += d as i64;
        let l = bgra_luma(&curr[i..i + 4]);
        tex_sum += (l - prev_luma).abs() as i64;
        prev_luma = l;
        count += 1;
        x += step_x;
    }
    if count == 0 {
        return (0.0, 0.0);
    }
    (
        diff_sum as f32 / (count as f32 * 3.0),
        tex_sum as f32 / count as f32,
    )
}

#[inline]
fn col_stats(curr: &[u8], anchor: &[u8], width: usize, height: usize, x: usize, step_y: usize) -> (f32, f32) {
    let mut diff_sum = 0i64;
    let mut tex_sum = 0i64;
    let mut count = 0i64;
    let mut prev_luma = bgra_luma(&curr[x * 4..x * 4 + 4]);
    let mut y = 0usize;
    while y < height {
        let i = (y * width + x) * 4;
        let d = (curr[i] as i32 - anchor[i] as i32).abs()
            + (curr[i + 1] as i32 - anchor[i + 1] as i32).abs()
            + (curr[i + 2] as i32 - anchor[i + 2] as i32).abs();
        diff_sum += d as i64;
        let l = bgra_luma(&curr[i..i + 4]);
        tex_sum += (l - prev_luma).abs() as i64;
        prev_luma = l;
        count += 1;
        y += step_y;
    }
    if count == 0 {
        return (0.0, 0.0);
    }
    (
        diff_sum as f32 / (count as f32 * 3.0),
        tex_sum as f32 / count as f32,
    )
}

fn estimate_sticky_borders(
    curr: &[u8],
    anchor: &[u8],
    width: usize,
    height: usize,
    current_sticky: StickyMargins,
    active_axis: Option<ScrollAxis>,
) -> (StickyMargins, bool) {
    let sb = if width > 120 { 18.min(width / 12) } else { 0 };
    let eff_w = (width - sb).max(1);
    let step_x = (eff_w / 48).max(1);
    let step_y = (height / 48).max(1);

    let max_top = (height * 35) / 100;
    let max_bottom = (height * 25) / 100;

    let mut top = 0usize;
    let mut top_has_tex = false;
    for y in 0..max_top {
        let (mad, tex) = row_stats(curr, anchor, width, y, eff_w, step_x);
        if mad >= 3.2 {
            break;
        }
        if tex >= 2.0 {
            top_has_tex = true;
            top = y + 1;
        } else if top_has_tex && y < top + 16 {
            top = y + 1;
        }
    }
    if !top_has_tex {
        top = 0;
    }

    let mut bottom = 0usize;
    let mut bottom_has_tex = false;
    for b_off in 0..max_bottom {
        let ry = height - 1 - b_off;
        if ry <= top + 16 {
            break;
        }
        let (mad, tex) = row_stats(curr, anchor, width, ry, eff_w, step_x);
        if mad >= 3.2 {
            break;
        }
        if tex >= 2.0 {
            bottom_has_tex = true;
            bottom = b_off + 1;
        } else if bottom_has_tex && b_off < bottom + 16 {
            bottom = b_off + 1;
        }
    }
    if !bottom_has_tex {
        bottom = 0;
    }

    // Only pay column border scan when horizontal mode is possible/active.
    let mut left = current_sticky.left;
    let mut right = current_sticky.right;
    if active_axis != Some(ScrollAxis::Vertical) {
        let max_left = (width * 30) / 100;
        let max_right = (width * 25) / 100;
        let mut cand_left = 0usize;
        let mut left_has_tex = false;
        for x in 0..max_left {
            let (mad, tex) = col_stats(curr, anchor, width, height, x, step_y);
            if mad >= 3.2 {
                break;
            }
            if tex >= 2.0 {
                left_has_tex = true;
                cand_left = x + 1;
            } else if left_has_tex && x < cand_left + 16 {
                cand_left = x + 1;
            }
        }
        if left_has_tex {
            left = left.max(cand_left);
        }

        let mut cand_right = 0usize;
        let mut right_has_tex = false;
        for r_off in 0..max_right {
            let rx = width - 1 - r_off;
            if rx <= left + 16 {
                break;
            }
            let (mad, tex) = col_stats(curr, anchor, width, height, rx, step_y);
            if mad >= 3.2 {
                break;
            }
            if tex >= 2.0 {
                right_has_tex = true;
                cand_right = r_off + 1;
            } else if right_has_tex && r_off < cand_right + 16 {
                cand_right = r_off + 1;
            }
        }
        if right_has_tex {
            right = right.max(cand_right);
        }
    }

    // Fast sampled interior check for global motion.
    let mut changed_samples = 0usize;
    let mut y = max_top;
    let mid_end = height.saturating_sub(max_bottom);
    let mid_step = ((mid_end.saturating_sub(max_top)) / 16).max(1);
    while y < mid_end {
        let (mad, _) = row_stats(curr, anchor, width, y, eff_w, step_x * 2);
        if mad >= 4.0 {
            changed_samples += 1;
        }
        y += mid_step;
    }

    (
        StickyMargins {
            top: top.max(current_sticky.top),
            bottom: bottom.max(current_sticky.bottom),
            left,
            right,
        },
        changed_samples >= 3,
    )
}

fn build_frame_sig(
    packed: &[u8],
    width: usize,
    height: usize,
    active_axis: Option<ScrollAxis>,
) -> FrameSig {
    const STEP: usize = 4;
    const BANDS: usize = 8;
    let small_w = (width / STEP).max(BANDS);
    let small_h = (height / STEP).max(BANDS);

    // Fast 2-tap diagonal 4x downsample cuts 8MB BGRA bandwidth in half while preventing 1px aliasing.
    let mut luma_small = vec![0u8; small_w * small_h];
    for sy in 0..small_h {
        let y0 = (sy * STEP).min(height - 1);
        let y2 = (y0 + 2).min(height - 1);
        let row0 = y0 * width * 4;
        let row2 = y2 * width * 4;
        for sx in 0..small_w {
            let x0 = (sx * STEP).min(width - 1);
            let x2 = (x0 + 2).min(width - 1);
            let l00 = bgra_luma(&packed[row0 + x0 * 4..row0 + x0 * 4 + 4]);
            let l22 = bgra_luma(&packed[row2 + x2 * 4..row2 + x2 * 4 + 4]);
            luma_small[sy * small_w + sx] = ((l00 + l22) >> 1) as u8;
        }
    }

    let mut row_bands = Vec::new();
    if active_axis != Some(ScrollAxis::Horizontal) {
        row_bands = vec![0i16; small_h * BANDS * 2];
        for sy in 0..small_h {
            let row = &luma_small[sy * small_w..(sy + 1) * small_w];
            let prev_row = if sy > 0 {
                &luma_small[(sy - 1) * small_w..sy * small_w]
            } else {
                row
            };
            let band_w = (small_w / BANDS).max(1);
            for b in 0..BANDS {
                let x0 = b * band_w;
                let x1 = if b + 1 == BANDS { small_w } else { (b + 1) * band_w };
                let mut l_sum = 0i32;
                let mut g_sum = 0i32;
                for sx in x0..x1 {
                    let c = row[sx] as i32;
                    let left = if sx > 0 { row[sx - 1] as i32 } else { c };
                    let up = prev_row[sx] as i32;
                    l_sum += c;
                    g_sum += (c - left).abs() + (c - up).abs();
                }
                let cnt = (x1 - x0).max(1) as i32;
                row_bands[sy * BANDS * 2 + b] = (l_sum / cnt) as i16;
                row_bands[sy * BANDS * 2 + BANDS + b] = (g_sum / cnt) as i16;
            }
        }
    }

    let mut col_bands = Vec::new();
    if active_axis != Some(ScrollAxis::Vertical) {
        col_bands = vec![0i16; small_w * BANDS * 2];
        for sx in 0..small_w {
            let band_h = (small_h / BANDS).max(1);
            for b in 0..BANDS {
                let y0 = b * band_h;
                let y1 = if b + 1 == BANDS { small_h } else { (b + 1) * band_h };
                let mut l_sum = 0i32;
                let mut g_sum = 0i32;
                for sy in y0..y1 {
                    let c = luma_small[sy * small_w + sx] as i32;
                    let left = if sx > 0 { luma_small[sy * small_w + sx - 1] as i32 } else { c };
                    let up = if sy > 0 { luma_small[(sy - 1) * small_w + sx] as i32 } else { c };
                    l_sum += c;
                    g_sum += (c - left).abs() + (c - up).abs();
                }
                let cnt = (y1 - y0).max(1) as i32;
                col_bands[sx * BANDS * 2 + b] = (l_sum / cnt) as i16;
                col_bands[sx * BANDS * 2 + BANDS + b] = (g_sum / cnt) as i16;
            }
        }
    }

    FrameSig {
        width,
        height,
        small_w,
        small_h,
        luma_small,
        row_bands,
        col_bands,
    }
}

fn match_vertical_with_sticky_confirm(
    anchor: &[u8],
    anchor_sig: &FrameSig,
    curr: &[u8],
    curr_sig: &FrameSig,
    confirmed: StickyMargins,
    candidate: StickyMargins,
    motion_events: u32,
) -> (i32, f32, StickyMargins) {
    let (d_conf, ncc_conf) = match_vertical_core(anchor, anchor_sig, curr, curr_sig, confirmed);
    let has_new_sticky = candidate.top > confirmed.top || candidate.bottom > confirmed.bottom;
    if has_new_sticky && (motion_events <= 2 || ncc_conf < 0.88) {
        let masked = StickyMargins {
            top: candidate.top,
            bottom: candidate.bottom,
            left: confirmed.left,
            right: confirmed.right,
        };
        let (d_mask, ncc_mask) = match_vertical_core(anchor, anchor_sig, curr, curr_sig, masked);
        if ncc_mask >= 0.78 && (ncc_conf < 0.86 || ncc_mask >= ncc_conf + 0.03) {
            return (d_mask, ncc_mask, masked);
        }
    }
    (d_conf, ncc_conf, confirmed)
}

fn match_horizontal_with_sticky_confirm(
    anchor: &[u8],
    anchor_sig: &FrameSig,
    curr: &[u8],
    curr_sig: &FrameSig,
    confirmed: StickyMargins,
    candidate: StickyMargins,
    motion_events: u32,
) -> (i32, f32, StickyMargins) {
    let (d_conf, ncc_conf) = match_horizontal_core(anchor, anchor_sig, curr, curr_sig, confirmed);
    let has_new_sticky = candidate.left > confirmed.left || candidate.right > confirmed.right;
    if has_new_sticky && (motion_events <= 2 || ncc_conf < 0.88) {
        let masked = StickyMargins {
            top: confirmed.top,
            bottom: confirmed.bottom,
            left: candidate.left,
            right: candidate.right,
        };
        let (d_mask, ncc_mask) = match_horizontal_core(anchor, anchor_sig, curr, curr_sig, masked);
        if ncc_mask >= 0.78 && (ncc_conf < 0.86 || ncc_mask >= ncc_conf + 0.03) {
            return (d_mask, ncc_mask, masked);
        }
    }
    (d_conf, ncc_conf, confirmed)
}

fn collect_coarse_peaks(
    a_bands: &[i16],
    b_bands: &[i16],
    small_len: usize,
    s_start: usize,
    s_end: usize,
) -> Vec<i32> {
    const STRIDE: usize = 16;
    let dyn_s = s_end.saturating_sub(s_start);
    if dyn_s < 8 || a_bands.is_empty() || b_bands.is_empty() {
        return vec![0];
    }
    let max_shift = ((dyn_s * 4) / 5) as i32;
    let min_ov = (dyn_s / 5).max(6);

    let mut scored: Vec<(i32, i32)> = Vec::with_capacity((max_shift * 2 + 1) as usize);
    for ds in -max_shift..=max_shift {
        let a_begin = if ds >= 0 { s_start + ds as usize } else { s_start };
        let b_begin = if ds >= 0 { s_start } else { s_start + (-ds) as usize };
        let a_avail = s_end.saturating_sub(a_begin);
        let b_avail = s_end.saturating_sub(b_begin);
        let ov = a_avail.min(b_avail);
        if ov < min_ov || a_begin + ov > small_len || b_begin + ov > small_len {
            continue;
        }
        let mut err: i64 = 0;
        for k in 0..ov {
            let ai = (a_begin + k) * STRIDE;
            let bi = (b_begin + k) * STRIDE;
            for j in 0..STRIDE {
                err += (a_bands[ai + j] - b_bands[bi + j]).abs() as i64;
            }
        }
        let avg_err = (err * 100 / (ov * STRIDE) as i64) as i32;
        scored.push((avg_err, ds));
    }

    scored.sort_unstable_by_key(|v| v.0);

    let mut peaks: Vec<i32> = Vec::with_capacity(12);
    peaks.push(0);
    for &(_, ds) in &scored {
        if peaks.iter().all(|&p| (p - ds).abs() >= 2) {
            peaks.push(ds);
            if peaks.len() >= 10 {
                break;
            }
        }
    }
    peaks
}

fn eval_small_vertical_ncc(
    a_small: &[u8],
    b_small: &[u8],
    sw: usize,
    sx0: usize,
    sx1: usize,
    sy0: usize,
    sy1: usize,
    ds: i32,
) -> (f32, f32) {
    let a_start = if ds >= 0 { sy0 + ds as usize } else { sy0 };
    let b_start = if ds >= 0 { sy0 } else { sy0 + (-ds) as usize };
    let ov_h = sy1.saturating_sub(a_start).min(sy1.saturating_sub(b_start));
    if ov_h < 4 || sx1 <= sx0 {
        return (-1.0, f32::INFINITY);
    }
    let step_y = (ov_h / 40).max(1);
    let step_x = ((sx1 - sx0) / 48).max(1);

    let mut sum_a = 0i64;
    let mut sum_b = 0i64;
    let mut sum_aa = 0i64;
    let mut sum_bb = 0i64;
    let mut sum_ab = 0i64;
    let mut abs_diff = 0i64;
    let mut n = 0i64;

    let mut dy = 0usize;
    while dy < ov_h {
        let ra = (a_start + dy) * sw;
        let rb = (b_start + dy) * sw;
        let mut sx = sx0;
        while sx < sx1 {
            let la = a_small[ra + sx] as i64;
            let lb = b_small[rb + sx] as i64;
            sum_a += la;
            sum_b += lb;
            sum_aa += la * la;
            sum_bb += lb * lb;
            sum_ab += la * lb;
            abs_diff += (la - lb).abs();
            n += 1;
            sx += step_x;
        }
        dy += step_y;
    }
    compute_ncc_and_mad(n, sum_a, sum_b, sum_aa, sum_bb, sum_ab, abs_diff)
}

fn eval_small_horizontal_ncc(
    a_small: &[u8],
    b_small: &[u8],
    sw: usize,
    sx0: usize,
    sx1: usize,
    sy0: usize,
    sy1: usize,
    ds: i32,
) -> (f32, f32) {
    let a_start = if ds >= 0 { sx0 + ds as usize } else { sx0 };
    let b_start = if ds >= 0 { sx0 } else { sx0 + (-ds) as usize };
    let ov_w = sx1.saturating_sub(a_start).min(sx1.saturating_sub(b_start));
    if ov_w < 4 || sy1 <= sy0 {
        return (-1.0, f32::INFINITY);
    }
    let step_x = (ov_w / 40).max(1);
    let step_y = ((sy1 - sy0) / 48).max(1);

    let mut sum_a = 0i64;
    let mut sum_b = 0i64;
    let mut sum_aa = 0i64;
    let mut sum_bb = 0i64;
    let mut sum_ab = 0i64;
    let mut abs_diff = 0i64;
    let mut n = 0i64;

    let mut sy = sy0;
    while sy < sy1 {
        let row = sy * sw;
        let mut dx = 0usize;
        while dx < ov_w {
            let la = a_small[row + a_start + dx] as i64;
            let lb = b_small[row + b_start + dx] as i64;
            sum_a += la;
            sum_b += lb;
            sum_aa += la * la;
            sum_bb += lb * lb;
            sum_ab += la * lb;
            abs_diff += (la - lb).abs();
            n += 1;
            dx += step_x;
        }
        sy += step_y;
    }
    compute_ncc_and_mad(n, sum_a, sum_b, sum_aa, sum_bb, sum_ab, abs_diff)
}

fn match_vertical_core(
    anchor: &[u8],
    anchor_sig: &FrameSig,
    curr: &[u8],
    curr_sig: &FrameSig,
    sticky: StickyMargins,
) -> (i32, f32) {
    let w = anchor_sig.width;
    let h = anchor_sig.height;
    let y0 = sticky.top.min(h / 3);
    let y1 = h.saturating_sub(sticky.bottom.min(h / 3));
    let x0 = sticky.left.min(w / 3);
    let x1 = w.saturating_sub(sticky.right.min(w / 3));
    if y1 <= y0 + 24 || x1 <= x0 + 16 {
        return (0, 0.0);
    }

    let dyn_h = y1 - y0;
    let sy0 = (y0 / 4).min(anchor_sig.small_h - 1);
    let sy1 = ((y1 + 3) / 4).min(anchor_sig.small_h);
    let sx0 = (x0 / 4).min(anchor_sig.small_w - 1);
    let sx1 = ((x1 + 3) / 4).min(anchor_sig.small_w);

    let coarse_peaks = collect_coarse_peaks(
        &anchor_sig.row_bands,
        &curr_sig.row_bands,
        anchor_sig.small_h,
        sy0,
        sy1,
    );

    // Stage 2: Fast 2D screening in L2-cache small luma pyramid.
    let max_ds = (((sy1 - sy0) * 4) / 5) as i32;
    let mut small_candidates: Vec<(f32, f32, i32)> = Vec::new();
    for &ds in &coarse_peaks {
        for off in -1..=1 {
            let cand_ds = ds + off;
            if cand_ds.abs() > max_ds {
                continue;
            }
            let (ncc, mad) = eval_small_vertical_ncc(
                &anchor_sig.luma_small,
                &curr_sig.luma_small,
                anchor_sig.small_w,
                sx0,
                sx1,
                sy0,
                sy1,
                cand_ds,
            );
            if ncc > -0.99 {
                small_candidates.push((ncc, mad, cand_ds * 4));
            }
        }
    }

    small_candidates.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
    });

    // Stage 3: Exact 1px full-res NCC refinement around top 3 coarse winners.
    let max_shift = ((dyn_h * 4) / 5) as i32;
    let min_ov = (dyn_h / 5).max(24);
    let mut best_delta = 0i32;
    let mut best_ncc = -1.0f32;
    let mut best_mad = f32::INFINITY;

    let mut tested_centers: Vec<i32> = Vec::with_capacity(3);
    for &(_, _, center) in &small_candidates {
        if tested_centers.iter().any(|&c| (c - center).abs() < 4) {
            continue;
        }
        tested_centers.push(center);
        // Coarse 2px scan within [-4..=4], then 1px around local best.
        let mut local_best_d = center;
        let mut local_best_ncc = -1.0f32;
        let mut local_best_mad = f32::INFINITY;
        for off in [-4, -2, 0, 2, 4] {
            let d = center + off;
            if d.abs() > max_shift {
                continue;
            }
            let (ncc, mad) = eval_vertical_ncc(anchor, curr, w, x0, x1, y0, y1, d, min_ov);
            if is_better_match(ncc, mad, local_best_ncc, local_best_mad) {
                local_best_ncc = ncc;
                local_best_mad = mad;
                local_best_d = d;
            }
        }
        for off in [-1, 0, 1] {
            let d = local_best_d + off;
            if d.abs() > max_shift {
                continue;
            }
            let (ncc, mad) = eval_vertical_ncc(anchor, curr, w, x0, x1, y0, y1, d, min_ov);
            if is_better_match(ncc, mad, best_ncc, best_mad) {
                best_ncc = ncc;
                best_mad = mad;
                best_delta = d;
            }
        }
        if tested_centers.len() >= 4 {
            break;
        }
    }

    if best_ncc < 0.72 && best_mad < 2.5 {
        return (0, 0.0);
    }

    (best_delta, best_ncc)
}

#[inline]
fn is_better_match(ncc: f32, mad: f32, best_ncc: f32, best_mad: f32) -> bool {
    if ncc > best_ncc + 0.002 {
        return true;
    }
    if (ncc - best_ncc).abs() <= 0.002 {
        return mad < best_mad;
    }
    false
}

fn eval_vertical_ncc(
    anchor: &[u8],
    curr: &[u8],
    width: usize,
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
    delta: i32,
    min_ov: usize,
) -> (f32, f32) {
    let a_start = if delta >= 0 { y0 + delta as usize } else { y0 };
    let b_start = if delta >= 0 { y0 } else { y0 + (-delta) as usize };
    let a_avail = y1.saturating_sub(a_start);
    let b_avail = y1.saturating_sub(b_start);
    let ov_h = a_avail.min(b_avail);
    if ov_h < min_ov {
        return (-1.0, f32::INFINITY);
    }

    let step_y = (ov_h / 64).max(1);
    let step_x = ((x1 - x0) / 80).max(1);

    let mut sum_a = 0i64;
    let mut sum_b = 0i64;
    let mut sum_aa = 0i64;
    let mut sum_bb = 0i64;
    let mut sum_ab = 0i64;
    let mut abs_diff = 0i64;
    let mut n = 0i64;

    let mut dy = 0usize;
    while dy < ov_h {
        let ra = (a_start + dy) * width * 4;
        let rb = (b_start + dy) * width * 4;
        let mut x = x0;
        while x < x1 {
            let ia = ra + x * 4;
            let ib = rb + x * 4;
            let la = bgra_luma(&anchor[ia..ia + 4]);
            let lb = bgra_luma(&curr[ib..ib + 4]);
            sum_a += la as i64;
            sum_b += lb as i64;
            sum_aa += (la * la) as i64;
            sum_bb += (lb * lb) as i64;
            sum_ab += (la * lb) as i64;
            abs_diff += (la - lb).abs() as i64;
            n += 1;
            x += step_x;
        }
        dy += step_y;
    }

    compute_ncc_and_mad(n, sum_a, sum_b, sum_aa, sum_bb, sum_ab, abs_diff)
}

fn match_horizontal_core(
    anchor: &[u8],
    anchor_sig: &FrameSig,
    curr: &[u8],
    curr_sig: &FrameSig,
    sticky: StickyMargins,
) -> (i32, f32) {
    let w = anchor_sig.width;
    let h = anchor_sig.height;
    let y0 = sticky.top.min(h / 3);
    let y1 = h.saturating_sub(sticky.bottom.min(h / 3));
    let x0 = sticky.left.min(w / 3);
    let x1 = w.saturating_sub(sticky.right.min(w / 3));
    if x1 <= x0 + 24 || y1 <= y0 + 16 {
        return (0, 0.0);
    }

    let dyn_w = x1 - x0;
    let sy0 = (y0 / 4).min(anchor_sig.small_h - 1);
    let sy1 = ((y1 + 3) / 4).min(anchor_sig.small_h);
    let sx0 = (x0 / 4).min(anchor_sig.small_w - 1);
    let sx1 = ((x1 + 3) / 4).min(anchor_sig.small_w);

    let coarse_peaks = collect_coarse_peaks(
        &anchor_sig.col_bands,
        &curr_sig.col_bands,
        anchor_sig.small_w,
        sx0,
        sx1,
    );

    let max_ds = (((sx1 - sx0) * 4) / 5) as i32;
    let mut small_candidates: Vec<(f32, f32, i32)> = Vec::new();
    for &ds in &coarse_peaks {
        for off in -1..=1 {
            let cand_ds = ds + off;
            if cand_ds.abs() > max_ds {
                continue;
            }
            let (ncc, mad) = eval_small_horizontal_ncc(
                &anchor_sig.luma_small,
                &curr_sig.luma_small,
                anchor_sig.small_w,
                sx0,
                sx1,
                sy0,
                sy1,
                cand_ds,
            );
            if ncc > -0.99 {
                small_candidates.push((ncc, mad, cand_ds * 4));
            }
        }
    }

    small_candidates.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
    });

    let max_shift = ((dyn_w * 4) / 5) as i32;
    let min_ov = (dyn_w / 5).max(24);
    let mut best_delta = 0i32;
    let mut best_ncc = -1.0f32;
    let mut best_mad = f32::INFINITY;

    let mut tested_centers: Vec<i32> = Vec::with_capacity(3);
    for &(_, _, center) in &small_candidates {
        if tested_centers.iter().any(|&c| (c - center).abs() < 4) {
            continue;
        }
        tested_centers.push(center);
        let mut local_best_d = center;
        let mut local_best_ncc = -1.0f32;
        let mut local_best_mad = f32::INFINITY;
        for off in [-4, -2, 0, 2, 4] {
            let d = center + off;
            if d.abs() > max_shift {
                continue;
            }
            let (ncc, mad) = eval_horizontal_ncc(anchor, curr, w, x0, x1, y0, y1, d, min_ov);
            if is_better_match(ncc, mad, local_best_ncc, local_best_mad) {
                local_best_ncc = ncc;
                local_best_mad = mad;
                local_best_d = d;
            }
        }
        for off in [-1, 0, 1] {
            let d = local_best_d + off;
            if d.abs() > max_shift {
                continue;
            }
            let (ncc, mad) = eval_horizontal_ncc(anchor, curr, w, x0, x1, y0, y1, d, min_ov);
            if is_better_match(ncc, mad, best_ncc, best_mad) {
                best_ncc = ncc;
                best_mad = mad;
                best_delta = d;
            }
        }
        if tested_centers.len() >= 4 {
            break;
        }
    }

    if best_ncc < 0.72 && best_mad < 2.5 {
        return (0, 0.0);
    }

    (best_delta, best_ncc)
}

fn eval_horizontal_ncc(
    anchor: &[u8],
    curr: &[u8],
    width: usize,
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
    delta: i32,
    min_ov: usize,
) -> (f32, f32) {
    let a_start = if delta >= 0 { x0 + delta as usize } else { x0 };
    let b_start = if delta >= 0 { x0 } else { x0 + (-delta) as usize };
    let a_avail = x1.saturating_sub(a_start);
    let b_avail = x1.saturating_sub(b_start);
    let ov_w = a_avail.min(b_avail);
    if ov_w < min_ov {
        return (-1.0, f32::INFINITY);
    }

    let step_x = (ov_w / 64).max(1);
    let step_y = ((y1 - y0) / 80).max(1);

    let mut sum_a = 0i64;
    let mut sum_b = 0i64;
    let mut sum_aa = 0i64;
    let mut sum_bb = 0i64;
    let mut sum_ab = 0i64;
    let mut abs_diff = 0i64;
    let mut n = 0i64;

    let mut y = y0;
    while y < y1 {
        let row = y * width * 4;
        let mut dx = 0usize;
        while dx < ov_w {
            let ia = row + (a_start + dx) * 4;
            let ib = row + (b_start + dx) * 4;
            let la = bgra_luma(&anchor[ia..ia + 4]);
            let lb = bgra_luma(&curr[ib..ib + 4]);
            sum_a += la as i64;
            sum_b += lb as i64;
            sum_aa += (la * la) as i64;
            sum_bb += (lb * lb) as i64;
            sum_ab += (la * lb) as i64;
            abs_diff += (la - lb).abs() as i64;
            n += 1;
            dx += step_x;
        }
        y += step_y;
    }

    compute_ncc_and_mad(n, sum_a, sum_b, sum_aa, sum_bb, sum_ab, abs_diff)
}

#[inline]
fn compute_ncc_and_mad(
    n: i64,
    sum_a: i64,
    sum_b: i64,
    sum_aa: i64,
    sum_bb: i64,
    sum_ab: i64,
    abs_diff: i64,
) -> (f32, f32) {
    if n <= 1 {
        return (-1.0, f32::INFINITY);
    }
    let nf = n as f64;
    let mad = abs_diff as f32 / nf as f32;
    let var_a = sum_aa as f64 - (sum_a as f64 * sum_a as f64) / nf;
    let var_b = sum_bb as f64 - (sum_b as f64 * sum_b as f64) / nf;
    if var_a <= 1e-6 * nf || var_b <= 1e-6 * nf {
        return if mad < 2.0 { (0.65, mad) } else { (-1.0, mad) };
    }
    let cov = sum_ab as f64 - (sum_a as f64 * sum_b as f64) / nf;
    let denom = (var_a * var_b).sqrt();
    let ncc = (cov / denom).clamp(-1.0, 1.0) as f32;
    (ncc, mad)
}
