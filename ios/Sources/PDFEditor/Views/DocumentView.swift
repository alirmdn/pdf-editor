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

    /// Placed with a preview the user drags and sizes, rather than by a tap.
    var isDrawn: Bool { self == .signature || self == .initials }

    var prompt: String {
        switch self {
        case .signature: "Drag your signature into place, pull the corner to resize"
        case .initials: "Drag your initials into place, pull the corner to resize"
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
    /// Bumped by Place: the page view places the previewed signature where it is.
    @State private var placeToken = 0

    var body: some View {
        PDFKitView(
            model: model,
            revision: model.revision,
            paragraphs: model.paragraphs[model.currentPage],
            tool: tool,
            query: searching ? query : "",
            searchToken: searchToken,
            placeToken: placeToken,
            onTapParagraph: { page, paragraph in editing = (page, paragraph) },
            onPlace: { page, point in place(at: point, on: page) },
            onPlaceRect: { page, rect in place(in: rect, on: page) }
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

    /// Place the previewed signature or initials in `rect` (displayed page space) on `page`.
    private func place(in rect: CGRect, on page: Int) {
        guard case .place(let mark) = tool, mark.isDrawn else { return }
        tool = .read
        let kind: SignatureStore.Kind = mark == .signature ? .signature : .initials
        Task { await model.fillSign(kind.rawValue, page: page, at: rect.origin, image: SignatureStore.url(kind), rect: rect) }
    }

    /// Place the date or a checkmark at `point` (displayed page space) on `page`.
    private func place(at point: CGPoint, on page: Int) {
        guard case .place(let mark) = tool, !mark.isDrawn else { return }
        tool = .read
        Task {
            switch mark {
            case .signature, .initials:
                break
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
            VStack(spacing: 8) {
                Text(mark.prompt).multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    Button("Cancel") { tool = .read }
                    if mark.isDrawn {
                        Button("Place") { placeToken += 1 }.fontWeight(.bold)
                    }
                }
                .fontWeight(.semibold)
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
    let placeToken: Int
    let onTapParagraph: (Int, Paragraph) -> Void
    /// A tap while placing the date or a checkmark: the page (0-based) and the displayed-space point.
    let onPlace: (Int, CGPoint) -> Void
    /// Place pressed with a signature previewed: the page (0-based) and its displayed-space box.
    let onPlaceRect: (Int, CGRect) -> Void

    /// A container: the PDF view, with the signature preview above it (outside the PDF view's
    /// scrolling, so dragging the preview never scrolls the page).
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let view = PDFView()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
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
        context.coordinator.container = container
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let view = c.view else { return }
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
        c.syncPreview()
        if placeToken != c.placeToken {
            c.placeToken = placeToken
            c.commitPreview()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        weak var view: PDFView?
        weak var container: UIView?
        var revision = -1
        var searchToken = 0
        var placeToken = 0
        /// The signature being placed, and which drawing it shows.
        private var preview: MarkPreview?
        private var previewKind: SignatureStore.Kind?
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
            if case .place(let mark) = parent.tool {
                if mark.isDrawn {
                    // A tap moves the preview there.
                    if let preview, let container { preview.center = view.convert(point, to: container) }
                } else {
                    parent.onPlace(index, at)
                }
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

        /// Show the signature preview while a signature or initials is being placed.
        func syncPreview() {
            var kind: SignatureStore.Kind?
            if case .place(let mark) = parent.tool, mark.isDrawn { kind = mark == .signature ? .signature : .initials }
            guard let kind, let container, let image = UIImage(contentsOfFile: SignatureStore.url(kind).path) else {
                preview?.removeFromSuperview()
                preview = nil
                previewKind = nil
                return
            }
            if preview != nil, previewKind == kind { return }
            preview?.removeFromSuperview()
            let aspect = image.size.width / max(image.size.height, 1)
            let width = min(container.bounds.width * 0.55, 260)
            let height = width / max(aspect, 0.1)
            let frame = CGRect(x: (container.bounds.width - width) / 2, y: container.bounds.height * 0.42 - height / 2, width: width, height: height)
            let p = MarkPreview(image: image, frame: frame)
            container.addSubview(p)
            preview = p
            previewKind = kind
        }

        /// Place the previewed signature where it is on screen.
        func commitPreview() {
            guard let preview, let container, let view, let doc = view.document else { return }
            let frame = container.convert(preview.frame, to: view)
            guard let page = view.page(for: CGPoint(x: frame.midX, y: frame.midY), nearest: true) else { return }
            let r = view.convert(frame, to: page)
            let a = page.displayPoint(CGPoint(x: r.minX, y: r.minY))
            let b = page.displayPoint(CGPoint(x: r.maxX, y: r.maxY))
            let display = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            parent.onPlaceRect(doc.index(for: page), display)
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

/// The signature being placed: drag it to move, pinch or pull the corner handle to resize (it
/// keeps its proportions). Lives above the PDF view, so it never scrolls the page.
final class MarkPreview: UIView {
    private let imageView: UIImageView
    private let handle = UIView()
    private let aspect: CGFloat

    init(image: UIImage, frame: CGRect) {
        imageView = UIImageView(image: image)
        aspect = max(image.size.width / max(image.size.height, 1), 0.1)
        super.init(frame: frame)
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderColor = UIColor(Theme.accent).cgColor
        layer.borderWidth = 1.5
        layer.cornerRadius = 4
        handle.backgroundColor = UIColor(Theme.accent)
        handle.layer.cornerRadius = 14
        handle.layer.borderColor = UIColor.white.cgColor
        handle.layer.borderWidth = 2
        addSubview(handle)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(move(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resize(_:))))
        isAccessibilityElement = true
        accessibilityLabel = "Signature preview. Drag to move it, pinch to resize it, then tap Place."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        handle.frame = CGRect(x: bounds.maxX - 14, y: bounds.maxY - 14, width: 28, height: 28)
    }

    /// The corner handle sits half outside the box; it still takes touches.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -18, dy: -18).contains(point)
    }

    @objc private func move(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        g.setTranslation(.zero, in: superview)
    }

    @objc private func resize(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        setWidth(frame.width + t.x, keepingCenter: false)
        g.setTranslation(.zero, in: superview)
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        setWidth(frame.width * g.scale, keepingCenter: true)
        g.scale = 1
    }

    private func setWidth(_ wanted: CGFloat, keepingCenter: Bool) {
        let limit = max((superview?.bounds.width ?? 400) * 0.95, 60)
        let width = min(max(wanted, 40), limit)
        let size = CGSize(width: width, height: width / aspect)
        if keepingCenter {
            let c = center
            bounds.size = size
            center = c
        } else {
            frame = CGRect(origin: frame.origin, size: size)
        }
        setNeedsLayout()
    }
}
