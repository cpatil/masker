import Foundation

struct PresidioInputSegment: Codable, Equatable {
    let documentIndex: Int
    let pageIndex: Int
    let text: String
}

struct PresidioCandidate: Codable, Identifiable, Hashable {
    let value: String
    let entityType: String
    let score: Double
    let occurrences: Int

    var id: String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayType: String {
        entityType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum PresidioDiscoveryError: LocalizedError {
    case notInstalled
    case helperMissing
    case couldNotStart
    case analysisFailed
    case invalidResponse
    case unsupportedPython
    case installationFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Presidio is not installed for Masker yet."
        case .helperMissing:
            return "Masker's Presidio helper is missing. Reinstall Masker and try again."
        case .couldNotStart:
            return "Masker could not start the local Presidio process."
        case .analysisFailed:
            return "Presidio could not analyze this document."
        case .invalidResponse:
            return "Presidio returned an unreadable result."
        case .unsupportedPython:
            return "Presidio needs Python 3.10 through 3.14. Install a compatible Python and try again."
        case .installationFailed:
            return "Presidio could not be installed. Check your internet connection and Python installation."
        }
    }
}

enum PresidioDiscoveryService {
    private struct AnalysisRequest: Codable {
        let language: String
        let minimumScore: Double
        let segments: [PresidioInputSegment]
    }

    private struct AnalysisResponse: Codable {
        let candidates: [PresidioCandidate]
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Masker/Presidio", isDirectory: true)
    }

    static var pythonURL: URL {
        if let override = ProcessInfo.processInfo.environment["MASKER_PRESIDIO_PYTHON"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("venv/bin/python3")
    }

    static var helperURL: URL? {
        if let override = ProcessInfo.processInfo.environment["MASKER_PRESIDIO_HELPER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "presidio_helper", withExtension: "py")
    }

    static var installerURL: URL? {
        if let override = ProcessInfo.processInfo.environment["MASKER_PRESIDIO_INSTALLER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "install_presidio", withExtension: "sh")
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) && helperURL != nil
    }

    static func analyze(
        segments: [PresidioInputSegment],
        minimumScore: Double = 0.20
    ) throws -> [PresidioCandidate] {
        guard isInstalled else { throw PresidioDiscoveryError.notInstalled }
        guard let helperURL else { throw PresidioDiscoveryError.helperMissing }
        let request = AnalysisRequest(
            language: "en",
            minimumScore: min(max(minimumScore, 0), 1),
            segments: segments
        )
        let input = try JSONEncoder().encode(request)
        let output = try run(
            executable: pythonURL,
            arguments: [helperURL.path],
            input: input
        )
        guard let response = try? JSONDecoder().decode(AnalysisResponse.self, from: output) else {
            throw PresidioDiscoveryError.invalidResponse
        }
        return response.candidates
    }

    static func install() throws {
        guard let installerURL else { throw PresidioDiscoveryError.helperMissing }
        _ = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [installerURL.path, supportDirectory.path],
            input: nil
        )
        guard isInstalled else { throw PresidioDiscoveryError.installationFailed }
    }

    private static func run(executable: URL, arguments: [String], input: Data?) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if input != nil { process.standardInput = inputPipe }
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw PresidioDiscoveryError.couldNotStart
        }
        var output = Data()
        var errorOutput = Data()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        if let input {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        readers.wait()
        _ = errorOutput
        guard process.terminationStatus == 0 else {
            if arguments.first?.hasSuffix("install_presidio.sh") == true {
                if process.terminationStatus == 10 {
                    throw PresidioDiscoveryError.unsupportedPython
                }
                throw PresidioDiscoveryError.installationFailed
            }
            throw PresidioDiscoveryError.analysisFailed
        }
        return output
    }
}
