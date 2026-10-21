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
                if (try? await readScan(page: page, doc: doc)) ?? 0 > 0 {
                    _ = try await Engine.shared.first("doc_save", ["doc": doc])
                    try await refreshState()
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

    // MARK: Fill & Sign

    /// Place a Fill & Sign mark on `page` (0-based) at `at`, a displayed-space point (top-left
    /// origin): "signature" and "initials" (the drawing at `image`, its left edge at `at`),
    /// "date" (today, its top-left at `at`) or "check" (centred on `at`).
    /// Returns whether the mark was placed (an error is shown otherwise).
    @discardableResult
    func fillSign(_ type: String, page: Int, at: CGPoint, image: URL? = nil, rect: CGRect? = nil) async -> Bool {
        var edit: [String: Any] = ["page": page + 1, "type": type, "at": [Double(at.x), Double(at.y)]]
        if let image { edit["path"] = Engine.shared.relativePath(image) }
        // The box the user dragged and sized the drawing to.
        if let rect { edit["rect"] = [Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY)] }
        var placed = false
        await run(type == "date" || type == "check" ? "Adding…" : "Signing…") {
            try await commit(edit, tool: "fill_sign_add")
            placed = true
        }
        return placed
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

    /// The result of the last "Make Scans Editable" run, shown to the user.
    var notice: String?

    /// Read one scanned page and add its words as the page's text layer. Apple's Vision reads it
    /// when this iPhone has Arabic (iOS 18 and later); otherwise the engine's own recogniser.
    /// Returns the number of words added.
    private func readScan(page: Int, doc: Int) async throws -> Int {
        if PageReader.available, let pdfPage = pdf?.page(at: page) {
            let words = try await PageReader.read(pdfPage)
            guard !words.isEmpty else { return 0 }
            let out = try await Engine.shared.first("ocr_add_words", ["doc": doc, "page": page + 1, "words": words.map(\.json)])
            return out["words"] as? Int ?? words.count
        }
        let out = try await Engine.shared.first("ocr_recognize", ["doc": doc, "pages": [page + 1], "language": "auto"])
        return out["words"] as? Int ?? 0
    }

    /// OCR every scanned page (pages that already have real text are skipped): the words found
    /// become invisible text over the picture, so the page can be searched, selected and edited.
    func recognizeAll() async {
        guard let doc = docID else { return }
        await run("Reading the scanned pages…") {
            var words = 0, pages = 0
            for page in 0..<pageCount {
                // A page that already has text (real text or an earlier reading) is left alone.
                let existing = pdf?.page(at: page)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard existing.isEmpty else { continue }
                busy = pageCount > 1 ? "Reading page \(page + 1) of \(pageCount)…" : "Reading the scanned page…"
                let found = try await readScan(page: page, doc: doc)
                words += found
                if found > 0 { pages += 1 }
            }
            if words > 0 {
                _ = try await Engine.shared.first("doc_save", ["doc": doc])
                try await refreshState()
                reload()
                recognized.formUnion(0..<pageCount)
                notice = "Found \(words) words on \(pages) page\(pages == 1 ? "" : "s"). You can now search them, and edit them with Edit Text."
            } else {
                notice = "No scanned pages needed reading: this PDF's text is already searchable and editable."
            }
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
