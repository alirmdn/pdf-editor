import CPDFEditorCore
import Foundation

/// Something the engine refused or could not do, worded for the user.
struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The shared Rust engine. Every call runs on one background queue, in order; the engine itself
/// is also safe to call from several threads.
final class Engine: @unchecked Sendable {
    static let shared = Engine()

    /// The app's Documents folder: every path given to the engine is relative to it.
    let root: URL
    private let handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.alirmdn.pdfeditor.engine", qos: .userInitiated)

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs
        let models = Bundle.main.url(forResource: "Models", withExtension: nil)?.path
        handle = docs.path.withCString { rootPath in
            if let models {
                return models.withCString { pe_engine_new(rootPath, $0) }
            }
            return pe_engine_new(rootPath, nil)
        }
    }

    /// The path of `url` relative to the engine's root.
    func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return full
    }

    /// Run `tool` with `args`; returns the tool's JSON outputs (PNG outputs arrive as
    /// `["png": base64, "width": …, "height": …]`).
    func call(_ tool: String, _ args: [String: Any] = [:]) async throws -> [[String: Any]] {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = String(decoding: data, as: UTF8.self)
        let answer: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.handle else {
                    continuation.resume(throwing: EngineError(message: "The PDF engine could not start."))
                    return
                }
                let raw = tool.withCString { t in json.withCString { a in pe_call(handle, t, a) } }
                guard let raw else {
                    continuation.resume(throwing: EngineError(message: "The PDF engine did not answer."))
                    return
                }
                let text = String(cString: raw)
                pe_string_free(raw)
                continuation.resume(returning: text)
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any] else {
            throw EngineError(message: "The PDF engine gave an unreadable answer.")
        }
        guard object["ok"] as? Bool == true else {
            throw EngineError(message: object["error"] as? String ?? "Something went wrong.")
        }
        return (object["result"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// The first JSON output of `tool`.
    func first(_ tool: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        try await call(tool, args).first ?? [:]
    }
}
