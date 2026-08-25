import Foundation

@main
struct PrivateBatchSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("masker-private-batch-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let store = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        setenv("MASKER_PRIVATE_BATCH_DIRECTORY", store.path, 1)
        defer {
            unsetenv("MASKER_PRIVATE_BATCH_DIRECTORY")
            try? FileManager.default.removeItem(at: root)
        }

        let second = source.appendingPathComponent("B-document.pdf")
        let first = source.appendingPathComponent("A-document.pdf")
        try Data("synthetic pdf one".utf8).write(to: first)
        try Data("synthetic pdf two".utf8).write(to: second)
        try Data("ignored".utf8).write(to: source.appendingPathComponent("notes.txt"))

        let documents = try PrivateBatchStore.documents(in: source)
        precondition(documents.map(\.id) == ["document-001", "document-002"])
        precondition(documents[0].path == first.standardizedFileURL.path)

        var session = PrivateBatchSession.create(folder: source, documents: documents)
        session.masks = [MaskValueEntry(value: "SYNTHETIC SECRET", replaceWith: "Client-1")]
        session.settings.detectAccountSuffixes = true
        try PrivateBatchStore.save(session)
        guard let restored = try PrivateBatchStore.load() else { fatalError("Session was not restored") }
        precondition(restored.id == session.id)
        precondition(restored.documents == session.documents)
        precondition(restored.masks == session.masks)
        precondition(restored.settings == session.settings)

        let sessionPermissions = try FileManager.default.attributesOfItem(
            atPath: PrivateBatchStore.sessionURL.path
        )[.posixPermissions] as? NSNumber
        precondition(sessionPermissions?.intValue == 0o600)

        let status = PrivateBatchPublicStatus(
            format: "masker-mcp-status",
            version: 1,
            revision: 1,
            state: "ready",
            sessionID: session.id,
            phase: session.phase.rawValue,
            documentCount: 2,
            documents: [
                PrivateBatchPublicDocumentStatus(id: "document-001", index: 1, state: "unreviewed"),
                PrivateBatchPublicDocumentStatus(id: "document-002", index: 2, state: "unreviewed")
            ],
            activeDocumentID: "document-001",
            activeDocumentIndex: 1,
            maskSetVersion: 1,
            reviewedCount: 0,
            staleCount: 0,
            exportedCount: 0,
            currentReviewed: false,
            currentScanned: false,
            matchCount: nil,
            selectedMatchCount: nil,
            busy: false,
            userActionRequired: "scan_and_review_current_document"
        )
        try PrivateBatchStore.savePublicStatus(status)
        let publicData = try Data(contentsOf: PrivateBatchStore.publicStatusURL)
        let publicText = String(decoding: publicData, as: UTF8.self)
        precondition(!publicText.contains(source.path))
        precondition(!publicText.contains("SYNTHETIC SECRET"))
        let decodedStatus = try JSONDecoder().decode(PrivateBatchPublicStatus.self, from: publicData)
        precondition(decodedStatus == status)

        _ = try PrivateBatchStore.validate(documents[0])
        try Data("changed".utf8).write(to: first)
        do {
            _ = try PrivateBatchStore.validate(documents[0])
            fatalError("A changed source document was accepted")
        } catch PrivateBatchStoreError.changedDocument(let id) {
            precondition(id == "document-001")
        }

        print("PASS private-batch privacy and persistence")
    }
}
