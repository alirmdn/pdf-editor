import Foundation
import PDFKit
import UIKit

/// One paragraph on a page, as the engine groups it (Acrobat-style text boxes).
struct Paragraph: Identifiable, Equatable {
    let number: Int
    let text: String
    /// The box in the page's displayed space: points, origin at the top-left.
    let rect: CGRect
    let size: Double
    var id: Int { number }

    var isRightToLeft: Bool {
        text.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFC).contains($0.value) }
    }
}

/// An open PDF: the PDFKit document on screen and the same file open in the engine, which makes
/// every change. After a change the engine saves the file and the view reloads it.
@MainActor
@Observable
final class DocumentModel {
    let url: URL
    private(set) var pdf: PDFDocument?
    private(set) var docID: Int?
    private(set) var pageCount = 0
    var currentPage = 0
    private(set) var paragraphs: [Int: [Paragraph]] = [:]
    private(set) var busy: String?
    var errorMessage: String?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var editable = true
    /// Bumped whenever `pdf` is replaced, so views redraw.
    private(set) var revision = 0
    /// Pages already offered automatic text recognition this session.
    private var recognized: Set<Int> = []

    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) {
        self.url = url
        pdf = PDFDocument(url: url)
        pageCount = pdf?.pageCount ?? 0
    }

    // MARK: Engine

    func open() async {
        guard docID == nil else { return }
        await run("Opening…") {
            let info = try await Engine.shared.first("doc_open", ["path": Engine.shared.relativePath(self.url)])
            self.docID = info["doc"] as? Int
            self.editable = info["editable"] as? Bool ?? true
            if let reason = info["read_only_reason"] as? String, !(info["editable"] as? Bool ?? true) {
                self.errorMessage = reason
            }
        }
    }

    /// Run `work` with a progress label, turning engine errors into a message.
    private func run(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do { try await work() } catch { errorMessage = error.localizedDescription }
    }

    /// Save through the engine and show the result.
    private func commit(_ edit: [String: Any], tool: String) async throws {
        guard let doc = docID else { throw EngineError(message: "The document is not open yet.") }
        var args = edit
        args["doc"] = doc
        _ = try await Engine.shared.call(tool, args)
        _ = try await Engine.shared.first("doc_save", ["doc": doc])
        try await refreshState()
        reload()
    }

    private func refreshState() async throws {
        guard let doc = docID else { return }
        let info = try await Engine.shared.first("doc_info", ["doc": doc])
        let summary = info["document"] as? [String: Any] ?? [:]
        canUndo = summary["undo"] is String
        canRedo = summary["redo"] is String
    }

    /// Reload the PDF from disk after the engine wrote it (a fresh PDFDocument; PDFKit caches by URL).
    private func reload() {
        if let data = try? Data(contentsOf: url), let fresh = PDFDocument(data: data) {
            pdf = fresh
            pageCount = fresh.pageCount
            currentPage = min(currentPage, max(pageCount - 1, 0))
        }
        paragraphs = [:]
        revision += 1
    }

    // MARK: Edit text

    /// The paragraphs of `page` (0-based). A page with no text but a picture (a scan, a photo) is
    /// recognized first, as Acrobat does, so its lines become editable.
    func loadParagraphs(page: Int) async {
        guard let doc = docID, paragraphs[page] == nil else { return }
        do {
            var found = try await fetchParagraphs(doc: doc, page: page)
            if found.isEmpty, editable, !recognized.contains(page) {
                recognized.insert(page)
                busy = "Recognizing text on this scanned page…"
                defer { busy = nil }
                let result = try? await Engine.shared.call("ocr_recognize", ["doc": doc, "pages": [page + 1], "language": "auto"])
                if result != nil {
                    _ = try await Engine.shared.first("doc_save", ["doc": doc])
                    reload()
                    found = try await fetchParagraphs(doc: doc, page: page)
                }
            }
            paragraphs[page] = found
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchParagraphs(doc: Int, page: Int) async throws -> [Paragraph] {
        let out = try await Engine.shared.first("text_paragraphs", ["doc": doc, "page": page + 1])
        let list = out["paragraphs"] as? [[String: Any]] ?? []
        return list.compactMap { p in
            guard let n = p["paragraph"] as? Int, let r = p["rect"] as? [Double], r.count == 4 else { return nil }
            return Paragraph(
                number: n,
                text: p["text"] as? String ?? "",
                rect: CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1]),
                size: p["size"] as? Double ?? 12
            )
        }
    }

    func replace(_ paragraph: Paragraph, on page: Int, with text: String) async {
        guard text != paragraph.text else { return }
        await run("Saving…") {
            try await commit(["page": page + 1, "paragraph": paragraph.number, "text": text], tool: "text_edit")
        }
    }

    // MARK: Pages

    func rotate(page: Int, by degrees: Int) async {
        await run("Rotating…") { try await commit(["pages": [page + 1], "degrees": degrees], tool: "page_rotate") }
    }

    func delete(page: Int) async {
        guard pageCount > 1 else {
            errorMessage = "A PDF needs at least one page."
            return
        }
        await run("Deleting page…") { try await commit(["pages": [page + 1]], tool: "page_delete") }
    }

    /// Move `page` one place earlier (`-1`) or later (`+1`).
    func move(page: Int, by step: Int) async {
        let target = page + step
        guard target >= 0, target < pageCount else { return }
        // `to` counts positions before the move: later means "before the page after next".
        let to = step < 0 ? target + 1 : target + 2
        await run("Moving page…") { try await commit(["pages": [page + 1], "to": to], tool: "page_move") }
    }

    func recognizeAll() async {
        await run("Recognizing text…") {
            try await commit(["language": "auto"], tool: "ocr_recognize")
        }
    }

    func undo() async {
        await run("Undoing…") { try await commit([:], tool: "edit_undo") }
    }

    func redo() async {
        await run("Redoing…") { try await commit([:], tool: "edit_redo") }
    }
}

// MARK: Coordinates

extension PDFPage {
    /// The crop box and the clockwise display rotation (0, 90, 180, 270).
    private var displayFrame: (box: CGRect, rotation: Int) {
        (bounds(for: .cropBox), ((rotation % 360) + 360) % 360)
    }

    /// A point in page space → the displayed page, top-left origin (the engine's `rect` space).
    func displayPoint(_ p: CGPoint) -> CGPoint {
        let (b, r) = displayFrame
        switch r {
        case 90: return CGPoint(x: p.y - b.minY, y: p.x - b.minX)
        case 180: return CGPoint(x: b.maxX - p.x, y: p.y - b.minY)
        case 270: return CGPoint(x: b.maxY - p.y, y: b.maxX - p.x)
        default: return CGPoint(x: p.x - b.minX, y: b.maxY - p.y)
        }
    }

    /// A displayed-space point (top-left origin) → page space.
    func pagePoint(_ d: CGPoint) -> CGPoint {
        let (b, r) = displayFrame
        switch r {
        case 90: return CGPoint(x: d.y + b.minX, y: d.x + b.minY)
        case 180: return CGPoint(x: b.maxX - d.x, y: d.y + b.minY)
        case 270: return CGPoint(x: b.maxX - d.y, y: b.maxY - d.x)
        default: return CGPoint(x: d.x + b.minX, y: b.maxY - d.y)
        }
    }

    /// A displayed-space rectangle → page space.
    func pageRect(_ r: CGRect) -> CGRect {
        let a = pagePoint(CGPoint(x: r.minX, y: r.minY))
        let b = pagePoint(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
