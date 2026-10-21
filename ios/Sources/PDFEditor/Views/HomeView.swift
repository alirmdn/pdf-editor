import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Home: open, scan or create a PDF, and the recent files as a grid of first pages.
struct HomeView: View {
    @Environment(FileStore.self) private var store
    @Binding var opened: URL?
    @State private var importing = false
    @State private var scanning = false
    @State private var showingSettings = false
    @State private var renaming: StoredFile?
    @State private var newName = ""
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    recent
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("PDF Editor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open PDF", systemImage: "folder") { importing = true }
                        if VNDocumentCameraViewController.isSupported {
                            Button("Scan Document", systemImage: "doc.viewfinder") { scanning = true }
                        }
                        Divider()
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .navigationDestination(item: $opened) { url in
                DocumentView(model: DocumentModel(url: url))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                do { opened = try store.importFile(from: url) } catch { errorMessage = error.localizedDescription }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView { images in
                scanning = false
                saveScan(images)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let f = renaming { store.rename(f, to: newName) } }
        }
        .alert("Couldn't open", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { store.refresh() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit any PDF").font(.title3.bold())
                    Text("Arabic and English text, scans, pages and signatures — all on this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button { importing = true } label: {
                    Label("Open PDF", systemImage: "folder.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if VNDocumentCameraViewController.isSupported {
                    Button { scanning = true } label: {
                        Label("Scan", systemImage: "doc.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var recent: some View {
        Text("Recent").font(.title2.bold())
        if store.files.isEmpty {
            ContentUnavailableView(
                "No PDFs yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Open a PDF from Files, scan a document, or use “Open in PDF Editor” from another app.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(store.files) { file in
                    Button { opened = file.url } label: { FileCard(file: file) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button("Rename", systemImage: "pencil") {
                                newName = file.name
                                renaming = file
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(file) }
                        }
                }
            }
        }
    }

    private func saveScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let pdf = PDFDocument()
        for (i, image) in images.enumerated() {
            if let page = PDFPage(image: image) { pdf.insert(page, at: i) }
        }
        guard let data = pdf.dataRepresentation() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        do {
            opened = try store.create(named: "Scan \(formatter.string(from: .now))", data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A recent file: its first page, name and date.
struct FileCard: View {
    let file: StoredFile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06))
                if let image = Thumbnails.image(for: file, size: CGSize(width: 300, height: 400)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                        .padding(10)
                } else {
                    Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(0.78, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardBorder))
            Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(file.modified, format: .dateTime.day().month().year())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Apple's document camera: finds the page, straightens it and returns the scans.
struct ScannerView: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void
        init(done: @escaping ([UIImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done([]) }
    }
}
