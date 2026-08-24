import AppKit
import Foundation
import PDFKit
import SwiftUI

@main
struct MaskerUISnapshot {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: masker-ui-snapshot input.pdf output.png")
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])

        let matches = PDFMasker.scan(
            files: [input],
            exactTerms: ["JOE AND MARY FARMER", "444-55-6666"],
            options: PatternOptions(
                detectSSN: true,
                detectEIN: true,
                detectEmail: true,
                detectPhone: true,
                generateNameVariants: true,
                detectAccountSuffixes: true
            ),
            progress: { _ in }
        )

        let defaultsSuite = "local.masker.snapshot.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: defaultsSuite) else {
            fatalError("Could not create isolated recent-file preferences")
        }
        testDefaults.removePersistentDomain(forName: defaultsSuite)
        defer { testDefaults.removePersistentDomain(forName: defaultsSuite) }

        let seedModel = MaskerModel(userDefaults: testDefaults)
        seedModel.addFiles([input])
        seedModel.exactValues = "JOE AND MARY FARMER\n444-55-6666"
        seedModel.stashMaskValuesForLoadedFiles()

        let model = MaskerModel(userDefaults: testDefaults)
        precondition(model.recentFiles == [input.standardizedFileURL], "Recent PDF was not restored")
        model.openRecentFile(input)
        precondition(
            model.exactValues == "JOE AND MARY FARMER\n444-55-6666",
            "Saved mask values were not restored with the recent PDF"
        )
        model.outputFolder = URL(fileURLWithPath: "/Users/example/Documents/Masked PDFs", isDirectory: true)
        model.detectEmail = true
        model.detectPhone = true
        model.generateNameVariants = true
        model.detectAccountSuffixes = true
        model.replaceWithLabels = true
        model.revealMaskedTextOnHover = true
        model.accountSuffixExceptions = "FORM 8879"
        var reviewMatches = matches
        if let index = reviewMatches.firstIndex(where: {
            $0.matchedText.caseInsensitiveCompare("Joe Farmer") == .orderedSame
        }) {
            reviewMatches[index].isSelected = false
        }
        model.matches = reviewMatches
        model.status = "Found \(matches.count) matches. Review the checked items before exporting."
        model.pdfSearchText = "FARMER"
        model.revealDetectedValues = true

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let size = NSSize(width: 1440, height: 950)
        let root = ContentView(model: model).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(4.0))
        hosting.layoutSubtreeIfNeeded()
        precondition(model.pdfSearchResultCount == 1, "Search should list only the unchecked Farmer result")
        precondition(model.stashedValueCount(for: input) == 2, "Recent PDF did not retain two mask values")
        let exportedData = try model.stashedMaskValuesJSON(for: input)
        let exportedValues = try JSONSerialization.jsonObject(with: exportedData) as? [String: Any]
        precondition(exportedValues?["format"] as? String == "masker-mask-values", "Mask-value export format is missing")
        precondition(exportedValues?["pdfFileName"] as? String == input.lastPathComponent, "Mask-value export has the wrong PDF name")
        precondition((exportedValues?["maskValues"] as? [String])?.count == 2, "Mask-value export did not include two values")
        precondition(exportedValues?["pdfPath"] == nil, "Mask-value export must not disclose the local PDF path")
        model.exactValues = ""
        model.stashMaskValuesForLoadedFiles()
        precondition(model.stashedValueCount(for: input) == 0, "Could not clear values before import test")
        let importedCount = try model.importStashedMaskValuesJSON(exportedData, for: input)
        precondition(importedCount == 2, "Mask-value import did not restore two values")
        precondition(
            model.exactValues == "JOE AND MARY FARMER\n444-55-6666",
            "Mask-value import did not restore the exact-value editor"
        )
        let exportedFile = output.deletingLastPathComponent().appendingPathComponent("roundtrip-mask-values.json")
        try exportedData.write(to: exportedFile, options: .atomic)
        model.exactValues = ""
        model.stashMaskValuesForLoadedFiles()
        let fileImportedCount = try model.importStashedMaskValuesFile(exportedFile, for: input)
        precondition(fileImportedCount == 2, "Mask-value file import did not restore two values")
        precondition(
            model.exactValues == "JOE AND MARY FARMER\n444-55-6666",
            "Mask-value file import did not restore the exact-value editor"
        )
        try? FileManager.default.removeItem(at: exportedFile)

        var mismatchedObject = exportedValues ?? [:]
        mismatchedObject["pdfFileName"] = "different-document.pdf"
        let mismatchedData = try JSONSerialization.data(withJSONObject: mismatchedObject)
        do {
            try model.importStashedMaskValuesJSON(mismatchedData, for: input)
            preconditionFailure("Mask-value import accepted a mismatched filename without confirmation")
        } catch { }

        var embeddedPDFView: PDFView?
        if let pdfView = findPDFView(in: hosting), let document = pdfView.document {
            embeddedPDFView = pdfView
            precondition(pdfView.displayMode == .singlePageContinuous, "PDF viewer is not continuous")
            let annotationCount = (0..<document.pageCount).reduce(0) {
                $0 + (document.page(at: $1)?.annotations.count ?? 0)
            }
            FileHandle.standardError.write(Data("PDFView pages=\(document.pageCount) annotations=\(annotationCount)\n".utf8))
            if let page = document.page(at: 0) {
                let thumbnail = page.thumbnail(of: NSSize(width: 918, height: 1188), for: .mediaBox)
                if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                    try data.write(to: output.deletingPathExtension().appendingPathExtension("page.png"))
                }
            }
        }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("Could not allocate snapshot bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode snapshot")
        }
        try png.write(to: output)
        if let pdfView = embeddedPDFView,
           let secondPage = pdfView.document?.page(at: 1) {
            pdfView.go(to: secondPage)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            precondition(model.currentPreviewPage == 1, "Match list did not follow PDF page navigation")
        }

        model.clearRecentFiles()
        let clearedModel = MaskerModel(userDefaults: testDefaults)
        precondition(clearedModel.recentFiles.isEmpty, "Clear did not remove recent PDFs")
        precondition(clearedModel.stashedValueCount(for: input) == 0, "Clear did not remove saved mask values")
        FileHandle.standardError.write(Data("PASS uiSnapshot=\(output.path) matches=\(matches.count)\n".utf8))
    }

    private static func findPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for subview in view.subviews {
            if let found = findPDFView(in: subview) { return found }
        }
        return nil
    }
}
