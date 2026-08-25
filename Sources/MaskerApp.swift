import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if !SNAPSHOT_TEST
@main
struct MaskerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 940, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
#endif

private struct FilenameHoverTooltip: ViewModifier {
    let filename: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .overlay(alignment: .topLeading) {
                if isHovering {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                        )
                        .shadow(radius: 4, y: 2)
                        .offset(y: 24)
                        .allowsHitTesting(false)
                        .zIndex(100)
                }
            }
            .zIndex(isHovering ? 100 : 0)
    }
}

private extension View {
    func fullFilenameOnHover(_ filename: String) -> some View {
        modifier(FilenameHoverTooltip(filename: filename))
    }
}

final class MaskerModel: ObservableObject {
    private struct MaskSetExport: Codable {
        let format: String
        let version: Int
        let masks: [MaskValueEntry]
    }

    private struct MaskSetImport: Decodable {
        let format: String
        let version: Int
        let pdfFileName: String?
        let maskValues: [String]?
        let masks: [MaskValueEntry]?
    }

    private enum MaskSetImportError: LocalizedError {
        case invalidFormat
        case unsupportedVersion(Int)
        case noValues

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "This is not a Masker mask-set file."
            case .unsupportedVersion(let version):
                return "This mask-set file uses unsupported version \(version)."
            case .noValues:
                return "This file does not contain any mask values or labels."
            }
        }
    }

    private static let recentPDFPathsKey = "recentPDFPaths"
    private static let maskValuesByPDFPathKey = "maskValuesByPDFPath"
    private static let maskReplacementsByPDFPathKey = "maskReplacementsByPDFPath"
    private static let maximumRecentPDFs = 10
    static let replacementFonts: [(name: String, label: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"),
        ("Helvetica", "Helvetica"),
        ("Times-Bold", "Times Bold"),
        ("Times-Roman", "Times"),
        ("Courier-Bold", "Courier Bold"),
        ("Courier", "Courier")
    ]

    private let userDefaults: UserDefaults

    @Published var files: [URL] = []
    @Published private(set) var recentFiles: [URL] = []
    @Published var exactValues = ""
    @Published var detectSSN = true
    @Published var detectEIN = true
    @Published var detectEmail = false
    @Published var detectPhone = false
    @Published var generateNameVariants = false
    @Published var detectAccountSuffixes = false
    @Published var accountSuffixExceptions = ""
    @Published private var replacementEntriesByKey: [String: MaskValueEntry] = [:]
    @Published var matches: [RedactionMatch] = []
    @Published var selectedMatchID: UUID?
    @Published var activeFileURL: URL?
    @Published var currentPreviewPage = 0
    @Published var outputFolder: URL?
    @Published var isBusy = false
    @Published var status = "Drop PDFs here or choose files."
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var revealDetectedValues = false
    @Published var pdfSearchText = ""
    @Published var pdfSearchResultCount = 0
    @Published var pdfSearchResultIndex = 0
    @Published var pdfSearchIsBusy = false
    @Published var pdfSearchProgress = ""
    @Published var searchNavigationToken = 0
    @Published var searchNavigationDirection = 1
    @Published private(set) var privateBatchSession: PrivateBatchSession?

    private var lastScannedBatchDocumentID: String?
    private var lastScannedBatchMaskSetVersion: Int?
    private var publicStatusRevision = 0
    private var maskSetImportPanel: NSOpenPanel?

    var selectedCount: Int { matches.filter(\.isSelected).count }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedPaths = userDefaults.stringArray(forKey: Self.recentPDFPathsKey) ?? []
        recentFiles = storedPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter {
                $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame &&
                    FileManager.default.fileExists(atPath: $0.path)
            }
        persistRecentFiles()
        privateBatchSession = try? PrivateBatchStore.load()
        publishPrivateBatchStatus(userActionRequired: privateBatchSession == nil ? nil : "open_or_review_document")
    }

    var privateBatchActiveDocumentIndex: Int? {
        guard let session = privateBatchSession,
              let activeID = session.activeDocumentID else { return nil }
        return session.documents.firstIndex(where: { $0.id == activeID })
    }

    var privateBatchReviewedCount: Int {
        guard let session = privateBatchSession else { return 0 }
        return session.documents.filter { documentIsReviewed($0, in: session) }.count
    }

    var privateBatchCurrentIsReviewed: Bool {
        guard let session = privateBatchSession,
              let document = activePrivateBatchDocument(in: session) else { return false }
        return documentIsReviewed(document, in: session)
    }

    var privateBatchCurrentIsScanned: Bool {
        guard let session = privateBatchSession,
              let activeID = session.activeDocumentID else { return false }
        return lastScannedBatchDocumentID == activeID &&
            lastScannedBatchMaskSetVersion == session.maskSetVersion
    }

    var isPrivateBatchDocumentLoaded: Bool {
        guard let session = privateBatchSession,
              let document = activePrivateBatchDocument(in: session) else { return false }
        return activeFileURL?.standardizedFileURL.path == document.path
    }

    func beginPrivateBatchSelection() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Private PDF Folder"
        panel.prompt = "Create Private Batch"
        panel.message = "Masker reads PDFs locally. Codex receives only opaque document IDs and counts."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        publishPrivateBatchStatus(userActionRequired: "choose_folder_in_masker")
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let folder = panel.url else {
                self.publishPrivateBatchStatus(userActionRequired: "choose_folder_in_masker")
                return
            }
            self.startPrivateBatch(in: folder)
        }
    }

    func startPrivateBatch(in folder: URL) {
        do {
            let documents = try PrivateBatchStore.documents(in: folder.standardizedFileURL)
            let session = PrivateBatchSession.create(folder: folder, documents: documents)
            try PrivateBatchStore.save(session)
            privateBatchSession = nil
            exactValues = ""
            replacementEntriesByKey = [:]
            applyPrivateBatchSettings(session.settings)
            privateBatchSession = session
            try openPrivateBatchDocument(session.activeDocumentID ?? documents[0].id)
            status = "Created a private batch with \(documents.count) PDF\(documents.count == 1 ? "" : "s")."
            publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
        } catch {
            showError(error.localizedDescription)
            publishPrivateBatchStatus(userActionRequired: "choose_folder_in_masker")
        }
    }

    func resumePrivateBatch() {
        do {
            let savedSession = try PrivateBatchStore.load()
            guard let session = privateBatchSession ?? savedSession,
                  let documentID = session.activeDocumentID ?? session.documents.first?.id else {
                beginPrivateBatchSelection()
                return
            }
            privateBatchSession = session
            try openPrivateBatchDocument(documentID)
        } catch {
            showError(error.localizedDescription)
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    func handleControlURL(_ url: URL) {
        guard url.scheme == "masker", url.host == "private-batch" else {
            addFiles([url])
            return
        }
        let command = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let documentID = components?.queryItems?.first(where: { $0.name == "document" })?.value
        switch command {
        case "new":
            beginPrivateBatchSelection()
        case "resume":
            resumePrivateBatch()
        case "open":
            guard let documentID else {
                publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
                return
            }
            if let session = privateBatchSession,
               session.activeDocumentID != documentID,
               isPrivateBatchDocumentLoaded,
               !privateBatchCurrentIsReviewed {
                showError("Mark the current document reviewed before opening another private-batch document.")
                publishPrivateBatchStatus(userActionRequired: "mark_current_document_reviewed")
                return
            }
            do {
                try openPrivateBatchDocument(documentID)
                publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
            } catch {
                showError(error.localizedDescription)
                publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
            }
        case "scan":
            scan()
        case "review":
            markCurrentPrivateBatchDocumentReviewed()
        case "next":
            openAdjacentPrivateBatchDocument(offset: 1)
        case "previous":
            openAdjacentPrivateBatchDocument(offset: -1)
        case "begin-final":
            beginPrivateBatchFinalPass()
        case "export":
            export()
        default:
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    func openPrivateBatchDocument(_ documentID: String) throws {
        if let existing = privateBatchSession,
           let loadedDocument = activePrivateBatchDocument(in: existing),
           activeFileURL?.standardizedFileURL.path == loadedDocument.path {
            savePrivateBatchState()
        }
        guard var session = privateBatchSession,
              let index = session.documents.firstIndex(where: { $0.id == documentID }) else {
            throw PrivateBatchStoreError.invalidSession
        }
        let url = try PrivateBatchStore.validate(session.documents[index])
        session.activeDocumentID = documentID
        try PrivateBatchStore.save(session)
        privateBatchSession = session
        files = [url]
        activeFileURL = url
        currentPreviewPage = 0
        outputFolder = URL(fileURLWithPath: session.outputFolderPath, isDirectory: true)
        exactValues = session.masks.map(\.value).joined(separator: "\n")
        replacementEntriesByKey = Dictionary(uniqueKeysWithValues: session.masks.compactMap { entry in
            let key = PDFMasker.normalizedReplacementKey(for: entry.value)
            guard !key.isEmpty, !entry.replaceWith.isEmpty else { return nil }
            return (key, entry)
        })
        applyPrivateBatchSettings(session.settings)
        matches = []
        selectedMatchID = nil
        lastScannedBatchDocumentID = nil
        lastScannedBatchMaskSetVersion = nil
        status = "Opened \(url.lastPathComponent) from the private batch."
        publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
    }

    func openAdjacentPrivateBatchDocument(offset: Int) {
        guard let session = privateBatchSession,
              let currentIndex = privateBatchActiveDocumentIndex else { return }
        if offset > 0 && !privateBatchCurrentIsReviewed {
            showError("Mark the current document reviewed before advancing.")
            publishPrivateBatchStatus(userActionRequired: "mark_current_document_reviewed")
            return
        }
        let nextIndex = currentIndex + offset
        guard session.documents.indices.contains(nextIndex) else {
            let action = session.phase == .discovery ? "begin_final_pass" : "export_or_finish_batch"
            publishPrivateBatchStatus(userActionRequired: action)
            return
        }
        do {
            try openPrivateBatchDocument(session.documents[nextIndex].id)
        } catch {
            showError(error.localizedDescription)
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    func markCurrentPrivateBatchDocumentReviewed() {
        savePrivateBatchState()
        guard var session = privateBatchSession,
              let activeID = session.activeDocumentID,
              let index = session.documents.firstIndex(where: { $0.id == activeID }) else { return }
        guard privateBatchCurrentIsScanned else {
            showError("Scan the current document with the current mask set before marking it reviewed.")
            publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
            return
        }
        session.documents[index].excludedMatchFingerprints = matches
            .filter { !$0.isSelected && $0.fileURL.standardizedFileURL == activeFileURL?.standardizedFileURL }
            .map(matchFingerprint)
            .sorted()
        if session.phase == .discovery {
            session.documents[index].discoveryReviewedVersion = session.maskSetVersion
        } else {
            session.documents[index].finalReviewedVersion = session.maskSetVersion
        }
        do {
            try PrivateBatchStore.save(session)
            privateBatchSession = session
            status = "Marked the current private-batch document reviewed."
            let isLast = index == session.documents.count - 1
            publishPrivateBatchStatus(
                userActionRequired: isLast
                    ? (session.phase == .discovery ? "begin_final_pass" : "export_or_finish_batch")
                    : "open_next_document"
            )
        } catch {
            showError(error.localizedDescription)
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    func setOutputFolder(_ folder: URL) {
        outputFolder = folder.standardizedFileURL
        guard isPrivateBatchDocumentLoaded, var session = privateBatchSession else { return }
        session.outputFolderPath = folder.standardizedFileURL.path
        do {
            try PrivateBatchStore.save(session)
            privateBatchSession = session
            publishPrivateBatchStatus(userActionRequired: "review_and_mark_current_document")
        } catch {
            showError("The private-batch output folder could not be saved.")
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    func beginPrivateBatchFinalPass() {
        savePrivateBatchState()
        guard var session = privateBatchSession else { return }
        guard session.documents.allSatisfy({ $0.discoveryReviewedVersion != nil }) else {
            showError("Review every document at least once before beginning the final pass.")
            publishPrivateBatchStatus(userActionRequired: "finish_discovery_review")
            return
        }
        session.phase = .finalReview
        for index in session.documents.indices {
            session.documents[index].finalReviewedVersion = nil
            session.documents[index].exportedVersion = nil
        }
        session.activeDocumentID = session.documents.first?.id
        do {
            try PrivateBatchStore.save(session)
            privateBatchSession = session
            if let firstID = session.activeDocumentID {
                try openPrivateBatchDocument(firstID)
            }
            status = "Final pass started. Rescan, review, and export every document."
            publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
        } catch {
            showError(error.localizedDescription)
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    private func savePrivateBatchState() {
        guard isPrivateBatchDocumentLoaded, var session = privateBatchSession else { return }
        let masks = currentMaskEntries()
        let settings = currentPrivateBatchSettings()
        if masks != session.masks || settings != session.settings {
            session.masks = masks
            session.settings = settings
            session.maskSetVersion += 1
            lastScannedBatchDocumentID = nil
            lastScannedBatchMaskSetVersion = nil
        }
        do {
            try PrivateBatchStore.save(session)
            privateBatchSession = session
            publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
        } catch {
            status = "Could not save the private batch session."
            publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
        }
    }

    private func currentMaskEntries() -> [MaskValueEntry] {
        let values = exactValues
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var entries = values.compactMap { value -> MaskValueEntry? in
            let key = PDFMasker.normalizedReplacementKey(for: value)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            var entry = replacementEntriesByKey[key] ?? MaskValueEntry(value: value, replaceWith: "")
            entry.value = value
            return entry
        }
        entries.append(contentsOf: replacementEntriesByKey.values.filter {
            seen.insert(PDFMasker.normalizedReplacementKey(for: $0.value)).inserted
        })
        return entries.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
    }

    private func currentPrivateBatchSettings() -> PrivateBatchPatternSettings {
        PrivateBatchPatternSettings(
            detectSSN: detectSSN,
            detectEIN: detectEIN,
            detectEmail: detectEmail,
            detectPhone: detectPhone,
            generateNameVariants: generateNameVariants,
            detectAccountSuffixes: detectAccountSuffixes,
            accountSuffixExceptions: accountSuffixExceptions
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func applyPrivateBatchSettings(_ settings: PrivateBatchPatternSettings) {
        detectSSN = settings.detectSSN
        detectEIN = settings.detectEIN
        detectEmail = settings.detectEmail
        detectPhone = settings.detectPhone
        generateNameVariants = settings.generateNameVariants
        detectAccountSuffixes = settings.detectAccountSuffixes
        accountSuffixExceptions = settings.accountSuffixExceptions.joined(separator: "\n")
    }

    private func activePrivateBatchDocument(in session: PrivateBatchSession) -> PrivateBatchDocument? {
        guard let activeID = session.activeDocumentID else { return nil }
        return session.documents.first(where: { $0.id == activeID })
    }

    private func documentIsReviewed(_ document: PrivateBatchDocument, in session: PrivateBatchSession) -> Bool {
        if session.phase == .discovery {
            return document.discoveryReviewedVersion != nil
        }
        return document.finalReviewedVersion == session.maskSetVersion
    }

    private func matchFingerprint(_ match: RedactionMatch) -> String {
        let rectangles = match.rects.map { rect in
            [rect.minX, rect.minY, rect.width, rect.height]
                .map { String(format: "%.1f", $0) }
                .joined(separator: ",")
        }.sorted().joined(separator: ";")
        return [
            String(match.pageIndex),
            match.category,
            PDFMasker.normalizedReplacementKey(for: match.matchedText),
            String(match.textRotationDegrees),
            rectangles
        ].joined(separator: "|")
    }

    private func applySavedPrivateBatchDecisions(to found: inout [RedactionMatch]) {
        guard let session = privateBatchSession,
              let document = activePrivateBatchDocument(in: session) else { return }
        let excluded = Set(document.excludedMatchFingerprints)
        guard !excluded.isEmpty else { return }
        for index in found.indices where excluded.contains(matchFingerprint(found[index])) {
            found[index].isSelected = false
        }
    }

    private func publishPrivateBatchStatus(userActionRequired: String?) {
        publicStatusRevision += 1
        guard let session = privateBatchSession else {
            let publicStatus = PrivateBatchPublicStatus(
                format: "masker-mcp-status",
                version: 1,
                revision: publicStatusRevision,
                state: "idle",
                sessionID: nil,
                phase: nil,
                documentCount: 0,
                documents: [],
                activeDocumentID: nil,
                activeDocumentIndex: nil,
                maskSetVersion: nil,
                reviewedCount: 0,
                staleCount: 0,
                exportedCount: 0,
                currentReviewed: false,
                currentScanned: false,
                matchCount: nil,
                selectedMatchCount: nil,
                busy: false,
                userActionRequired: userActionRequired
            )
            try? PrivateBatchStore.savePublicStatus(publicStatus)
            return
        }
        let documentStatuses = session.documents.enumerated().map { index, document in
            let reviewedVersion = session.phase == .discovery
                ? document.discoveryReviewedVersion
                : document.finalReviewedVersion
            let state: String
            if document.exportedVersion == session.maskSetVersion {
                state = "exported"
            } else if reviewedVersion == session.maskSetVersion {
                state = "reviewed"
            } else if reviewedVersion != nil {
                state = "stale"
            } else {
                state = "unreviewed"
            }
            return PrivateBatchPublicDocumentStatus(id: document.id, index: index + 1, state: state)
        }
        let activeIndex = privateBatchActiveDocumentIndex
        let reviewedCount = documentStatuses.filter { $0.state == "reviewed" || $0.state == "exported" }.count
        let staleCount = documentStatuses.filter { $0.state == "stale" }.count
        let exportedCount = documentStatuses.filter { $0.state == "exported" }.count
        let scanned = privateBatchCurrentIsScanned
        let publicStatus = PrivateBatchPublicStatus(
            format: "masker-mcp-status",
            version: 1,
            revision: publicStatusRevision,
            state: isBusy ? "busy" : "ready",
            sessionID: session.id,
            phase: session.phase.rawValue,
            documentCount: session.documents.count,
            documents: documentStatuses,
            activeDocumentID: session.activeDocumentID,
            activeDocumentIndex: activeIndex.map { $0 + 1 },
            maskSetVersion: session.maskSetVersion,
            reviewedCount: reviewedCount,
            staleCount: staleCount,
            exportedCount: exportedCount,
            currentReviewed: privateBatchCurrentIsReviewed,
            currentScanned: scanned,
            matchCount: scanned ? matches.count : nil,
            selectedMatchCount: scanned ? selectedCount : nil,
            busy: isBusy,
            userActionRequired: userActionRequired
        )
        try? PrivateBatchStore.savePublicStatus(publicStatus)
    }

    func addFiles(_ urls: [URL]) {
        let pdfs = urls
            .map(\.standardizedFileURL)
            .filter { $0.pathExtension.lowercased() == "pdf" }
        let wasEmpty = files.isEmpty
        for url in pdfs where !files.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            files.append(url)
        }
        rememberRecentFiles(pdfs)
        if wasEmpty {
            if pdfs.count == 1 {
                exactValues = storedMaskValues(for: pdfs[0]) ?? ""
                replacementEntriesByKey = storedReplacementEntries(for: pdfs[0])
            } else {
                replacementEntriesByKey = [:]
            }
        }
        if outputFolder == nil, let first = files.first {
            outputFolder = first.deletingLastPathComponent().appendingPathComponent("Masked PDFs", isDirectory: true)
        }
        if activeFileURL == nil { activeFileURL = files.first }
        matches = []
        selectedMatchID = nil
        status = files.isEmpty ? "No PDF files selected." : "Ready to scan \(files.count) PDF\(files.count == 1 ? "" : "s")."
    }

    func openRecentFile(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            forgetRecentFile(standardized)
            showError("That recent PDF has been moved or deleted.")
            return
        }

        stashMaskValuesForLoadedFiles()
        files = [standardized]
        matches = []
        selectedMatchID = nil
        activeFileURL = standardized
        currentPreviewPage = 0
        outputFolder = standardized.deletingLastPathComponent().appendingPathComponent("Masked PDFs", isDirectory: true)
        exactValues = storedMaskValues(for: standardized) ?? ""
        replacementEntriesByKey = storedReplacementEntries(for: standardized)
        rememberRecentFiles([standardized])
        status = "Restored recent PDF and its saved mask values. Ready to scan."
    }

    func stashMaskValuesForLoadedFiles() {
        if let session = privateBatchSession,
           let loadedDocument = activePrivateBatchDocument(in: session),
           activeFileURL?.standardizedFileURL.path == loadedDocument.path {
            savePrivateBatchState()
            return
        }
        guard !files.isEmpty else { return }
        var stored = userDefaults.dictionary(forKey: Self.maskValuesByPDFPathKey) as? [String: String] ?? [:]
        var storedReplacements = userDefaults.dictionary(
            forKey: Self.maskReplacementsByPDFPathKey
        ) as? [String: String] ?? [:]
        let encodedReplacements = encodedReplacementEntries(replacementEntriesByKey)
        for file in files {
            let path = file.standardizedFileURL.path
            if exactValues.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stored.removeValue(forKey: path)
            } else {
                stored[path] = exactValues
            }
            if let encodedReplacements {
                storedReplacements[path] = encodedReplacements
            } else {
                storedReplacements.removeValue(forKey: path)
            }
        }
        userDefaults.set(stored, forKey: Self.maskValuesByPDFPathKey)
        userDefaults.set(storedReplacements, forKey: Self.maskReplacementsByPDFPathKey)
    }

    func stashedValueCount(for file: URL) -> Int {
        let exactKeys = Set((storedMaskValues(for: file) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { PDFMasker.normalizedReplacementKey(for: String($0)) }
            .filter { !$0.isEmpty })
        return exactKeys.union(storedReplacementEntries(for: file).keys).count
    }

    var maskSetValueCount: Int { currentMaskEntries().count }

    func currentMaskSetJSON() throws -> Data {
        let masks = currentMaskEntries()
        guard !masks.isEmpty else { throw MaskSetImportError.noValues }
        let payload = MaskSetExport(format: "masker-mask-set", version: 1, masks: masks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    func exportCurrentMaskSet() {
        guard maskSetValueCount > 0 else {
            showError("Add at least one mask value or label before exporting the set.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Mask Set"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "masker-mask-set.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try currentMaskSetJSON().write(to: destination, options: .atomic)
            status = "Exported the mask set to \(destination.lastPathComponent)."
        } catch {
            showError("Could not export the mask set: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func importMaskSetJSON(_ data: Data) throws -> Int {
        let payload = try JSONDecoder().decode(MaskSetImport.self, from: data)

        var seen = Set<String>()
        let importedEntries: [MaskValueEntry]
        if payload.format == "masker-mask-set" {
            guard payload.version == 1 else {
                throw MaskSetImportError.unsupportedVersion(payload.version)
            }
            importedEntries = payload.masks ?? []
        } else if payload.format == "masker-mask-values", payload.version == 1 {
            importedEntries = (payload.maskValues ?? []).map {
                MaskValueEntry(value: $0, replaceWith: "")
            }
        } else if payload.format == "masker-mask-values", payload.version == 2 {
            importedEntries = payload.masks ?? []
        } else if payload.format == "masker-mask-values" {
            throw MaskSetImportError.unsupportedVersion(payload.version)
        } else {
            throw MaskSetImportError.invalidFormat
        }
        let entries = importedEntries.compactMap { raw -> MaskValueEntry? in
            let value = raw.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = PDFMasker.normalizedReplacementKey(for: value)
            guard !value.isEmpty, seen.insert(key).inserted else { return nil }
            return MaskValueEntry(
                value: value,
                replaceWith: raw.replaceWith.trimmingCharacters(in: .whitespacesAndNewlines),
                fontName: normalizedReplacementFont(raw.fontName),
                fontSize: raw.fontSize.map { min(max($0, 4), 24) },
                widthPercent: raw.widthPercent.map { min(max($0, 35), 100) },
                justification: ReplacementLabelAlignment(rawValue: raw.justification ?? "")?.rawValue
            )
        }
        guard !entries.isEmpty else { throw MaskSetImportError.noValues }

        var mergedByKey = Dictionary(uniqueKeysWithValues: currentMaskEntries().map {
            (PDFMasker.normalizedReplacementKey(for: $0.value), $0)
        })
        var addedCount = 0
        var filledLabelCount = 0
        for entry in entries {
            let key = PDFMasker.normalizedReplacementKey(for: entry.value)
            if var existing = mergedByKey[key] {
                if existing.replaceWith.isEmpty, !entry.replaceWith.isEmpty {
                    existing.replaceWith = entry.replaceWith
                    existing.fontName = entry.fontName
                    existing.fontSize = entry.fontSize
                    existing.widthPercent = entry.widthPercent
                    existing.justification = entry.justification
                    mergedByKey[key] = existing
                    filledLabelCount += 1
                }
            } else {
                mergedByKey[key] = entry
                addedCount += 1
            }
        }
        let merged = mergedByKey.values.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
        let joined = merged.map(\.value).joined(separator: "\n")
        let replacements = Dictionary(uniqueKeysWithValues: merged.compactMap { entry -> (String, MaskValueEntry)? in
            guard !entry.replaceWith.isEmpty else { return nil }
            return (PDFMasker.normalizedReplacementKey(for: entry.value), entry)
        })
        exactValues = joined
        replacementEntriesByKey = replacements
        matches = []
        selectedMatchID = nil
        stashMaskValuesForLoadedFiles()
        let labelSummary = filledLabelCount == 0 ? "" : " and filled \(filledLabelCount) label\(filledLabelCount == 1 ? "" : "s")"
        status = "Imported \(addedCount) new value\(addedCount == 1 ? "" : "s")\(labelSummary). \(merged.count) total."
        return merged.count
    }

    func importMaskSet() {
        guard maskSetImportPanel == nil else {
            maskSetImportPanel?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Mask Set"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        maskSetImportPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            defer { self.maskSetImportPanel = nil }
            guard response == .OK, let source = panel.url else { return }
            do {
                try self.importMaskSetFile(source)
            } catch {
                self.showError("Could not import the mask set: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func importMaskSetFile(_ source: URL) throws -> Int {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        return try importMaskSetJSON(data)
    }

    func forgetRecentFile(_ url: URL) {
        let path = url.standardizedFileURL.path
        recentFiles.removeAll { $0.standardizedFileURL.path == path }
        persistRecentFiles()
        var stored = userDefaults.dictionary(forKey: Self.maskValuesByPDFPathKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: path)
        userDefaults.set(stored, forKey: Self.maskValuesByPDFPathKey)
        var storedReplacements = userDefaults.dictionary(
            forKey: Self.maskReplacementsByPDFPathKey
        ) as? [String: String] ?? [:]
        storedReplacements.removeValue(forKey: path)
        userDefaults.set(storedReplacements, forKey: Self.maskReplacementsByPDFPathKey)
    }

    func clearRecentFiles() {
        recentFiles = []
        userDefaults.removeObject(forKey: Self.recentPDFPathsKey)
        userDefaults.removeObject(forKey: Self.maskValuesByPDFPathKey)
        userDefaults.removeObject(forKey: Self.maskReplacementsByPDFPathKey)
    }

    func removeFile(_ url: URL) {
        files.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        matches.removeAll { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
        if activeFileURL?.standardizedFileURL == url.standardizedFileURL {
            activeFileURL = files.first
            currentPreviewPage = 0
        }
        status = files.isEmpty ? "Drop PDFs here or choose files." : "Ready to scan."
    }

    func scan() {
        guard !files.isEmpty else {
            showError("Add at least one PDF first.")
            return
        }
        let terms = exactValues
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let options = PatternOptions(
            detectSSN: detectSSN,
            detectEIN: detectEIN,
            detectEmail: detectEmail,
            detectPhone: detectPhone,
            generateNameVariants: generateNameVariants,
            detectAccountSuffixes: detectAccountSuffixes,
            accountSuffixExceptions: accountSuffixExceptions
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let inputFiles = files
        stashMaskValuesForLoadedFiles()
        let previouslyActiveFile = activeFileURL
        let previousPage = currentPreviewPage

        isBusy = true
        matches = []
        status = "Starting local scan..."
        publishPrivateBatchStatus(userActionRequired: nil)

        DispatchQueue.global(qos: .userInitiated).async {
            let found = PDFMasker.scan(files: inputFiles, exactTerms: terms, options: options) { message in
                DispatchQueue.main.async { self.status = message }
            }
            DispatchQueue.main.async {
                var reviewed = found
                self.applySavedPrivateBatchDecisions(to: &reviewed)
                self.matches = reviewed
                self.selectedMatchID = reviewed.first?.id
                if let previous = previouslyActiveFile,
                   inputFiles.contains(where: { $0.standardizedFileURL == previous.standardizedFileURL }) {
                    self.activeFileURL = previous
                    self.currentPreviewPage = previousPage
                } else {
                    self.activeFileURL = found.first?.fileURL ?? inputFiles.first
                    self.currentPreviewPage = 0
                }
                self.isBusy = false
                if let session = self.privateBatchSession, self.isPrivateBatchDocumentLoaded {
                    self.lastScannedBatchDocumentID = session.activeDocumentID
                    self.lastScannedBatchMaskSetVersion = session.maskSetVersion
                }
                self.status = reviewed.isEmpty
                    ? "No matches found. Check spelling or whether the PDF is readable."
                    : "Found \(reviewed.count) match\(reviewed.count == 1 ? "" : "es"). Review the checked items before exporting."
                self.publishPrivateBatchStatus(userActionRequired: "review_and_mark_current_document")
            }
        }
    }

    func export() {
        guard selectedCount > 0 else {
            showError("Select at least one detected match to mask.")
            return
        }
        guard let folder = outputFolder else {
            showError("Choose an output folder.")
            return
        }
        if let session = privateBatchSession, isPrivateBatchDocumentLoaded {
            guard session.phase == .finalReview else {
                showError("Begin the final pass before exporting private-batch documents.")
                publishPrivateBatchStatus(userActionRequired: "begin_final_pass")
                return
            }
            guard privateBatchCurrentIsReviewed, privateBatchCurrentIsScanned else {
                showError("Rescan and mark the current document reviewed before exporting it.")
                publishPrivateBatchStatus(userActionRequired: "scan_and_review_current_document")
                return
            }
        }

        let inputFiles = files
        let reviewedMatches = matches
        let replacements = replacementsByValue
        let replacementStyles = replacementStylesByValue
        isBusy = true
        status = "Preparing sanitized copies..."
        publishPrivateBatchStatus(userActionRequired: nil)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outputs = try PDFMasker.exportSanitizedCopies(
                    files: inputFiles,
                    matches: reviewedMatches,
                    outputFolder: folder,
                    replacementsByValue: replacements,
                    replacementStylesByValue: replacementStyles
                ) { message in
                    DispatchQueue.main.async { self.status = message }
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    if var session = self.privateBatchSession,
                       let activeID = session.activeDocumentID,
                       let index = session.documents.firstIndex(where: { $0.id == activeID }) {
                        session.documents[index].exportedVersion = session.maskSetVersion
                        try? PrivateBatchStore.save(session)
                        self.privateBatchSession = session
                    }
                    self.status = "Created and validated \(outputs.count) sanitized PDF\(outputs.count == 1 ? "" : "s") in \(folder.path)."
                    self.publishPrivateBatchStatus(userActionRequired: "open_next_document")
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showError(error.localizedDescription)
                    self.publishPrivateBatchStatus(userActionRequired: "resolve_error_in_masker")
                }
            }
        }
    }

    func selectAll(_ selected: Bool) {
        for index in matches.indices { matches[index].isSelected = selected }
        publishPrivateBatchStatus(userActionRequired: "review_and_mark_current_document")
    }

    func matchIsSelected(_ id: UUID) -> Bool {
        matches.first(where: { $0.id == id })?.isSelected ?? false
    }

    func setMatchSelected(_ selected: Bool, id: UUID) {
        guard let index = matches.firstIndex(where: { $0.id == id }) else { return }
        matches[index].isSelected = selected
        publishPrivateBatchStatus(userActionRequired: "review_and_mark_current_document")
    }

    var replacementsByValue: [String: String] {
        replacementEntriesByKey.mapValues(\.replaceWith)
    }

    var replacementStylesByValue: [String: ReplacementLabelStyle] {
        replacementEntriesByKey.mapValues { entry in
            ReplacementLabelStyle(
                fontName: normalizedReplacementFont(entry.fontName) ?? "Helvetica-Bold",
                fontSize: entry.fontSize.map { CGFloat($0) },
                widthFraction: CGFloat((entry.widthPercent ?? 100) / 100),
                alignment: ReplacementLabelAlignment(rawValue: entry.justification ?? "") ?? .center
            ).normalized
        }
    }

    func replacementText(for value: String) -> String {
        replacementEntriesByKey[PDFMasker.normalizedReplacementKey(for: value)]?.replaceWith ?? ""
    }

    func setReplacementText(_ text: String, for value: String) {
        let key = PDFMasker.normalizedReplacementKey(for: value)
        guard !key.isEmpty else { return }
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            replacementEntriesByKey.removeValue(forKey: key)
        } else {
            var entry = replacementEntriesByKey[key] ?? MaskValueEntry(value: value, replaceWith: label)
            entry.value = value
            entry.replaceWith = label
            replacementEntriesByKey[key] = entry
        }
        stashMaskValuesForLoadedFiles()
    }

    func replacementFontName(for value: String) -> String {
        normalizedReplacementFont(
            replacementEntriesByKey[PDFMasker.normalizedReplacementKey(for: value)]?.fontName
        ) ?? "Helvetica-Bold"
    }

    func replacementFontSize(for value: String) -> Double {
        replacementEntriesByKey[PDFMasker.normalizedReplacementKey(for: value)]?.fontSize ?? 0
    }

    func replacementWidthPercent(for value: String) -> Double {
        replacementEntriesByKey[PDFMasker.normalizedReplacementKey(for: value)]?.widthPercent ?? 100
    }

    func replacementJustification(for value: String) -> String {
        let raw = replacementEntriesByKey[
            PDFMasker.normalizedReplacementKey(for: value)
        ]?.justification ?? ""
        return ReplacementLabelAlignment(rawValue: raw)?.rawValue ?? ReplacementLabelAlignment.center.rawValue
    }

    func setReplacementFontName(_ fontName: String, for value: String) {
        updateReplacementEntry(for: value) { $0.fontName = normalizedReplacementFont(fontName) }
    }

    func setReplacementFontSize(_ fontSize: Double, for value: String) {
        updateReplacementEntry(for: value) {
            $0.fontSize = fontSize == 0 ? nil : min(max(fontSize, 4), 24)
        }
    }

    func setReplacementWidthPercent(_ widthPercent: Double, for value: String) {
        updateReplacementEntry(for: value) { $0.widthPercent = min(max(widthPercent, 35), 100) }
    }

    func setReplacementJustification(_ justification: String, for value: String) {
        updateReplacementEntry(for: value) {
            $0.justification = ReplacementLabelAlignment(rawValue: justification)?.rawValue
        }
    }

    private func updateReplacementEntry(
        for value: String,
        update: (inout MaskValueEntry) -> Void
    ) {
        let key = PDFMasker.normalizedReplacementKey(for: value)
        guard !key.isEmpty, var entry = replacementEntriesByKey[key], !entry.replaceWith.isEmpty else { return }
        update(&entry)
        replacementEntriesByKey[key] = entry
        stashMaskValuesForLoadedFiles()
    }

    private func normalizedReplacementFont(_ fontName: String?) -> String? {
        guard let fontName,
              Self.replacementFonts.contains(where: { $0.name == fontName }) else { return nil }
        return fontName
    }

    func selectCurrentPage(_ selected: Bool) {
        guard let file = activeFileURL else { return }
        for index in matches.indices where
            matches[index].fileURL.standardizedFileURL == file.standardizedFileURL &&
            matches[index].pageIndex == currentPreviewPage {
            matches[index].isSelected = selected
        }
        publishPrivateBatchStatus(userActionRequired: "review_and_mark_current_document")
    }

    func showFile(_ file: URL) {
        activeFileURL = file
        currentPreviewPage = 0
        pdfSearchResultCount = 0
        pdfSearchResultIndex = 0
        pdfSearchIsBusy = false
        pdfSearchProgress = ""
    }

    func navigateSearch(_ direction: Int) {
        searchNavigationDirection = direction
        searchNavigationToken += 1
    }

    func addSearchTermAndRescan() {
        let term = pdfSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let existing = exactValues
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            if !exactValues.isEmpty, !exactValues.hasSuffix("\n") { exactValues += "\n" }
            exactValues += term
        }
        scan()
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
        status = message
    }

    private func rememberRecentFiles(_ urls: [URL]) {
        for url in urls.reversed() {
            let standardized = url.standardizedFileURL
            recentFiles.removeAll { $0.standardizedFileURL.path == standardized.path }
            recentFiles.insert(standardized, at: 0)
        }
        recentFiles = Array(recentFiles.prefix(Self.maximumRecentPDFs))
        persistRecentFiles()
    }

    private func persistRecentFiles() {
        userDefaults.set(recentFiles.map { $0.standardizedFileURL.path }, forKey: Self.recentPDFPathsKey)
    }

    private func storedMaskValues(for file: URL) -> String? {
        let stored = userDefaults.dictionary(forKey: Self.maskValuesByPDFPathKey) as? [String: String]
        return stored?[file.standardizedFileURL.path]
    }

    private func storedReplacementEntries(for file: URL) -> [String: MaskValueEntry] {
        guard let stored = userDefaults.dictionary(
            forKey: Self.maskReplacementsByPDFPathKey
        ) as? [String: String],
              let encoded = stored[file.standardizedFileURL.path],
              let data = encoded.data(using: .utf8),
              let entries = try? JSONDecoder().decode([MaskValueEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            let key = PDFMasker.normalizedReplacementKey(for: entry.value)
            guard !key.isEmpty, !entry.replaceWith.isEmpty else { return nil }
            return (key, entry)
        })
    }

    private func encodedReplacementEntries(_ entries: [String: MaskValueEntry]) -> String? {
        let values = entries.values.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
        guard !values.isEmpty,
              let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ContentView: View {
    @StateObject private var model = MaskerModel()
    @State private var isDropTargeted = false
    @State private var recentPDFsExpanded = true

    init(model: MaskerModel = MaskerModel()) {
        _model = StateObject(wrappedValue: model)
    }

    private var displayedVersion: String {
#if SNAPSHOT_TEST
        if let snapshotVersion = ProcessInfo.processInfo.environment["MASKER_SNAPSHOT_VERSION"],
           !snapshotVersion.isEmpty {
            return snapshotVersion
        }
#endif
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "v\(version) (\($0))" } ?? "v\(version)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                controls
                    .frame(minWidth: 310, idealWidth: 340, maxWidth: 390)
                review
                    .frame(minWidth: 560)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Masker", isPresented: $model.showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage)
        }
        .onOpenURL { url in model.handleControlURL(url) }
        .onReceive(
            model.$exactValues
                .dropFirst()
                .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
        ) { _ in
            model.stashMaskValuesForLoadedFiles()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Masker")
                        .font(.title2.weight(.semibold))
                    Text(displayedVersion)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text("Permanent, local PDF redaction")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Offline", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("1. Add PDFs") {
                    VStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                                )
                            VStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                Text("Drop PDFs here")
                                    .font(.headline)
                                HStack(spacing: 8) {
                                    Button("Choose PDFs...") { choosePDFs() }
                                    Button {
                                        model.beginPrivateBatchSelection()
                                    } label: {
                                        Label("Private Batch...", systemImage: "folder.badge.gearshape")
                                    }
                                    .help("Review a folder of private PDFs with one shared mask set")
                                    Button {
                                        withAnimation { recentPDFsExpanded.toggle() }
                                    } label: {
                                        Label("Recents", systemImage: "clock")
                                    }
                                    .help("Reopen a PDF and restore its locally remembered mask set")
                                }
                            }
                        }
                        .frame(height: 120)
                        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }

                        ForEach(model.files, id: \.path) { file in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.red)
                                Text(file.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .fullFilenameOnHover(file.lastPathComponent)
                                Spacer()
                                Button {
                                    model.removeFile(file)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.callout)
                        }

                        if model.files.count > 1 {
                            Text("\(model.files.count) PDFs selected. They share one scan and mask set, but export as separate PDF files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let session = model.privateBatchSession {
                            Divider()
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label("Private batch", systemImage: "lock.shield")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(session.phase == .discovery ? "Discovery" : "Final pass")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                if let index = model.privateBatchActiveDocumentIndex {
                                    Text("Document \(index + 1) of \(session.documents.count) · mask set v\(session.maskSetVersion)")
                                        .font(.caption)
                                }
                                Text("\(model.privateBatchReviewedCount) reviewed")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !model.isPrivateBatchDocumentLoaded {
                                    Button("Resume Private Batch") { model.resumePrivateBatch() }
                                        .controlSize(.small)
                                } else {
                                    HStack(spacing: 6) {
                                    Button {
                                        model.openAdjacentPrivateBatchDocument(offset: -1)
                                    } label: {
                                        Image(systemName: "chevron.left")
                                    }
                                    .disabled((model.privateBatchActiveDocumentIndex ?? 0) == 0)
                                    Button("Mark Reviewed") {
                                        model.markCurrentPrivateBatchDocumentReviewed()
                                    }
                                    .disabled(!model.privateBatchCurrentIsScanned || model.isBusy)
                                    Button {
                                        model.openAdjacentPrivateBatchDocument(offset: 1)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                    }
                                    .disabled(!model.privateBatchCurrentIsReviewed ||
                                        model.privateBatchActiveDocumentIndex == session.documents.count - 1)
                                    if session.phase == .discovery {
                                        Spacer()
                                        Button("Final Pass") { model.beginPrivateBatchFinalPass() }
                                    }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }

                        if recentPDFsExpanded {
                            Divider()
                            HStack {
                                Text("Recent PDFs")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") { model.clearRecentFiles() }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .disabled(model.recentFiles.isEmpty)
                            }

                            if model.recentFiles.isEmpty {
                                Text("No recent PDFs yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(model.recentFiles.prefix(6), id: \.path) { file in
                                HStack(spacing: 7) {
                                    Button {
                                        model.openRecentFile(file)
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(file.lastPathComponent)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .fullFilenameOnHover(file.lastPathComponent)
                                                let count = model.stashedValueCount(for: file)
                                                Text("\(count) saved mask value\(count == 1 ? "" : "s")")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        model.forgetRecentFile(file)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Forget this recent PDF and its saved mask values")
                                }
                                .font(.callout)
                            }

                            Text("Recent paths and exact values are stored only on this Mac.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }

                GroupBox("2. Choose what to mask") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Mask set")
                                        .font(.callout.weight(.medium))
                                    Text("Portable values, labels, and label appearance")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    model.importMaskSet()
                                } label: {
                                    Label("Import", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Import a generic Masker mask-set JSON file")
                                Button {
                                    model.exportCurrentMaskSet()
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.maskSetValueCount == 0)
                                .help("Export the current values and labels as a generic JSON mask set")
                            }
                            Text("Exact values - one per line")
                                .font(.caption.weight(.medium))
                            TextEditor(text: $model.exactValues)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 90)
                                .padding(5)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            Text("Examples: full name, street address, account number")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Divider()
                            Toggle("SSN / ITIN", isOn: $model.detectSSN)
                            Toggle("Employer ID (EIN)", isOn: $model.detectEIN)
                            Toggle("Email addresses", isOn: $model.detectEmail)
                            Toggle("US phone numbers", isOn: $model.detectPhone)
                            Toggle("Institution account suffixes", isOn: $model.detectAccountSuffixes)
                            Text("Opt-in: masks only a trailing 3-8 digit identifier on institution-like lines. Names remain visible.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.detectAccountSuffixes {
                                Text("Never auto-mask lines containing - one per line")
                                    .font(.caption.weight(.medium))
                                TextEditor(text: $model.accountSuffixExceptions)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 58)
                                    .padding(4)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                                Text("Example: FORM 8879. This exception applies only to the account-suffix detector.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Toggle("First + last name variants", isOn: $model.generateNameVariants)
                            Text("Opt-in: a value such as “JOE AND MARY FARMER” also searches for “JOE FARMER.” Review these matches carefully.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 5)
                    }
                    .frame(height: 310)
                }

                Button {
                    model.scan()
                } label: {
                    Label("Scan PDFs Locally", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.files.isEmpty || model.isBusy)

                Text("Nothing is uploaded. Image-only pages are read using Apple's on-device OCR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var review: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3. Review and search")
                        .font(.headline)
                    Text("The match list follows the page currently in view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let activeFile = model.activeFileURL {
                    Menu {
                        ForEach(model.files, id: \.path) { file in
                            Button {
                                model.showFile(file)
                            } label: {
                                if file.standardizedFileURL == activeFile.standardizedFileURL {
                                    Label(file.lastPathComponent, systemImage: "checkmark")
                                } else {
                                    Text(file.lastPathComponent)
                                }
                            }
                        }
                    } label: {
                        Label(activeFile.lastPathComponent, systemImage: "doc")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 280)
                    .fullFilenameOnHover(activeFile.lastPathComponent)
                }
            }
            .padding(14)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Matches on page \(model.currentPreviewPage + 1)")
                        .font(.callout.weight(.semibold))
                    Text("\(currentMatches.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer()
                    if !model.matches.isEmpty {
                        Toggle("Reveal values", isOn: $model.revealDetectedValues)
                            .toggleStyle(.checkbox)
                        Button("Page: All") { model.selectCurrentPage(true) }
                            .disabled(currentMatches.isEmpty)
                        Button("Page: None") { model.selectCurrentPage(false) }
                            .disabled(currentMatches.isEmpty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if currentMatches.isEmpty {
                                HStack {
                                    Image(systemName: model.matches.isEmpty ? "magnifyingglass" : "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                    Text(model.matches.isEmpty ? "Scan the PDFs to detect matches." : "No detected matches on this page.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(14)
                            } else {
                                ForEach(currentMatches) { match in
                                    let matchID = match.id
                                    HStack(spacing: 10) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(model.selectedMatchID == matchID ? Color.accentColor : Color.clear)
                                            .frame(width: 3)
                                        Toggle(
                                            "",
                                            isOn: Binding(
                                                get: { model.matchIsSelected(matchID) },
                                                set: { model.setMatchSelected($0, id: matchID) }
                                            )
                                        )
                                            .labelsHidden()
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(match.category)
                                                .font(.callout.weight(.semibold))
                                            Text(match.matchedText)
                                                .font(.system(.callout, design: .monospaced))
                                                .lineLimit(1)
                                                .redacted(reason: model.revealDetectedValues ? [] : .privacy)
                                        }
                                        Spacer()
                                        TextField(
                                            "Replace with",
                                            text: Binding(
                                                get: { model.replacementText(for: match.matchedText) },
                                                set: { model.setReplacementText($0, for: match.matchedText) }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                        .frame(width: 112)
                                        .help("Optional label rendered inside the black mask")
                                        Menu {
                                            Picker(
                                                "Font",
                                                selection: Binding(
                                                    get: { model.replacementFontName(for: match.matchedText) },
                                                    set: { model.setReplacementFontName($0, for: match.matchedText) }
                                                )
                                            ) {
                                                ForEach(Array(MaskerModel.replacementFonts.enumerated()), id: \.offset) { _, font in
                                                    Text(font.label).tag(font.name)
                                                }
                                            }
                                            Picker(
                                                "Maximum size",
                                                selection: Binding(
                                                    get: { model.replacementFontSize(for: match.matchedText) },
                                                    set: { model.setReplacementFontSize($0, for: match.matchedText) }
                                                )
                                            ) {
                                                Text("Auto").tag(0.0)
                                                ForEach([6.0, 8.0, 10.0, 12.0, 16.0], id: \.self) { size in
                                                    Text("\(Int(size)) pt").tag(size)
                                                }
                                            }
                                            Picker(
                                                "Label width",
                                                selection: Binding(
                                                    get: { model.replacementWidthPercent(for: match.matchedText) },
                                                    set: { model.setReplacementWidthPercent($0, for: match.matchedText) }
                                                )
                                            ) {
                                                ForEach([50.0, 75.0, 100.0], id: \.self) { width in
                                                    Text("\(Int(width))%").tag(width)
                                                }
                                            }
                                            Picker(
                                                "Alignment",
                                                selection: Binding(
                                                    get: { model.replacementJustification(for: match.matchedText) },
                                                    set: { model.setReplacementJustification($0, for: match.matchedText) }
                                                )
                                            ) {
                                                Label("Left", systemImage: "text.alignleft").tag(ReplacementLabelAlignment.left.rawValue)
                                                Label("Center", systemImage: "text.aligncenter").tag(ReplacementLabelAlignment.center.rawValue)
                                                Label("Right", systemImage: "text.alignright").tag(ReplacementLabelAlignment.right.rawValue)
                                            }
                                        } label: {
                                            Image(systemName: "textformat")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                        .disabled(model.replacementText(for: match.matchedText).isEmpty)
                                        .help("Label font, maximum size, width, and alignment")
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(model.selectedMatchID == matchID ? Color.accentColor.opacity(0.14) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectedMatchID = matchID }
                                    .id(matchID)
                                    Divider()
                                        .padding(.leading, 42)
                                }
                            }
                        }
                    }
                    .onReceive(model.$selectedMatchID.removeDuplicates()) { matchID in
                        guard let matchID else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(matchID, anchor: .center)
                        }
                    }
                }
                .frame(height: 150)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this PDF", text: $model.pdfSearchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.navigateSearch(1) }
                if model.pdfSearchIsBusy {
                    ProgressView()
                        .controlSize(.small)
                    if !model.pdfSearchProgress.isEmpty {
                        Text(model.pdfSearchProgress)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else if model.pdfSearchResultCount > 0 {
                    Text("\(model.pdfSearchResultIndex + 1) of \(model.pdfSearchResultCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else if !model.pdfSearchText.isEmpty {
                    Text("No results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button { model.navigateSearch(-1) } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous result")
                .disabled(model.pdfSearchResultCount == 0)
                Button { model.navigateSearch(1) } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next result")
                .disabled(model.pdfSearchResultCount == 0)
                Button {
                    model.addSearchTermAndRescan()
                } label: {
                    Label("Add & Rescan", systemImage: "plus")
                }
                .disabled(model.pdfSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            Group {
                if let activeFile = model.activeFileURL {
                    ContinuousPDFView(
                        fileURL: activeFile,
                        matches: model.matches.filter { $0.fileURL.standardizedFileURL == activeFile.standardizedFileURL },
                        replacementsByValue: model.replacementsByValue,
                        replacementStylesByValue: model.replacementStylesByValue,
                        currentPage: $model.currentPreviewPage,
                        selectedMatchID: $model.selectedMatchID,
                        searchText: model.pdfSearchText,
                        searchResultCount: $model.pdfSearchResultCount,
                        searchResultIndex: $model.pdfSearchResultIndex,
                        searchIsBusy: $model.pdfSearchIsBusy,
                        searchProgress: $model.pdfSearchProgress,
                        navigationToken: model.searchNavigationToken,
                        navigationDirection: model.searchNavigationDirection
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc")
                            .font(.system(size: 42))
                            .foregroundStyle(.tertiary)
                        Text("Add a PDF to begin")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 260)

            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Output folder")
                        .font(.caption.weight(.medium))
                    Text(model.outputFolder?.path ?? "Not selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change...") { chooseOutputFolder() }
                Button {
                    model.export()
                } label: {
                    Label(
                        model.files.count > 1
                            ? "Create \(model.files.count) Sanitized Copies"
                            : "Create Sanitized Copy",
                        systemImage: "lock.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCount == 0 || model.isBusy)
            }
            .padding(14)
        }
    }

    private var currentMatches: [RedactionMatch] {
        guard let file = model.activeFileURL else { return [] }
        return model.matches.filter {
            $0.fileURL.standardizedFileURL == file.standardizedFileURL &&
            $0.pageIndex == model.currentPreviewPage
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Text(model.status)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            if !model.matches.isEmpty {
                Text("\(model.selectedCount) of \(model.matches.count) selected")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func choosePDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.addFiles(panel.urls) }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folder = panel.url { model.setOutputFolder(folder) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                if let url {
                    DispatchQueue.main.async { model.addFiles([url]) }
                }
            }
        }
        return handled
    }
}

#if SNAPSHOT_TEST
final class MaskPDFView: PDFView {
    var maskPointHandlerForTesting: ((CGPoint) -> Bool)?

    func simulateMaskClickForTesting(at point: CGPoint) -> Bool {
        maskPointHandlerForTesting?(point) ?? false
    }
}
#else
typealias MaskPDFView = PDFView
#endif

private final class MaskLabelPreviewAnnotation: PDFAnnotation {
    private let label: String
    private let rotationDegrees: Int
    private let labelStyle: ReplacementLabelStyle

    init(
        bounds: CGRect,
        label: String,
        rotationDegrees: Int,
        style: ReplacementLabelStyle
    ) {
        self.label = label
        self.rotationDegrees = rotationDegrees
        self.labelStyle = style
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
        color = .clear
        interiorColor = .clear
        let clearBorder = PDFBorder()
        clearBorder.lineWidth = 0
        border = clearBorder
    }

    required init?(coder: NSCoder) {
        label = ""
        rotationDegrees = 0
        labelStyle = .standard
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        PDFMasker.drawReplacementLabel(
            label,
            in: bounds,
            context: context,
            rotationDegrees: rotationDegrees,
            style: labelStyle
        )
    }
}

struct ContinuousPDFView: NSViewRepresentable {
    let fileURL: URL
    let matches: [RedactionMatch]
    let replacementsByValue: [String: String]
    let replacementStylesByValue: [String: ReplacementLabelStyle]
    @Binding var currentPage: Int
    @Binding var selectedMatchID: UUID?
    let searchText: String
    @Binding var searchResultCount: Int
    @Binding var searchResultIndex: Int
    @Binding var searchIsBusy: Bool
    @Binding var searchProgress: String
    let navigationToken: Int
    let navigationDirection: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = MaskPDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        pdfView.backgroundColor = .underPageBackgroundColor
        context.coordinator.attach(to: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateDocumentIfNeeded(
            fileURL: fileURL,
            matches: matches,
            replacementsByValue: replacementsByValue,
            replacementStylesByValue: replacementStylesByValue,
            requestedPage: currentPage
        )
        context.coordinator.updateSearchIfNeeded(searchText)
        context.coordinator.navigateIfNeeded(token: navigationToken, direction: navigationDirection)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        private final class SearchCancellation {
            private let lock = NSLock()
            private var cancelled = false

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }

            func cancel() {
                lock.lock()
                cancelled = true
                lock.unlock()
            }
        }

        private struct PreviewMaskGroup {
            let page: PDFPage
            let hitRects: [CGRect]
        }

        var parent: ContinuousPDFView
        private weak var pdfView: PDFView?
        private var pageObserver: NSObjectProtocol?
        private var clickMonitor: Any?
        private var previewMasks: [UUID: PreviewMaskGroup] = [:]
        private var documentSignature = ""
        private var loadedFilePath = ""
        private var lastSearchText = ""
        private var searchWorkItem: DispatchWorkItem?
        private var searchCancellation: SearchCancellation?
        private var searchGeneration = 0
        private var searchResults: [RedactionMatch] = []
        private var searchAnnotations: [(PDFPage, PDFAnnotation)] = []
        private var currentSearchIndex = 0
        private var lastNavigationToken = 0

        init(parent: ContinuousPDFView) {
            self.parent = parent
            super.init()
        }

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
#if SNAPSHOT_TEST
            (pdfView as? MaskPDFView)?.maskPointHandlerForTesting = { [weak self] point in
                self?.handleMaskClick(at: point) ?? false
            }
#endif
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                return self.handleMaskClick(event) ? nil : event
            }
            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                self?.pageDidChange()
            }
        }

        func detach() {
            searchWorkItem?.cancel()
            searchCancellation?.cancel()
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
#if SNAPSHOT_TEST
            (pdfView as? MaskPDFView)?.maskPointHandlerForTesting = nil
#endif
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
        }

        func updateDocumentIfNeeded(
            fileURL: URL,
            matches: [RedactionMatch],
            replacementsByValue: [String: String],
            replacementStylesByValue: [String: ReplacementLabelStyle],
            requestedPage: Int
        ) {
            guard let pdfView else { return }
            let filePath = fileURL.standardizedFileURL.path
            let matchPart = matches
                .map { "\($0.id.uuidString):\($0.isSelected ? 1 : 0)" }
                .joined(separator: "|")
            let replacementPart = replacementsByValue
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "|")
            let stylePart = replacementStylesByValue
                .sorted { $0.key < $1.key }
                .map { key, style in
                    "\(key)=\(style.fontName),\(style.fontSize ?? 0),\(style.widthFraction),\(style.alignment.rawValue)"
                }
                .joined(separator: "|")
            let signature = filePath + "|" + matchPart + "|" + replacementPart + "|" + stylePart

            if signature != documentSignature {
                previewMasks = [:]
                searchWorkItem?.cancel()
                searchCancellation?.cancel()
                searchGeneration += 1
                let visiblePage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
                let targetPage = loadedFilePath == filePath ? (visiblePage ?? requestedPage) : requestedPage
                guard let data = try? Data(contentsOf: fileURL), let document = PDFDocument(data: data) else { return }
                addRedactionAnnotations(
                    matches.filter(\.isSelected),
                    replacementsByValue: replacementsByValue,
                    replacementStylesByValue: replacementStylesByValue,
                    to: document
                )
                documentSignature = signature
                loadedFilePath = filePath
                pdfView.document = document
                searchAnnotations = []
                pdfView.autoScales = true
                for pageIndex in Set(matches.filter(\.isSelected).map(\.pageIndex)) {
                    if let page = document.page(at: pageIndex) {
                        page.displaysAnnotations = true
                        pdfView.annotationsChanged(on: page)
                    }
                }
                goToPage(targetPage)
                lastSearchText = ""
            } else if let document = pdfView.document,
                      let visible = pdfView.currentPage.map({ document.index(for: $0) }),
                      visible != requestedPage,
                      requestedPage >= 0,
                      requestedPage < document.pageCount {
                goToPage(requestedPage)
            }
        }

        private func handleMaskClick(_ event: NSEvent) -> Bool {
            guard let pdfView,
                  event.window === pdfView.window else { return false }
            let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
            return handleMaskClick(at: viewPoint)
        }

        private func handleMaskClick(at viewPoint: CGPoint) -> Bool {
            guard let pdfView,
                  pdfView.bounds.contains(viewPoint),
                  pdfView.document != nil,
                  let page = pdfView.page(for: viewPoint, nearest: true) else { return false }
            let pagePoint = pdfView.convert(viewPoint, to: page)
            let candidates = previewMasks.filter { _, group in
                group.page === page && group.hitRects.contains(where: { $0.contains(pagePoint) })
            }
            let matchID = candidates.min { lhs, rhs in
                let leftArea = lhs.value.hitRects.map { $0.width * $0.height }.min() ?? .greatestFiniteMagnitude
                let rightArea = rhs.value.hitRects.map { $0.width * $0.height }.min() ?? .greatestFiniteMagnitude
                return leftArea < rightArea
            }?.key
            guard let matchID else { return false }
            selectMask(matchID, on: page)
            return true
        }

        private func selectMask(_ matchID: UUID, on page: PDFPage) {
            if let document = pdfView?.document {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound { parent.currentPage = pageIndex }
            }
            parent.selectedMatchID = matchID
        }

        func updateSearchIfNeeded(_ query: String) {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized != lastSearchText else { return }
            lastSearchText = normalized
            searchWorkItem?.cancel()
            searchCancellation?.cancel()
            searchGeneration += 1
            let generation = searchGeneration

            guard !normalized.isEmpty else {
                searchResults = []
                currentSearchIndex = 0
                clearSearchAnnotations()
                parent.searchProgress = ""
                publishSearchState(isBusy: false)
                return
            }

            searchResults = []
            currentSearchIndex = 0
            clearSearchAnnotations()
            parent.searchProgress = "Preparing..."
            publishSearchState(isBusy: true)
            let cancellation = SearchCancellation()
            searchCancellation = cancellation
            let work = DispatchWorkItem { [weak self] in
                self?.performSearch(normalized, generation: generation, cancellation: cancellation)
            }
            searchWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        func navigateIfNeeded(token: Int, direction: Int) {
            guard token != lastNavigationToken else { return }
            lastNavigationToken = token
            guard !searchResults.isEmpty else { return }
            currentSearchIndex = (currentSearchIndex + direction + searchResults.count) % searchResults.count
            showCurrentSearchResult()
        }

        private func performSearch(
            _ query: String,
            generation: Int,
            cancellation: SearchCancellation
        ) {
            guard query == lastSearchText,
                  generation == searchGeneration,
                  !cancellation.isCancelled else { return }
            let fileURL = parent.fileURL
            let selectedMatches = parent.matches.filter(\.isSelected)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let scanned = PDFMasker.scan(
                    files: [fileURL],
                    exactTerms: [query],
                    options: PatternOptions(
                        detectSSN: false,
                        detectEIN: false,
                        detectEmail: false,
                        detectPhone: false,
                        generateNameVariants: false
                    ),
                    matchExactWordBoundaries: false,
                    shouldCancel: { cancellation.isCancelled },
                    progress: { message in
                        let label: String
                        if let pageRange = message.range(of: ", page ") {
                            label = "Page " + message[pageRange.upperBound...]
                        } else {
                            label = "Searching..."
                        }
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  generation == self.searchGeneration,
                                  !cancellation.isCancelled else { return }
                            self.parent.searchProgress = label
                        }
                    }
                )
                let found = PDFMasker.searchResults(
                    scanned,
                    excludingSelectedMatches: selectedMatches
                )
                DispatchQueue.main.async {
                    guard let self,
                          generation == self.searchGeneration,
                          !cancellation.isCancelled,
                          query == self.lastSearchText,
                          fileURL.standardizedFileURL.path == self.loadedFilePath else { return }
                    self.searchResults = found
                    self.currentSearchIndex = 0
                    self.installSearchAnnotations()
                    self.parent.searchProgress = ""
                    self.publishSearchState(isBusy: false)
                    if !found.isEmpty { self.showCurrentSearchResult() }
                }
            }
        }

        private func showCurrentSearchResult() {
            guard let pdfView, searchResults.indices.contains(currentSearchIndex) else { return }
            let result = searchResults[currentSearchIndex]
            guard let page = pdfView.document?.page(at: result.pageIndex) else { return }
            pdfView.go(to: page)
            publishSearchState(isBusy: false)
        }

        private func publishSearchState(isBusy: Bool) {
            let count = searchResults.count
            let index = currentSearchIndex
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.searchResultCount != count { self.parent.searchResultCount = count }
                if self.parent.searchResultIndex != index { self.parent.searchResultIndex = index }
                if self.parent.searchIsBusy != isBusy { self.parent.searchIsBusy = isBusy }
            }
        }

        private func pageDidChange() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else { return }
            let index = document.index(for: page)
            guard index != NSNotFound, index != parent.currentPage else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.currentPage = index
            }
        }

        private func goToPage(_ index: Int) {
            guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
            let clamped = min(max(index, 0), document.pageCount - 1)
            if let page = document.page(at: clamped) { pdfView.go(to: page) }
        }

        private func addRedactionAnnotations(
            _ matches: [RedactionMatch],
            replacementsByValue: [String: String],
            replacementStylesByValue: [String: ReplacementLabelStyle],
            to document: PDFDocument
        ) {
            for match in matches {
                guard let page = document.page(at: match.pageIndex) else { continue }
                let pageRects = PDFMasker.safeRedactionRects(match.rects, on: page).map {
                    pageRect(for: $0, on: page).insetBy(dx: -0.5, dy: -0.5)
                }
                let label = PDFMasker.replacementLabel(
                    for: match.matchedText,
                    replacementsByValue: replacementsByValue
                )
                let labelStyle = PDFMasker.replacementStyle(
                    for: match.matchedText,
                    replacementStylesByValue: replacementStylesByValue
                )
                let labelIndex = label.flatMap { _ in
                    pageRects.indices.max {
                        let firstLength = match.textRotationDegrees % 180 == 0
                            ? pageRects[$0].width : pageRects[$0].height
                        let secondLength = match.textRotationDegrees % 180 == 0
                            ? pageRects[$1].width : pageRects[$1].height
                        return firstLength < secondLength
                    }
                }
                for (index, pageRect) in pageRects.enumerated() {
                    let replacementText = index == labelIndex ? label : nil
                    let mask = PDFAnnotation(
                        bounds: pageRect,
                        forType: .square,
                        withProperties: nil
                    )
                    mask.color = .black
                    mask.interiorColor = .black
                    mask.shouldDisplay = true
                    mask.shouldPrint = true
                    let maskBorder = PDFBorder()
                    maskBorder.lineWidth = 0
                    mask.border = maskBorder
                    page.addAnnotation(mask)
                    if let replacementText {
                        let pageRotation = ((page.rotation % 360) + 360) % 360
                        let labelAnnotation = MaskLabelPreviewAnnotation(
                            bounds: pageRect.insetBy(dx: 1, dy: 1),
                            label: replacementText,
                            rotationDegrees: match.textRotationDegrees - pageRotation,
                            style: labelStyle
                        )
                        page.addAnnotation(labelAnnotation)
                    }
                }
                if !pageRects.isEmpty {
                    previewMasks[match.id] = PreviewMaskGroup(page: page, hitRects: pageRects)
                }
            }
        }

        private func installSearchAnnotations() {
            clearSearchAnnotations()
            guard let document = pdfView?.document else { return }

            for result in searchResults {
                guard let page = document.page(at: result.pageIndex) else { continue }
                for displayRect in result.rects {
                    let annotation = PDFAnnotation(
                        bounds: pageRect(for: displayRect, on: page).insetBy(dx: -1.5, dy: -1.5),
                        forType: .square,
                        withProperties: nil
                    )
                    annotation.color = .systemOrange
                    annotation.interiorColor = NSColor.systemYellow.withAlphaComponent(0.28)
                    annotation.shouldDisplay = true
                    let border = PDFBorder()
                    border.lineWidth = 1.5
                    annotation.border = border
                    page.addAnnotation(annotation)
                    searchAnnotations.append((page, annotation))
                    pdfView?.annotationsChanged(on: page)
                }
            }
            pdfView?.needsDisplay = true
        }

        private func clearSearchAnnotations() {
            for (page, annotation) in searchAnnotations {
                page.removeAnnotation(annotation)
                pdfView?.annotationsChanged(on: page)
            }
            searchAnnotations = []
            pdfView?.needsDisplay = true
        }

        private func pageRect(for displayRect: CGRect, on page: PDFPage) -> CGRect {
            let transform = page.transform(for: .mediaBox)
            let transformedBounds = page.bounds(for: .mediaBox).applying(transform).standardized
            let transformedRect = displayRect.offsetBy(
                dx: transformedBounds.minX,
                dy: transformedBounds.minY
            )
            return transformedRect.applying(transform.inverted()).standardized
        }
    }
}
