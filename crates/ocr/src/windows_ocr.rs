//! Windows' own text recogniser (Windows.Media.Ocr), the one built into Windows 10 and 11.
//!
//! It reads a page image line by line and boxes every word where it is drawn. Each language
//! it reads is an optional Windows feature: Arabic needs the Arabic OCR feature installed
//! (Settings ▸ Time & language ▸ Language & region ▸ add Arabic, or
//! `Add-WindowsCapability -Online -Name Language.OCR~~~ar-SA~0.0.1.0`). When a language is not
//! installed, recognition falls back to the bundled models.
//!
//! Windows returns a right-to-left line's words in left-to-right coordinate order, so the words
//! of an Arabic line are put back in typing order ([`crate::arabic::typing_order`]).

#[cfg(windows)]
use windows::{
    Globalization::Language,
    Graphics::Imaging::{BitmapPixelFormat, SoftwareBitmap},
    Media::Ocr::OcrEngine,
    Storage::Streams::DataWriter,
    core::HSTRING,
};

#[cfg(windows)]
use crate::OcrError;
use crate::{Line, Word};

/// A Windows recogniser for one language.
#[cfg(windows)]
pub struct Engine {
    engine: OcrEngine,
}

#[cfg(windows)]
impl Engine {
    /// The recogniser for `tag` (a BCP-47 language tag such as "ar" or "en-US"), if that
    /// language's OCR feature is installed.
    pub fn for_language(tag: &str) -> Option<Engine> {
        let language = Language::CreateLanguage(&HSTRING::from(tag)).ok()?;
        if !OcrEngine::IsLanguageSupported(&language).unwrap_or(false) {
            return None;
        }
        OcrEngine::TryCreateFromLanguage(&language).ok().map(|engine| Engine { engine })
    }

    /// The first installed recogniser for one of `tags`.
    pub fn first_of(tags: &[&str]) -> Option<Engine> {
        tags.iter().find_map(|t| Engine::for_language(t))
    }

    /// Read an RGBA image, `width` × `height` pixels: its lines, each word boxed in pixels.
    pub fn read(&self, rgba: &[u8], width: u32, height: u32) -> Result<Vec<Line>, OcrError> {
        let err = |e: windows::core::Error| OcrError::Recognize(e.message());
        // Windows reads images up to a size; a larger page is read at a fraction of its size and
        // the boxes scaled back.
        let max = OcrEngine::MaxImageDimension().map_err(err)?.max(1);
        let (scale, bgra, w, h) = fit(rgba, width, height, max).ok_or(OcrError::EmptyImage)?;
        let writer = DataWriter::new().map_err(err)?;
        writer.WriteBytes(&bgra).map_err(err)?;
        let buffer = writer.DetachBuffer().map_err(err)?;
        let w_i = i32::try_from(w).map_err(|_| OcrError::EmptyImage)?;
        let h_i = i32::try_from(h).map_err(|_| OcrError::EmptyImage)?;
        let bitmap = SoftwareBitmap::CreateCopyFromBuffer(&buffer, BitmapPixelFormat::Bgra8, w_i, h_i).map_err(err)?;
        let result = self.engine.RecognizeAsync(&bitmap).map_err(err)?.join().map_err(err)?;
        let mut out = Vec::new();
        for line in result.Lines().map_err(err)? {
            let mut words = Vec::new();
            for word in line.Words().map_err(err)? {
                let text = word.Text().map_err(err)?.to_string_lossy();
                let r = word.BoundingRect().map_err(err)?;
                let rect = [r.X / scale, r.Y / scale, (r.X + r.Width) / scale, (r.Y + r.Height) / scale];
                words.push((text, rect));
            }
            if let Some(line) = line_from(words) {
                out.push(line);
            }
        }
        Ok(out)
    }
}

/// The BGRA pixels Windows reads, at most `max` pixels on a side, and the scale they are at.
/// Accepts RGBA, RGB or grey input; `None` for an empty or mis-sized image.
pub fn fit(pixels: &[u8], width: u32, height: u32, max: u32) -> Option<(f32, Vec<u8>, u32, u32)> {
    let (w, h) = (width as usize, height as usize);
    let n = w.checked_mul(h)?;
    if n == 0 {
        return None;
    }
    let channels = match pixels.len() {
        l if Some(l) == n.checked_mul(4) => 4,
        l if Some(l) == n.checked_mul(3) => 3,
        l if l == n => 1,
        _ => return None,
    };
    let scale = (max as f32 / width.max(height) as f32).min(1.0);
    let (ow, oh) = (((width as f32 * scale).floor() as u32).max(1), ((height as f32 * scale).floor() as u32).max(1));
    let mut out = Vec::with_capacity((ow as usize).checked_mul(oh as usize)?.checked_mul(4)?);
    for y in 0..oh as usize {
        let sy = ((y as f32 + 0.5) / scale) as usize;
        for x in 0..ow as usize {
            let sx = ((x as f32 + 0.5) / scale) as usize;
            let i = sy.min(h - 1) * w + sx.min(w - 1);
            let px = |c: usize| pixels.get(i * channels + c.min(channels - 1)).copied().unwrap_or(255);
            out.extend([px(2), px(1), px(0), 255]);
        }
    }
    Some((scale, out, ow, oh))
}

/// Read a page with Windows' recogniser in `language` (a [`crate::LANGUAGES`] code), or `None`
/// when that language's OCR feature is not installed (or Windows failed), so the bundled models
/// read it instead. "auto" reads with both the Arabic and the English recogniser
/// ([`combine`]). `PDFCRAFT_OCR=bundled` always uses the bundled models.
#[cfg(windows)]
pub fn recognize(pixels: &[u8], width: u32, height: u32, language: &str) -> Option<Vec<Line>> {
    if std::env::var("PDFCRAFT_OCR").is_ok_and(|v| v.eq_ignore_ascii_case("bundled")) {
        return None;
    }
    const ARABIC: &[&str] = &["ar", "ar-SA", "ar-AE"];
    const ENGLISH: &[&str] = &["en", "en-US", "en-GB"];
    let read = |tags: &[&str]| Engine::first_of(tags).and_then(|e| e.read(pixels, width, height).ok());
    let lines = match language {
        "ar" => read(ARABIC)?,
        "auto" => {
            let arabic = read(ARABIC)?;
            match read(ENGLISH) {
                Some(english) => combine(arabic, english),
                None => arabic,
            }
        }
        _ => read(ENGLISH)?,
    };
    Some(crate::arabic::merge_bands(lines))
}

/// Whether Windows can read `language` itself.
#[cfg(windows)]
pub fn reads(language: &str) -> bool {
    match language {
        "ar" | "auto" => Engine::first_of(&["ar", "ar-SA", "ar-AE"]).is_some(),
        _ => Engine::first_of(&["en", "en-US", "en-GB"]).is_some(),
    }
}

/// One recognised line from its words (text and pixel box, as Windows lists them): blank words
/// and broken boxes dropped, and an Arabic line's words in typing order.
pub fn line_from(words: Vec<(String, [f32; 4])>) -> Option<Line> {
    let words: Vec<Word> = words
        .into_iter()
        .filter(|(t, r)| !t.trim().is_empty() && r.iter().all(|v| v.is_finite()) && r[2] > r[0] && r[3] > r[1])
        .map(|(text, rect)| Word { text: text.trim().to_owned(), rect })
        .collect();
    if words.is_empty() {
        return None;
    }
    let arabic = words.iter().any(|w| crate::arabic::mostly_arabic(&w.text));
    Some(Line { words: if arabic { crate::arabic::typing_order(words) } else { words } })
}

/// One page read by the Arabic and the English recognisers together: the Arabic reading's
/// Arabic lines, and the English reading's lines where the Arabic reading has no Arabic (the
/// Arabic recogniser misreads Latin letters as Arabic-looking ones). An English line that lies
/// mostly on a kept Arabic line is that line read wrongly, and is left out.
pub fn combine(arabic: Vec<Line>, english: Vec<Line>) -> Vec<Line> {
    let kept: Vec<Line> = arabic.into_iter().filter(|l| crate::arabic::mostly_arabic(&l.text())).collect();
    let rects: Vec<[f32; 4]> = kept.iter().filter_map(line_rect).collect();
    let mut out = kept;
    for line in english {
        let Some(r) = line_rect(&line) else { continue };
        let area = (r[2] - r[0]) * (r[3] - r[1]);
        let covered: f32 = rects.iter().map(|a| ((r[2].min(a[2]) - r[0].max(a[0])).max(0.0)) * ((r[3].min(a[3]) - r[1].max(a[1])).max(0.0))).sum();
        if area > 0.0 && covered < area * 0.5 {
            out.push(line);
        }
    }
    out
}

fn line_rect(l: &Line) -> Option<[f32; 4]> {
    l.words.iter().map(|w| w.rect).reduce(|a, b| [a[0].min(b[0]), a[1].min(b[1]), a[2].max(b[2]), a[3].max(b[3])])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arabic_lines_come_back_in_typing_order() {
        // Windows lists an Arabic line's words left to right on the page.
        let line = line_from(vec![
            ("الله".into(), [0.0, 0.0, 40.0, 20.0]),
            ("ورحمة".into(), [50.0, 0.0, 100.0, 20.0]),
            (" ".into(), [100.0, 0.0, 101.0, 20.0]),
            ("السلام".into(), [110.0, 0.0, 170.0, 20.0]),
        ])
        .unwrap();
        assert_eq!(line.text(), "السلام ورحمة الله");
        let latin = line_from(vec![("Hello".into(), [0.0, 0.0, 40.0, 20.0]), ("world".into(), [50.0, 0.0, 90.0, 20.0])]).unwrap();
        assert_eq!(latin.text(), "Hello world");
        assert!(line_from(vec![("x".into(), [5.0, 0.0, 5.0, 9.0]), ("y".into(), [f32::NAN, 0.0, 1.0, 1.0])]).is_none());
    }

    #[test]
    fn english_fills_in_where_the_arabic_reading_has_no_arabic() {
        let w = |t: &str, r: [f32; 4]| Line { words: vec![Word { text: t.into(), rect: r }] };
        let arabic = vec![w("السلام", [0.0, 0.0, 100.0, 20.0]), w("ححح", [0.0, 50.0, 100.0, 70.0])];
        let english = vec![w("Peace", [0.0, 0.0, 100.0, 20.0]), w("DUBAI", [0.0, 50.0, 100.0, 70.0])];
        let texts: Vec<String> = combine(arabic, english).iter().map(Line::text).collect();
        // "ححح" is Arabic letters, so it stays and its English reading is dropped.
        assert_eq!(texts, ["السلام", "ححح"]);
        let arabic = vec![w("السلام", [0.0, 0.0, 100.0, 20.0]), w("123", [0.0, 50.0, 100.0, 70.0])];
        let texts: Vec<String> = combine(arabic, vec![w("DUBAI COURTS", [0.0, 50.0, 100.0, 70.0])]).iter().map(Line::text).collect();
        assert_eq!(texts, ["السلام", "DUBAI COURTS"]);
    }

    #[test]
    fn pages_fit_the_size_windows_reads() {
        let rgba = [10u8, 20, 30, 255].repeat(4 * 2);
        let (scale, bgra, w, h) = fit(&rgba, 4, 2, 2).unwrap();
        assert_eq!((scale, w, h), (0.5, 2, 1));
        assert_eq!(bgra, [30, 20, 10, 255, 30, 20, 10, 255]);
        let (scale, _, w, h) = fit(&[0u8; 12], 2, 2, 100).unwrap();
        assert_eq!((scale, w, h), (1.0, 2, 2));
        assert!(fit(&[0u8; 5], 2, 2, 100).is_none());
        assert!(fit(&[], 0, 0, 100).is_none());
    }
}
