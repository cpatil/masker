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

enum PrivateBatchPhase: String, Codable {
    case discovery
    case finalReview = "final_review"
}

struct PrivateBatchPatternSettings: Codable, Equatable {
    var detectSSN = true
    var detectEIN = true
    var detectEmail = false
    var detectPhone = false
    var generateNameVariants = false
    var detectAccountSuffixes = false
    var accountSuffixExceptions: [String] = []
}

struct PrivateBatchDocument: Codable, Equatable, Identifiable {
    let id: String
    let path: String
    let sourceFingerprint: String
    var discoveryReviewedVersion: Int?
    var finalReviewedVersion: Int?
    var exportedVersion: Int?
    var excludedMatchFingerprints: [String]
}

struct PrivateBatchSession: Codable, Equatable {
    let format: String
    let version: Int
    let id: String
    let folderPath: String
    var documents: [PrivateBatchDocument]
    var activeDocumentID: String?
    var maskSetVersion: Int
    var masks: [MaskValueEntry]
    var settings: PrivateBatchPatternSettings
    var outputFolderPath: String
    var phase: PrivateBatchPhase
    var updatedAt: TimeInterval

    static func create(folder: URL, documents: [PrivateBatchDocument]) -> PrivateBatchSession {
        PrivateBatchSession(
            format: "masker-private-batch",
            version: 1,
            id: "session-" + UUID().uuidString.lowercased(),
            folderPath: folder.standardizedFileURL.path,
            documents: documents,
            activeDocumentID: documents.first?.id,
            maskSetVersion: 1,
            masks: [],
            settings: PrivateBatchPatternSettings(),
            outputFolderPath: folder
                .appendingPathComponent("Masked PDFs", isDirectory: true)
                .standardizedFileURL.path,
            phase: .discovery,
            updatedAt: Date().timeIntervalSince1970
        )
    }
}

struct PrivateBatchPublicDocumentStatus: Codable, Equatable {
    let id: String
    let index: Int
    let state: String
}

struct PrivateBatchPublicStatus: Codable, Equatable {
    let format: String
    let version: Int
    let revision: Int
    let state: String
    let sessionID: String?
    let phase: String?
    let documentCount: Int
    let documents: [PrivateBatchPublicDocumentStatus]
    let activeDocumentID: String?
    let activeDocumentIndex: Int?
    let maskSetVersion: Int?
    let reviewedCount: Int
    let staleCount: Int
    let exportedCount: Int
    let currentReviewed: Bool
    let currentScanned: Bool
    let matchCount: Int?
    let selectedMatchCount: Int?
    let busy: Bool
    let userActionRequired: String?
}

enum PrivateBatchStoreError: LocalizedError {
    case noPDFs
    case invalidSession
    case changedDocument(String)

    var errorDescription: String? {
        switch self {
        case .noPDFs:
            return "That folder does not contain any PDF files."
        case .invalidSession:
            return "The saved private batch session is invalid."
        case .changedDocument(let id):
            return "\(id) changed after it was added to the private batch. Start a new batch to review it safely."
        }
    }
}

enum PrivateBatchStore {
    private static let directoryName = "Private Batch"
    private static let sessionFileName = "active-session.json"
    private static let publicStatusFileName = "mcp-status.json"

    static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["MASKER_PRIVATE_BATCH_DIRECTORY"],
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

    static func documents(in folder: URL) throws -> [PrivateBatchDocument] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let pdfs = urls.filter { url in
            guard url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else { return false }
            return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard !pdfs.isEmpty else { throw PrivateBatchStoreError.noPDFs }
        return try pdfs.enumerated().map { index, url in
            PrivateBatchDocument(
                id: String(format: "document-%03d", index + 1),
                path: url.standardizedFileURL.path,
                sourceFingerprint: try fingerprint(of: url),
                discoveryReviewedVersion: nil,
                finalReviewedVersion: nil,
                exportedVersion: nil,
                excludedMatchFingerprints: []
            )
        }
    }

    static func save(_ session: PrivateBatchSession) throws {
        try ensureDirectory()
        var copy = session
        copy.updatedAt = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeProtected(encoder.encode(copy), to: sessionURL)
    }

    static func load() throws -> PrivateBatchSession? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        let data = try Data(contentsOf: sessionURL, options: .mappedIfSafe)
        let session = try JSONDecoder().decode(PrivateBatchSession.self, from: data)
        guard session.format == "masker-private-batch", session.version == 1 else {
            throw PrivateBatchStoreError.invalidSession
        }
        return session
    }

    static func savePublicStatus(_ status: PrivateBatchPublicStatus) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeProtected(encoder.encode(status), to: publicStatusURL)
    }

    static func validate(_ document: PrivateBatchDocument) throws -> URL {
        let url = URL(fileURLWithPath: document.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              try fingerprint(of: url) == document.sourceFingerprint else {
            throw PrivateBatchStoreError.changedDocument(document.id)
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
