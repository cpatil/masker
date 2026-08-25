import Foundation

@main
struct WorkflowSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("masker-workflow-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("nested/tax", isDirectory: true)
        let output = source.appendingPathComponent("Masked PDFs", isDirectory: true)
        let store = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        setenv("MASKER_WORKFLOW_DIRECTORY", store.path, 1)
        defer {
            unsetenv("MASKER_WORKFLOW_DIRECTORY")
            try? FileManager.default.removeItem(at: root)
        }

        let first = source.appendingPathComponent("A-document.pdf")
        let second = nested.appendingPathComponent("B-document.pdf")
        let oldOutput = output.appendingPathComponent("old_masked.pdf")
        try Data("synthetic pdf one".utf8).write(to: first)
        try Data("synthetic pdf two".utf8).write(to: second)
        try Data("old output".utf8).write(to: oldOutput)
        try Data("ignored".utf8).write(to: source.appendingPathComponent("notes.txt"))

        let documents = try WorkflowStore.documents(in: source, excluding: output)
        precondition(documents.map(\.id) == ["document-001", "document-002"])
        precondition(documents[0].path == first.standardizedFileURL.path)
        precondition(documents[1].path == second.standardizedFileURL.path)

        var session = DiscoverySession.create(folder: source, documents: documents)
        session.masks = [MaskValueEntry(value: "SYNTHETIC SECRET", replaceWith: "Client-1")]
        session.settings.detectAccountSuffixes = true
        session.activeDocumentID = documents[1].id
        session.visitedDocumentIDs.append(documents[1].id)
        try WorkflowStore.save(session)
        guard let restored = try WorkflowStore.load() else { fatalError("Discovery session was not restored") }
        precondition(restored.id == session.id)
        precondition(restored.documents == session.documents)
        precondition(restored.activeDocumentID == session.activeDocumentID)
        precondition(restored.visitedDocumentIDs == session.visitedDocumentIDs)
        precondition(restored.masks == session.masks)
        precondition(restored.settings == session.settings)

        let sessionPermissions = try FileManager.default.attributesOfItem(
            atPath: WorkflowStore.sessionURL.path
        )[.posixPermissions] as? NSNumber
        precondition(sessionPermissions?.intValue == 0o600)

        let status = WorkflowPublicStatus(
            format: "masker-workflow-status",
            version: 1,
            revision: 1,
            workflow: "discovery",
            state: "ready",
            sessionID: session.id,
            documentCount: 2,
            documents: [
                WorkflowPublicDocumentStatus(id: "document-001", index: 1, state: "visited"),
                WorkflowPublicDocumentStatus(id: "document-002", index: 2, state: "active")
            ],
            activeDocumentID: "document-002",
            activeDocumentIndex: 2,
            visitedCount: 2,
            processedCount: 0,
            failedCount: 0,
            currentScanned: false,
            matchCount: nil,
            selectedMatchCount: nil,
            busy: false,
            userActionRequired: "scan_or_open_next_document"
        )
        try WorkflowStore.savePublicStatus(status)
        let publicData = try Data(contentsOf: WorkflowStore.publicStatusURL)
        let publicText = String(decoding: publicData, as: UTF8.self)
        precondition(!publicText.contains(source.path))
        precondition(!publicText.contains("SYNTHETIC SECRET"))
        precondition(!publicText.contains("A-document"))
        let decodedStatus = try JSONDecoder().decode(WorkflowPublicStatus.self, from: publicData)
        precondition(decodedStatus == status)

        _ = try WorkflowStore.validate(documents[0])
        try Data("changed".utf8).write(to: first)
        do {
            _ = try WorkflowStore.validate(documents[0])
            fatalError("A changed source document was accepted")
        } catch WorkflowStoreError.changedDocument(let id) {
            precondition(id == "document-001")
        }

        try WorkflowStore.clearDiscovery()
        let clearedSession = try WorkflowStore.load()
        precondition(clearedSession == nil)
        print("PASS workflow recursion, privacy, and persistence")
    }
}
