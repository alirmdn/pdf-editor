import Foundation
import PDFKit
import UIKit

/// A PDF in the app's folder (On My iPhone ▸ PDF Editor in the Files app).
struct StoredFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The app's PDFs: imported copies, scans and new documents, newest first.
@MainActor
@Observable
final class FileStore {
    static let shared = FileStore()

    private(set) var files: [StoredFile] = []
    let folder: URL

    private init() {
        folder = Engine.shared.root.appendingPathComponent("Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        files = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return StoredFile(url: url, modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Copy a PDF from Files, Mail or another app into the app's folder and return the copy.
    func importFile(from source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = uniqueURL(for: source.deletingPathExtension().lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        refresh()
        return target
    }

    /// Save `data` as a new PDF named `name`.
    func create(named name: String, data: Data) throws -> URL {
        let target = uniqueURL(for: name)
        try data.write(to: target, options: .atomic)
        refresh()
        return target
    }

    func delete(_ file: StoredFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    func rename(_ file: StoredFile, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        try? FileManager.default.moveItem(at: file.url, to: uniqueURL(for: clean))
        refresh()
    }

    private func uniqueURL(for name: String) -> URL {
        let base = name.isEmpty ? "Document" : name
        var url = folder.appendingPathComponent(base).appendingPathExtension("pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("pdf")
            n += 1
        }
        return url
    }
}

/// Page thumbnails, cached by file and modification date.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for file: StoredFile, size: CGSize) -> UIImage? {
        let key = "\(file.url.path)|\(file.modified.timeIntervalSince1970)|\(Int(size.width))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let page = PDFDocument(url: file.url)?.page(at: 0) else { return nil }
        let image = page.thumbnail(of: size, for: .cropBox)
        cache.setObject(image, forKey: key)
        return image
    }
}
