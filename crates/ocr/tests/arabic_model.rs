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
