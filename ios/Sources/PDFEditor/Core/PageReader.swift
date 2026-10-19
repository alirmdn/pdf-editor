import PDFKit
import UIKit
import Vision

/// Reads the text in a scanned page with Apple's own OCR (Vision, the engine behind Live Text),
/// which runs on the iPhone's Neural Engine and reads Arabic far better than the bundled models.
/// The words it finds go to the engine (`ocr_add_words`), which writes them as the page's
/// invisible text layer and groups them into editable paragraphs.
enum PageReader {
    /// One recognised word: its text and its box in the displayed page's points, top-left origin
    /// (the space the engine's `rect` uses).
    struct Word {
        let text: String
        let rect: CGRect

        var json: [String: Any] { ["text": text, "rect": [rect.minX, rect.minY, rect.maxX, rect.maxY]] }
    }

    /// The languages to read, best first, among those this iPhone's Vision supports. Arabic needs
    /// iOS 18 or later; without it the engine's own recogniser is used instead.
    static func languages() -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let supported = try? request.supportedRecognitionLanguages() else { return nil }
        let wanted = ["ar-SA", "en-US"].filter(supported.contains)
        return wanted.contains("ar-SA") ? wanted : nil
    }

    /// Whether Vision can read this page's languages here (Arabic and English).
    static var available: Bool { languages() != nil }

    /// Read `page`. Lines come back top to bottom; each line's words in typing order (an Arabic
    /// line from the right).
    static func read(_ page: PDFPage) async throws -> [Word] {
        guard let languages = languages() else { return [] }
        let (image, size) = render(page)
        guard let cg = image?.cgImage, size.width > 0, size.height > 0 else { return [] }
        let lines: [[Word]] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.006
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            let fit = Fit(image: CGSize(width: cg.width, height: cg.height), page: size)
            return (request.results ?? []).compactMap { (observation: VNRecognizedTextObservation) -> [Word]? in
                guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
                let words = PageReader.words(in: best, line: fit.rect(observation.boundingBox), fit: fit)
                return words.isEmpty ? nil : words
            }
        }.value
        return order(lines).flatMap { $0 }
    }

    // MARK: Rendering

    /// The page as an image about 2800 pixels on its long side, the way it is displayed (rotation
    /// applied), and the displayed page's size in points.
    private static func render(_ page: PDFPage) -> (UIImage?, CGSize) {
        let box = page.bounds(for: .cropBox)
        let quarter = ((page.rotation % 360) + 360) % 360
        let size = quarter == 90 || quarter == 270 ? CGSize(width: box.height, height: box.width) : box.size
        let long = max(size.width, size.height)
        guard long > 0 else { return (nil, .zero) }
        func shot(_ points: CGFloat) -> UIImage {
            let k = points / long
            return page.thumbnail(of: CGSize(width: size.width * k, height: size.height * k), for: .cropBox)
        }
        var image = shot(1000)
        if let cg = image.cgImage {
            let pixels = CGFloat(max(cg.width, cg.height))
            if pixels > 0, pixels < 2400 { image = shot(1000 * 2800 / pixels) }
        }
        return (image, size)
    }

    /// Image → page mapping. A thumbnail fits the page inside the requested size, so any margin
    /// it adds is taken off.
    private struct Fit {
        let scale: CGFloat
        let offset: CGPoint
        let image: CGSize

        init(image: CGSize, page: CGSize) {
            self.image = image
            scale = min(image.width / page.width, image.height / page.height)
            offset = CGPoint(x: (image.width - page.width * scale) / 2, y: (image.height - page.height * scale) / 2)
        }

        /// A Vision box (normalised, origin bottom-left) → page points, origin top-left.
        func rect(_ n: CGRect) -> CGRect {
            let x = n.minX * image.width, y = (1 - n.maxY) * image.height
            return CGRect(
                x: (x - offset.x) / scale, y: (y - offset.y) / scale,
                width: n.width * image.width / scale, height: n.height * image.height / scale
            )
        }
    }

    // MARK: Words

    private static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFC).contains($0.value) }
    }

    /// The words of one line. Vision boxes each word when asked; a box that is missing or falls
    /// outside the line gives way to a share of the line's width by characters.
    private static func words(in text: VNRecognizedText, line: CGRect, fit: Fit) -> [Word] {
        let string = text.string
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for i in string.indices {
            if string[i].isWhitespace {
                if let s = start { ranges.append(s..<i) }
                start = nil
            } else if start == nil {
                start = i
            }
        }
        if let s = start { ranges.append(s..<string.endIndex) }
        guard !ranges.isEmpty, line.width > 0, line.height > 0 else { return [] }
        let slack = line.insetBy(dx: -line.height, dy: -line.height * 0.6)
        var boxed: [Word] = []
        for r in ranges {
            guard let box = try? text.boundingBox(for: r)?.boundingBox else { break }
            let rect = fit.rect(box).intersection(slack)
            guard !rect.isNull, rect.width > 0.5, rect.height > 0.5 else { break }
            // Words share the line's height, so the layer's baseline stays straight.
            boxed.append(Word(text: String(string[r]), rect: CGRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height)))
        }
        if boxed.count == ranges.count, !overlapping(boxed) { return boxed }
        return shared(string: string, ranges: ranges, line: line)
    }

    /// Whether two boxes cover each other by more than half the narrower one (a bad word box).
    private static func overlapping(_ words: [Word]) -> Bool {
        for (i, a) in words.enumerated() {
            for b in words.dropFirst(i + 1) {
                let cover = a.rect.intersection(b.rect)
                if !cover.isNull, cover.width > min(a.rect.width, b.rect.width) * 0.5 { return true }
            }
        }
        return false
    }

    /// The words placed by their share of the line's characters, from the right for Arabic.
    private static func shared(string: String, ranges: [Range<String.Index>], line: CGRect) -> [Word] {
        let counts = ranges.map { string[$0].count }
        let total = counts.reduce(0, +) + max(ranges.count - 1, 0)
        guard total > 0 else { return [] }
        let unit = line.width / CGFloat(total)
        let rtl = isArabic(string)
        var edge = rtl ? line.maxX : line.minX
        var out: [Word] = []
        for (r, n) in zip(ranges, counts) {
            let w = CGFloat(n) * unit
            let x = rtl ? edge - w : edge
            out.append(Word(text: String(string[r]), rect: CGRect(x: x, y: line.minY, width: w, height: line.height)))
            edge = rtl ? x - unit : x + w + unit
        }
        return out
    }

    /// Lines in reading order: top to bottom; lines sharing a band read from the right when
    /// Arabic, from the left otherwise.
    private static func order(_ lines: [[Word]]) -> [[Word]] {
        func bounds(_ l: [Word]) -> CGRect { l.map(\.rect).reduce(CGRect.null) { $0.union($1) } }
        let rtl = lines.filter { isArabic($0.map(\.text).joined()) }.count * 2 >= lines.count
        let sorted = lines.map { ($0, bounds($0)) }.sorted { $0.1.midY < $1.1.midY }
        var bands: [[([Word], CGRect)]] = []
        for line in sorted {
            if let last = bands.last?.last, abs(last.1.midY - line.1.midY) < min(last.1.height, line.1.height) * 0.5 {
                bands[bands.count - 1].append(line)
            } else {
                bands.append([line])
            }
        }
        return bands.flatMap { band in
            joinPieces(band.sorted { rtl ? $0.1.maxX > $1.1.maxX : $0.1.minX < $1.1.minX }, rtl: rtl)
        }
    }

    /// Vision often splits one printed line where a number or a wide space sits. Neighbouring
    /// pieces of a band (less than a line height apart) become one line again, every word given
    /// the line's full height so the text layer shares one baseline.
    private static func joinPieces(_ band: [([Word], CGRect)], rtl: Bool) -> [[Word]] {
        var out: [([Word], CGRect)] = []
        for piece in band {
            if let last = out.last {
                let gap = rtl ? last.1.minX - piece.1.maxX : piece.1.minX - last.1.maxX
                if gap < max(last.1.height, piece.1.height) * 1.2 {
                    out[out.count - 1] = (last.0 + piece.0, last.1.union(piece.1))
                    continue
                }
            }
            out.append(piece)
        }
        return out.map { line in
            line.0.map { Word(text: $0.text, rect: CGRect(x: $0.rect.minX, y: line.1.minY, width: $0.rect.width, height: line.1.height)) }
        }
    }
}
