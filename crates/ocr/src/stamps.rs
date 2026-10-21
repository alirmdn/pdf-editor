//! Stamps, seals and signatures on a scanned page: the coloured ink a recogniser reads as
//! junk words (a ring of letters around a seal, a signature's loops).
//!
//! [`find`] marks the page's large blobs of coloured ink: a grid of cells, each coloured when
//! enough of its pixels are saturated ink, grown into connected regions. A region counts as a
//! stamp when it is big (several text lines tall) and roughly compact; a coloured heading is a
//! long thin strip and is left alone. [`drop_stamped`] then removes the words whose middle is in
//! a stamp and whose own ink is mostly coloured, so black text printed over or beside a stamp,
//! or inside a coloured sticker, is kept.

use crate::{Line, Word};

/// Whether an RGB pixel is coloured ink: saturated and not pale (paper tints and the pastel
/// background patterns of certificates are light and barely saturated).
fn colored(r: u8, g: u8, b: u8) -> bool {
    let (hi, lo) = (r.max(g).max(b), r.min(g).min(b));
    hi - lo >= 50 && lo < 200
}

/// Whether an RGB pixel is ink of any colour (dark, or coloured).
fn inked(r: u8, g: u8, b: u8) -> bool {
    r.min(g).min(b) < 140 || colored(r, g, b)
}

/// A page image: RGBA, RGB or grey pixels, `width` × `height`.
struct Image<'a> {
    px: &'a [u8],
    w: usize,
    h: usize,
    channels: usize,
}

impl<'a> Image<'a> {
    fn new(px: &'a [u8], width: u32, height: u32) -> Option<Image<'a>> {
        let (w, h) = (width as usize, height as usize);
        let n = w.checked_mul(h).filter(|n| *n > 0)?;
        let channels = [4, 3, 1].into_iter().find(|c| n.checked_mul(*c) == Some(px.len()))?;
        Some(Image { px, w, h, channels })
    }

    fn rgb(&self, x: usize, y: usize) -> (u8, u8, u8) {
        let i = (y * self.w + x) * self.channels;
        let c = |k: usize| self.px.get(i + k.min(self.channels - 1)).copied().unwrap_or(255);
        (c(0), c(1), c(2))
    }
}

/// The stamp regions of a page image, `[left, top, right, bottom]` in pixels.
pub fn find(pixels: &[u8], width: u32, height: u32) -> Vec<[f32; 4]> {
    let Some(img) = Image::new(pixels, width, height) else { return Vec::new() };
    let long = img.w.max(img.h);
    let cell = (long / 300).max(3);
    let (gw, gh) = (img.w.div_ceil(cell), img.h.div_ceil(cell));
    // Which cells hold coloured ink.
    let mut grid = vec![false; gw * gh];
    for gy in 0..gh {
        for gx in 0..gw {
            let (mut ink, mut all) = (0usize, 0usize);
            for y in gy * cell..((gy + 1) * cell).min(img.h) {
                for x in gx * cell..((gx + 1) * cell).min(img.w) {
                    let (r, g, b) = img.rgb(x, y);
                    all += 1;
                    if colored(r, g, b) {
                        ink += 1;
                    }
                }
            }
            if let Some(c) = grid.get_mut(gy * gw + gx) {
                *c = all > 0 && ink * 8 >= all;
            }
        }
    }
    // Connected regions, with gaps of up to two cells bridged (a stamp's letters and rings are
    // separate strokes).
    const REACH: isize = 2;
    let mut seen = vec![false; gw * gh];
    let mut out = Vec::new();
    for start in 0..gw * gh {
        if !grid.get(start).copied().unwrap_or(false) || seen.get(start).copied().unwrap_or(true) {
            continue;
        }
        let mut stack = vec![start];
        if let Some(s) = seen.get_mut(start) {
            *s = true;
        }
        let (mut x0, mut y0, mut x1, mut y1, mut cells) = (usize::MAX, usize::MAX, 0usize, 0usize, 0usize);
        while let Some(i) = stack.pop() {
            let (cx, cy) = (i % gw, i / gw);
            cells += 1;
            (x0, y0, x1, y1) = (x0.min(cx), y0.min(cy), x1.max(cx), y1.max(cy));
            for dy in -REACH..=REACH {
                for dx in -REACH..=REACH {
                    let (nx, ny) = (cx as isize + dx, cy as isize + dy);
                    if nx < 0 || ny < 0 || nx as usize >= gw || ny as usize >= gh {
                        continue;
                    }
                    let j = ny as usize * gw + nx as usize;
                    if grid.get(j).copied().unwrap_or(false) && !seen.get(j).copied().unwrap_or(true) {
                        if let Some(s) = seen.get_mut(j) {
                            *s = true;
                        }
                        stack.push(j);
                    }
                }
            }
        }
        let (bw, bh) = ((x1 - x0 + 1) as f32, (y1 - y0 + 1) as f32);
        let (gwf, ghf) = (gw as f32, gh as f32);
        let big = bw >= gwf.max(ghf) * 0.04 && bh >= gwf.max(ghf) * 0.035;
        let not_page = bw <= gwf * 0.6 && bh <= ghf * 0.5;
        let compact = bw <= bh * 4.0 && bh <= bw * 4.0;
        let dense = cells as f32 >= bw * bh * 0.08;
        if big && not_page && compact && dense {
            out.push([(x0 * cell) as f32, (y0 * cell) as f32, ((x1 + 1) * cell).min(img.w) as f32, ((y1 + 1) * cell).min(img.h) as f32]);
        }
    }
    out
}

/// The share of a word box's ink that is coloured (0 when the box has no ink).
fn colored_share(img: &Image, rect: [f32; 4]) -> f32 {
    let clamp = |v: f32, max: usize| (v.max(0.0) as usize).min(max);
    let (x0, x1) = (clamp(rect[0], img.w), clamp(rect[2].ceil(), img.w));
    let (y0, y1) = (clamp(rect[1], img.h), clamp(rect[3].ceil(), img.h));
    let (mut ink, mut color) = (0usize, 0usize);
    for y in y0..y1 {
        for x in x0..x1 {
            let (r, g, b) = img.rgb(x, y);
            if inked(r, g, b) {
                ink += 1;
                if colored(r, g, b) {
                    color += 1;
                }
            }
        }
    }
    if ink == 0 { 0.0 } else { color as f32 / ink as f32 }
}

/// Whether `word` (a box in pixels) is part of a stamp: its middle is inside one of `stamps`
/// and most of its ink is coloured.
pub fn is_stamped(pixels: &[u8], width: u32, height: u32, stamps: &[[f32; 4]], word: [f32; 4]) -> bool {
    let Some(img) = Image::new(pixels, width, height) else { return false };
    let (mx, my) = ((word[0] + word[2]) / 2.0, (word[1] + word[3]) / 2.0);
    stamps.iter().any(|s| mx >= s[0] && mx <= s[2] && my >= s[1] && my <= s[3]) && colored_share(&img, word) >= 0.5
}

/// `lines` without the words that are a stamp's ink (and without lines left empty).
pub fn drop_stamped(lines: Vec<Line>, pixels: &[u8], width: u32, height: u32) -> Vec<Line> {
    let stamps = find(pixels, width, height);
    if stamps.is_empty() {
        return lines;
    }
    lines
        .into_iter()
        .filter_map(|line| {
            let words: Vec<Word> = line.words.into_iter().filter(|w| !is_stamped(pixels, width, height, &stamps, w.rect)).collect();
            (!words.is_empty()).then_some(Line { words })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A white page with black text strips, a blue round stamp with blue "letters", black text
    /// printed across the stamp, and a long thin red heading.
    fn paint(px: &mut [u8], w: u32, x0: u32, y0: u32, x1: u32, y1: u32, c: [u8; 3]) {
        for y in y0..y1 {
            for x in x0..x1 {
                let i = ((y * w + x) * 3) as usize;
                px[i..i + 3].copy_from_slice(&c);
            }
        }
    }

    fn page() -> (Vec<u8>, u32, u32) {
        let (w, h) = (600u32, 800u32);
        let mut px = vec![255u8; (w * h * 3) as usize];
        // Body text.
        for row in 0..10 {
            paint(&mut px, w, 50, 100 + row * 30, 550, 112 + row * 30, [20, 20, 20]);
        }
        // A red heading: long and thin.
        paint(&mut px, w, 100, 40, 500, 60, [200, 30, 30]);
        // The stamp: a blue ring 120 px across, with letters inside.
        for y in 500..620u32 {
            for x in 300..420u32 {
                let (dx, dy) = (x as f32 - 360.0, y as f32 - 560.0);
                let d = (dx * dx + dy * dy).sqrt();
                if (52.0..60.0).contains(&d) || ((350..372).contains(&x) && (540..580).contains(&y) && x % 4 < 2) {
                    let i = ((y * w + x) * 3) as usize;
                    px[i..i + 3].copy_from_slice(&[60, 60, 170]);
                }
            }
        }
        // Black words printed over the stamp.
        paint(&mut px, w, 310, 600, 410, 612, [15, 15, 15]);
        (px, w, h)
    }

    #[test]
    fn a_seal_is_a_stamp_and_a_coloured_heading_is_not() {
        let (px, w, h) = page();
        let stamps = find(&px, w, h);
        assert_eq!(stamps.len(), 1, "{stamps:?}");
        let s = stamps[0];
        assert!(s[0] <= 305.0 && s[2] >= 415.0 && s[1] <= 505.0 && s[3] >= 595.0, "{s:?}");
    }

    #[test]
    fn only_the_stamps_own_ink_is_dropped() {
        let (px, w, h) = page();
        let w_ = |t: &str, r: [f32; 4]| Word { text: t.into(), rect: r };
        let lines = vec![
            Line { words: vec![w_("body", [50.0, 100.0, 200.0, 112.0])] },
            Line { words: vec![w_("heading", [100.0, 40.0, 500.0, 60.0])] },
            Line { words: vec![w_("seal", [345.0, 535.0, 375.0, 585.0])] },
            Line { words: vec![w_("over", [310.0, 598.0, 410.0, 614.0])] },
        ];
        let kept: Vec<String> = drop_stamped(lines, &px, w, h).iter().map(Line::text).collect();
        assert_eq!(kept, ["body", "heading", "over"]);
    }

    #[test]
    fn broken_images_find_nothing() {
        assert!(find(&[], 0, 0).is_empty());
        assert!(find(&[0; 7], 2, 2).is_empty());
        let white = vec![255u8; 100 * 100 * 4];
        assert!(find(&white, 100, 100).is_empty());
        assert!(!is_stamped(&[], 0, 0, &[[0.0, 0.0, 9.0, 9.0]], [1.0, 1.0, 2.0, 2.0]));
    }
}
