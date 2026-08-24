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
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/masker-self-test", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sample-tax-document.pdf")
        let outputs = root.appendingPathComponent("outputs", isDirectory: true)

        try makeSamplePDF(at: source)
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
            exactTerms: ["Example Person", "987-65-4321", "555-66-7777"],
            options: PatternOptions(detectSSN: true, detectEIN: true, detectEmail: true, detectPhone: true),
            progress: { _ in }
        )

        report("Detected: \(matches.map { "[\($0.category)] \($0.matchedText) rects=\($0.rects)" }.joined(separator: ", "))")

        let nativeSSNs = matches.filter { $0.matchedText == "123-45-6789" }
        let scannedSSNs = matches.filter { $0.matchedText == "987-65-4321" }
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
        try require(matches.contains(where: { $0.matchedText == "12-3456789" }), "Failed to detect EIN")
        try require(matches.contains(where: { $0.matchedText == "alpha@example.com" }), "Failed to detect email")
        try require(matches.contains(where: { $0.matchedText == "(415) 555-0198" }), "Failed to detect phone")

        let created = try PDFMasker.exportSanitizedCopies(
            files: [source],
            matches: matches,
            outputFolder: outputs,
            dpi: 180,
            progress: { _ in }
        )
        try require(created.count == 1, "Expected one output")
        guard let output = PDFDocument(url: created[0]) else { fatalError("Could not reopen output") }
        try require(output.pageCount == 3, "Expected three pages")
        try require((0..<output.pageCount).allSatisfy { (output.page(at: $0)?.string ?? "").isEmpty }, "Output still has a text layer")
        try require((0..<output.pageCount).allSatisfy { output.page(at: $0)?.annotations.isEmpty == true }, "Output still has annotations")

        let residual = PDFMasker.scan(
            files: created,
            exactTerms: ["Example Person", "123-45-6789", "987-65-4321", "555-66-7777", "12-3456789", "alpha@example.com", "(415) 555-0198"],
            options: PatternOptions(detectSSN: true, detectEIN: true, detectEmail: true, detectPhone: true),
            progress: { _ in }
        )
        try require(residual.isEmpty, "OCR found sensitive text after sanitization: \(residual.map(\.matchedText))")

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
        drawText("Taxpayer: Example Person\nSSN: 123-45-6789\nEIN: 12-3456789\nEmail: alpha@example.com\nPhone: (415) 555-0198", in: pdf, at: CGPoint(x: 72, y: 650))
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
        pdf.closePDF()

        if let document = PDFDocument(url: url), let page = document.page(at: 2) {
            page.rotation = 90
            document.write(to: url)
        }
    }

    private static func drawText(_ text: String, in context: CGContext, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: point.x, y: point.y - 180, width: 470, height: 180), transform: nil)
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
        drawText("SCANNED FORM\nTax ID: 987-65-4321", in: context, at: CGPoint(x: 70, y: 260))
        return context.makeImage()
    }
}
