import AppKit
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

final class MaskerModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var exactValues = ""
    @Published var detectSSN = true
    @Published var detectEIN = true
    @Published var detectEmail = false
    @Published var detectPhone = false
    @Published var generateNameVariants = false
    @Published var detectAccountSuffixes = false
    @Published var accountSuffixExceptions = ""
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
    @Published var searchNavigationToken = 0
    @Published var searchNavigationDirection = 1

    var selectedCount: Int { matches.filter(\.isSelected).count }

    func addFiles(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        for url in pdfs where !files.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            files.append(url)
        }
        if outputFolder == nil, let first = files.first {
            outputFolder = first.deletingLastPathComponent().appendingPathComponent("Masked PDFs", isDirectory: true)
        }
        if activeFileURL == nil { activeFileURL = files.first }
        matches = []
        selectedMatchID = nil
        status = files.isEmpty ? "No PDF files selected." : "Ready to scan \(files.count) PDF\(files.count == 1 ? "" : "s")."
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
        let previouslyActiveFile = activeFileURL
        let previousPage = currentPreviewPage

        isBusy = true
        matches = []
        status = "Starting local scan..."

        DispatchQueue.global(qos: .userInitiated).async {
            let found = PDFMasker.scan(files: inputFiles, exactTerms: terms, options: options) { message in
                DispatchQueue.main.async { self.status = message }
            }
            DispatchQueue.main.async {
                self.matches = found
                self.selectedMatchID = found.first?.id
                if let previous = previouslyActiveFile,
                   inputFiles.contains(where: { $0.standardizedFileURL == previous.standardizedFileURL }) {
                    self.activeFileURL = previous
                    self.currentPreviewPage = previousPage
                } else {
                    self.activeFileURL = found.first?.fileURL ?? inputFiles.first
                    self.currentPreviewPage = 0
                }
                self.isBusy = false
                self.status = found.isEmpty
                    ? "No matches found. Check spelling or whether the PDF is readable."
                    : "Found \(found.count) match\(found.count == 1 ? "" : "es"). Review the checked items before exporting."
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

        let inputFiles = files
        let reviewedMatches = matches
        isBusy = true
        status = "Preparing sanitized copies..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outputs = try PDFMasker.exportSanitizedCopies(
                    files: inputFiles,
                    matches: reviewedMatches,
                    outputFolder: folder
                ) { message in
                    DispatchQueue.main.async { self.status = message }
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = "Created and validated \(outputs.count) sanitized PDF\(outputs.count == 1 ? "" : "s") in \(folder.path)."
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func selectAll(_ selected: Bool) {
        for index in matches.indices { matches[index].isSelected = selected }
    }

    func selectCurrentPage(_ selected: Bool) {
        guard let file = activeFileURL else { return }
        for index in matches.indices where
            matches[index].fileURL.standardizedFileURL == file.standardizedFileURL &&
            matches[index].pageIndex == currentPreviewPage {
            matches[index].isSelected = selected
        }
    }

    func showFile(_ file: URL) {
        activeFileURL = file
        currentPreviewPage = 0
        pdfSearchResultCount = 0
        pdfSearchResultIndex = 0
        pdfSearchIsBusy = false
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
}

struct ContentView: View {
    @StateObject private var model = MaskerModel()
    @State private var isDropTargeted = false

    init(model: MaskerModel = MaskerModel()) {
        _model = StateObject(wrappedValue: model)
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
        .onOpenURL { url in
            model.addFiles([url])
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Masker")
                    .font(.title2.weight(.semibold))
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
                                Button("Choose PDFs...") { choosePDFs() }
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
                    }
                    .padding(.top, 6)
                }

                GroupBox("2. Choose what to mask") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Exact values - one per line")
                            .font(.callout.weight(.medium))
                        TextEditor(text: $model.exactValues)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 105)
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
                }
            }
            .padding(14)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Matches on page \(model.currentPreviewPage + 1)")
                        .font(.callout.weight(.semibold))
                    Text("\(currentMatchIndices.count)")
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
                            .disabled(currentMatchIndices.isEmpty)
                        Button("Page: None") { model.selectCurrentPage(false) }
                            .disabled(currentMatchIndices.isEmpty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if currentMatchIndices.isEmpty {
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
                            ForEach(currentMatchIndices, id: \.self) { index in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $model.matches[index].isSelected)
                                        .labelsHidden()
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.matches[index].category)
                                            .font(.callout.weight(.semibold))
                                        Text(model.matches[index].matchedText)
                                            .font(.system(.callout, design: .monospaced))
                                            .lineLimit(1)
                                            .redacted(reason: model.revealDetectedValues ? [] : .privacy)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                Divider()
                                    .padding(.leading, 42)
                            }
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
                        currentPage: $model.currentPreviewPage,
                        searchText: model.pdfSearchText,
                        searchResultCount: $model.pdfSearchResultCount,
                        searchResultIndex: $model.pdfSearchResultIndex,
                        searchIsBusy: $model.pdfSearchIsBusy,
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
                    Label("Create Sanitized Copies", systemImage: "lock.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCount == 0 || model.isBusy)
            }
            .padding(14)
        }
    }

    private var currentMatchIndices: [Int] {
        guard let file = model.activeFileURL else { return [] }
        return model.matches.indices.filter {
            model.matches[$0].fileURL.standardizedFileURL == file.standardizedFileURL &&
            model.matches[$0].pageIndex == model.currentPreviewPage
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
        if panel.runModal() == .OK { model.outputFolder = panel.url }
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

struct ContinuousPDFView: NSViewRepresentable {
    let fileURL: URL
    let matches: [RedactionMatch]
    @Binding var currentPage: Int
    let searchText: String
    @Binding var searchResultCount: Int
    @Binding var searchResultIndex: Int
    @Binding var searchIsBusy: Bool
    let navigationToken: Int
    let navigationDirection: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
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
            requestedPage: currentPage
        )
        context.coordinator.updateSearchIfNeeded(searchText)
        context.coordinator.navigateIfNeeded(token: navigationToken, direction: navigationDirection)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var parent: ContinuousPDFView
        private weak var pdfView: PDFView?
        private var pageObserver: NSObjectProtocol?
        private var documentSignature = ""
        private var loadedFilePath = ""
        private var lastSearchText = ""
        private var searchWorkItem: DispatchWorkItem?
        private var searchResults: [RedactionMatch] = []
        private var searchAnnotations: [(PDFPage, PDFAnnotation)] = []
        private var currentSearchIndex = 0
        private var lastNavigationToken = 0

        init(parent: ContinuousPDFView) {
            self.parent = parent
        }

        func attach(to pdfView: PDFView) {
            self.pdfView = pdfView
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
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
        }

        func updateDocumentIfNeeded(fileURL: URL, matches: [RedactionMatch], requestedPage: Int) {
            guard let pdfView else { return }
            let filePath = fileURL.standardizedFileURL.path
            let matchPart = matches
                .map { "\($0.id.uuidString):\($0.isSelected ? 1 : 0)" }
                .joined(separator: "|")
            let signature = filePath + "|" + matchPart

            if signature != documentSignature {
                let visiblePage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
                let targetPage = loadedFilePath == filePath ? (visiblePage ?? requestedPage) : requestedPage
                guard let data = try? Data(contentsOf: fileURL), let document = PDFDocument(data: data) else { return }
                addRedactionAnnotations(matches.filter(\.isSelected), to: document)
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

        func updateSearchIfNeeded(_ query: String) {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized != lastSearchText else { return }
            lastSearchText = normalized
            searchWorkItem?.cancel()

            guard !normalized.isEmpty else {
                searchResults = []
                currentSearchIndex = 0
                clearSearchAnnotations()
                publishSearchState(isBusy: false)
                return
            }

            searchResults = []
            currentSearchIndex = 0
            clearSearchAnnotations()
            publishSearchState(isBusy: true)
            let work = DispatchWorkItem { [weak self] in
                self?.performSearch(normalized)
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

        private func performSearch(_ query: String) {
            guard query == lastSearchText else { return }
            let fileURL = parent.fileURL
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = PDFMasker.scan(
                    files: [fileURL],
                    exactTerms: [query],
                    options: PatternOptions(
                        detectSSN: false,
                        detectEIN: false,
                        detectEmail: false,
                        detectPhone: false,
                        generateNameVariants: false
                    ),
                    progress: { _ in }
                )
                DispatchQueue.main.async {
                    guard let self,
                          query == self.lastSearchText,
                          fileURL.standardizedFileURL.path == self.loadedFilePath else { return }
                    self.searchResults = found
                    self.currentSearchIndex = 0
                    self.installSearchAnnotations()
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

        private func addRedactionAnnotations(_ matches: [RedactionMatch], to document: PDFDocument) {
            for match in matches {
                guard let page = document.page(at: match.pageIndex) else { continue }
                for displayRect in match.rects {
                    let pageRect = pageRect(for: displayRect, on: page).insetBy(dx: -0.5, dy: -0.5)
                    let annotation = PDFAnnotation(bounds: pageRect, forType: .square, withProperties: nil)
                    annotation.color = .black
                    annotation.interiorColor = .black
                    annotation.shouldDisplay = true
                    annotation.shouldPrint = true
                    let border = PDFBorder()
                    border.lineWidth = 0
                    annotation.border = border
                    page.addAnnotation(annotation)
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
