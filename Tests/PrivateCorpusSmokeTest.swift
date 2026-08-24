import Foundation
import PDFKit

@main
struct PrivateCorpusSmokeTest {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        guard let input = CommandLine.arguments.dropFirst().first else {
            throw TestFailure(description: "Pass a folder containing private PDF fixtures.")
        }
        let root = URL(fileURLWithPath: input, isDirectory: true)
        let files = pdfFiles(under: root)
        try require(!files.isEmpty, "No PDFs found.")

        var readableFiles = 0
        var totalPages = 0
        for file in files {
            if let document = PDFDocument(url: file) {
                readableFiles += 1
                totalPages += document.pageCount
            }
        }
        try require(readableFiles == files.count, "One or more fixtures could not be opened.")

        let options = PatternOptions(
            detectSSN: true,
            detectEIN: true,
            detectEmail: true,
            detectPhone: true,
            detectAccountSuffixes: true
        )
        let matches = PDFMasker.scan(files: files, exactTerms: [], options: options, progress: { _ in })
        let matchedFiles = Set(matches.map { $0.fileURL.standardizedFileURL }).count
        report("Corpus scan passed: files=\(files.count) pages=\(totalPages) filesWithMatches=\(matchedFiles) matches=\(matches.count)")

        if let fixture = matches.first?.fileURL {
            let fixtureMatches = matches.filter { $0.fileURL.standardizedFileURL == fixture.standardizedFileURL }
            let temporaryFolder = FileManager.default.temporaryDirectory
                .appendingPathComponent("masker-private-smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporaryFolder) }

            let outputs = try PDFMasker.exportSanitizedCopies(
                files: [fixture],
                matches: fixtureMatches,
                outputFolder: temporaryFolder,
                dpi: 180,
                progress: { _ in }
            )
            try require(outputs.count == 1, "Private fixture export did not create one sanitized copy.")

            let exactTerms = Array(Set(fixtureMatches.map(\.matchedText)))
            let residual = PDFMasker.scan(files: outputs, exactTerms: exactTerms, options: options, progress: { _ in })
            try require(residual.isEmpty, "A detected value remained recoverable after sanitization.")
            report("Private export validation passed: selectedMatches=\(fixtureMatches.count) residual=0")
        } else {
            report("No built-in PII patterns were present, so export validation was skipped.")
        }
    }

    private static func pdfFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "pdf" else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
