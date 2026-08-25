import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

enum ReplacementKind: String, Codable, CaseIterable {
    case account = "Acct"
    case name = "Name"
    case identifier = "ID"
    case email = "Email"
    case phone = "Phone"
    case value = "Value"
}

struct RedactionMatch: Identifiable {
    let id: UUID
    let fileURL: URL
    let pageIndex: Int
    let category: String
    let matchedText: String
    let rects: [CGRect]
    let replacementKind: ReplacementKind?
    let replacementKey: String?
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        fileURL: URL,
        pageIndex: Int,
        category: String,
        matchedText: String,
        rects: [CGRect],
        replacementKind: ReplacementKind? = nil,
        replacementKey: String? = nil,
        isSelected: Bool = true
    ) {
        self.id = id
        self.fileURL = fileURL
        self.pageIndex = pageIndex
        self.category = category
        self.matchedText = matchedText
        self.rects = rects
        self.replacementKind = replacementKind
        self.replacementKey = replacementKey
        self.isSelected = isSelected
    }
}

struct PatternOptions {
    var detectSSN = true
    var detectEIN = true
    var detectEmail = false
    var detectPhone = false
    var generateNameVariants = false
    var detectAccountSuffixes = false
    var accountSuffixExceptions: [String] = []
}

enum MaskerError: LocalizedError {
    case cannotOpen(URL)
    case cannotCreateOutput(URL)
    case cannotRender(page: Int, file: URL)
    case outputValidationFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let url):
            return "Could not open \(url.lastPathComponent)."
        case .cannotCreateOutput(let url):
            return "Could not create \(url.path)."
        case .cannotRender(let page, let file):
            return "Could not render page \(page + 1) of \(file.lastPathComponent)."
        case .outputValidationFailed(let url, let reason):
            return "The sanitized copy failed validation: \(reason) (\(url.lastPathComponent))."
        }
    }
}

enum PDFMasker {
    private struct ReplacementOverlay {
        let matchID: UUID
        let rects: [CGRect]
        let label: String
    }

    private struct ReplacementPlacementCandidate {
        let placement: ReplacementLabelPlacement
        let sourceRect: CGRect
    }

    struct ReplacementLabelPlacement {
        let matchID: UUID
        let rect: CGRect
        let label: String
    }

    private final class OCRPageCacheEntry: NSObject {
        let observations: [VNRecognizedTextObservation]

        init(observations: [VNRecognizedTextObservation]) {
            self.observations = observations
        }
    }

    private static let ocrPageCache: NSCache<NSString, OCRPageCacheEntry> = {
        let cache = NSCache<NSString, OCRPageCacheEntry>()
        cache.countLimit = 256
        return cache
    }()
    private static let ocrCacheLock = NSLock()

    private struct PatternRule {
        let label: String
        let expression: String
        let replacementKind: ReplacementKind
    }

    private struct SearchRule {
        let label: String
        let value: String
        let requiresDigitBoundaries: Bool
        let replacementKind: ReplacementKind
        let replacementKey: String
    }

    static func scan(
        files: [URL],
        exactTerms: [String],
        options: PatternOptions,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (String) -> Void
    ) -> [RedactionMatch] {
        var allMatches: [RedactionMatch] = []
        let primaryRules = searchRules(for: exactTerms, options: options)

        for fileURL in files {
            if shouldCancel() { break }
            guard let document = PDFDocument(url: fileURL) else { continue }
            var fileMatches: [RedactionMatch] = []
            for pageIndex in 0..<document.pageCount {
                if shouldCancel() { break }
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
                            searchRules: primaryRules,
                            options: options,
                            shouldCancel: shouldCancel
                        )
                    } else {
                        pageMatches = scanTextPage(
                            page,
                            text: pageText,
                            fileURL: fileURL,
                            pageIndex: pageIndex,
                            searchRules: primaryRules,
                            options: options
                        )
                    }
                    fileMatches.append(contentsOf: pageMatches)
                }
            }

            let compactRules = compactIdentifierRules(from: fileMatches)
            if !compactRules.isEmpty && !shouldCancel() {
                for pageIndex in 0..<document.pageCount {
                    if shouldCancel() { break }
                    autoreleasepool {
                        progress("Checking identifier variants in \(fileURL.lastPathComponent), page \(pageIndex + 1) of \(document.pageCount)")
                        guard let page = document.page(at: pageIndex) else { return }
                        let pageText = page.string ?? ""
                        let variantMatches: [RedactionMatch]
                        if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            variantMatches = scanImagePage(
                                page,
                                fileURL: fileURL,
                                pageIndex: pageIndex,
                                searchRules: compactRules,
                                options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
                                shouldCancel: shouldCancel
                            )
                        } else {
                            variantMatches = scanTextPage(
                                page,
                                text: pageText,
                                fileURL: fileURL,
                                pageIndex: pageIndex,
                                searchRules: compactRules,
                                options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false)
                            )
                        }
                        fileMatches.append(contentsOf: variantMatches)
                    }
                }
            }
            allMatches.append(contentsOf: fileMatches)
        }

        return deduplicated(allMatches)
    }

    static func exportSanitizedCopies(
        files: [URL],
        matches: [RedactionMatch],
        outputFolder: URL,
        replaceWithLabels: Bool = false,
        replacementLabelFontFamily: String = "Helvetica",
        replacementLabelFontSize: CGFloat = 6,
        replacementLabelWidthScale: CGFloat = 1,
        dpi: CGFloat = 300,
        progress: @escaping (String) -> Void
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        var outputs: [URL] = []

        for fileURL in files {
            let allFileMatches = matches.filter {
                $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL
            }
            let fileMatches = allFileMatches.filter(\.isSelected)
            guard !fileMatches.isEmpty else { continue }
            guard let document = PDFDocument(url: fileURL) else { throw MaskerError.cannotOpen(fileURL) }
            let labelsByMatchID = replaceWithLabels ? replacementLabels(for: allFileMatches) : [:]

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

            do {
                for pageIndex in 0..<document.pageCount {
                    try autoreleasepool {
                        progress("Sanitizing \(fileURL.lastPathComponent), page \(pageIndex + 1) of \(document.pageCount)")
                        guard let page = document.page(at: pageIndex) else {
                            throw MaskerError.cannotRender(page: pageIndex, file: fileURL)
                        }
                        let displayRect = displayBounds(for: page)
                        var pageRect = CGRect(origin: .zero, size: displayRect.size)
                        let mediaBoxData = Data(bytes: &pageRect, count: MemoryLayout<CGRect>.size)
                        let pageInfo = [kCGPDFContextMediaBox: mediaBoxData] as CFDictionary
                        context.beginPDFPage(pageInfo)

                        let redactionRects = fileMatches
                            .filter { $0.pageIndex == pageIndex }
                            .flatMap(\.rects)
                        let replacementOverlays = fileMatches
                            .filter { $0.pageIndex == pageIndex }
                            .compactMap { match -> ReplacementOverlay? in
                                guard let label = labelsByMatchID[match.id] else { return nil }
                                return ReplacementOverlay(matchID: match.id, rects: match.rects, label: label)
                            }

                        guard let image = renderPage(
                            page,
                            dpi: dpi,
                            redactionRects: redactionRects,
                            replacementOverlays: replacementOverlays,
                            replacementLabelFontFamily: replacementLabelFontFamily,
                            replacementLabelFontSize: replacementLabelFontSize,
                            replacementLabelWidthScale: replacementLabelWidthScale
                        ) else {
                            context.endPDFPage()
                            throw MaskerError.cannotRender(page: pageIndex, file: fileURL)
                        }
                        context.saveGState()
                        context.interpolationQuality = .high
                        context.draw(image, in: pageRect)
                        context.restoreGState()
                        context.endPDFPage()
                    }
                }
                context.closePDF()
            } catch {
                context.closePDF()
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }

            progress("Visually validating \(fileURL.lastPathComponent)")
            if let validationFailure = sanitizedOutputValidationFailure(
                outputURL,
                sourceDocument: document,
                matches: fileMatches,
                labelsByMatchID: labelsByMatchID,
                replacementLabelFontFamily: replacementLabelFontFamily,
                replacementLabelFontSize: replacementLabelFontSize,
                replacementLabelWidthScale: replacementLabelWidthScale
            ) {
                try? FileManager.default.removeItem(at: outputURL)
                throw MaskerError.outputValidationFailed(outputURL, validationFailure)
            }
            outputs.append(outputURL)
        }

        return outputs
    }

    static func previewImage(
        fileURL: URL,
        pageIndex: Int,
        matches: [RedactionMatch],
        replaceWithLabels: Bool = false,
        replacementLabelFontFamily: String = "Helvetica",
        replacementLabelFontSize: CGFloat = 6,
        replacementLabelWidthScale: CGFloat = 1,
        dpi: CGFloat = 110
    ) -> NSImage? {
        guard let document = PDFDocument(url: fileURL), let page = document.page(at: pageIndex) else { return nil }
        let pageMatches = matches.filter { $0.pageIndex == pageIndex && $0.isSelected }
        let rects = pageMatches.flatMap(\.rects)
        let labelsByMatchID = replaceWithLabels ? replacementLabels(for: matches) : [:]
        let overlays = pageMatches.compactMap { match -> ReplacementOverlay? in
            guard let label = labelsByMatchID[match.id] else { return nil }
            return ReplacementOverlay(matchID: match.id, rects: match.rects, label: label)
        }
        guard let cgImage = renderPage(
            page,
            dpi: dpi,
            redactionRects: rects,
            replacementOverlays: overlays,
            replacementLabelFontFamily: replacementLabelFontFamily,
            replacementLabelFontSize: replacementLabelFontSize,
            replacementLabelWidthScale: replacementLabelWidthScale
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: displayBounds(for: page).size)
    }

    static func searchResults(
        _ results: [RedactionMatch],
        excludingSelectedMatches selectedMatches: [RedactionMatch]
    ) -> [RedactionMatch] {
        let selectedByPage = Dictionary(grouping: selectedMatches.filter(\.isSelected)) {
            "\($0.fileURL.standardizedFileURL.path)|\($0.pageIndex)"
        }

        return results.filter { result in
            guard !result.rects.isEmpty else { return true }
            let key = "\(result.fileURL.standardizedFileURL.path)|\(result.pageIndex)"
            let selectedRects = selectedByPage[key]?.flatMap(\.rects) ?? []
            guard !selectedRects.isEmpty else { return true }

            let isCovered = result.rects.allSatisfy { resultRect in
                let standardized = resultRect.standardized
                let center = CGPoint(x: standardized.midX, y: standardized.midY)
                return selectedRects.contains { $0.standardized.contains(center) }
            }
            return !isCovered
        }
    }

    private static func scanTextPage(
        _ page: PDFPage,
        text: String,
        fileURL: URL,
        pageIndex: Int,
        searchRules: [SearchRule],
        options: PatternOptions
    ) -> [RedactionMatch] {
        let nsText = text as NSString
        var matches: [RedactionMatch] = []

        for rule in searchRules where !rule.value.isEmpty {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let found = nsText.range(of: rule.value, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                if (!rule.requiresDigitBoundaries || hasDigitBoundaries(in: nsText, range: found)),
                   let match = nativeMatch(
                    page: page,
                    range: found,
                    fileURL: fileURL,
                    pageIndex: pageIndex,
                    category: rule.label,
                    text: nsText.substring(with: found),
                    replacementKind: rule.replacementKind,
                    replacementKey: rule.replacementKey
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
                    text: nsText.substring(with: result.range),
                    replacementKind: rule.replacementKind,
                    replacementKey: normalizedReplacementKey(
                        nsText.substring(with: result.range),
                        kind: rule.replacementKind
                    )
                ) {
                    matches.append(match)
                }
            }
        }
        if options.detectAccountSuffixes {
            matches.append(contentsOf: nativeAccountSuffixMatches(
                page: page,
                text: text,
                fileURL: fileURL,
                pageIndex: pageIndex,
                exceptions: options.accountSuffixExceptions
            ))
        }
        return matches
    }

    private static func nativeMatch(
        page: PDFPage,
        range: NSRange,
        fileURL: URL,
        pageIndex: Int,
        category: String,
        text: String,
        replacementKind: ReplacementKind? = nil,
        replacementKey: String? = nil
    ) -> RedactionMatch? {
        guard let selection = page.selection(for: range) else { return nil }
        let lineSelections = selection.selectionsByLine()
        let pageTransform = page.transform(for: .mediaBox)
        let transformedPageBounds = page.bounds(for: .mediaBox).applying(pageTransform).standardized
        let selections = lineSelections.isEmpty ? [selection] : lineSelections
        let candidateRects = selections.map { selectedLine -> CGRect in
            let pageRect = selectedLine.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
            let transformed = pageRect.applying(pageTransform).standardized
            return transformed.offsetBy(dx: -transformedPageBounds.minX, dy: -transformedPageBounds.minY)
        }
        let rects = safeRedactionRects(candidateRects, on: page)

        guard !rects.isEmpty else { return nil }
        return RedactionMatch(
            fileURL: fileURL,
            pageIndex: pageIndex,
            category: category,
            matchedText: text,
            rects: rects,
            replacementKind: replacementKind,
            replacementKey: replacementKey
        )
    }

    private static func scanImagePage(
        _ page: PDFPage,
        fileURL: URL,
        pageIndex: Int,
        searchRules: [SearchRule],
        options: PatternOptions,
        shouldCancel: @escaping () -> Bool
    ) -> [RedactionMatch] {
        guard !shouldCancel(),
              let observations = recognizedTextObservations(
                page,
                fileURL: fileURL,
                pageIndex: pageIndex,
                shouldCancel: shouldCancel
              ) else { return [] }
        let displayRect = displayBounds(for: page)
        var matches: [RedactionMatch] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            let nsLine = line as NSString

            for rule in searchRules where !rule.value.isEmpty {
                var searchRange = NSRange(location: 0, length: nsLine.length)
                while searchRange.location < nsLine.length {
                    let found = nsLine.range(of: rule.value, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    if (!rule.requiresDigitBoundaries || hasDigitBoundaries(in: nsLine, range: found)),
                       let swiftRange = Range(found, in: line),
                       let box = try? candidate.boundingBox(for: swiftRange) {
                        matches.append(ocrMatch(
                            box: box.boundingBox,
                            displaySize: displayRect.size,
                            fileURL: fileURL,
                            pageIndex: pageIndex,
                            category: rule.label + " (OCR)",
                            text: nsLine.substring(with: found),
                            replacementKind: rule.replacementKind,
                            replacementKey: rule.replacementKey
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
                        text: nsLine.substring(with: result.range),
                        replacementKind: rule.replacementKind,
                        replacementKey: normalizedReplacementKey(
                            nsLine.substring(with: result.range),
                            kind: rule.replacementKind
                        )
                    ))
                }
            }

            if options.detectAccountSuffixes,
               let suffix = accountSuffixRange(in: line, exceptions: options.accountSuffixExceptions),
               let swiftRange = Range(suffix, in: line),
               let box = try? candidate.boundingBox(for: swiftRange) {
                matches.append(ocrMatch(
                    box: box.boundingBox,
                    displaySize: displayRect.size,
                    fileURL: fileURL,
                    pageIndex: pageIndex,
                    category: "Account suffix (OCR)",
                    text: nsLine.substring(with: suffix),
                    replacementKind: .account,
                    replacementKey: accountReplacementKey(in: line, suffixRange: suffix)
                ))
            }
        }
        return matches
    }

    private static func recognizedTextObservations(
        _ page: PDFPage,
        fileURL: URL,
        pageIndex: Int,
        shouldCancel: () -> Bool
    ) -> [VNRecognizedTextObservation]? {
        let cacheKey = ocrCacheKey(fileURL: fileURL, pageIndex: pageIndex)
        if let cached = ocrPageCache.object(forKey: cacheKey) {
            return cached.observations
        }

        ocrCacheLock.lock()
        defer { ocrCacheLock.unlock() }
        if let cached = ocrPageCache.object(forKey: cacheKey) {
            return cached.observations
        }
        guard !shouldCancel(),
              let image = renderPage(page, dpi: 180, redactionRects: []) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        ocrPageCache.setObject(OCRPageCacheEntry(observations: observations), forKey: cacheKey)
        return observations
    }

    private static func ocrCacheKey(fileURL: URL, pageIndex: Int) -> NSString {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(fileURL.standardizedFileURL.path)|\(modified)|\(size)|\(pageIndex)" as NSString
    }

    private static func ocrMatch(
        box: CGRect,
        displaySize: CGSize,
        fileURL: URL,
        pageIndex: Int,
        category: String,
        text: String,
        replacementKind: ReplacementKind? = nil,
        replacementKey: String? = nil
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
            rects: [rect],
            replacementKind: replacementKind,
            replacementKey: replacementKey
        )
    }

    private static func patternRules(_ options: PatternOptions) -> [PatternRule] {
        var rules: [PatternRule] = []
        if options.detectSSN {
            rules.append(PatternRule(
                label: "SSN / ITIN",
                expression: #"\b\d{3}[ -]\d{2}[ -]\d{4}\b"#,
                replacementKind: .identifier
            ))
        }
        if options.detectEIN {
            rules.append(PatternRule(
                label: "EIN",
                expression: #"\b\d{2}-\d{7}\b"#,
                replacementKind: .identifier
            ))
        }
        if options.detectEmail {
            rules.append(PatternRule(
                label: "Email",
                expression: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
                replacementKind: .email
            ))
        }
        if options.detectPhone {
            rules.append(PatternRule(
                label: "Phone",
                expression: #"(?<!\d)(?:\+?1[ .-]?)?(?:\(\d{3}\)|\d{3})[ .-]\d{3}[ .-]\d{4}(?!\d)"#,
                replacementKind: .phone
            ))
        }
        return rules
    }

    private static func nativeAccountSuffixMatches(
        page: PDFPage,
        text: String,
        fileURL: URL,
        pageIndex: Int,
        exceptions: [String]
    ) -> [RedactionMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let pageBounds = page.bounds(for: .mediaBox)
        return nativeAccountCandidateRegex.matches(in: text, range: fullRange).compactMap { result in
            let suffixRange = result.range(at: 1)
            guard suffixRange.location != NSNotFound,
                  let suffixSelection = page.selection(for: suffixRange) else { return nil }
            let suffix = nsText.substring(with: suffixRange)
            let suffixBounds = suffixSelection.bounds(for: page)
            let lineBand = CGRect(
                x: pageBounds.minX,
                y: suffixBounds.minY - 2,
                width: pageBounds.width,
                height: suffixBounds.height + 4
            )
            guard let bandSelection = page.selection(for: lineBand) else { return nil }
            let nearbyBounds = suffixBounds.insetBy(dx: -2, dy: -2)
            let physicalLine = bandSelection.selectionsByLine().first { selection in
                let lineText = selection.string ?? ""
                return selection.bounds(for: page).intersects(nearbyBounds) &&
                    lineText.range(of: suffix, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard let line = physicalLine?.string,
                  let detectedSuffix = accountSuffixRange(in: line, exceptions: exceptions),
                  (line as NSString).substring(with: detectedSuffix) == suffix else { return nil }
            return nativeMatch(
                page: page,
                range: suffixRange,
                fileURL: fileURL,
                pageIndex: pageIndex,
                category: "Account suffix",
                text: nsText.substring(with: suffixRange),
                replacementKind: .account,
                replacementKey: accountReplacementKey(in: line, suffixRange: detectedSuffix)
            )
        }
    }

    private static let nativeAccountCandidateRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9])([0-9]{3,8})(?![0-9])"#
    )

    private static func accountSuffixRange(in line: String, exceptions: [String]) -> NSRange? {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let result = accountSuffixRegex.firstMatch(in: line, range: fullRange) else { return nil }
        let prefixRange = result.range(at: 1)
        let suffixRange = result.range(at: 2)
        guard prefixRange.location != NSNotFound,
              suffixRange.location != NSNotFound,
              isInstitutionLikeAccountPrefix(
                nsLine.substring(with: prefixRange),
                suffix: nsLine.substring(with: suffixRange),
                line: line,
                exceptions: exceptions
              ) else { return nil }
        return suffixRange
    }

    private static let accountSuffixRegex = try! NSRegularExpression(
        pattern: #"(?m)^([^\r\n]*?)([0-9]{3,8})(?:[ \t]+(?:STC|LTC))?(?:(?:[ \t_-]*$)|(?:[ \t]*\.{2,}[ \t]*(?:\$[ \t]*)?[0-9][0-9,]*(?:\.[0-9]+)?\.?[ \t]*$))"#,
        options: [.caseInsensitive]
    )

    private static func isInstitutionLikeAccountPrefix(
        _ prefix: String,
        suffix: String,
        line: String,
        exceptions: [String]
    ) -> Bool {
        guard !containsAccountSuffixException(line, exceptions: exceptions) else { return false }
        guard let rawLast = prefix.last,
              rawLast.isWhitespace || rawLast == "-" || rawLast == "#" else { return false }

        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isNumber),
              !trimmed.contains("$"),
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.contains("=") else { return false }

        let explicitSeparator = trimmed.last == "-" || trimmed.last == "#"
        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in String(token).filter { $0.isLetter || $0 == "'" || $0 == "&" } }
            .filter { !$0.isEmpty && $0 != "&" }
        guard !words.isEmpty, words.joined().count >= 4 else { return false }

        let stopWords: Set<String> = [
            "AMOUNT", "BOX", "DATE", "FORM", "LINE", "NOTE", "PAGE", "PART",
            "SCHEDULE", "SECTION", "SUBTOTAL", "TAX", "TOTAL", "YEAR"
        ]
        let uppercaseWords = Set(words.map { $0.uppercased() })
        guard uppercaseWords.isDisjoint(with: stopWords) else { return false }

        let hasLowercase = trimmed.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let isAllCaps = !hasLowercase
        let hasDottedLeader = line.contains("..")
        guard explicitSeparator || (isAllCaps && (words.count >= 2 || hasDottedLeader)) else { return false }

        if let numericSuffix = Int(suffix),
           suffix.count == 4,
           (1900...2099).contains(numericSuffix) {
            return false
        }
        return true
    }

    private static func containsAccountSuffixException(_ line: String, exceptions: [String]) -> Bool {
        let normalizedLine = normalizedAccountLine(line)
        return exceptions.contains { exception in
            let normalizedException = normalizedAccountLine(exception)
            return !normalizedException.isEmpty && normalizedLine.contains(normalizedException)
        }
    }

    private static func normalizedAccountLine(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .uppercased()
    }

    private static func accountReplacementKey(in line: String, suffixRange: NSRange) -> String {
        let nsLine = line as NSString
        let prefix = nsLine.substring(to: suffixRange.location)
        var words = prefix
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .uppercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        let legalSuffixes: Set<String> = [
            "CO", "COMPANY", "CORP", "CORPORATION", "INC", "INCORPORATED",
            "LLC", "LLP", "LTD", "LIMITED"
        ]
        while let last = words.last, legalSuffixes.contains(last) {
            words.removeLast()
        }
        let institution = words.joined(separator: " ")
        let suffix = nsLine.substring(with: suffixRange).filter(\.isNumber)
        return institution.isEmpty ? suffix : institution + "|" + suffix
    }

    private static func searchRules(for exactTerms: [String], options: PatternOptions) -> [SearchRule] {
        var rules: [SearchRule] = []
        var seen = Set<String>()

        for term in exactTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let exactKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let replacementKind = replacementKind(forExactTerm: trimmed)
            let replacementKey = normalizedReplacementKey(trimmed, kind: replacementKind)
            if seen.insert(exactKey).inserted {
                rules.append(SearchRule(
                    label: "Exact value",
                    value: trimmed,
                    requiresDigitBoundaries: false,
                    replacementKind: replacementKind,
                    replacementKey: replacementKey
                ))
            }

            if options.generateNameVariants, let variant = firstAndLastNameVariant(from: trimmed) {
                let variantKey = variant.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(variantKey).inserted {
                    rules.append(SearchRule(
                        label: "Name variant",
                        value: variant,
                        requiresDigitBoundaries: false,
                        replacementKind: .name,
                        replacementKey: replacementKey
                    ))
                }
            }
        }
        return rules
    }

    private static func firstAndLastNameVariant(from value: String) -> String? {
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (3...8).contains(tokens.count) else { return nil }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'-.’"))
        guard tokens.allSatisfy({ token in
            !token.isEmpty && token.unicodeScalars.allSatisfy { allowed.contains($0) }
        }) else { return nil }
        guard let first = tokens.first, let last = tokens.last, first.count >= 2, last.count >= 2 else { return nil }
        return "\(first) \(last)"
    }

    private static func compactIdentifierRules(from matches: [RedactionMatch]) -> [SearchRule] {
        var rules: [SearchRule] = []
        var seen = Set<String>()

        for match in matches {
            let baseLabel: String?
            if match.category.hasPrefix("SSN / ITIN") {
                baseLabel = "SSN / ITIN compact variant"
            } else if match.category.hasPrefix("EIN") {
                baseLabel = "EIN compact variant"
            } else {
                baseLabel = nil
            }
            guard let label = baseLabel else { continue }
            let digits = match.matchedText.filter(\.isNumber)
            guard digits.count == 9, seen.insert("\(label)|\(digits)").inserted else { continue }
            rules.append(SearchRule(
                label: label,
                value: digits,
                requiresDigitBoundaries: true,
                replacementKind: .identifier,
                replacementKey: match.replacementKey ?? digits
            ))
        }
        return rules
    }

    private static func replacementKind(forExactTerm value: String) -> ReplacementKind {
        if value.contains("@") { return .email }
        let digits = value.filter(\.isNumber)
        if digits.count == 9,
           value.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) {
            return .identifier
        }
        if (digits.count == 10 || digits.count == 11),
           value.allSatisfy({ $0.isNumber || "()+-. ".contains($0) }) {
            return .phone
        }
        let nameTokens = value.split(whereSeparator: \.isWhitespace)
        let nameCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'-.’&"))
        if (2...8).contains(nameTokens.count),
           nameTokens.allSatisfy({ token in
               String(token).caseInsensitiveCompare("AND") == .orderedSame ||
                   token.unicodeScalars.allSatisfy { nameCharacters.contains($0) }
           }) {
            return .name
        }
        if digits.count >= 3,
           !value.contains(where: { $0.isWhitespace }),
           value.allSatisfy({ $0.isLetter || $0.isNumber || "#-*._".contains($0) }) {
            return .account
        }
        return .value
    }

    private static func normalizedReplacementKey(_ value: String, kind: ReplacementKind) -> String {
        switch kind {
        case .account, .identifier, .phone:
            let digits = value.filter(\.isNumber)
            return digits.isEmpty ? normalizedAccountLine(value) : digits
        case .email:
            return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        case .name, .value:
            return normalizedAccountLine(value)
        }
    }

    private static func hasDigitBoundaries(in text: NSString, range: NSRange) -> Bool {
        let decimalDigits = CharacterSet.decimalDigits
        if range.location > 0 {
            let previous = text.substring(with: NSRange(location: range.location - 1, length: 1))
            if previous.unicodeScalars.contains(where: { decimalDigits.contains($0) }) { return false }
        }
        let nextLocation = range.location + range.length
        if nextLocation < text.length {
            let next = text.substring(with: NSRange(location: nextLocation, length: 1))
            if next.unicodeScalars.contains(where: { decimalDigits.contains($0) }) { return false }
        }
        return true
    }

    private static func deduplicated(_ matches: [RedactionMatch]) -> [RedactionMatch] {
        var result: [RedactionMatch] = []
        var indexByKey: [String: Int] = [:]
        for match in matches {
            let rectKey = match.rects.map {
                "\(Int($0.minX.rounded())):\(Int($0.minY.rounded())):\(Int($0.width.rounded())):\(Int($0.height.rounded()))"
            }.joined(separator: ";")
            let key = "\(match.fileURL.standardizedFileURL.path)|\(match.pageIndex)|\(rectKey)"
            if let existingIndex = indexByKey[key] {
                let existing = result[existingIndex]
                if match.category.hasPrefix("Account suffix") &&
                    !existing.category.hasPrefix("Account suffix") {
                    result[existingIndex] = match
                }
            } else {
                indexByKey[key] = result.count
                result.append(match)
            }
        }
        return result
    }

    private static func displayBounds(for page: PDFPage) -> CGRect {
        let transform = page.transform(for: .mediaBox)
        let transformed = page.bounds(for: .mediaBox).applying(transform).standardized
        return CGRect(origin: .zero, size: transformed.size)
    }

    static func safeRedactionRects(_ rects: [CGRect], on page: PDFPage) -> [CGRect] {
        let pageRect = displayBounds(for: page)
        let maximumHeight = max(72, pageRect.height * 0.35)
        let maximumArea = pageRect.width * pageRect.height * 0.16

        return rects.compactMap { candidate in
            guard candidate.origin.x.isFinite,
                  candidate.origin.y.isFinite,
                  candidate.width.isFinite,
                  candidate.height.isFinite else { return nil }
            let clipped = candidate.standardized.intersection(pageRect)
            guard !clipped.isNull,
                  clipped.width > 0,
                  clipped.height > 0,
                  clipped.height <= maximumHeight,
                  clipped.width * clipped.height <= maximumArea else { return nil }
            return clipped
        }
    }

    static func replacementLabels(for matches: [RedactionMatch]) -> [UUID: String] {
        let ordered = matches.sorted { lhs, rhs in
            let leftPath = lhs.fileURL.standardizedFileURL.path
            let rightPath = rhs.fileURL.standardizedFileURL.path
            if leftPath != rightPath { return leftPath < rightPath }
            if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
            let leftRect = lhs.rects.first?.standardized ?? .zero
            let rightRect = rhs.rects.first?.standardized ?? .zero
            if abs(leftRect.maxY - rightRect.maxY) > 0.5 { return leftRect.maxY > rightRect.maxY }
            if abs(leftRect.minX - rightRect.minX) > 0.5 { return leftRect.minX < rightRect.minX }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var counters: [ReplacementKind: Int] = [:]
        var labelByGroup: [String: String] = [:]
        var result: [UUID: String] = [:]

        for match in ordered {
            let kind = match.replacementKind ?? fallbackReplacementKind(for: match)
            let key = match.replacementKey ?? normalizedReplacementKey(match.matchedText, kind: kind)
            guard !key.isEmpty else { continue }
            let group = kind.rawValue + "|" + key
            let label: String
            if let existing = labelByGroup[group] {
                label = existing
            } else {
                let number = counters[kind, default: 0] + 1
                counters[kind] = number
                label = "<\(kind.rawValue) \(number)>"
                labelByGroup[group] = label
            }
            result[match.id] = label
        }
        return result
    }

    static func replacementLabelPlacements(
        for matches: [RedactionMatch],
        labelsByMatchID: [UUID: String],
        on page: PDFPage,
        fontFamily: String = "Helvetica",
        fontSize: CGFloat = 6,
        widthScale: CGFloat = 1
    ) -> [ReplacementLabelPlacement] {
        let overlays = matches.compactMap { match -> ReplacementOverlay? in
            guard let label = labelsByMatchID[match.id] else { return nil }
            return ReplacementOverlay(matchID: match.id, rects: match.rects, label: label)
        }
        return replacementLabelPlacements(
            for: overlays,
            on: page,
            fontFamily: fontFamily,
            fontSize: fontSize,
            widthScale: widthScale
        )
    }

    static func replacementLabelForDisplay(
        _ label: String,
        in rect: CGRect,
        fontFamily: String = "Helvetica",
        fontSize: CGFloat = 6
    ) -> String {
        let availableWidth = max(rect.width - 3, 1)
        let minimumReadableFont = replacementNSFont(family: fontFamily, size: min(max(fontSize, 3), 14))
        let fullWidth = (label as NSString).size(withAttributes: [.font: minimumReadableFont]).width
        guard fullWidth > availableWidth else { return label }

        let pattern = #"^<([A-Za-z]+)\s+(\d+)>$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: label,
                range: NSRange(label.startIndex..., in: label)
              ),
              let kindRange = Range(match.range(at: 1), in: label),
              let numberRange = Range(match.range(at: 2), in: label),
              let initial = label[kindRange].first else { return label }
        return "<\(initial)\(label[numberRange])>"
    }

    private static func replacementLabelPlacements(
        for overlays: [ReplacementOverlay],
        on page: PDFPage,
        fontFamily: String,
        fontSize: CGFloat,
        widthScale: CGFloat
    ) -> [ReplacementLabelPlacement] {
        let pageRect = displayBounds(for: page)
        let safeWidthScale = min(max(widthScale, 1), 2)
        let candidates = overlays.compactMap { overlay -> ReplacementPlacementCandidate? in
            guard let widestRect = safeRedactionRects(overlay.rects, on: page).max(by: {
                if abs($0.width - $1.width) > 0.5 { return $0.width < $1.width }
                return $0.width * $0.height < $1.width * $1.height
            }) else { return nil }
            let labelFont = replacementNSFont(family: fontFamily, size: fontSize)
            let naturalLabelWidth = (overlay.label as NSString).size(
                withAttributes: [.font: labelFont]
            ).width + 7
            let maximumLabelWidth = widestRect.width * safeWidthScale
            let labelWidth = min(max(naturalLabelWidth, 12), maximumLabelWidth)
            let labelHeight = min(widestRect.height, max(fontSize * 1.55, 5))
            let compactRect = CGRect(
                x: widestRect.midX - labelWidth / 2,
                y: widestRect.midY - labelHeight / 2,
                width: labelWidth,
                height: labelHeight
            ).intersection(pageRect).standardized
            return ReplacementPlacementCandidate(
                placement: ReplacementLabelPlacement(
                    matchID: overlay.matchID,
                    rect: compactRect,
                    label: replacementLabelForDisplay(
                        overlay.label,
                        in: compactRect,
                        fontFamily: fontFamily,
                        fontSize: fontSize
                    )
                ),
                sourceRect: widestRect
            )
        }.sorted {
            let leftArea = $0.sourceRect.width * $0.sourceRect.height
            let rightArea = $1.sourceRect.width * $1.sourceRect.height
            if abs(leftArea - rightArea) > 0.5 { return leftArea > rightArea }
            if abs($0.sourceRect.maxY - $1.sourceRect.maxY) > 0.5 {
                return $0.sourceRect.maxY > $1.sourceRect.maxY
            }
            return $0.sourceRect.minX < $1.sourceRect.minX
        }

        var accepted: [ReplacementPlacementCandidate] = []
        for candidate in candidates {
            let overlapsExisting = accepted.contains { existing in
                let intersection = candidate.sourceRect.intersection(existing.sourceRect)
                guard !intersection.isNull else { return false }
                let intersectionArea = intersection.width * intersection.height
                let smallerArea = min(
                    candidate.sourceRect.width * candidate.sourceRect.height,
                    existing.sourceRect.width * existing.sourceRect.height
                )
                return smallerArea > 0 && intersectionArea / smallerArea > 0.35
            }
            if !overlapsExisting { accepted.append(candidate) }
        }
        return accepted.map(\.placement).sorted {
            if abs($0.rect.maxY - $1.rect.maxY) > 0.5 { return $0.rect.maxY > $1.rect.maxY }
            return $0.rect.minX < $1.rect.minX
        }
    }

    static func replacementNSFont(family: String, size: CGFloat) -> NSFont {
        let safeSize = min(max(size, 2.5), 18)
        if family == "System" { return .systemFont(ofSize: safeSize) }
        return NSFont(name: family, size: safeSize) ?? .systemFont(ofSize: safeSize)
    }

    private static func fallbackReplacementKind(for match: RedactionMatch) -> ReplacementKind {
        if match.category.hasPrefix("Account suffix") { return .account }
        if match.category.hasPrefix("SSN") || match.category.hasPrefix("EIN") { return .identifier }
        if match.category.hasPrefix("Email") { return .email }
        if match.category.hasPrefix("Phone") { return .phone }
        if match.category.hasPrefix("Name variant") { return .name }
        return replacementKind(forExactTerm: match.matchedText)
    }

    private static func renderPage(
        _ page: PDFPage,
        dpi: CGFloat,
        redactionRects: [CGRect],
        replacementOverlays: [ReplacementOverlay] = [],
        replacementLabelFontFamily: String = "Helvetica",
        replacementLabelFontSize: CGFloat = 6,
        replacementLabelWidthScale: CGFloat = 1
    ) -> CGImage? {
        let scale = max(dpi / 72.0, 1.0)
        let pageBounds = page.bounds(for: .mediaBox)
        let pageTransform = page.transform(for: .mediaBox)
        let transformedBounds = pageBounds.applying(pageTransform).standardized
        let displaySize = transformedBounds.size
        let requestedWidth = max(displaySize.width * scale, 1)
        let requestedHeight = max(displaySize.height * scale, 1)
        let maximumPixelCount: CGFloat = 20_000_000
        let pixelReduction = min(1, sqrt(maximumPixelCount / (requestedWidth * requestedHeight)))
        let renderScale = scale * pixelReduction
        let pixelWidth = max(Int(ceil(displaySize.width * renderScale)), 1)
        let pixelHeight = max(Int(ceil(displaySize.height * renderScale)), 1)

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

        bitmap.scaleBy(x: renderScale, y: renderScale)
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(origin: .zero, size: displaySize))

        bitmap.saveGState()
        if let pageRef = page.pageRef {
            let target = CGRect(origin: .zero, size: displaySize)
            let drawingTransform = pageRef.getDrawingTransform(
                .mediaBox,
                rect: target,
                rotate: 0,
                preserveAspectRatio: true
            )
            bitmap.concatenate(drawingTransform)
            bitmap.drawPDFPage(pageRef)
            for annotation in page.annotations where annotation.shouldDisplay || annotation.shouldPrint {
                annotation.draw(with: .mediaBox, in: bitmap)
            }
        } else {
            bitmap.translateBy(x: -transformedBounds.minX, y: -transformedBounds.minY)
            page.draw(with: .mediaBox, to: bitmap)
        }
        bitmap.restoreGState()

        if !redactionRects.isEmpty {
            bitmap.setFillColor(replacementOverlays.isEmpty ? NSColor.black.cgColor : NSColor.white.cgColor)
            for rect in safeRedactionRects(redactionRects, on: page) {
                bitmap.fill(rect.insetBy(dx: -0.75, dy: -0.75))
            }
            if !replacementOverlays.isEmpty {
                for placement in replacementLabelPlacements(
                    for: replacementOverlays,
                    on: page,
                    fontFamily: replacementLabelFontFamily,
                    fontSize: replacementLabelFontSize,
                    widthScale: replacementLabelWidthScale
                ) {
                    drawReplacementLabel(
                        placement.label,
                        in: placement.rect,
                        fontFamily: replacementLabelFontFamily,
                        preferredFontSize: replacementLabelFontSize,
                        context: bitmap
                    )
                }
            }
        }
        return bitmap.makeImage()
    }

    private static func drawReplacementLabel(
        _ label: String,
        in rect: CGRect,
        fontFamily: String,
        preferredFontSize: CGFloat,
        context: CGContext
    ) {
        let available = rect.insetBy(dx: 0.8, dy: 0.4)
        guard available.width > 4, available.height > 3 else { return }
        let badgeRect = rect.insetBy(dx: 0.15, dy: 0.15)
        let badgePath = CGPath(
            roundedRect: badgeRect,
            cornerWidth: min(max(badgeRect.height * 0.22, 1), 3),
            cornerHeight: min(max(badgeRect.height * 0.22, 1), 3),
            transform: nil
        )
        context.saveGState()
        context.addPath(badgePath)
        context.setFillColor(NSColor(calibratedWhite: 0.985, alpha: 1).cgColor)
        context.fillPath()
        context.restoreGState()
        var fontSize = min(max(preferredFontSize, 2.5), max(available.height * 0.72, 2.5))
        var nsFont = replacementNSFont(family: fontFamily, size: fontSize)
        var font = CTFontCreateWithName(nsFont.fontName as CFString, fontSize, nil)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: NSColor.black.cgColor
        ]
        var line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary))
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > available.width {
            fontSize = max(2.5, fontSize * available.width / max(width, 1))
            nsFont = replacementNSFont(family: fontFamily, size: fontSize)
            font = CTFontCreateWithName(nsFont.fontName as CFString, fontSize, nil)
            attributes[kCTFontAttributeName] = font
            line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary))
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let x = available.minX + max((available.width - width) / 2, 0)
        let y = available.midY - (ascent - descent) / 2
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func validateSanitizedOutput(
        _ url: URL,
        sourceDocument: PDFDocument,
        matches: [RedactionMatch],
        replaceWithLabels: Bool = false,
        replacementLabelFontFamily: String = "Helvetica",
        replacementLabelFontSize: CGFloat = 6,
        replacementLabelWidthScale: CGFloat = 1
    ) -> Bool {
        sanitizedOutputValidationFailure(
            url,
            sourceDocument: sourceDocument,
            matches: matches,
            labelsByMatchID: replaceWithLabels ? replacementLabels(for: matches) : [:],
            replacementLabelFontFamily: replacementLabelFontFamily,
            replacementLabelFontSize: replacementLabelFontSize,
            replacementLabelWidthScale: replacementLabelWidthScale
        ) == nil
    }

    static func sanitizedOutputValidationFailure(
        _ url: URL,
        sourceDocument: PDFDocument,
        matches: [RedactionMatch],
        labelsByMatchID: [UUID: String] = [:],
        replacementLabelFontFamily: String = "Helvetica",
        replacementLabelFontSize: CGFloat = 6,
        replacementLabelWidthScale: CGFloat = 1
    ) -> String? {
        guard let output = PDFDocument(url: url) else { return "the output could not be reopened" }
        guard output.pageCount == sourceDocument.pageCount else { return "the page count changed" }
        for index in 0..<output.pageCount {
            guard let outputPage = output.page(at: index),
                  let sourcePage = sourceDocument.page(at: index) else {
                return "page \(index + 1) could not be reopened"
            }
            if !(outputPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "page \(index + 1) still contains searchable text"
            }
            if !outputPage.annotations.isEmpty {
                return "page \(index + 1) still contains live annotations"
            }
            let redactionRects = matches
                .filter { $0.pageIndex == index && $0.isSelected }
                .flatMap(\.rects)
            let replacementOverlays = matches
                .filter { $0.pageIndex == index && $0.isSelected }
                .compactMap { match -> ReplacementOverlay? in
                    guard let label = labelsByMatchID[match.id] else { return nil }
                    return ReplacementOverlay(matchID: match.id, rects: match.rects, label: label)
                }
            guard let expectedImage = renderPage(
                    sourcePage,
                    dpi: 72,
                    redactionRects: redactionRects,
                    replacementOverlays: replacementOverlays,
                    replacementLabelFontFamily: replacementLabelFontFamily,
                    replacementLabelFontSize: replacementLabelFontSize,
                    replacementLabelWidthScale: replacementLabelWidthScale
                  ),
                  let outputImage = renderPage(outputPage, dpi: 72, redactionRects: []),
                  imagesAreVisuallyEquivalent(expectedImage, outputImage) else {
                return "page \(index + 1) does not visually match the source"
            }
        }
        return nil
    }

    private static func imagesAreVisuallyEquivalent(_ first: CGImage, _ second: CGImage) -> Bool {
        let comparisonWidth = min(max(first.width, second.width), 160)
        let firstAspect = CGFloat(first.height) / CGFloat(max(first.width, 1))
        let secondAspect = CGFloat(second.height) / CGFloat(max(second.width, 1))
        guard abs(firstAspect - secondAspect) < 0.02 else { return false }
        let comparisonHeight = max(Int((CGFloat(comparisonWidth) * firstAspect).rounded()), 1)
        guard let firstPixels = grayscalePixels(first, width: comparisonWidth, height: comparisonHeight),
              let secondPixels = grayscalePixels(second, width: comparisonWidth, height: comparisonHeight),
              firstPixels.count == secondPixels.count,
              !firstPixels.isEmpty else { return false }

        var totalDifference = 0
        var materiallyDifferentPixels = 0
        for index in firstPixels.indices {
            let difference = abs(Int(firstPixels[index]) - Int(secondPixels[index]))
            totalDifference += difference
            if difference > 48 { materiallyDifferentPixels += 1 }
        }
        let pixelCount = firstPixels.count
        let meanDifference = Double(totalDifference) / Double(pixelCount * 255)
        let materialDifferenceRatio = Double(materiallyDifferentPixels) / Double(pixelCount)
        return meanDifference <= 0.08 && materialDifferenceRatio <= 0.18
    }

    private static func grayscalePixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 255, count: width * height)
        let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? pixels : nil
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
