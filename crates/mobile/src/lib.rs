//! PDF Editor's engine for the iOS app.
//!
//! The Swift app calls the same automation tools the desktop CLI and MCP server use
//! (`doc_open`, `text_paragraphs`, `text_edit`, `ocr_recognize`, `doc_save`, … — see
//! `pdfcraft-automation`), through a three-function C interface:
//!
//! ```c
//! PEEngine *pe_engine_new(const char *root, const char *models);
//! char     *pe_call(PEEngine *engine, const char *tool, const char *args_json);
//! void      pe_string_free(char *s);
//! void      pe_engine_free(PEEngine *engine);
//! ```
//!
//! `pe_call` answers with JSON: `{"ok":true,"result":[…]}` where each item is the tool's JSON
//! output or `{"png":"<base64>","width":…,"height":…}`, or `{"ok":false,"error":"…"}`. It never
//! unwinds into Swift: a panic in the engine comes back as an error.
//!
//! Every path a tool reads or writes is confined to `root` (the app's sandbox folder).

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Mutex;

use base64::Engine as _;
use pdfcraft_automation::{Automation, Content};
use serde_json::{Value, json};

/// The engine behind the opaque `PEEngine *` handle.
pub struct PEEngine {
    automation: Mutex<Automation>,
}

impl PEEngine {
    /// A session confined to `root`. `models`, when given, is where the OCR models are (the
    /// app bundle's Models folder).
    pub fn new(root: PathBuf, models: Option<PathBuf>) -> Result<Self, String> {
        if let Some(dir) = models {
            // Read once by the OCR crate's model search; set before any recognition starts.
            // SAFETY of the environment write: called on the app's first engine creation, before
            // any engine thread exists.
            unsafe { std::env::set_var("PDFCRAFT_MODELS", dir) };
        }
        let automation = Automation::new().with_root(root).map_err(|e| format!("the app folder can't be used: {e}"))?;
        Ok(Self { automation: Mutex::new(automation) })
    }

    /// Run one tool and answer in the JSON envelope described in the crate docs.
    pub fn call(&self, tool: &str, args: &str) -> Value {
        let args: Value = match serde_json::from_str(if args.trim().is_empty() { "{}" } else { args }) {
            Ok(v) => v,
            Err(e) => return json!({ "ok": false, "error": format!("arguments are not JSON: {e}") }),
        };
        let Ok(mut automation) = self.automation.lock() else {
            return json!({ "ok": false, "error": "the engine stopped after an earlier failure; reopen the document" });
        };
        let outcome = catch_unwind(AssertUnwindSafe(|| automation.call(tool, &args)));
        match outcome {
            Ok(Ok(items)) => json!({ "ok": true, "result": items.into_iter().map(encode).collect::<Vec<_>>() }),
            Ok(Err(e)) => json!({ "ok": false, "error": e.to_string() }),
            Err(_) => json!({ "ok": false, "error": format!("{tool} failed unexpectedly") }),
        }
    }
}

fn encode(item: Content) -> Value {
    match item {
        Content::Json(v) => v,
        Content::Png { data, width, height } => {
            json!({ "png": base64::engine::general_purpose::STANDARD.encode(data), "width": width, "height": height })
        }
    }
}

/// A Rust string for a C string argument; `None` for null or invalid UTF-8.
///
/// # Safety
/// `p` is null or points to a NUL-terminated string that stays valid for the call.
unsafe fn arg<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    // SAFETY: non-null and NUL-terminated per this function's contract.
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// A C string the caller frees with [`pe_string_free`]. Interior NULs (never produced by
/// serde_json) are replaced rather than failing.
fn out(s: String) -> *mut c_char {
    let s = CString::new(s).unwrap_or_else(|e| {
        let mut bytes = e.into_vec();
        bytes.retain(|b| *b != 0);
        // Infallible: every NUL was just removed.
        CString::new(bytes).unwrap_or_default()
    });
    s.into_raw()
}

/// Create an engine whose files live under `root`; `models` (may be null) is the OCR models
/// folder. Returns null when `root` can't be used.
///
/// # Safety
/// `root` and `models` are null or NUL-terminated strings valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pe_engine_new(root: *const c_char, models: *const c_char) -> *mut PEEngine {
    // SAFETY: the caller's contract above.
    let (root, models) = unsafe { (arg(root), arg(models)) };
    let Some(root) = root else { return std::ptr::null_mut() };
    let made = catch_unwind(|| PEEngine::new(PathBuf::from(root), models.filter(|m| !m.is_empty()).map(PathBuf::from)));
    match made {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        _ => std::ptr::null_mut(),
    }
}

/// Run `tool` with `args_json` (a JSON object, or null for `{}`). Always returns a string to free
/// with [`pe_string_free`].
///
/// # Safety
/// `engine` came from [`pe_engine_new`] and was not freed; `tool` and `args_json` are null or
/// NUL-terminated strings valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pe_call(engine: *mut PEEngine, tool: *const c_char, args_json: *const c_char) -> *mut c_char {
    if engine.is_null() {
        return out(json!({ "ok": false, "error": "no engine" }).to_string());
    }
    // SAFETY: a live engine from pe_engine_new (contract); shared access only, the Mutex inside
    // serialises calls from several Swift threads.
    let engine = unsafe { &*engine };
    // SAFETY: the caller's contract above.
    let (tool, args) = unsafe { (arg(tool), arg(args_json)) };
    let Some(tool) = tool else { return out(json!({ "ok": false, "error": "no tool name" }).to_string()) };
    out(engine.call(tool, args.unwrap_or("{}")).to_string())
}

/// Free a string returned by [`pe_call`]. Null is ignored.
///
/// # Safety
/// `s` is null or a string from [`pe_call`] not freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pe_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: produced by CString::into_raw in `out` and not freed before (contract).
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Free an engine. Null is ignored.
///
/// # Safety
/// `engine` is null or from [`pe_engine_new`], not freed before, and no call is in progress.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pe_engine_free(engine: *mut PEEngine) {
    if !engine.is_null() {
        // SAFETY: produced by Box::into_raw in pe_engine_new and not freed before (contract).
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine() -> (tempfile::TempDir, PEEngine) {
        let dir = tempfile::tempdir().unwrap();
        let e = PEEngine::new(dir.path().to_path_buf(), None).unwrap();
        (dir, e)
    }

    const PDF: &[u8] = b"%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj\n4 0 obj << /Length 44 >> stream\nBT /F1 14 Tf 20 150 Td (Hello world) Tj ET\nendstream endobj\n5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF";

    #[test]
    fn opens_lists_edits_and_saves_through_json() {
        let (dir, e) = engine();
        std::fs::write(dir.path().join("in.pdf"), PDF).unwrap();
        let opened = e.call("doc_open", r#"{"path":"in.pdf"}"#);
        assert_eq!(opened["ok"], true, "{opened}");
        let doc = opened["result"][0]["id"].as_u64().or_else(|| opened["result"][0]["doc"].as_u64()).expect("a document id");
        let paras = e.call("text_paragraphs", &json!({"doc": doc, "page": 1}).to_string());
        assert_eq!(paras["ok"], true, "{paras}");
        assert!(paras.to_string().contains("Hello world"), "{paras}");
        let edited = e.call("text_edit", &json!({"doc": doc, "page": 1, "paragraph": 1, "text": "Hello iPhone"}).to_string());
        assert_eq!(edited["ok"], true, "{edited}");
        let saved = e.call("doc_save", &json!({"doc": doc, "path": "out.pdf"}).to_string());
        assert_eq!(saved["ok"], true, "{saved}");
        let reopened = e.call("doc_open", r#"{"path":"out.pdf"}"#);
        let doc2 = reopened["result"][0]["id"].as_u64().or_else(|| reopened["result"][0]["doc"].as_u64()).unwrap();
        let text = e.call("text_extract", &json!({"doc": doc2}).to_string());
        assert!(text.to_string().contains("Hello iPhone"), "{text}");
    }

    #[test]
    fn renders_pages_as_base64_png() {
        let (dir, e) = engine();
        std::fs::write(dir.path().join("in.pdf"), PDF).unwrap();
        let opened = e.call("doc_open", r#"{"path":"in.pdf"}"#);
        let doc = opened["result"][0]["id"].as_u64().or_else(|| opened["result"][0]["doc"].as_u64()).unwrap();
        let shot = e.call("page_render", &json!({"doc": doc, "page": 1, "dpi": 72}).to_string());
        let png = shot["result"].as_array().unwrap().iter().find(|v| v.get("png").is_some()).expect("a png item");
        let bytes = base64::engine::general_purpose::STANDARD.decode(png["png"].as_str().unwrap()).unwrap();
        assert_eq!(&bytes[1..4], b"PNG");
    }

    #[test]
    fn bad_input_is_an_error_never_a_crash() {
        let (_dir, e) = engine();
        assert_eq!(e.call("doc_open", "not json")["ok"], false);
        assert_eq!(e.call("no_such_tool", "{}")["ok"], false);
        assert_eq!(e.call("doc_open", r#"{"path":"../../etc/passwd"}"#)["ok"], false);
        // The C entry points refuse nulls.
        unsafe {
            assert!(pe_engine_new(std::ptr::null(), std::ptr::null()).is_null());
            let s = pe_call(std::ptr::null_mut(), std::ptr::null(), std::ptr::null());
            assert!(CStr::from_ptr(s).to_str().unwrap().contains("no engine"));
            pe_string_free(s);
            pe_engine_free(std::ptr::null_mut());
        }
    }
}
