//! Arabic text recognition: PaddleOCR's PP-OCRv5 Arabic line recogniser (Apache-2.0), run with
//! rten from its ONNX file, on the text lines the ocrs detector finds.
//!
//! The recogniser reads a line image left to right and emits CTC class scores; its alphabet is
//! `arabic-dict.txt` (one entry per line, class 0 is the CTC blank, a space is the last class).
//! What it reads comes out in drawing order, so [`logical`] turns it back into typing order the
//! way PaddleOCR's own decoder does: Arabic letters reversed, runs of Latin letters and digits
//! kept as they read.

use std::path::Path;

use rten_tensor::prelude::*;
use rten_tensor::{NdTensor, Tensor};

use crate::{Line, OcrError, Word};

/// The model and dictionary file names in the models folder.
pub const MODEL: &str = "arabic-recognition.onnx";
pub const DICT: &str = "arabic-dict.txt";

/// The recogniser's input height in pixels.
const HEIGHT: usize = 48;
/// The widest line image read in one pass (longer lines are squeezed to fit).
const MAX_WIDTH: usize = 3200;
/// The most classes a dictionary may have (the shipped one has about 750).
const MAX_CLASSES: usize = 20_000;

pub struct Reader {
    model: rten::Model,
    /// Class `k` (1-based; 0 is the blank) is `chars[k - 1]`.
    chars: Vec<String>,
}

impl Reader {
    pub fn load(model: &Path, dict: &Path) -> Result<Reader, OcrError> {
        let m = rten::Model::load_file(model).map_err(|e| OcrError::Load(model.display().to_string(), e.to_string()))?;
        let text = std::fs::read_to_string(dict).map_err(|e| OcrError::Load(dict.display().to_string(), e.to_string()))?;
        let mut chars: Vec<String> = text.lines().map(|l| l.trim_end_matches('\r').to_owned()).take(MAX_CLASSES).collect();
        chars.push(" ".into());
        Ok(Reader { model: m, chars })
    }

    /// Read one line image (`rgb`, 3 bytes per pixel, `width` × `height`), cropped to `crop`
    /// (`[left, top, right, bottom]` in pixels), in typing order.
    pub fn read_line(&self, rgb: &[u8], width: u32, height: u32, crop: [f32; 4]) -> Result<String, OcrError> {
        Ok(self.read(rgb, width, height, crop)?.text())
    }

    /// [`Reader::read_line`] as words, each boxed where the recogniser read it (the steps of
    /// its output where the word's letters came out), in typing order. `crop` is the line's box.
    pub fn read(&self, rgb: &[u8], width: u32, height: u32, crop: [f32; 4]) -> Result<Line, OcrError> {
        let (best, span) = self.best_path(rgb, width, height, crop)?;
        let mut words = positioned_words(&best, &self.chars, span, crop);
        if let Some(ink) = ink_columns(rgb, width, height, crop) {
            fit_to_ink(&mut words, &ink);
        }
        if words.is_empty() {
            // No step positions (an empty reading): share the line out evenly.
            return Ok(words_in_line(&logical(&decode(&best, &self.chars)), crop));
        }
        Ok(Line { words: typing_order(words) })
    }

    /// The most likely class at each output step, and the image's x range the steps cover.
    fn best_path(&self, rgb: &[u8], width: u32, height: u32, crop: [f32; 4]) -> Result<(Vec<usize>, [f32; 2]), OcrError> {
        let (input, span) = line_tensor(rgb, width, height, crop).ok_or(OcrError::EmptyImage)?;
        let input: Tensor<f32> = input.into();
        let out = self.model.run_one(input.view().into(), None).map_err(|e| OcrError::Recognize(e.to_string()))?;
        let scores: NdTensor<f32, 3> = out.try_into().map_err(|_| OcrError::Recognize("the Arabic model gave an unexpected output".into()))?;
        let [_, steps, classes] = scores.shape();
        let mut best = Vec::with_capacity(steps);
        for t in 0..steps {
            let mut arg = 0usize;
            let mut top = f32::NEG_INFINITY;
            for c in 0..classes {
                let v = scores.get([0, t, c]).copied().unwrap_or(f32::NEG_INFINITY);
                if v > top {
                    top = v;
                    arg = c;
                }
            }
            best.push(arg);
        }
        Ok((best, span))
    }
}

/// The words of a best path in drawing order, each in typing order itself and boxed from the
/// first to the last step its letters were read at (half a step wider each side). `span` is the
/// image x range the steps cover, `crop` the line's box (the words stay inside it).
pub fn positioned_words(best: &[usize], chars: &[String], span: [f32; 2], crop: [f32; 4]) -> Vec<Word> {
    let steps = best.len();
    if steps == 0 || span[1].partial_cmp(&span[0]) != Some(std::cmp::Ordering::Greater) {
        return Vec::new();
    }
    let step = (span[1] - span[0]) / steps as f32;
    let x = |t: usize| span[0] + t as f32 * step;
    let mut words = Vec::new();
    // The word being read: its drawn letters and the steps they span.
    let mut drawn = String::new();
    let mut first = 0usize;
    let mut last = 0usize;
    let mut flush = |drawn: &mut String, first: usize, last: usize| {
        let text = logical(drawn);
        drawn.clear();
        if text.is_empty() {
            return;
        }
        let left = (x(first) - step * 0.5).clamp(crop[0], crop[2]);
        let right = (x(last + 1) + step * 0.5).clamp(crop[0], crop[2]);
        if right > left {
            words.push(Word { text, rect: [left, crop[1], right, crop[3]] });
        }
    };
    let mut prev = 0usize;
    for (t, &k) in best.iter().enumerate() {
        if k != 0
            && let Some(c) = chars.get(k - 1)
        {
            if c.trim().is_empty() {
                if k != prev {
                    flush(&mut drawn, first, last);
                }
            } else {
                if drawn.is_empty() {
                    first = t;
                }
                if k != prev {
                    drawn.push_str(c);
                }
                last = t;
            }
        }
        prev = k;
    }
    flush(&mut drawn, first, last);
    words
}

/// Which image columns have ink in the line `crop`, indexed by x (columns outside the crop are
/// blank). Ink is darker than halfway between the line's lightest and darkest pixels; `None`
/// for a line with no contrast.
fn ink_columns(rgb: &[u8], width: u32, height: u32, crop: [f32; 4]) -> Option<Vec<bool>> {
    let (w, h) = (width as usize, height as usize);
    let col = |v: f32| (v.max(0.0) as usize).min(w);
    let row = |v: f32| (v.max(0.0) as usize).min(h);
    let (y0, y1) = (row(crop[1]), row(crop[3].ceil()));
    let (x0, x1) = (col(crop[0]), col(crop[2].ceil()));
    let luma = |x: usize, y: usize| {
        let i = y.checked_mul(w).and_then(|r| r.checked_add(x)).and_then(|p| p.checked_mul(3)).unwrap_or(usize::MAX);
        match rgb.get(i..i.saturating_add(3)) {
            Some([r, g, b]) => (u32::from(*r) * 3 + u32::from(*g) * 6 + u32::from(*b)) / 10,
            _ => 255,
        }
    };
    let (mut lo, mut hi) = (255u32, 0u32);
    for y in y0..y1 {
        for x in x0..x1 {
            let v = luma(x, y);
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    if hi < lo + 40 {
        return None;
    }
    let mid = (lo + hi) / 2;
    Some((0..w).map(|x| (x0..x1).contains(&x) && (y0..y1).any(|y| luma(x, y) < mid)).collect())
}

/// Move word boxes (from the recogniser's steps, right within a step or two) onto the ink: the
/// boundary between neighbouring words goes to the widest blank gap between their middles, and
/// each box then shrinks to its first and last inked column.
fn fit_to_ink(words: &mut [Word], ink: &[bool]) {
    let inked = |x: usize| ink.get(x).copied().unwrap_or(false);
    let at = |v: f32| (v.max(0.0) as usize).min(ink.len());
    let mut order: Vec<usize> = (0..words.len()).collect();
    order.sort_by(|a, b| {
        let mid = |i: &usize| words.get(*i).map_or(0.0, |w| w.rect[0] + w.rect[2]);
        mid(a).total_cmp(&mid(b))
    });
    for pair in order.windows(2) {
        let [l, r] = [pair[0], pair[1]];
        let (Some(lw), Some(rw)) = (words.get(l), words.get(r)) else { continue };
        let (from, to) = (at((lw.rect[0] + lw.rect[2]) / 2.0), at((rw.rect[0] + rw.rect[2]) / 2.0));
        // The widest run of blank columns between the two middles.
        let (mut best, mut start) = (None::<(usize, usize)>, None);
        for x in from..=to {
            match (inked(x) || x == to, start) {
                (false, None) => start = Some(x),
                (true, Some(s)) => {
                    if best.is_none_or(|(a, b)| x - s > b - a) {
                        best = Some((s, x));
                    }
                    start = None;
                }
                _ => {}
            }
        }
        if let Some((a, b)) = best {
            if let Some(w) = words.get_mut(l) {
                w.rect[2] = a as f32;
            }
            if let Some(w) = words.get_mut(r) {
                w.rect[0] = b as f32;
            }
        }
    }
    for w in words.iter_mut() {
        let (x0, x1) = (at(w.rect[0]), at(w.rect[2].ceil()));
        if let (Some(first), Some(last)) = ((x0..x1).find(|x| inked(*x)), (x0..x1).rev().find(|x| inked(*x))) {
            w.rect[0] = first as f32;
            w.rect[2] = (last + 1) as f32;
        }
    }
}

/// Words of one Arabic line, placed anywhere on it, in typing order: right to left, except that
/// neighbouring words of Latin letters (a name, "UNITED ARAB EMIRATES") keep reading left to
/// right among themselves. A number is a word of its own, as the bidirectional algorithm treats
/// one between Arabic words: "رقم 2025 / 7525" is drawn with 7525 leftmost.
pub fn typing_order(mut words: Vec<Word>) -> Vec<Word> {
    words.sort_by(|a, b| b.rect[2].total_cmp(&a.rect[2]));
    let latin = |w: &Word| w.text.chars().any(|c| c.is_ascii_alphabetic()) && !w.text.chars().any(is_arabic);
    let mut i = 0;
    while i < words.len() {
        let mut j = i;
        while words.get(j).is_some_and(latin) {
            j += 1;
        }
        if let Some(run) = words.get_mut(i..j) {
            run.reverse();
        }
        i = j.max(i + 1);
    }
    words
}

/// Join the lines that are pieces of one printed Arabic line: the detector often stops a line at
/// a number or a wide space, and the piece read on its own (a date, "2025", a name in Latin
/// letters) would become a block of its own, cut out of its sentence. Lines on one band (a
/// similar height, sharing most of it) less than two line heights apart, at least one of them
/// Arabic, become one line in typing order. Farther pieces (a form's label and its value, a
/// table's columns) stay apart. Lines come back top to bottom.
pub fn merge_bands(lines: Vec<Line>) -> Vec<Line> {
    let rect = |l: &Line| l.words.iter().map(|w| w.rect).reduce(|a, b| [a[0].min(b[0]), a[1].min(b[1]), a[2].max(b[2]), a[3].max(b[3])]);
    let mut items: Vec<([f32; 4], Line)> = lines.into_iter().filter_map(|l| rect(&l).map(|r| (r, l))).collect();
    let arabic = |l: &Line| l.words.iter().any(|w| w.text.chars().any(is_arabic));
    let same = |a: &([f32; 4], Line), b: &([f32; 4], Line)| {
        let (ra, rb) = (a.0, b.0);
        let (ha, hb) = ((ra[3] - ra[1]).max(0.0), (rb[3] - rb[1]).max(0.0));
        let (lo, hi) = (ha.min(hb), ha.max(hb));
        let overlap = (ra[3].min(rb[3]) - ra[1].max(rb[1])).max(0.0);
        let gap = (rb[0] - ra[2]).max(ra[0] - rb[2]);
        (arabic(&a.1) || arabic(&b.1)) && lo > 0.0 && lo >= hi * 0.5 && overlap >= lo * 0.6 && gap < hi * 2.0
    };
    // Each pass joins one pair, so this ends within `items.len()` passes.
    loop {
        let mut pair = None;
        'scan: for i in 0..items.len() {
            for j in i + 1..items.len() {
                if let (Some(a), Some(b)) = (items.get(i), items.get(j))
                    && same(a, b)
                {
                    pair = Some((i, j));
                    break 'scan;
                }
            }
        }
        let Some((i, j)) = pair else { break };
        let (rb, lb) = items.swap_remove(j);
        if let Some((ra, la)) = items.get_mut(i) {
            *ra = [ra[0].min(rb[0]), ra[1].min(rb[1]), ra[2].max(rb[2]), ra[3].max(rb[3])];
            la.words.extend(lb.words);
            la.words = typing_order(std::mem::take(&mut la.words));
        }
    }
    items.sort_by(|a, b| a.0[1].total_cmp(&b.0[1]).then(b.0[2].total_cmp(&a.0[2])));
    items.into_iter().map(|(_, l)| l).collect()
}

fn is_arabic(c: char) -> bool {
    matches!(u32::from(c), 0x0600..=0x06FF | 0x0750..=0x077F | 0x08A0..=0x08FF | 0xFB50..=0xFDFF | 0xFE70..=0xFEFF)
}

/// Greedy CTC: collapse repeats, drop the blank (class 0), map classes to their characters.
pub fn decode(best: &[usize], chars: &[String]) -> String {
    let mut out = String::new();
    let mut prev = 0usize;
    for &k in best {
        if k != prev
            && k != 0
            && let Some(c) = chars.get(k - 1)
        {
            out.push_str(c);
        }
        prev = k;
    }
    out
}

/// Characters that read left to right inside an Arabic line (PaddleOCR's `[a-zA-Z0-9 :*./%+-]`).
fn keeps_order(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, ' ' | ':' | '*' | '.' | '/' | '%' | '+' | '-')
}

/// Drawing order → typing order: the pieces (each Arabic character on its own, each run of
/// [`keeps_order`] characters as a whole) in reverse.
pub fn logical(drawn: &str) -> String {
    let mut pieces: Vec<String> = Vec::new();
    let mut run = String::new();
    // A run's own leading and trailing spaces separate it from the Arabic around it: they are
    // pieces of their own, so they stay between the words when the pieces are reversed.
    let flush = |run: &mut String, pieces: &mut Vec<String>| {
        if run.is_empty() {
            return;
        }
        let lead = run.len() - run.trim_start().len();
        let trail = run.len() - run.trim_end().len();
        if lead > 0 {
            pieces.push(" ".into());
        }
        let core = run.trim();
        if !core.is_empty() {
            pieces.push(core.to_owned());
        }
        if trail > 0 && !core.is_empty() {
            pieces.push(" ".into());
        }
        run.clear();
    };
    for c in drawn.chars() {
        if keeps_order(c) {
            run.push(c);
        } else {
            flush(&mut run, &mut pieces);
            pieces.push(c.to_string());
        }
    }
    flush(&mut run, &mut pieces);
    let joined: String = pieces.into_iter().rev().collect();
    joined.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The NCHW input for one line: the crop, padded by a fifth of its height, resized to
/// [`HEIGHT`] pixels tall (bilinear), and scaled to −1…1; and the image x range it covers.
fn line_tensor(rgb: &[u8], width: u32, height: u32, crop: [f32; 4]) -> Option<(NdTensor<f32, 4>, [f32; 2])> {
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 || rgb.len() < w.checked_mul(h)?.checked_mul(3)? {
        return None;
    }
    let pad = ((crop[3] - crop[1]) * 0.2).max(2.0);
    let left = (crop[0] - pad).floor().clamp(0.0, w as f32 - 1.0);
    let top = (crop[1] - pad).floor().clamp(0.0, h as f32 - 1.0);
    let right = (crop[2] + pad).ceil().clamp(left + 1.0, w as f32);
    let bottom = (crop[3] + pad).ceil().clamp(top + 1.0, h as f32);
    let (cw, ch) = (right - left, bottom - top);
    if !(cw >= 1.0 && ch >= 1.0) {
        return None;
    }
    let out_w = ((cw * HEIGHT as f32 / ch).round() as usize).clamp(8, MAX_WIDTH);
    let mut t = NdTensor::<f32, 4>::zeros([1, 3, HEIGHT, out_w]);
    let sample = |x: f32, y: f32, c: usize| -> f32 {
        let x = x.clamp(0.0, w as f32 - 1.0);
        let y = y.clamp(0.0, h as f32 - 1.0);
        let (x0, y0) = (x.floor() as usize, y.floor() as usize);
        let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
        let (fx, fy) = (x - x0 as f32, y - y0 as f32);
        let px = |xx: usize, yy: usize| rgb.get((yy * w + xx) * 3 + c).copied().unwrap_or(255) as f32;
        let top = px(x0, y0) * (1.0 - fx) + px(x1, y0) * fx;
        let bottom = px(x0, y1) * (1.0 - fx) + px(x1, y1) * fx;
        top * (1.0 - fy) + bottom * fy
    };
    for oy in 0..HEIGHT {
        let sy = top + (oy as f32 + 0.5) * ch / HEIGHT as f32 - 0.5;
        for ox in 0..out_w {
            let sx = left + (ox as f32 + 0.5) * cw / out_w as f32 - 0.5;
            for c in 0..3 {
                if let Some(v) = t.get_mut([0, c, oy, ox]) {
                    *v = (sample(sx, sy, c) / 255.0 - 0.5) / 0.5;
                }
            }
        }
    }
    Some((t, [left, right]))
}

/// Whether at least half the letters of `text` are Arabic script.
pub fn mostly_arabic(text: &str) -> bool {
    let letters = text.chars().filter(|c| c.is_alphabetic()).count();
    let arabic = text.chars().filter(|c| is_arabic(*c)).count();
    letters > 0 && arabic * 2 >= letters
}

/// Words for a line read as `text` across `rect` (`[left, top, right, bottom]`): each word gets
/// a share of the line's width in proportion to its characters, the first typed word rightmost.
pub fn words_in_line(text: &str, rect: [f32; 4]) -> Line {
    let words: Vec<&str> = text.split_whitespace().collect();
    let total: usize = words.iter().map(|w| w.chars().count()).sum::<usize>() + words.len().saturating_sub(1);
    if words.is_empty() || total == 0 {
        return Line::default();
    }
    let unit = (rect[2] - rect[0]).max(0.0) / total as f32;
    let mut right = rect[2];
    let mut out = Vec::with_capacity(words.len());
    for w in words {
        let n = w.chars().count() as f32;
        let left = (right - n * unit).max(rect[0]);
        out.push(Word { text: w.to_owned(), rect: [left, rect[1], right, rect[3]] });
        right = left - unit;
    }
    Line { words: out }
}

/// Join pieces of one text line (`[left, top, right, bottom]` boxes; `None` is skipped) into
/// whole lines: pieces of a similar height that share most of their height and sit less than a
/// line height apart. Returns each line's box and the indexes of its pieces, top to bottom.
/// Pieces farther apart (another column, a table cell) stay separate lines.
pub fn join_line_pieces(pieces: &[Option<[f32; 4]>]) -> Vec<([f32; 4], Vec<usize>)> {
    let mut lines: Vec<([f32; 4], Vec<usize>)> = pieces.iter().enumerate().filter_map(|(i, r)| r.map(|r| (r, vec![i]))).collect();
    let height = |r: &[f32; 4]| (r[3] - r[1]).max(0.0);
    let same_line = |a: &[f32; 4], b: &[f32; 4]| {
        let (ha, hb) = (height(a), height(b));
        let (lo, hi) = (ha.min(hb), ha.max(hb));
        let overlap = (a[3].min(b[3]) - a[1].max(b[1])).max(0.0);
        let gap = (b[0] - a[2]).max(a[0] - b[2]);
        lo > 0.0 && lo >= hi * 0.5 && overlap >= lo * 0.6 && gap < hi
    };
    // Each pass joins at least one pair, so this ends within `lines.len()` passes.
    loop {
        let mut joined = false;
        'scan: for i in 0..lines.len() {
            for j in i + 1..lines.len() {
                let (Some(a), Some(b)) = (lines.get(i), lines.get(j)) else { continue };
                if same_line(&a.0, &b.0) {
                    let (rb, mb) = lines.swap_remove(j);
                    if let Some(a) = lines.get_mut(i) {
                        a.0 = [a.0[0].min(rb[0]), a.0[1].min(rb[1]), a.0[2].max(rb[2]), a.0[3].max(rb[3])];
                        a.1.extend(mb);
                        a.1.sort_unstable();
                    }
                    joined = true;
                    break 'scan;
                }
            }
        }
        if !joined {
            break;
        }
    }
    lines.sort_by(|a, b| a.0[1].total_cmp(&b.0[1]).then(b.0[2].total_cmp(&a.0[2])));
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pieces_of_one_line_join_and_columns_stay_apart() {
        let pieces = [
            Some([300.0, 10.0, 400.0, 30.0]),
            Some([180.0, 12.0, 290.0, 31.0]),
            None,
            Some([180.0, 50.0, 400.0, 70.0]),
            // Another column, far to the left of the first line.
            Some([0.0, 10.0, 100.0, 30.0]),
        ];
        let lines = join_line_pieces(&pieces);
        assert_eq!(lines.len(), 3, "{lines:?}");
        let first = lines.iter().find(|l| l.1 == vec![0, 1]).expect("the two pieces join");
        assert_eq!(first.0, [180.0, 10.0, 400.0, 31.0]);
        assert!(lines.iter().any(|l| l.1 == vec![4]));
        assert!(lines.iter().any(|l| l.1 == vec![3]));
        assert!(join_line_pieces(&[]).is_empty());
        assert!(join_line_pieces(&[Some([5.0, 5.0, 5.0, 5.0])]).len() == 1);
    }

    #[test]
    fn drawing_order_becomes_typing_order_and_numbers_keep_theirs() {
        // What the recogniser reads off "مرحبا 2026" drawn right to left: the number first.
        let drawn: String = "2026 ".chars().chain("مرحبا".chars().rev()).collect();
        assert_eq!(logical(&drawn), "مرحبا 2026");
        assert_eq!(logical(&"السلام".chars().rev().collect::<String>()), "السلام");
        assert_eq!(logical(""), "");
    }

    #[test]
    fn ctc_collapses_repeats_and_drops_the_blank() {
        let chars: Vec<String> = ["a", "b"].iter().map(|s| (*s).to_owned()).collect();
        assert_eq!(decode(&[0, 1, 1, 0, 1, 2, 2, 0, 9], &chars), "aab");
    }

    #[test]
    fn words_share_the_line_right_to_left() {
        let line = words_in_line("واحد اثنين", [0.0, 0.0, 100.0, 10.0]);
        assert_eq!(line.words.len(), 2);
        assert!(line.words[0].rect[0] > line.words[1].rect[2], "the first word is on the right: {line:?}");
        assert!((line.words[0].rect[2] - 100.0).abs() < 0.01);
    }

    /// Each word is boxed where its letters were read, numbers included, and the words come out
    /// right to left with a Latin run kept in its own order.
    #[test]
    fn words_are_boxed_where_they_were_read() {
        let chars: Vec<String> = ["ب", "ا", "1", "2", "A", "B", " "].iter().map(|s| (*s).to_owned()).collect();
        let (ba, a1, two, one, ca, cb, sp) = (1, 2, 4, 3, 5, 6, 7);
        // Drawn left to right over 20 steps of 5 px: "AB B" (Latin, x 0–20 and 25–30) "21"
        // (a number, x 40–50) and "اب" (Arabic, x 70–80).
        let mut best = vec![0; 20];
        best[0] = ca;
        best[2] = cb;
        best[4] = sp;
        best[5] = cb;
        best[6] = sp;
        best[8] = one;
        best[9] = two;
        best[11] = sp;
        best[14] = a1;
        best[15] = ba;
        let words = positioned_words(&best, &chars, [0.0, 100.0], [0.0, 0.0, 100.0, 10.0]);
        assert_eq!(words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["AB", "B", "12", "با"]);
        let num = &words[2];
        assert!(num.rect[0] >= 35.0 && num.rect[2] <= 55.0, "{num:?}");
        let typed = typing_order(words);
        assert_eq!(typed.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["با", "12", "AB", "B"]);
        assert!(positioned_words(&[], &chars, [0.0, 1.0], [0.0; 4]).is_empty());
        assert!(positioned_words(&best, &chars, [5.0, 5.0], [0.0; 4]).is_empty());
    }

    /// A number the detector read as a line of its own rejoins its Arabic sentence, in its place;
    /// a value far across the form stays apart.
    #[test]
    fn a_number_piece_rejoins_its_arabic_line() {
        let w = |t: &str, x0: f32, x1: f32, y0: f32| Word { text: t.into(), rect: [x0, y0, x1, y0 + 20.0] };
        let lines = vec![
            Line { words: vec![w("في", 300.0, 340.0, 10.0), w("يوم", 250.0, 290.0, 10.0)] },
            Line { words: vec![w("من", 125.0, 160.0, 11.0)] },
            Line { words: vec![w("10", 190.0, 220.0, 12.0)] },
            Line { words: vec![w("قيمة", 400.0, 450.0, 60.0)] },
            Line { words: vec![w("بعيد", 0.0, 50.0, 60.0)] },
        ];
        let merged = merge_bands(lines);
        let texts: Vec<String> = merged.iter().map(Line::text).collect();
        assert_eq!(texts, ["في يوم 10 من", "قيمة", "بعيد"]);
        assert!(merge_bands(Vec::new()).is_empty());
        assert!(merge_bands(vec![Line::default()]).is_empty());
    }

    #[test]
    fn line_tensors_refuse_bad_input_and_never_index_past_the_image() {
        assert!(line_tensor(&[], 0, 0, [0.0; 4]).is_none());
        assert!(line_tensor(&[0; 5], 2, 2, [0.0, 0.0, 1.0, 1.0]).is_none());
        let img = vec![255u8; 30 * 10 * 3];
        let (t, span) = line_tensor(&img, 30, 10, [-50.0, -50.0, 500.0, 500.0]).unwrap();
        assert_eq!(span, [0.0, 30.0]);
        assert_eq!(t.shape()[2], HEIGHT);
        assert!(t.iter().all(|v| (*v - 1.0).abs() < 1e-5));
    }
}
