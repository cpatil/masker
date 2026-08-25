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
        let workflowStore = output.deletingLastPathComponent()
            .appendingPathComponent("workflow-store-\(UUID().uuidString)", isDirectory: true)
        setenv("MASKER_WORKFLOW_DIRECTORY", workflowStore.path, 1)
        defer {
            unsetenv("MASKER_WORKFLOW_DIRECTORY")
            try? FileManager.default.removeItem(at: workflowStore)
        }

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
        seedModel.setReplacementText("Client", for: "JOE AND MARY FARMER")
        seedModel.setReplacementFontName("Times-Bold", for: "JOE AND MARY FARMER")
        seedModel.setReplacementFontSize(12, for: "JOE AND MARY FARMER")
        seedModel.setReplacementWidthPercent(75, for: "JOE AND MARY FARMER")
        seedModel.setReplacementJustification("left", for: "JOE AND MARY FARMER")
        seedModel.stashMaskValuesForLoadedFiles()

        let model = MaskerModel(userDefaults: testDefaults)
        precondition(model.recentFiles == [input.standardizedFileURL], "Recent PDF was not restored")
        model.openRecentFile(input)
        precondition(
            model.exactValues == "JOE AND MARY FARMER\n444-55-6666",
            "Saved mask values were not restored with the recent PDF"
        )
        precondition(
            model.replacementText(for: "joe and mary farmer") == "Client",
            "Saved replacement label was not restored case-insensitively"
        )
        precondition(model.replacementFontName(for: "joe and mary farmer") == "Times-Bold", "Saved label font was not restored")
        precondition(model.replacementFontSize(for: "joe and mary farmer") == 12, "Saved label size was not restored")
        precondition(model.replacementWidthPercent(for: "joe and mary farmer") == 75, "Saved label width was not restored")
        precondition(model.replacementJustification(for: "joe and mary farmer") == "left", "Saved label alignment was not restored")
        model.outputFolder = URL(fileURLWithPath: "/Users/example/Documents/Masked PDFs", isDirectory: true)
        model.detectEmail = true
        model.detectPhone = true
        model.generateNameVariants = true
        model.detectAccountSuffixes = true
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
        app.appearance = NSAppearance(named: .aqua)
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
        let exportedData = try model.currentMaskSetJSON()
        let exportedValues = try JSONSerialization.jsonObject(with: exportedData) as? [String: Any]
        precondition(exportedValues?["format"] as? String == "masker-mask-set", "Generic mask-set export format is missing")
        precondition(exportedValues?["version"] as? Int == 1, "Mask-set export did not use schema v1")
        precondition(exportedValues?["pdfFileName"] == nil, "Generic mask-set export must not contain a PDF filename")
        precondition(exportedValues?["settings"] as? [String: Any] != nil, "Mask-set export did not include detector settings")
        let exportedMasks = exportedValues?["masks"] as? [[String: Any]]
        precondition(exportedMasks?.count == 2, "Mask-set export did not include two values")
        precondition(
            exportedMasks?.contains(where: {
                ($0["value"] as? String)?.caseInsensitiveCompare("JOE AND MARY FARMER") == .orderedSame &&
                    $0["replaceWith"] as? String == "Client" &&
                    $0["fontName"] as? String == "Times-Bold" &&
                    $0["fontSize"] as? Double == 12 &&
                    $0["widthPercent"] as? Double == 75 &&
                    $0["justification"] as? String == "left"
            }) == true,
            "Mask-set export did not carry the replacement mapping"
        )
        precondition(exportedValues?["pdfPath"] == nil, "Mask-set export must not disclose the local PDF path")
        model.exactValues = ""
        model.setReplacementText("", for: "JOE AND MARY FARMER")
        model.stashMaskValuesForLoadedFiles()
        precondition(model.stashedValueCount(for: input) == 0, "Could not clear values before import test")
        let importedCount = try model.importMaskSetJSON(exportedData)
        precondition(importedCount == 2, "Mask-set import did not restore two values")
        precondition(
            Set(model.exactValues.split(whereSeparator: \.isNewline).map(String.init)) ==
                Set(["JOE AND MARY FARMER", "444-55-6666"]),
            "Mask-set import did not restore the exact-value editor"
        )
        precondition(
            model.replacementText(for: "Joe And Mary Farmer") == "Client",
            "Mask-set import did not restore the replacement mapping"
        )
        precondition(model.replacementFontName(for: "Joe And Mary Farmer") == "Times-Bold", "Mask-value import did not restore the label font")
        precondition(model.replacementFontSize(for: "Joe And Mary Farmer") == 12, "Mask-value import did not restore the label size")
        precondition(model.replacementWidthPercent(for: "Joe And Mary Farmer") == 75, "Mask-value import did not restore the label width")
        precondition(model.replacementJustification(for: "Joe And Mary Farmer") == "left", "Mask-value import did not restore the label alignment")
        let exportedFile = output.deletingLastPathComponent().appendingPathComponent("roundtrip-mask-set.json")
        try exportedData.write(to: exportedFile, options: .atomic)
        model.exactValues = "JOE AND MARY FARMER\nLOCAL ONLY"
        model.setReplacementText("Local Client", for: "JOE AND MARY FARMER")
        model.stashMaskValuesForLoadedFiles()
        let fileImportedCount = try model.importMaskSetFile(exportedFile)
        precondition(fileImportedCount == 3, "Mask-set file import did not merge with existing values")
        precondition(
            Set(model.exactValues.split(whereSeparator: \.isNewline).map(String.init)) ==
                Set(["JOE AND MARY FARMER", "LOCAL ONLY", "444-55-6666"]),
            "Mask-set file import did not keep existing values while adding imported values"
        )
        precondition(
            model.replacementText(for: "Joe And Mary Farmer") == "Local Client",
            "Mask-set import overwrote an existing label"
        )
        for _ in 0..<3 {
            let repeatedCount = try model.importMaskSetFile(exportedFile)
            precondition(repeatedCount == 3, "Repeated mask-set import introduced duplicates")
        }
        let fillLabelModel = MaskerModel(userDefaults: testDefaults)
        fillLabelModel.exactValues = "JOE AND MARY FARMER"
        let fillLabelCount = try fillLabelModel.importMaskSetFile(exportedFile)
        precondition(fillLabelCount == 2, "Mask-set import did not merge into a prefilled editor")
        precondition(
            fillLabelModel.replacementText(for: "joe and mary farmer") == "Client",
            "Imported label did not fill an existing unlabeled value"
        )
        try? FileManager.default.removeItem(at: exportedFile)

        let legacyV2Object: [String: Any] = [
            "format": "masker-mask-values",
            "version": 2,
            "pdfFileName": "different-document.pdf",
            "masks": [["value": "LEGACY V2 VALUE", "replaceWith": "Imported Label"]]
        ]
        let legacyV2Data = try JSONSerialization.data(withJSONObject: legacyV2Object)
        let portableImportCount = try model.importMaskSetJSON(legacyV2Data)
        precondition(
            portableImportCount == 4 && model.replacementText(for: "legacy v2 value") == "Imported Label",
            "Legacy v2 mapping could not be merged as a generic mask set"
        )
        let legacyObject: [String: Any] = [
            "format": "masker-mask-values",
            "version": 1,
            "pdfFileName": "different-document.pdf",
            "maskValues": ["Legacy Value"]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyCount = try model.importMaskSetJSON(legacyData)
        precondition(legacyCount == 5, "Legacy v1 values did not merge into the generic mask set")

        if let pdfView = findPDFView(in: hosting), let document = pdfView.document {
            precondition(pdfView.displayMode == .singlePageContinuous, "PDF viewer is not continuous")
            let annotationCount = (0..<document.pageCount).reduce(0) {
                $0 + (document.page(at: $1)?.annotations.count ?? 0)
            }
            FileHandle.standardError.write(Data("PDFView pages=\(document.pageCount) annotations=\(annotationCount)\n".utf8))
            model.selectedMatchID = nil
            let target = reviewMatches.compactMap { match -> (PDFPage, CGRect)? in
                guard match.isSelected,
                      let displayRect = match.rects.first,
                      let page = document.page(at: match.pageIndex) else { return nil }
                let transform = page.transform(for: .mediaBox)
                let transformedBounds = page.bounds(for: .mediaBox).applying(transform).standardized
                let transformedRect = displayRect.offsetBy(
                    dx: transformedBounds.minX,
                    dy: transformedBounds.minY
                )
                return (page, transformedRect.applying(transform.inverted()).standardized)
            }.first
            guard let maskView = pdfView as? MaskPDFView,
                  let (clickPage, clickRect) = target else {
                preconditionFailure("Could not find a preview mask to click")
            }
            let clickPoint = pdfView.convert(
                CGPoint(x: clickRect.midX, y: clickRect.midY),
                from: clickPage
            )
            let clickHandled = maskView.simulateMaskClickForTesting(at: clickPoint)
            precondition(clickHandled, "Preview mask hit testing failed")
            precondition(model.selectedMatchID != nil, "Clicking a mask did not select its review row")
            FileHandle.standardError.write(Data("PASS maskClickSelection\n".utf8))

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

        model.pdfSearchText = "Example Person"
        model.addSearchTermAndRescan()
        let rescanDeadline = Date().addingTimeInterval(30)
        while model.isBusy, Date() < rescanDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        precondition(!model.isBusy, "Add & Rescan did not finish")
        precondition(
            model.matches.contains(where: {
                $0.matchedText.caseInsensitiveCompare("Example Person") == .orderedSame
            }),
            "Add & Rescan did not add the new exact value"
        )
        FileHandle.standardError.write(Data("PASS addAndRescanStableBindings\n".utf8))

        window.orderOut(nil)
        window.contentView = nil
        model.clearRecentFiles()
        let clearedModel = MaskerModel(userDefaults: testDefaults)
        precondition(clearedModel.recentFiles.isEmpty, "Clear did not remove recent PDFs")
        precondition(clearedModel.stashedValueCount(for: input) == 0, "Clear did not remove saved mask values")
        let workflowFolder = output.deletingLastPathComponent()
            .appendingPathComponent("workflow-fixture-\(UUID().uuidString)", isDirectory: true)
        let nestedFolder = workflowFolder.appendingPathComponent("nested/tax", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workflowFolder) }
        try FileManager.default.copyItem(
            at: input,
            to: workflowFolder.appendingPathComponent("first-generated-document.pdf")
        )
        try FileManager.default.copyItem(
            at: input,
            to: nestedFolder.appendingPathComponent("second-generated-document.pdf")
        )
        let workflowModel = MaskerModel(userDefaults: testDefaults)
        workflowModel.exactValues = "Example Person"
        workflowModel.startDiscovery(in: workflowFolder)
        precondition(workflowModel.discoverySession?.documents.count == 2, "Discovery did not enumerate nested PDFs")
        precondition(workflowModel.recentFiles.isEmpty, "Discovery leaked documents into Recents")
        precondition(workflowModel.discoveryActiveDocumentIndex == 0, "Discovery did not open the first PDF")
        workflowModel.openAdjacentDiscoveryDocument(offset: 1)
        precondition(
            workflowModel.discoveryActiveDocumentIndex == 1,
            "Discovery Next remained gated before scanning"
        )
        workflowModel.openAdjacentDiscoveryDocument(offset: -1)
        workflowModel.exactValues += "\nJOE AND MARY FARMER"
        workflowModel.stashMaskValuesForLoadedFiles()
        let restoredDiscovery = try WorkflowStore.load()
        precondition(
            restoredDiscovery?.masks.map(\.value).contains("JOE AND MARY FARMER") == true,
            "Discovery did not persist newly added mask values"
        )
        let reloadedWorkflowModel = MaskerModel(userDefaults: testDefaults)
        precondition(reloadedWorkflowModel.discoverySession?.documents.count == 2, "Discovery did not reload after restart")
        reloadedWorkflowModel.resumeDiscovery()
        precondition(reloadedWorkflowModel.isDiscoveryDocumentLoaded, "Resume Discovery did not reopen the saved PDF")
        precondition(
            reloadedWorkflowModel.exactValues.split(whereSeparator: \.isNewline).map(String.init).contains("JOE AND MARY FARMER"),
            "Resume Discovery did not restore the shared mask set"
        )

        let batchMaskSet = workflowFolder.appendingPathComponent("masker-mask-set.json")
        try reloadedWorkflowModel.currentMaskSetJSON().write(to: batchMaskSet, options: .atomic)
        let customOutput = workflowFolder.appendingPathComponent("Batch Output", isDirectory: true)
        reloadedWorkflowModel.runBatchConvert(
            inputFolder: workflowFolder,
            maskSetURL: batchMaskSet,
            outputFolder: customOutput
        )
        let batchDeadline = Date().addingTimeInterval(90)
        while reloadedWorkflowModel.isBusy, Date() < batchDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        precondition(!reloadedWorkflowModel.isBusy, "Batch Convert did not finish")
        precondition(reloadedWorkflowModel.batchConversionTotal == 2, "Batch Convert included its output folder or missed a nested PDF")
        precondition(reloadedWorkflowModel.batchConversionProcessed == 2, "Batch Convert did not process every PDF")
        precondition(reloadedWorkflowModel.batchConversionFailed == 0, "Batch Convert failed a generated PDF")
        precondition(
            FileManager.default.fileExists(atPath: customOutput.appendingPathComponent("first-generated-document_masked.pdf").path),
            "Batch Convert did not create the root-level output"
        )
        precondition(
            FileManager.default.fileExists(
                atPath: customOutput.appendingPathComponent("nested/tax/second-generated-document_masked.pdf").path
            ),
            "Batch Convert did not preserve the nested output hierarchy"
        )
        let publicStatusData = try Data(contentsOf: WorkflowStore.publicStatusURL)
        let publicStatusText = String(decoding: publicStatusData, as: UTF8.self)
        precondition(!publicStatusText.contains(workflowFolder.path), "MCP status leaked the workflow folder path")
        precondition(!publicStatusText.contains("Example Person"), "MCP status leaked a mask value")
        precondition(!publicStatusText.contains("first-generated-document"), "MCP status leaked a filename")
        FileHandle.standardError.write(Data("PASS discoveryAndBatchConversion\n".utf8))
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
