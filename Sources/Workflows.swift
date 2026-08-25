import CryptoKit
import Foundation

struct MaskValueEntry: Codable, Equatable {
    var value: String
    var replaceWith: String
    var fontName: String? = nil
    var fontSize: Double? = nil
    var widthPercent: Double? = nil
    var justification: String? = nil
}

struct MaskPatternSettings: Codable, Equatable {
    var detectSSN = true
    var detectEIN = true
    var detectEmail = false
    var detectPhone = false
    var generateNameVariants = false
    var detectAccountSuffixes = false
    var accountSuffixExceptions: [String] = []
}

struct DiscoveryDocument: Codable, Equatable, Identifiable {
    let id: String
    let path: String
    let sourceFingerprint: String
}

struct DiscoverySession: Codable, Equatable {
    let format: String
    let version: Int
    let id: String
    let rootFolderPath: String
    var documents: [DiscoveryDocument]
    var activeDocumentID: String?
    var visitedDocumentIDs: [String]
    var masks: [MaskValueEntry]
    var settings: MaskPatternSettings
    var updatedAt: TimeInterval

    static func create(
        folder: URL,
        documents: [DiscoveryDocument],
        masks: [MaskValueEntry] = [],
        settings: MaskPatternSettings = MaskPatternSettings()
    ) -> DiscoverySession {
        let firstID = documents.first?.id
        return DiscoverySession(
            format: "masker-discovery",
            version: 1,
            id: "discovery-" + UUID().uuidString.lowercased(),
            rootFolderPath: folder.standardizedFileURL.path,
            documents: documents,
            activeDocumentID: firstID,
            visitedDocumentIDs: firstID.map { [$0] } ?? [],
            masks: masks,
            settings: settings,
            updatedAt: Date().timeIntervalSince1970
        )
    }
}

struct WorkflowPublicDocumentStatus: Codable, Equatable {
    let id: String
    let index: Int
    let state: String
}

struct WorkflowPublicStatus: Codable, Equatable {
    let format: String
    let version: Int
    let revision: Int
    let workflow: String?
    let state: String
    let sessionID: String?
    let documentCount: Int
    let documents: [WorkflowPublicDocumentStatus]
    let activeDocumentID: String?
    let activeDocumentIndex: Int?
    let visitedCount: Int
    let processedCount: Int
    let failedCount: Int
    let currentScanned: Bool
    let matchCount: Int?
    let selectedMatchCount: Int?
    let busy: Bool
    let userActionRequired: String?
}

enum WorkflowStoreError: LocalizedError {
    case noPDFs
    case invalidSession
    case changedDocument(String)

    var errorDescription: String? {
        switch self {
        case .noPDFs:
            return "That folder hierarchy does not contain any PDF files."
        case .invalidSession:
            return "The saved discovery session is invalid."
        case .changedDocument(let id):
            return "\(id) changed after discovery started. Start a new discovery session to review it safely."
        }
    }
}

enum WorkflowStore {
    private static let directoryName = "Workflows"
    private static let sessionFileName = "discovery-session.json"
    private static let publicStatusFileName = "mcp-status.json"

    static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["MASKER_WORKFLOW_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Masker", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var sessionURL: URL {
        directoryURL.appendingPathComponent(sessionFileName)
    }

    static var publicStatusURL: URL {
        directoryURL.appendingPathComponent(publicStatusFileName)
    }

    static func documents(in folder: URL, excluding excludedFolder: URL? = nil) throws -> [DiscoveryDocument] {
        let root = folder.standardizedFileURL
        let excludedPath = excludedFolder?.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WorkflowStoreError.noPDFs
        }

        var pdfs: [URL] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            if let excludedPath,
               standardized.path == excludedPath || standardized.path.hasPrefix(excludedPath + "/") {
                if (try? standardized.resourceValues(forKeys: keys).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try? standardized.resourceValues(forKeys: keys)
            guard values?.isHidden != true,
                  values?.isRegularFile == true,
                  standardized.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else { continue }
            pdfs.append(standardized)
        }
        pdfs.sort {
            relativePath(of: $0, under: root).localizedStandardCompare(
                relativePath(of: $1, under: root)
            ) == .orderedAscending
        }
        guard !pdfs.isEmpty else { throw WorkflowStoreError.noPDFs }
        return try pdfs.enumerated().map { index, url in
            DiscoveryDocument(
                id: String(format: "document-%03d", index + 1),
                path: url.path,
                sourceFingerprint: try fingerprint(of: url)
            )
        }
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    static func save(_ session: DiscoverySession) throws {
        try ensureDirectory()
        var copy = session
        copy.updatedAt = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeProtected(encoder.encode(copy), to: sessionURL)
    }

    static func load() throws -> DiscoverySession? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        let data = try Data(contentsOf: sessionURL, options: .mappedIfSafe)
        let session = try JSONDecoder().decode(DiscoverySession.self, from: data)
        guard session.format == "masker-discovery", session.version == 1 else {
            throw WorkflowStoreError.invalidSession
        }
        return session
    }

    static func clearDiscovery() throws {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return }
        try FileManager.default.removeItem(at: sessionURL)
    }

    static func savePublicStatus(_ status: WorkflowPublicStatus) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeProtected(encoder.encode(status), to: publicStatusURL)
    }

    static func validate(_ document: DiscoveryDocument) throws -> URL {
        let url = URL(fileURLWithPath: document.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              try fingerprint(of: url) == document.sourceFingerprint else {
            throw WorkflowStoreError.changedDocument(document.id)
        }
        return url
    }

    static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
