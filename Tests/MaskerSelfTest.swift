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
            exactTerms: ["Example Person", fullFarmerName, "444-55-6666", "555-66-7777"],
            options: PatternOptions(detectSSN: true, detectEIN: true, detectEmail: true, detectPhone: true, generateNameVariants: true, detectAccountSuffixes: true),
            progress: { _ in }
        )

        report("Detected: \(matches.map { "[\($0.category)] \($0.matchedText) rects=\($0.rects)" }.joined(separator: ", "))")

        let nativeSSNs = matches.filter { $0.matchedText == "123-45-6789" }
        let scannedSSNs = matches.filter { $0.matchedText == "444-55-6666" }
        let rotatedSSNs = matches.filter { $0.matchedText == "555-66-7777" }
        if !rotatedSSNs.isEmpty,
           let preview = PDFMasker.previewImage(fileURL: source, pageIndex: 2, matches: rotatedSSNs, dpi: 180),
           let cgImage = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let representation = NSBitmapImageRep(cgImage: cgImage)
            if let data = representation.representation(using: .png, properties: [:]) {
                try data.write(to: root.appendingPathComponent("core-render-rotated-masked.png"))
            }
        }
        try require(!nativeSSNs.isEmpty, "Failed to detect the native-text SSN")
        try require(!scannedSSNs.isEmpty, "Failed to detect the image-only SSN using OCR")
        try require(!rotatedSSNs.isEmpty, "Failed to detect the rotated-page SSN")
        try require(matches.contains(where: { $0.matchedText.caseInsensitiveCompare("Example Person") == .orderedSame }), "Failed to detect exact name")
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
        let expectedSuffixes = ["3436", "8891", "5077", "2396", "21807", "2759", "4985", "7788"]
        try require(Set(accountSuffixes) == Set(expectedSuffixes), "Account suffix detection mismatch: \(accountSuffixes)")
        try require(
            accountSuffixes.filter { $0 == "2759" }.count == 2,
            "CHARLES SCHWAB 2759 STC should be detected in addition to VANGUARD #2759"
        )
        try require(
            !accountSuffixes.contains("1040") && !accountSuffixes.contains("2025") && !accountSuffixes.contains("8879"),
            "Form number or tax year was mistaken for an account suffix"
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

        let created = try PDFMasker.exportSanitizedCopies(
            files: [source],
            matches: matches,
            outputFolder: outputs,
            dpi: 180,
            progress: { _ in }
        )
        try require(created.count == 1, "Expected one output")
        guard let output = PDFDocument(url: created[0]) else { fatalError("Could not reopen output") }
        try require(output.pageCount == 4, "Expected four pages")
        try require((0..<output.pageCount).allSatisfy { (output.page(at: $0)?.string ?? "").isEmpty }, "Output still has a text layer")
        try require((0..<output.pageCount).allSatisfy { output.page(at: $0)?.annotations.isEmpty == true }, "Output still has annotations")

        let residual = PDFMasker.scan(
            files: created,
            exactTerms: ["Example Person", fullFarmerName, joeFarmerVariant, "123-45-6789", "123456789", "444-55-6666", "555-66-7777", "98-7654321", "987654321", "alpha@example.com", "(415) 555-0198"] + expectedSuffixes,
            options: PatternOptions(detectSSN: true, detectEIN: true, detectEmail: true, detectPhone: true, generateNameVariants: true, detectAccountSuffixes: true),
            progress: { _ in }
        )
        try require(residual.isEmpty, "OCR found sensitive text after sanitization: \(residual.map(\.matchedText))")

        let preservedInstitutions = PDFMasker.scan(
            files: created,
            exactTerms: ["ALLY BANK", "CHARLES SCHWAB", "MERRILL LYNCH", "VANGUARD", "WEALTHFRONT", "FIDELITY"],
            options: PatternOptions(detectSSN: false, detectEIN: false, detectEmail: false, detectPhone: false),
            progress: { _ in }
        )
        let preservedNames = Set(preservedInstitutions.map { $0.matchedText.uppercased() })
        for institution in ["ALLY BANK", "CHARLES SCHWAB", "MERRILL LYNCH", "VANGUARD", "WEALTHFRONT", "FIDELITY"] {
            try require(preservedNames.contains(institution), "Institution name was not preserved: \(institution)")
        }

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
        drawText("Taxpayer: Example Person\nOwners: JOE AND MARY FARMER\nShort form: Joe Farmer\nSSN: 123-45-6789\nSSN copy: 123456789\nEIN: 98-7654321\nEIN copy: 987654321\nEmail: alpha@example.com\nPhone: (415) 555-0198", in: pdf, at: CGPoint(x: 72, y: 700))
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
        drawText("ALLY BANK 3436\nCHARLES SCHWAB & CO., INC -8891\nCHARLES SCHWAB 5077\nMERRILL LYNCH - 2396\nMERRILL LYNCH 21807\nVANGUARD #2759\nWEALTHFRONT - 4985\nCHARLES SCHWAB 2759 STC\nBLACKSTONE PRIVATE CREDIT FUND\nVANGUARD #2025\nFORM 1040\nINTERNAL REVENUE SERVICE FORM 8879\nTAX YEAR 2025", in: pdf, at: CGPoint(x: 72, y: 700))
        pdf.endPDFPage()
        pdf.closePDF()

        if let document = PDFDocument(url: url), let page = document.page(at: 2) {
            page.rotation = 90
            document.write(to: url)
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

    private static func drawText(_ text: String, in context: CGContext, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: point.x, y: point.y - 300, width: 470, height: 300), transform: nil)
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
