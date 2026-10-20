//! The Arabic recogniser on a rendered line, when the model is available locally:
//! `PDFCRAFT_ARABIC_TEST_DIR` holds arabic-recognition.onnx, arabic-dict.txt and line.rgb
//! (900 × 80 RGB, "السلام عليكم ورحمة الله" drawn right to left). Skipped otherwise.

#[test]
fn reads_an_arabic_line_in_typing_order() {
    let Some(dir) = std::env::var_os("PDFCRAFT_ARABIC_TEST_DIR").map(std::path::PathBuf::from) else {
        eprintln!("skipping: set PDFCRAFT_ARABIC_TEST_DIR");
        return;
    };
    let reader = pdfcraft_ocr::arabic::Reader::load(&dir.join("arabic-recognition.onnx"), &dir.join("arabic-dict.txt")).unwrap();
    let rgb = std::fs::read(dir.join("line.rgb")).unwrap();
    let text = reader.read_line(&rgb, 900, 80, [500.0, 15.0, 870.0, 70.0]).unwrap();
    assert_eq!(text, "السلام عليكم ورحمة الله");
}

/// The words of a real reading are boxed where they are drawn: inside the line, right to left,
/// without overlapping, each as wide as a word and not a share of the line.
#[test]
fn real_words_are_boxed_where_they_are_drawn() {
    let Some(dir) = std::env::var_os("PDFCRAFT_ARABIC_TEST_DIR").map(std::path::PathBuf::from) else {
        eprintln!("skipping: set PDFCRAFT_ARABIC_TEST_DIR");
        return;
    };
    let reader = pdfcraft_ocr::arabic::Reader::load(&dir.join("arabic-recognition.onnx"), &dir.join("arabic-dict.txt")).unwrap();
    let rgb = std::fs::read(dir.join("line.rgb")).unwrap();
    let crop = [500.0, 15.0, 870.0, 70.0];
    let line = reader.read(&rgb, 900, 80, crop).unwrap();
    eprintln!("{:?}", line.words.iter().map(|w| (&w.text, w.rect[0], w.rect[2])).collect::<Vec<_>>());
    assert_eq!(line.text(), "السلام عليكم ورحمة الله");
    for pair in line.words.windows(2) {
        assert!(pair[0].rect[0] >= pair[1].rect[2] - 4.0, "right to left, apart: {pair:?}");
    }
    // The ink of the four words, measured from the image (columns with a dark pixel).
    let ink = [[784.0, 867.0], [693.0, 772.0], [597.0, 681.0], [541.0, 584.0]];
    for (w, ink) in line.words.iter().zip(ink) {
        assert!((w.rect[0] - ink[0]).abs() <= 2.0 && (w.rect[2] - ink[1]).abs() <= 2.0, "{w:?} vs {ink:?}");
        assert!(w.rect[0] >= crop[0] && w.rect[2] <= crop[2]);
    }
}
