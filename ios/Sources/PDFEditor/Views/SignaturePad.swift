import PencilKit
import SwiftUI

/// The signature and initials the user drew, kept as transparent PNGs in the app's Documents
/// folder (the engine reads files from there), and reused until the user draws new ones.
enum SignatureStore {
    enum Kind: String {
        case signature
        case initials

        var title: String { self == .signature ? "Signature" : "Initials" }
        /// How tall the engine draws it on the page, in points (fill_sign_add).
        var height: CGFloat { self == .signature ? 32 : 24 }
    }

    private static var folder: URL { Engine.shared.root.appendingPathComponent(".signatures", isDirectory: true) }

    static func url(_ kind: Kind) -> URL { folder.appendingPathComponent("\(kind.rawValue).png") }

    static func exists(_ kind: Kind) -> Bool { FileManager.default.fileExists(atPath: url(kind).path) }

    static func save(_ image: UIImage, as kind: Kind) throws {
        guard let png = image.pngData() else { throw EngineError(message: "The signature could not be saved.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: url(kind), options: .atomic)
    }

    /// Width ÷ height of the saved drawing (1 when there is none).
    static func aspect(_ kind: Kind) -> CGFloat {
        guard let image = UIImage(contentsOfFile: url(kind).path), image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    /// The width the engine gives it on the page: its height, at most 150 points wide.
    static func placedWidth(_ kind: Kind) -> CGFloat { min(150, kind.height * aspect(kind)) }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Draw a signature (or initials) with a finger or Apple Pencil, in black ink on white.
struct SignaturePad: View {
    let kind: SignatureStore.Kind
    /// Called after the drawing is saved.
    let onDone: () -> Void
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
            try SignatureStore.save(image, as: kind)
            dismiss()
            onDone()
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
