import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

final class MaskerModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var exactValues = ""
    @Published var detectSSN = true
    @Published var detectEIN = true
    @Published var detectEmail = false
    @Published var detectPhone = false
    @Published var matches: [RedactionMatch] = []
    @Published var selectedMatchID: UUID?
    @Published var outputFolder: URL?
    @Published var isBusy = false
    @Published var status = "Drop PDFs here or choose files."
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var previewImage: NSImage?
    @Published var revealDetectedValues = false

    var selectedCount: Int { matches.filter(\.isSelected).count }

    func addFiles(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        for url in pdfs where !files.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            files.append(url)
        }
        if outputFolder == nil, let first = files.first {
            outputFolder = first.deletingLastPathComponent().appendingPathComponent("Masked PDFs", isDirectory: true)
        }
        matches = []
        selectedMatchID = nil
        previewImage = nil
        status = files.isEmpty ? "No PDF files selected." : "Ready to scan \(files.count) PDF\(files.count == 1 ? "" : "s")."
    }

    func removeFile(_ url: URL) {
        files.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        matches.removeAll { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
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
            detectPhone: detectPhone
        )
        let inputFiles = files

        isBusy = true
        matches = []
        previewImage = nil
        status = "Starting local scan..."

        DispatchQueue.global(qos: .userInitiated).async {
            let found = PDFMasker.scan(files: inputFiles, exactTerms: terms, options: options) { message in
                DispatchQueue.main.async { self.status = message }
            }
            DispatchQueue.main.async {
                self.matches = found
                self.selectedMatchID = found.first?.id
                self.isBusy = false
                self.status = found.isEmpty
                    ? "No matches found. Check spelling or whether the PDF is readable."
                    : "Found \(found.count) match\(found.count == 1 ? "" : "es"). Review the checked items before exporting."
                self.updatePreview()
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

    func updatePreview() {
        guard let id = selectedMatchID, let selected = matches.first(where: { $0.id == id }) else {
            previewImage = nil
            return
        }
        let pageMatches = matches.filter {
            $0.fileURL.standardizedFileURL == selected.fileURL.standardizedFileURL && $0.pageIndex == selected.pageIndex
        }
        previewImage = PDFMasker.previewImage(
            fileURL: selected.fileURL,
            pageIndex: selected.pageIndex,
            matches: pageMatches
        )
    }

    func selectAll(_ selected: Bool) {
        for index in matches.indices { matches[index].isSelected = selected }
        updatePreview()
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
        .onChange(of: model.selectedMatchID) { _ in model.updatePreview() }
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
                    Text("3. Review matches")
                        .font(.headline)
                    Text("Only checked matches will be covered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.matches.isEmpty {
                    Toggle("Reveal values", isOn: $model.revealDetectedValues)
                        .toggleStyle(.checkbox)
                    Button("All") { model.selectAll(true) }
                    Button("None") { model.selectAll(false) }
                }
            }
            .padding(14)

            Divider()

            if model.matches.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 42))
                        .foregroundStyle(.tertiary)
                    Text("Detected matches will appear here")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    List(selection: $model.selectedMatchID) {
                        ForEach($model.matches) { $match in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $match.isSelected)
                                    .labelsHidden()
                                    .onChange(of: match.isSelected) { _ in model.updatePreview() }
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(match.category)
                                            .font(.callout.weight(.semibold))
                                        Text("Page \(match.pageIndex + 1)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(match.matchedText)
                                        .font(.system(.callout, design: .monospaced))
                                        .lineLimit(1)
                                        .redacted(reason: model.revealDetectedValues ? [] : .privacy)
                                    Text(match.fileURL.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .tag(match.id)
                        }
                    }
                    .frame(minHeight: 200)

                    Group {
                        if let image = model.previewImage {
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(12)
                            }
                            .background(Color(nsColor: .underPageBackgroundColor))
                        } else {
                            Text("Select a match to preview its page.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 230)
                }
            }

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
