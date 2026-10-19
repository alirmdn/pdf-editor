import PDFKit
import SwiftUI

/// What a tap on the page does.
enum DocumentTool: Hashable {
    case read
    case editText
}

/// An open PDF: pages with native scrolling and zoom, and the tools in a bottom bar.
struct DocumentView: View {
    @State var model: DocumentModel
    @State private var tool: DocumentTool = .read
    @State private var editing: (page: Int, paragraph: Paragraph)?
    @State private var showingPages = false
    @State private var searching = false
    @State private var query = ""
    @State private var searchToken = 0

    var body: some View {
        PDFKitView(
            model: model,
            revision: model.revision,
            paragraphs: model.paragraphs[model.currentPage],
            tool: tool,
            query: searching ? query : "",
            searchToken: searchToken,
            onTapParagraph: { page, paragraph in editing = (page, paragraph) }
        )
        .ignoresSafeArea(edges: .bottom)
        .background(Color.black)
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .overlay(alignment: .top) { statusBanner }
        .searchable(text: $query, isPresented: $searching, prompt: "Find in document")
        .onSubmit(of: .search) { searchToken += 1 }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                EditTextSheet(paragraph: editing.paragraph) { text in
                    let target = editing
                    self.editing = nil
                    Task { await model.replace(target.paragraph, on: target.page, with: text) }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showingPages) { OrganizeView(model: model) }
        .alert("PDF Editor", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.open() }
        .task(id: TaskKey(page: model.currentPage, tool: tool, revision: model.revision)) {
            if tool == .editText { await model.loadParagraphs(page: model.currentPage) }
        }
    }

    private struct TaskKey: Hashable {
        let page: Int
        let tool: DocumentTool
        let revision: Int
    }

    @ToolbarContentBuilder
    private var topBar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { Task { await model.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo || model.busy != nil)
            Button { Task { await model.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo || model.busy != nil)
            ShareLink(item: model.url) { Image(systemName: "square.and.arrow.up") }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton("Edit Text", "character.cursor.ibeam", selected: tool == .editText) {
                tool = tool == .editText ? .read : .editText
            }
            .disabled(!model.editable)
            barButton("Search", "magnifyingglass", selected: searching) { searching.toggle() }
            barButton("Pages", "square.grid.2x2", selected: false) { showingPages = true }
                .disabled(!model.editable)
            barButton("Recognize", "text.viewfinder", selected: false) { Task { await model.recognizeAll() } }
                .disabled(!model.editable)
            Text("\(model.currentPage + 1) / \(model.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Page \(model.currentPage + 1) of \(model.pageCount)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .background(.bar)
    }

    private func barButton(_ title: String, _ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let busy = model.busy {
            HStack(spacing: 10) {
                ProgressView()
                Text(busy).font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if tool == .editText {
            Text("Tap a paragraph to edit it")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.accent.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 8)
        }
    }
}

/// PDFKit's viewer: Apple's own scrolling, zoom, text selection and search highlighting. In Edit
/// Text mode the paragraphs are outlined and a tap opens one.
struct PDFKitView: UIViewRepresentable {
    let model: DocumentModel
    /// Passed in (not only read from the model) so SwiftUI updates the view when they change.
    let revision: Int
    let paragraphs: [Paragraph]?
    let tool: DocumentTool
    let query: String
    let searchToken: Int
    let onTapParagraph: (Int, Paragraph) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .black
        view.pageShadowsEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: view
        )
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.revision != revision || view.document == nil {
            let page = model.currentPage
            c.revision = revision
            c.outlines = []
            view.document = model.pdf
            if let target = model.pdf?.page(at: page) { view.go(to: target) }
        }
        c.drawOutlines()
        if searchToken != c.searchToken {
            c.searchToken = searchToken
            c.search(query)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        weak var view: PDFView?
        var revision = -1
        var searchToken = 0
        /// The outline annotations added in Edit Text mode (on screen only, never saved).
        var outlines: [(PDFPage, PDFAnnotation)] = []

        init(parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view, let page = view.currentPage, let doc = view.document else { return }
            let index = doc.index(for: page)
            if parent.model.currentPage != index { parent.model.currentPage = index }
        }

        /// Draw a thin red box round every paragraph of the current page in Edit Text mode.
        func drawOutlines() {
            for (page, annotation) in outlines { page.removeAnnotation(annotation) }
            outlines = []
            guard parent.tool == .editText, let doc = view?.document,
                  let page = doc.page(at: parent.model.currentPage),
                  let paragraphs = parent.paragraphs else { return }
            for p in paragraphs {
                let box = PDFAnnotation(bounds: page.pageRect(p.rect).insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
                box.color = UIColor(Theme.accent).withAlphaComponent(0.85)
                let border = PDFBorder()
                border.lineWidth = 1
                box.border = border
                page.addAnnotation(box)
                outlines.append((page, box))
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard parent.tool == .editText, let view, let doc = view.document else { return }
            let point = gesture.location(in: view)
            guard let page = view.page(for: point, nearest: true) else { return }
            let index = doc.index(for: page)
            let at = page.displayPoint(view.convert(point, to: page))
            guard let paragraphs = parent.model.paragraphs[index] else { return }
            // The smallest box under the finger, with a little slack for small text.
            let hit = paragraphs
                .filter { $0.rect.insetBy(dx: -6, dy: -6).contains(at) }
                .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
            if let hit { parent.onTapParagraph(index, hit) }
        }

        func search(_ text: String) {
            guard let view, let doc = view.document, !text.isEmpty else {
                view?.highlightedSelections = nil
                return
            }
            let found = doc.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
            found.forEach { $0.color = UIColor(Theme.accent).withAlphaComponent(0.45) }
            view.highlightedSelections = found
            if let first = found.first {
                view.go(to: first)
                view.setCurrentSelection(first, animate: true)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
