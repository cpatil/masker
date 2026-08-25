import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

@main
struct MaskerSelfTest {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        let fullFarmerName = "JOE AND MARY FARMER"
        let joeFarmerVariant = "JOE FARMER"
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/masker-self-test", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sample-tax-document.pdf")
        let boundarySource = root.appendingPathComponent("digit-boundary-document.pdf")
        let outputs = root.appendingPathComponent("outputs", isDirectory: true)

        try makeSamplePDF(at: source)
        try makeBoundaryPDF(at: boundarySource)
        if let doc = PDFDocument(url: source) {
            report("Page strings: \((0..<doc.pageCount).map { String(describing: doc.page(at: $0)?.string) })")
        }
        if let preview = PDFMasker.previewImage(fileURL: source, pageIndex: 1, matches: [], dpi: 180),
           let cgImage = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let representation = NSBitmapImageRep(cgImage: cgImage)
            if let data = representation.representation(using: .png, properties: [:]) {
                try data.write(to: root.appendingPathComponent("core-render-page-2.png"))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
                report("Direct OCR: \((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })")
            } catch {
                let nsError = error as NSError
                report("Direct OCR error: domain=\(nsError.domain) code=\(nsError.code) info=\(nsError.userInfo)")
            }
        }

        let matches = PDFMasker.scan(
            files: [source],
            exactTerms: [
                "Jordan",
                "Alex & Jordan",
                "PATI",
                "Example Person",
                fullFarmerName,
                "444-55-6666",
                "555-66-7777"
            ],
            options: PatternOptions(detectSSN: true, detectEIN: true, detectEmail: true, detectPhone: true, generateNameVariants: true, detectAccountSuffixes: true),
            progress: { _ in }
        )

        report("Detected: \(matches.map { "[\($0.category)] \($0.matchedText) rects=\($0.rects)" }.joined(separator: ", "))")

        let nativeSSNs = matches.filter { $0.matchedText == "123-45-6789" }
        let scannedSSNs = matches.filter { $0.matchedText == "444-55-6666" }
        let rotatedSSNs = matches.filter { $0.matchedText == "555-66-7777" }
        let rotatedReplacement = [
            PDFMasker.normalizedReplacementKey(for: "555-66-7777"): "Tax ID"
        ]
        let rotatedStyles = [
            PDFMasker.normalizedReplacementKey(for: "555-66-7777"): ReplacementLabelStyle(
                fontName: "Courier-Bold",
                fontSize: 10,
                widthFraction: 0.75,
                alignment: .left
            )
        ]
        if !rotatedSSNs.isEmpty,
           let preview = PDFMasker.previewImage(
                fileURL: source,
                pageIndex: 2,
                matches: rotatedSSNs,
                replacementsByValue: rotatedReplacement,
                replacementStylesByValue: rotatedStyles,
                dpi: 180
           ),
           let cgImage = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let representation = NSBitmapImageRep(cgImage: cgImage)
            if let data = representation.representation(using: .png, properties: [:]) {
                try data.write(to: root.appendingPathComponent("core-render-rotated-masked.png"))
            }
        }
        try require(!nativeSSNs.isEmpty, "Failed to detect the native-text SSN")
        try require(!scannedSSNs.isEmpty, "Failed to detect the image-only SSN using OCR")
        try require(!rotatedSSNs.isEmpty, "Failed to detect the rotated-page SSN")
        try require(
            rotatedSSNs.allSatisfy { $0.textRotationDegrees == 90 || $0.textRotationDegrees == 270 },
            "Rotated-page text orientation was not detected: \(rotatedSSNs.map(\.textRotationDegrees))"
        )
        try require(matches.contains(where: { $0.matchedText.caseInsensitiveCompare("Example Person") == .orderedSame }), "Failed to detect exact name")
        let standaloneJordanMatches = matches.filter {
            $0.matchedText.caseInsensitiveCompare("Jordan") == .orderedSame
        }
        try require(
            standaloneJordanMatches.count == 1,
            "Longest-match selection should suppress the embedded Jordan match but keep the standalone occurrence"
        )
        try require(
            matches.contains(where: { $0.matchedText.caseInsensitiveCompare("Alex & Jordan") == .orderedSame }),
            "Longest-match selection dropped the complete Alex & Jordan value"
        )
        let standalonePATI = matches.filter { $0.matchedText.caseInsensitiveCompare("PATI") == .orderedSame }
        try require(
            standalonePATI.count == 2,
            "Exact value PATI should match standalone tokens twice without matching inside Participation"
        )
        let joeFarmerMatches = matches.filter {
            $0.matchedText.uppercased() == joeFarmerVariant && $0.category == "Name variant"
        }
        try require(joeFarmerMatches.count == 1, "Joe Farmer variant should be detected exactly once, case-insensitively")
        try require(matches.filter({ $0.matchedText == "123456789" && $0.category.hasPrefix("SSN / ITIN compact") }).count == 1, "Failed compact SSN detection")
        try require(matches.contains(where: { $0.matchedText == "987654321" && $0.category.hasPrefix("EIN compact") }), "Failed to detect compact EIN variant")
        try require(matches.contains(where: { $0.matchedText == "98-7654321" }), "Failed to detect EIN")
        try require(matches.contains(where: { $0.matchedText == "alpha@example.com" }), "Failed to detect email")
        try require(matches.contains(where: { $0.matchedText == "(415) 555-0198" }), "Failed to detect phone")
        let accountSuffixes = matches
            .filter { $0.category.hasPrefix("Account suffix") }
            .map(\.matchedText)
        let expectedSuffixes = ["3436", "8891", "5077", "2396", "21807", "2759", "4985", "0684", "9550", "0421", "7788"]
        try require(Set(accountSuffixes) == Set(expectedSuffixes), "Account suffix detection mismatch: \(accountSuffixes)")
        try require(
            accountSuffixes.filter { $0 == "2759" }.count == 2,
            "CHARLES SCHWAB 2759 STC should be detected in addition to VANGUARD #2759"
        )
        try require(
            !accountSuffixes.contains("1040") && !accountSuffixes.contains("2025") &&
                !accountSuffixes.contains("8879") && !accountSuffixes.contains("777"),
            "Form number or tax year was mistaken for an account suffix"
        )

        let partialMaskedNameSearch = PDFMasker.scan(
            files: [source],
            exactTerms: ["Example P"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            matchExactWordBoundaries: false,
            progress: { _ in }
        )
        try require(
            partialMaskedNameSearch.count == 1,
            "Expected one partial-name search result; found \(partialMaskedNameSearch.count)"
        )
        try require(
            PDFMasker.searchResults(partialMaskedNameSearch, excludingSelectedMatches: matches).isEmpty,
            "Search listed text already covered by a selected mask"
        )
        var matchesWithExampleUnselected = matches
        if let index = matchesWithExampleUnselected.firstIndex(where: {
            $0.matchedText.caseInsensitiveCompare("Example Person") == .orderedSame
        }) {
            matchesWithExampleUnselected[index].isSelected = false
        }
        try require(
            PDFMasker.searchResults(
                partialMaskedNameSearch,
                excludingSelectedMatches: matchesWithExampleUnselected
            ).count == 1,
            "Search did not restore a result after its mask was unchecked"
        )

        let institutionNameSearch = PDFMasker.scan(
            files: [source],
            exactTerms: ["CHARLES SCHWAB"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        try require(
            PDFMasker.searchResults(institutionNameSearch, excludingSelectedMatches: matches).count == institutionNameSearch.count,
            "Masking an account suffix incorrectly hid its visible institution name from search"
        )

        let exceptionMatches = PDFMasker.scan(
            files: [source],
            exactTerms: [],
            options: PatternOptions(
                detectSSN: false,
                detectEIN: false,
                detectEmail: false,
                detectPhone: false,
                detectAccountSuffixes: true,
                accountSuffixExceptions: ["ally   bank 3436", "FIDELITY - 7788"]
            ),
            progress: { _ in }
        )
        let exceptionSuffixes = exceptionMatches
            .filter { $0.category.hasPrefix("Account suffix") }
            .map(\.matchedText)
        try require(!exceptionSuffixes.contains("3436"), "Native-text account suffix exception was ignored")
        try require(!exceptionSuffixes.contains("7788"), "OCR account suffix exception was ignored")
        try require(exceptionSuffixes.contains("8891"), "An unrelated account suffix was incorrectly excluded")

        let cachedSearchStarted = Date()
        let cachedSearch = PDFMasker.scan(
            files: [source],
            exactTerms: ["FIDELITY"],
            options: PatternOptions(
                detectSSN: false,
                detectEIN: false,
                detectEmail: false,
                detectPhone: false,
                generateNameVariants: false
            ),
            progress: { _ in }
        )
        try require(cachedSearch.contains(where: { $0.matchedText == "FIDELITY" }), "Cached OCR search missed a result")
        try require(-cachedSearchStarted.timeIntervalSinceNow < 2, "Cached OCR search was unexpectedly slow")

        var cancellationRequested = false
        let cancelledSearch = PDFMasker.scan(
            files: [source],
            exactTerms: ["MERRILL"],
            options: PatternOptions(
                detectSSN: false,
                detectEIN: false,
                detectEmail: false,
                detectPhone: false,
                generateNameVariants: false
            ),
            shouldCancel: { cancellationRequested },
            progress: { _ in cancellationRequested = true }
        )
        try require(cancelledSearch.isEmpty, "Cancelled search continued scanning later pages")

        let noNameVariants = PDFMasker.scan(
            files: [source],
            exactTerms: [fullFarmerName],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false, generateNameVariants: false),
            progress: { _ in }
        )
        try require(
            !noNameVariants.contains(where: { $0.matchedText.uppercased() == joeFarmerVariant }),
            "Joe Farmer should not be detected when name variants are disabled"
        )

        let boundaryMatches = PDFMasker.scan(
            files: [boundarySource],
            exactTerms: [],
            options: PatternOptions(detectSSN: true, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        try require(!boundaryMatches.contains(where: { $0.category.hasPrefix("SSN / ITIN compact") }), "Compact identifier matched inside a longer number")

        let replacements = [
            PDFMasker.normalizedReplacementKey(for: "Example Person"): "Client",
            PDFMasker.normalizedReplacementKey(for: "3436"): "Account 1",
            PDFMasker.normalizedReplacementKey(for: "555-66-7777"): "Tax ID"
        ]
        let replacementStyles = [
            PDFMasker.normalizedReplacementKey(for: "Example Person"): ReplacementLabelStyle(
                fontName: "Times-Bold",
                fontSize: 12,
                widthFraction: 0.75,
                alignment: .left
            ),
            PDFMasker.normalizedReplacementKey(for: "555-66-7777"): rotatedStyles[
                PDFMasker.normalizedReplacementKey(for: "555-66-7777")
            ]!
        ]
        if let preview = PDFMasker.previewImage(
            fileURL: source,
            pageIndex: 0,
            matches: matches,
            replacementsByValue: replacements,
            replacementStylesByValue: replacementStyles,
            dpi: 180
        ), let cgImage = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let representation = NSBitmapImageRep(cgImage: cgImage)
            if let data = representation.representation(using: .png, properties: [:]) {
                try data.write(to: root.appendingPathComponent("core-render-replacements.png"))
            }
        } else {
            throw TestFailure(description: "Could not render replacement-label preview")
        }

        let pathologicalRect = RedactionMatch(
            fileURL: source,
            pageIndex: 3,
            category: "Synthetic invalid rectangle",
            matchedText: "",
            rects: [CGRect(x: 0, y: 0, width: 612, height: 500)]
        )
        let created = try PDFMasker.exportSanitizedCopies(
            files: [source],
            matches: matches + [pathologicalRect],
            outputFolder: outputs,
            replacementsByValue: replacements,
            replacementStylesByValue: replacementStyles,
            progress: { _ in }
        )
        try require(created.count == 1, "Expected one output")
        guard let output = PDFDocument(url: created[0]) else { fatalError("Could not reopen output") }
        try require(output.pageCount == 5, "Expected five pages")
        try require((0..<output.pageCount).allSatisfy { (output.page(at: $0)?.string ?? "").isEmpty }, "Output still has a text layer")
        try require((0..<output.pageCount).allSatisfy { output.page(at: $0)?.annotations.isEmpty == true }, "Output still has annotations")

        let corruptOutput = root.appendingPathComponent("deliberately-corrupted-output.pdf")
        try makeVisuallyCorruptedPDF(at: corruptOutput, pageCount: 5)
        guard let sourceDocument = PDFDocument(url: source) else { fatalError("Could not reopen source") }
        let corruptFailure = PDFMasker.sanitizedOutputValidationFailure(
            corruptOutput,
            sourceDocument: sourceDocument,
            matches: matches + [pathologicalRect],
            replacementsByValue: replacements,
            replacementStylesByValue: replacementStyles
        )
        try require(corruptFailure != nil, "Visual validation accepted a half-corrupted PDF")
        try require(corruptFailure?.contains("page 1") == true, "Visual validation did not identify the corrupted page")

        let residual = PDFMasker.scan(
            files: created,
            exactTerms: ["Alex & Jordan", "Jordan", "PATI", "Example Person", fullFarmerName, joeFarmerVariant, "123-45-6789", "123456789", "444-55-6666", "555-66-7777", "98-7654321", "987654321", "alpha@example.com", "(415) 555-0198"] + expectedSuffixes,
            options: PatternOptions(detectSSN: true, detectEIN: true, detectEmail: true, detectPhone: true, generateNameVariants: true, detectAccountSuffixes: true),
            progress: { _ in }
        )
        try require(residual.isEmpty, "OCR found sensitive text after sanitization: \(residual.map(\.matchedText))")

        let preservedParticipation = PDFMasker.scan(
            files: created,
            exactTerms: ["Participation"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        try require(!preservedParticipation.isEmpty, "Word-boundary masking damaged Participation")

        let visibleLabels = PDFMasker.scan(
            files: created,
            exactTerms: ["Client"],
            options: PatternOptions(
                detectSSN: false,
                detectEIN: false,
                detectEmail: false,
                detectPhone: false
            ),
            progress: { _ in }
        )
        try require(!visibleLabels.isEmpty, "Replacement label was not visibly rendered into the output pixels")

        let preservedInstitutions = PDFMasker.scan(
            files: created,
            exactTerms: ["ALLY BANK", "CHARLES SCHWAB", "MERRILL LYNCH", "VANGUARD", "WEALTHFRONT", "NORTHSTAR", "FIDELITY"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        let preservedNames = Set(preservedInstitutions.map { $0.matchedText.uppercased() })
        for institution in ["ALLY BANK", "CHARLES SCHWAB", "MERRILL LYNCH", "VANGUARD", "WEALTHFRONT", "NORTHSTAR", "FIDELITY"] {
            try require(preservedNames.contains(institution), "Institution name was not preserved: \(institution)")
        }

        let preservedAmounts = PDFMasker.scan(
            files: created,
            exactTerms: ["4,277", "431", "88", "129", "254"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        let preservedAmountValues = Set(preservedAmounts.map(\.matchedText))
        for amount in ["4,277", "431", "88", "129", "254"] {
            try require(preservedAmountValues.contains(amount), "Table amount was not preserved: \(amount)")
        }

        let preservedAnnotation = PDFMasker.scan(
            files: created,
            exactTerms: ["VISIBLE ANNOTATION"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        try require(!preservedAnnotation.isEmpty, "Visible source annotation was not preserved in the sanitized pixels")

        report("PASS source=\(source.path)")
        report("PASS output=\(created[0].path)")
        report("PASS matches=\(matches.count) residual=\(residual.count)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func makeSamplePDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("No PDF consumer") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { fatalError("No PDF context") }

        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(mediaBox)
        drawText("Taxpayer: Example Person\nOwners: JOE AND MARY FARMER\nShort form: Joe Farmer\nHousehold: Alex & Jordan\nSeparate contact: Jordan\nCode: PATI\nAlias: (PATI)\nTopic: Participation\nSSN: 123-45-6789\nSSN copy: 123456789\nEIN: 98-7654321\nEIN copy: 987654321\nEmail: alpha@example.com\nPhone: (415) 555-0198", in: pdf, at: CGPoint(x: 72, y: 700), frameHeight: 390)
        pdf.endPDFPage()

        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(mediaBox)
        if let scan = makeScannedImage() {
            pdf.draw(scan, in: CGRect(x: 45, y: 270, width: 522, height: 250))
        }
        pdf.endPDFPage()

        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(mediaBox)
        drawText("ROTATED PAGE\nSSN: 555-66-7777", in: pdf, at: CGPoint(x: 72, y: 650))
        pdf.endPDFPage()

        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(mediaBox)
        drawText("ALLY BANK 3436\nCHARLES SCHWAB & CO., INC -8891\nCHARLES SCHWAB 5077\nMERRILL LYNCH - 2396\nMERRILL LYNCH 21807\nVANGUARD #2759\nWEALTHFRONT - 4985\nCHARLES SCHWAB 2759 STC\nALLY BANK 0684.......... $ 4,277.\nMERRILL LYNCH - 9550.......... 431.\nMERRILL LYNCH 2396.......... 32.\nNORTHSTAR 0421.......... 88.\nTOTAL 777.......... 88.\nHDFC BANK IN INDIA.......... 129.\nIDBI.......... 254.\nBLACKSTONE PRIVATE CREDIT FUND\nVANGUARD #2025\nFORM 1040\nINTERNAL REVENUE SERVICE FORM 8879\nTAX YEAR 2025", in: pdf, at: CGPoint(x: 72, y: 740), fontSize: 16, frameHeight: 500)
        pdf.endPDFPage()

        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(mediaBox)
        drawDenseTaxStylePage(in: pdf)
        pdf.endPDFPage()
        pdf.closePDF()

        if let document = PDFDocument(url: url) {
            if let page = document.page(at: 2) {
                page.rotation = 90
            }
            if let page = document.page(at: 0) {
                let annotation = PDFAnnotation(
                    bounds: CGRect(x: 72, y: 250, width: 280, height: 44),
                    forType: .freeText,
                    withProperties: nil
                )
                annotation.contents = "VISIBLE ANNOTATION"
                annotation.font = NSFont.boldSystemFont(ofSize: 20)
                annotation.fontColor = .black
                annotation.color = .clear
                annotation.interiorColor = .white
                page.addAnnotation(annotation)
            }
            document.write(to: url)
        }
    }

    private static func makeVisuallyCorruptedPDF(at url: URL, pageCount: Int) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("No PDF consumer") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { fatalError("No PDF context") }
        for pageIndex in 0..<pageCount {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(NSColor.white.cgColor)
            pdf.fill(mediaBox)
            if pageIndex == 0 {
                pdf.setFillColor(NSColor.black.cgColor)
                pdf.fill(CGRect(x: 0, y: 0, width: mediaBox.width, height: mediaBox.height * 0.55))
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    private static func drawDenseTaxStylePage(in context: CGContext) {
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 36, y: 36, width: 540, height: 720))
        drawText("FEDERAL INCOME TAX SUMMARY", in: context, at: CGPoint(x: 180, y: 740), fontSize: 11, frameHeight: 20)
        for column in 0..<3 {
            let x = CGFloat(54 + column * 178)
            for row in 0..<72 {
                let y = CGFloat(710 - row * 9)
                let label = "LINE \(row + 1): ITEMIZED VALUE $\(1000 + column * 100 + row).00"
                drawText(label, in: context, at: CGPoint(x: x, y: y), fontSize: 6.5, frameHeight: 9)
                if row.isMultiple(of: 8) {
                    context.setStrokeColor(NSColor(calibratedWhite: 0.72, alpha: 1).cgColor)
                    context.setLineWidth(0.35)
                    context.move(to: CGPoint(x: x, y: y - 1))
                    context.addLine(to: CGPoint(x: x + 160, y: y - 1))
                    context.strokePath()
                }
            }
        }
    }

    private static func makeBoundaryPDF(at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { fatalError("No PDF consumer") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { fatalError("No PDF context") }
        pdf.beginPDFPage(nil)
        pdf.setFillColor(NSColor.white.cgColor)
        pdf.fill(mediaBox)
        drawText("SSN: 123-45-6789\nLong number: 01234567890", in: pdf, at: CGPoint(x: 72, y: 700))
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private static func drawText(
        _ text: String,
        in context: CGContext,
        at point: CGPoint,
        fontSize: CGFloat = 20,
        frameHeight: CGFloat = 300
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: point.x, y: point.y - frameHeight, width: 470, height: frameHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func makeScannedImage() -> CGImage? {
        let width = 1400
        let height = 670
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        drawText("SCANNED FORM\nTax ID: 444-55-6666\nFIDELITY - 7788", in: context, at: CGPoint(x: 70, y: 300))
        return context.makeImage()
    }
}
