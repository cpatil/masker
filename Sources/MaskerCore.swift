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
    var generateNameVariants = false
    var detectAccountSuffixes = false
    var accountSuffixExceptions: [String] = []
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
    }

    private struct SearchRule {
        let label: String
        let value: String
        let requiresDigitBoundaries: Bool
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

                        guard let image = renderPage(page, dpi: dpi, redactionRects: redactionRects) else {
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
            guard validateSanitizedOutput(
                outputURL,
                sourceDocument: document,
                matches: fileMatches
            ) else {
                try? FileManager.default.removeItem(at: outputURL)
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
        text: String
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
            rects: rects
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
                    text: nsLine.substring(with: suffix)
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
                text: nsText.substring(with: suffixRange)
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

    private static func searchRules(for exactTerms: [String], options: PatternOptions) -> [SearchRule] {
        var rules: [SearchRule] = []
        var seen = Set<String>()

        for term in exactTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let exactKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(exactKey).inserted {
                rules.append(SearchRule(label: "Exact value", value: trimmed, requiresDigitBoundaries: false))
            }

            if options.generateNameVariants, let variant = firstAndLastNameVariant(from: trimmed) {
                let variantKey = variant.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(variantKey).inserted {
                    rules.append(SearchRule(label: "Name variant", value: variant, requiresDigitBoundaries: false))
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
            rules.append(SearchRule(label: label, value: digits, requiresDigitBoundaries: true))
        }
        return rules
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
            bitmap.setFillColor(NSColor.black.cgColor)
            for rect in safeRedactionRects(redactionRects, on: page) {
                bitmap.fill(rect.insetBy(dx: -0.75, dy: -0.75))
            }
        }
        return bitmap.makeImage()
    }

    static func validateSanitizedOutput(
        _ url: URL,
        sourceDocument: PDFDocument,
        matches: [RedactionMatch]
    ) -> Bool {
        guard let output = PDFDocument(url: url), output.pageCount == sourceDocument.pageCount else { return false }
        for index in 0..<output.pageCount {
            guard let outputPage = output.page(at: index),
                  let sourcePage = sourceDocument.page(at: index) else { return false }
            if !(outputPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if !outputPage.annotations.isEmpty {
                return false
            }
            let redactionRects = matches
                .filter { $0.pageIndex == index && $0.isSelected }
                .flatMap(\.rects)
            guard let expectedImage = renderPage(sourcePage, dpi: 72, redactionRects: redactionRects),
                  let outputImage = renderPage(outputPage, dpi: 72, redactionRects: []),
                  imagesAreVisuallyEquivalent(expectedImage, outputImage) else { return false }
        }
        return true
    }

    private static func imagesAreVisuallyEquivalent(_ first: CGImage, _ second: CGImage) -> Bool {
        let comparisonWidth = min(max(first.width, second.width), 640)
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
        return meanDifference <= 0.035 && materialDifferenceRatio <= 0.045
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
