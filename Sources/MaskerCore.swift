import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

struct RedactionMatch: Identifiable {
    let id: UUID
    let fileURL: URL
    let pageIndex: Int
    let category: String
    let matchedText: String
    let rects: [CGRect]
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        fileURL: URL,
        pageIndex: Int,
        category: String,
        matchedText: String,
        rects: [CGRect],
        isSelected: Bool = true
    ) {
        self.id = id
        self.fileURL = fileURL
        self.pageIndex = pageIndex
        self.category = category
        self.matchedText = matchedText
        self.rects = rects
        self.isSelected = isSelected
    }
}

struct PatternOptions {
    var detectSSN = true
    var detectEIN = true
    var detectEmail = false
    var detectPhone = false
}

enum MaskerError: LocalizedError {
    case cannotOpen(URL)
    case cannotCreateOutput(URL)
    case cannotRender(page: Int, file: URL)
    case outputValidationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let url):
            return "Could not open \(url.lastPathComponent)."
        case .cannotCreateOutput(let url):
            return "Could not create \(url.path)."
        case .cannotRender(let page, let file):
            return "Could not render page \(page + 1) of \(file.lastPathComponent)."
        case .outputValidationFailed(let url):
            return "The sanitized copy failed validation: \(url.lastPathComponent)."
        }
    }
}

enum PDFMasker {
    private struct PatternRule {
        let label: String
        let expression: String
    }

    static func scan(
        files: [URL],
        exactTerms: [String],
        options: PatternOptions,
        progress: @escaping (String) -> Void
    ) -> [RedactionMatch] {
        var allMatches: [RedactionMatch] = []

        for fileURL in files {
            guard let document = PDFDocument(url: fileURL) else { continue }
            for pageIndex in 0..<document.pageCount {
                autoreleasepool {
                    progress("Scanning \(fileURL.lastPathComponent), page \(pageIndex + 1) of \(document.pageCount)")
                    guard let page = document.page(at: pageIndex) else { return }
                    let pageText = page.string ?? ""
                    let pageMatches: [RedactionMatch]

                    if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pageMatches = scanImagePage(
                            page,
                            fileURL: fileURL,
                            pageIndex: pageIndex,
                            exactTerms: exactTerms,
                            options: options
                        )
                    } else {
                        pageMatches = scanTextPage(
                            page,
                            text: pageText,
                            fileURL: fileURL,
                            pageIndex: pageIndex,
                            exactTerms: exactTerms,
                            options: options
                        )
                    }
                    allMatches.append(contentsOf: pageMatches)
                }
            }
        }

        return deduplicated(allMatches)
    }

    static func exportSanitizedCopies(
        files: [URL],
        matches: [RedactionMatch],
        outputFolder: URL,
        dpi: CGFloat = 300,
        progress: @escaping (String) -> Void
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        var outputs: [URL] = []

        for fileURL in files {
            let fileMatches = matches.filter { $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL && $0.isSelected }
            guard !fileMatches.isEmpty else { continue }
            guard let document = PDFDocument(url: fileURL) else { throw MaskerError.cannotOpen(fileURL) }

            let outputURL = uniqueOutputURL(for: fileURL, in: outputFolder)
            guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
                throw MaskerError.cannotCreateOutput(outputURL)
            }

            var initialBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            let metadata: [CFString: Any] = [
                kCGPDFContextCreator: "Masker",
                kCGPDFContextTitle: "Sanitized document"
            ]
            guard let context = CGContext(consumer: consumer, mediaBox: &initialBox, metadata as CFDictionary) else {
                throw MaskerError.cannotCreateOutput(outputURL)
            }

            for pageIndex in 0..<document.pageCount {
                autoreleasepool {
                    progress("Sanitizing \(fileURL.lastPathComponent), page \(pageIndex + 1) of \(document.pageCount)")
                    guard let page = document.page(at: pageIndex) else { return }
                    let displayRect = displayBounds(for: page)
                    var pageRect = CGRect(origin: .zero, size: displayRect.size)
                    let mediaBoxData = Data(bytes: &pageRect, count: MemoryLayout<CGRect>.size)
                    let pageInfo = [kCGPDFContextMediaBox: mediaBoxData] as CFDictionary
                    context.beginPDFPage(pageInfo)

                    let redactionRects = fileMatches
                        .filter { $0.pageIndex == pageIndex }
                        .flatMap(\.rects)

                    if let image = renderPage(page, dpi: dpi, redactionRects: redactionRects) {
                        context.saveGState()
                        context.interpolationQuality = .high
                        context.draw(image, in: pageRect)
                        context.restoreGState()
                    }
                    context.endPDFPage()
                }
            }
            context.closePDF()

            guard validateSanitizedOutput(outputURL, expectedPageCount: document.pageCount) else {
                throw MaskerError.outputValidationFailed(outputURL)
            }
            outputs.append(outputURL)
        }

        return outputs
    }

    static func previewImage(
        fileURL: URL,
        pageIndex: Int,
        matches: [RedactionMatch],
        dpi: CGFloat = 110
    ) -> NSImage? {
        guard let document = PDFDocument(url: fileURL), let page = document.page(at: pageIndex) else { return nil }
        let rects = matches.filter { $0.pageIndex == pageIndex && $0.isSelected }.flatMap(\.rects)
        guard let cgImage = renderPage(page, dpi: dpi, redactionRects: rects) else { return nil }
        return NSImage(cgImage: cgImage, size: displayBounds(for: page).size)
    }

    private static func scanTextPage(
        _ page: PDFPage,
        text: String,
        fileURL: URL,
        pageIndex: Int,
        exactTerms: [String],
        options: PatternOptions
    ) -> [RedactionMatch] {
        let nsText = text as NSString
        var matches: [RedactionMatch] = []

        for term in exactTerms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let found = nsText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                if let match = nativeMatch(
                    page: page,
                    range: found,
                    fileURL: fileURL,
                    pageIndex: pageIndex,
                    category: "Exact value",
                    text: nsText.substring(with: found)
                ) {
                    matches.append(match)
                }
                let nextLocation = found.location + max(found.length, 1)
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }

        for rule in patternRules(options) {
            guard let regex = try? NSRegularExpression(pattern: rule.expression, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: nsText.length)
            for result in regex.matches(in: text, range: range) {
                if let match = nativeMatch(
                    page: page,
                    range: result.range,
                    fileURL: fileURL,
                    pageIndex: pageIndex,
                    category: rule.label,
                    text: nsText.substring(with: result.range)
                ) {
                    matches.append(match)
                }
            }
        }
        return matches
    }

    private static func nativeMatch(
        page: PDFPage,
        range: NSRange,
        fileURL: URL,
        pageIndex: Int,
        category: String,
        text: String
    ) -> RedactionMatch? {
        guard let selection = page.selection(for: range) else { return nil }
        let lineSelections = selection.selectionsByLine()
        let pageTransform = page.transform(for: .mediaBox)
        let transformedPageBounds = page.bounds(for: .mediaBox).applying(pageTransform).standardized
        let selections = lineSelections.isEmpty ? [selection] : lineSelections
        let rects = selections.map { selectedLine -> CGRect in
            let pageRect = selectedLine.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
            let transformed = pageRect.applying(pageTransform).standardized
            return transformed.offsetBy(dx: -transformedPageBounds.minX, dy: -transformedPageBounds.minY)
        }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }

        guard !rects.isEmpty else { return nil }
        return RedactionMatch(
            fileURL: fileURL,
            pageIndex: pageIndex,
            category: category,
            matchedText: text,
            rects: rects
        )
    }

    private static func scanImagePage(
        _ page: PDFPage,
        fileURL: URL,
        pageIndex: Int,
        exactTerms: [String],
        options: PatternOptions
    ) -> [RedactionMatch] {
        guard let image = renderPage(page, dpi: 180, redactionRects: []) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return []
        }

        let displayRect = displayBounds(for: page)
        let observations = request.results ?? []
        var matches: [RedactionMatch] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            let nsLine = line as NSString

            for term in exactTerms where !term.isEmpty {
                var searchRange = NSRange(location: 0, length: nsLine.length)
                while searchRange.location < nsLine.length {
                    let found = nsLine.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    if let swiftRange = Range(found, in: line),
                       let box = try? candidate.boundingBox(for: swiftRange) {
                        matches.append(ocrMatch(
                            box: box.boundingBox,
                            displaySize: displayRect.size,
                            fileURL: fileURL,
                            pageIndex: pageIndex,
                            category: "Exact value (OCR)",
                            text: nsLine.substring(with: found)
                        ))
                    }
                    let nextLocation = found.location + max(found.length, 1)
                    searchRange = NSRange(location: nextLocation, length: nsLine.length - nextLocation)
                }
            }

            for rule in patternRules(options) {
                guard let regex = try? NSRegularExpression(pattern: rule.expression, options: [.caseInsensitive]) else { continue }
                let fullRange = NSRange(location: 0, length: nsLine.length)
                for result in regex.matches(in: line, range: fullRange) {
                    guard let swiftRange = Range(result.range, in: line),
                          let box = try? candidate.boundingBox(for: swiftRange) else { continue }
                    matches.append(ocrMatch(
                        box: box.boundingBox,
                        displaySize: displayRect.size,
                        fileURL: fileURL,
                        pageIndex: pageIndex,
                        category: rule.label + " (OCR)",
                        text: nsLine.substring(with: result.range)
                    ))
                }
            }
        }
        return matches
    }

    private static func ocrMatch(
        box: CGRect,
        displaySize: CGSize,
        fileURL: URL,
        pageIndex: Int,
        category: String,
        text: String
    ) -> RedactionMatch {
        let rect = CGRect(
            x: box.minX * displaySize.width,
            y: box.minY * displaySize.height,
            width: box.width * displaySize.width,
            height: box.height * displaySize.height
        ).insetBy(dx: -2, dy: -2)
        return RedactionMatch(
            fileURL: fileURL,
            pageIndex: pageIndex,
            category: category,
            matchedText: text,
            rects: [rect]
        )
    }

    private static func patternRules(_ options: PatternOptions) -> [PatternRule] {
        var rules: [PatternRule] = []
        if options.detectSSN {
            rules.append(PatternRule(label: "SSN / ITIN", expression: #"\b\d{3}[ -]\d{2}[ -]\d{4}\b"#))
        }
        if options.detectEIN {
            rules.append(PatternRule(label: "EIN", expression: #"\b\d{2}-\d{7}\b"#))
        }
        if options.detectEmail {
            rules.append(PatternRule(label: "Email", expression: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#))
        }
        if options.detectPhone {
            rules.append(PatternRule(label: "Phone", expression: #"(?<!\d)(?:\+?1[ .-]?)?(?:\(\d{3}\)|\d{3})[ .-]\d{3}[ .-]\d{4}(?!\d)"#))
        }
        return rules
    }

    private static func deduplicated(_ matches: [RedactionMatch]) -> [RedactionMatch] {
        var seen = Set<String>()
        return matches.filter { match in
            let rectKey = match.rects.map {
                "\(Int($0.minX.rounded())):\(Int($0.minY.rounded())):\(Int($0.width.rounded())):\(Int($0.height.rounded()))"
            }.joined(separator: ";")
            let key = "\(match.fileURL.standardizedFileURL.path)|\(match.pageIndex)|\(rectKey)"
            return seen.insert(key).inserted
        }
    }

    private static func displayBounds(for page: PDFPage) -> CGRect {
        let transform = page.transform(for: .mediaBox)
        let transformed = page.bounds(for: .mediaBox).applying(transform).standardized
        return CGRect(origin: .zero, size: transformed.size)
    }

    private static func renderPage(
        _ page: PDFPage,
        dpi: CGFloat,
        redactionRects: [CGRect]
    ) -> CGImage? {
        let scale = max(dpi / 72.0, 1.0)
        let pageBounds = page.bounds(for: .mediaBox)
        let pageTransform = page.transform(for: .mediaBox)
        let transformedBounds = pageBounds.applying(pageTransform).standardized
        let displaySize = transformedBounds.size
        let pixelWidth = max(Int(ceil(displaySize.width * scale)), 1)
        let pixelHeight = max(Int(ceil(displaySize.height * scale)), 1)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }

        bitmap.scaleBy(x: scale, y: scale)
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(origin: .zero, size: displaySize))

        bitmap.saveGState()
        bitmap.translateBy(x: -transformedBounds.minX, y: -transformedBounds.minY)
        page.draw(with: .mediaBox, to: bitmap)
        bitmap.restoreGState()

        if !redactionRects.isEmpty {
            bitmap.setFillColor(NSColor.black.cgColor)
            for rect in redactionRects {
                bitmap.fill(rect.insetBy(dx: -0.75, dy: -0.75))
            }
        }
        return bitmap.makeImage()
    }

    private static func validateSanitizedOutput(_ url: URL, expectedPageCount: Int) -> Bool {
        guard let output = PDFDocument(url: url), output.pageCount == expectedPageCount else { return false }
        for index in 0..<output.pageCount {
            guard let page = output.page(at: index) else { return false }
            if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if !page.annotations.isEmpty {
                return false
            }
        }
        return true
    }

    private static func uniqueOutputURL(for input: URL, in folder: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + "_masked"
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("pdf")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_\(suffix)").appendingPathExtension("pdf")
            suffix += 1
        }
        return candidate
    }
}
