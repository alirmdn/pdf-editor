import PDFKit
import SwiftUI

/// What a tap on the page does.
enum DocumentTool: Hashable {
    case read
    case editText
    /// Place a Fill & Sign mark where the user taps.
    case place(SignMark)
}

/// The marks Fill & Sign places.
enum SignMark: Hashable {
    case signature
    case initials
    case date
    case check

    var prompt: String {
        switch self {
        case .signature: "Tap where your signature goes"
        case .initials: "Tap where your initials go"
        case .date: "Tap where today's date goes"
        case .check: "Tap where the checkmark goes"
        }
    }
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
    @State private var confirmingScan = false
    /// The drawing pad, when the user is drawing a new signature or initials.
    @State private var drawing: SignatureStore.Kind?

    var body: some View {
        PDFKitView(
            model: model,
            revision: model.revision,
            paragraphs: model.paragraphs[model.currentPage],
            tool: tool,
            query: searching ? query : "",
            searchToken: searchToken,
            onTapParagraph: { page, paragraph in editing = (page, paragraph) },
            onPlace: { page, point in place(at: point, on: page) }
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
        .sheet(isPresented: Binding(get: { drawing != nil }, set: { if !$0 { drawing = nil } })) {
            if let kind = drawing {
                SignaturePad(kind: kind) { tool = .place(kind == .signature ? .signature : .initials) }
            }
        }
        .alert("PDF Editor", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Make Scans Editable", isPresented: $confirmingScan, titleVisibility: .visible) {
            Button("Read All Scanned Pages") { Task { await model.recognizeAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scanned pages and photos are just pictures of text. This reads the words in them (Arabic and English) so you can search, copy and edit them. Pages that already have real text are left as they are. Edit Text also does this by itself for the page you are on.")
        }
        .alert("Make Scans Editable", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
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

    private var placing: Bool {
        if case .place = tool { return true }
        return false
    }

    /// Start placing `kind`: straight away if it was drawn before, else draw it first.
    private func sign(_ kind: SignatureStore.Kind) {
        if SignatureStore.exists(kind) {
            tool = .place(kind == .signature ? .signature : .initials)
        } else {
            drawing = kind
        }
    }

    /// Place the chosen mark at `point` (displayed page space) on `page`, then go back to reading.
    private func place(at point: CGPoint, on page: Int) {
        guard case .place(let mark) = tool else { return }
        tool = .read
        Task {
            switch mark {
            case .signature, .initials:
                let kind: SignatureStore.Kind = mark == .signature ? .signature : .initials
                // The engine places the drawing by its left edge, so centre it on the finger.
                let at = CGPoint(x: max(0, point.x - SignatureStore.placedWidth(kind) / 2), y: point.y)
                await model.fillSign(kind.rawValue, page: page, at: at, image: SignatureStore.url(kind))
            case .date:
                await model.fillSign("date", page: page, at: CGPoint(x: max(0, point.x - 28), y: max(0, point.y - 6)))
            case .check:
                await model.fillSign("check", page: page, at: point)
            }
        }
    }

    private var signMenu: some View {
        Menu {
            Button { sign(.signature) } label: { Label("Add Signature", systemImage: "signature") }
            Button { sign(.initials) } label: { Label("Add Initials", systemImage: "character.cursor.ibeam") }
            Button { tool = .place(.date) } label: { Label("Add Today's Date", systemImage: "calendar") }
            Button { tool = .place(.check) } label: { Label("Add Checkmark", systemImage: "checkmark") }
            Divider()
            Button { drawing = .signature } label: { Label("Draw New Signature", systemImage: "pencil.tip") }
            Button { drawing = .initials } label: { Label("Draw New Initials", systemImage: "pencil.tip") }
            if SignatureStore.exists(.signature) || SignatureStore.exists(.initials) {
                Button(role: .destructive) { SignatureStore.clear() } label: { Label("Forget Saved Signature", systemImage: "trash") }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "signature").font(.system(size: 19, weight: .medium))
                Text("Sign").font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(placing ? Theme.accent : Color.primary)
        }
        .disabled(!model.editable)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton("Edit Text", "character.cursor.ibeam", selected: tool == .editText) {
                tool = tool == .editText ? .read : .editText
            }
            .disabled(!model.editable)
            signMenu
            barButton("Search", "magnifyingglass", selected: searching) { searching.toggle() }
            barButton("Pages", "square.grid.2x2", selected: false) { showingPages = true }
                .disabled(!model.editable)
            barButton("Scans", "text.viewfinder", selected: false) { confirmingScan = true }
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
            hint("Tap a paragraph to edit it")
        } else if case .place(let mark) = tool {
            HStack(spacing: 10) {
                Text(mark.prompt)
                Button("Cancel") { tool = .read }.fontWeight(.semibold)
            }
            .modifier(HintStyle())
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).modifier(HintStyle())
    }

    private struct HintStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
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
    /// A tap while placing a Fill & Sign mark: the page (0-based) and the displayed-space point.
    let onPlace: (Int, CGPoint) -> Void

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
            guard let view, let doc = view.document else { return }
            let point = gesture.location(in: view)
            guard let page = view.page(for: point, nearest: true) else { return }
            let index = doc.index(for: page)
            let at = page.displayPoint(view.convert(point, to: page))
            if case .place = parent.tool {
                parent.onPlace(index, at)
                return
            }
            guard parent.tool == .editText else { return }
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
