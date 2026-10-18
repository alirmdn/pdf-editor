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
        let input = line_tensor(rgb, width, height, crop).ok_or(OcrError::EmptyImage)?;
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
        Ok(logical(&decode(&best, &self.chars)))
    }
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
/// [`HEIGHT`] pixels tall (bilinear), and scaled to −1…1.
fn line_tensor(rgb: &[u8], width: u32, height: u32, crop: [f32; 4]) -> Option<NdTensor<f32, 4>> {
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
    Some(t)
}

/// Whether at least half the letters of `text` are Arabic script.
pub fn mostly_arabic(text: &str) -> bool {
    let letters = text.chars().filter(|c| c.is_alphabetic()).count();
    let arabic = text.chars().filter(|c| matches!(u32::from(*c), 0x0600..=0x06FF | 0x0750..=0x077F | 0x08A0..=0x08FF | 0xFB50..=0xFDFF | 0xFE70..=0xFEFF)).count();
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

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn line_tensors_refuse_bad_input_and_never_index_past_the_image() {
        assert!(line_tensor(&[], 0, 0, [0.0; 4]).is_none());
        assert!(line_tensor(&[0; 5], 2, 2, [0.0, 0.0, 1.0, 1.0]).is_none());
        let img = vec![255u8; 30 * 10 * 3];
        let t = line_tensor(&img, 30, 10, [-50.0, -50.0, 500.0, 500.0]).unwrap();
        assert_eq!(t.shape()[2], HEIGHT);
        assert!(t.iter().all(|v| (*v - 1.0).abs() < 1e-5));
    }
}
