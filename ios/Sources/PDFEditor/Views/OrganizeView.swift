import PDFKit
import SwiftUI

/// Organize pages: a grid of thumbnails; each page can be rotated, moved or deleted.
struct OrganizeView: View {
    let model: DocumentModel
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        PageCell(model: model, index: index)
                    }
                }
                .padding()
                .id(model.revision)
            }
            .background(Color.black)
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if let busy = model.busy {
                    ProgressView(busy).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

private struct PageCell: View {
    let model: DocumentModel
    let index: Int

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let page = model.pdf?.page(at: index) {
                    Image(uiImage: page.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox))
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rotate Right", systemImage: "rotate.right") { Task { await model.rotate(page: index, by: 90) } }
            Button("Rotate Left", systemImage: "rotate.left") { Task { await model.rotate(page: index, by: -90) } }
            Button("Move Earlier", systemImage: "arrow.left") { Task { await model.move(page: index, by: -1) } }
                .disabled(index == 0)
            Button("Move Later", systemImage: "arrow.right") { Task { await model.move(page: index, by: 1) } }
                .disabled(index + 1 >= model.pageCount)
            Divider()
            Button("Delete Page", systemImage: "trash", role: .destructive) { Task { await model.delete(page: index) } }
        }
    }
}
