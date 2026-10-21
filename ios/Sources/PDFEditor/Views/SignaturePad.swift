import PencilKit
import SwiftUI

/// The signatures and initials the user drew, up to three of each, kept as transparent PNGs in
/// the app's Documents folder (the engine reads files from there) for the next documents.
enum SignatureStore {
    enum Kind: String {
        case signature
        case initials

        var title: String { self == .signature ? "Signature" : "Initials" }
        var plural: String { self == .signature ? "Signatures" : "Initials" }
    }

    /// How many of each kind are kept.
    static let limit = 3

    private static var folder: URL { Engine.shared.root.appendingPathComponent(".signatures", isDirectory: true) }

    /// The saved drawings of `kind`, oldest first.
    static func saved(_ kind: Kind) -> [URL] {
        migrate()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(kind.rawValue + "-") && $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func exists(_ kind: Kind) -> Bool { !saved(kind).isEmpty }

    static func isFull(_ kind: Kind) -> Bool { saved(kind).count >= limit }

    /// Save a new drawing of `kind`; returns its file. With three saved, the oldest makes room.
    @discardableResult
    static func add(_ image: UIImage, as kind: Kind) throws -> URL {
        guard let png = image.pngData() else { throw EngineError(message: "The signature could not be saved.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = saved(kind)
        if existing.count >= limit, let oldest = existing.first { try? FileManager.default.removeItem(at: oldest) }
        // Named by time, so the list keeps the order they were drawn in.
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let url = folder.appendingPathComponent("\(kind.rawValue)-\(stamp).png")
        try png.write(to: url, options: .atomic)
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func clear() { try? FileManager.default.removeItem(at: folder) }

    /// The single signature.png / initials.png of the first version becomes the first saved one.
    private static func migrate() {
        let fm = FileManager.default
        for kind in [Kind.signature, .initials] {
            let old = folder.appendingPathComponent("\(kind.rawValue).png")
            if fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: old, to: folder.appendingPathComponent("\(kind.rawValue)-0000000000001.png"))
            }
        }
    }
}

/// Pick one of the saved signatures (or initials), draw a new one, or delete one.
struct SignaturePicker: View {
    let kind: SignatureStore.Kind
    /// The chosen drawing.
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [URL] = []
    @State private var drawing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(saved, id: \.self) { url in
                        Button {
                            dismiss()
                            onPick(url)
                        } label: {
                            HStack {
                                if let image = UIImage(contentsOfFile: url.path) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 56)
                                        .frame(maxWidth: .infinity)
                                        .padding(8)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                SignatureStore.remove(url)
                                reload()
                            }
                        }
                    }
                } footer: {
                    Text(saved.isEmpty ? "Draw your \(kind.title.lowercased()) to use it." : "Tap one to place it. Swipe left to delete. Up to \(SignatureStore.limit) are kept on this iPhone.")
                }
                Section {
                    Button { drawing = true } label: {
                        Label(saved.count >= SignatureStore.limit ? "Draw New (replaces the oldest)" : "Draw New \(kind.title)", systemImage: "pencil.tip")
                    }
                }
            }
            .navigationTitle(kind.plural)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $drawing) {
                SignaturePad(kind: kind) { url in
                    reload()
                    dismiss()
                    onPick(url)
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() { saved = SignatureStore.saved(kind) }
}

/// Draw a signature (or initials) with a finger or Apple Pencil, in black ink on white.
struct SignaturePad: View {
    let kind: SignatureStore.Kind
    /// Called with the saved drawing's file.
    let onDone: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(kind == .signature ? "Sign with your finger" : "Write your initials")
                    .font(.headline)
                CanvasView(drawing: $drawing)
                    .frame(height: 240)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.gray.opacity(0.5)).frame(height: 1).padding(.horizontal, 28).padding(.bottom, 56)
                    }
                Text("It is kept on this iPhone only, for the next document you sign.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Button("Clear") { drawing = PKDrawing() }.disabled(drawing.strokes.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }.disabled(drawing.strokes.isEmpty)
                }
            }
            .alert("PDF Editor", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func save() {
        let bounds = drawing.bounds.insetBy(dx: -6, dy: -6)
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Rendered in light mode, so the ink stays black (dark mode would draw it white).
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: 4)
        }
        do {
            let url = try SignatureStore.add(image, as: kind)
            dismiss()
            onDone(url)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// PencilKit's canvas: draws with a finger or Apple Pencil, black pen on white.
private struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 7)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: CanvasView
        init(_ parent: CanvasView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            parent.drawing = canvas.drawing
        }
    }
}
