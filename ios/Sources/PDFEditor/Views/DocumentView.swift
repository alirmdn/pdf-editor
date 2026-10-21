import PDFKit
import SwiftUI

/// What a tap on the page does.
enum DocumentTool: Hashable {
    case read
    case editText
    /// Place a Fill & Sign mark where the user taps.
    case place(SignMark)
}

/// The marks Fill & Sign places. Each is placed from a preview the user drags and sizes.
enum SignMark: Hashable {
    /// A saved signature or initials drawing.
    case image(SignatureStore.Kind, URL)
    case date
    case check

    var prompt: String {
        switch self {
        case .image(let kind, _): "Drag your \(kind.title.lowercased()) into place. Pinch or pull the corner to resize."
        case .date: "Drag the date into place. Pinch or pull the corner to resize."
        case .check: "Drag the checkmark into place. Pinch or pull the corner to resize."
        }
    }

    /// Today as Fill & Sign writes it (the engine's default date format, m/d/yyyy).
    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yyyy"
        return f.string(from: Date())
    }

    /// What the preview shows: the drawing, or the date or checkmark drawn the way the page will.
    var previewImage: UIImage? {
        switch self {
        case .image(_, let url):
            return UIImage(contentsOfFile: url.path)
        case .date:
            // Laid out like the engine's text box: 1.2 em tall plus 6 pt, 8 pt wider than the text.
            let font = UIFont(name: "Helvetica", size: 40) ?? .systemFont(ofSize: 40)
            let text = Self.today as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let size = CGSize(width: ceil(text.size(withAttributes: attributes).width) + 8 * 4, height: 40 * 1.2 + 6 * 4)
            return UIGraphicsImageRenderer(size: size).image { _ in
                text.draw(at: CGPoint(x: 4 * 4, y: 3 * 4), withAttributes: attributes)
            }
        case .check:
            let config = UIImage.SymbolConfiguration(pointSize: 120, weight: .bold)
            return UIImage(systemName: "checkmark", withConfiguration: config)?.withTintColor(.black, renderingMode: .alwaysOriginal)
        }
    }

    /// The preview's starting width on screen.
    var previewWidth: CGFloat {
        switch self {
        case .image: 220
        case .date: 150
        case .check: 48
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
    /// The drawing pad, when the user is drawing their first signature or initials.
    @State private var drawing: SignatureStore.Kind?
    /// The saved signatures (or initials) to choose from.
    @State private var picking: SignatureStore.Kind?
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
                SignaturePad(kind: kind) { url in tool = .place(.image(kind, url)) }
            }
        }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            if let kind = picking {
                SignaturePicker(kind: kind) { url in tool = .place(.image(kind, url)) }
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

    /// Sign with a saved drawing of `kind` (chosen from the list), or draw the first one.
    private func sign(_ kind: SignatureStore.Kind) {
        if SignatureStore.exists(kind) {
            picking = kind
        } else {
            drawing = kind
        }
    }

    /// Place the previewed mark in `rect` (displayed page space) on `page`.
    private func place(in rect: CGRect, on page: Int) {
        guard case .place(let mark) = tool else { return }
        tool = .read
        Task {
            switch mark {
            case .image(let kind, let url):
                await model.fillSign(kind.rawValue, page: page, at: rect.origin, image: url, rect: rect)
            case .date:
                await model.fillSign("date", page: page, at: rect.origin, rect: rect)
            case .check:
                await model.fillSign("check", page: page, at: rect.origin, rect: rect)
            }
        }
    }

    private var signMenu: some View {
        Menu {
            Button { sign(.signature) } label: { Label("Add Signature", systemImage: "signature") }
            Button { sign(.initials) } label: { Label("Add Initials", systemImage: "character.cursor.ibeam") }
            Button { tool = .place(.date) } label: { Label("Add Today's Date", systemImage: "calendar") }
            Button { tool = .place(.check) } label: { Label("Add Checkmark", systemImage: "checkmark") }
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
                    Button("Place") { placeToken += 1 }.fontWeight(.bold)
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
        private var previewMark: SignMark?
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
                // A tap moves the preview there.
                if let preview, let container { preview.center = view.convert(point, to: container) }
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

        /// Show the preview of the mark being placed.
        func syncPreview() {
            var mark: SignMark?
            if case .place(let m) = parent.tool { mark = m }
            guard let mark, let container, let image = mark.previewImage else {
                preview?.removeFromSuperview()
                preview = nil
                previewMark = nil
                return
            }
            if preview != nil, previewMark == mark { return }
            preview?.removeFromSuperview()
            let aspect = image.size.width / max(image.size.height, 1)
            let width = min(container.bounds.width * 0.8, mark.previewWidth)
            let height = width / max(aspect, 0.1)
            let frame = CGRect(x: (container.bounds.width - width) / 2, y: container.bounds.height * 0.42 - height / 2, width: width, height: height)
            let p = MarkPreview(image: image, frame: frame)
            container.addSubview(p)
            preview = p
            previewMark = mark
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
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resized(_:))))
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

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        g.setTranslation(.zero, in: superview)
    }

    @objc private func resized(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        setWidth(frame.width + t.x, keepingCenter: false)
        g.setTranslation(.zero, in: superview)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        setWidth(frame.width * g.scale, keepingCenter: true)
        g.scale = 1
    }

    private func setWidth(_ wanted: CGFloat, keepingCenter: Bool) {
        let limit = max((superview?.bounds.width ?? 400) * 0.95, 60)
        let width = min(max(wanted, 24), limit)
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
