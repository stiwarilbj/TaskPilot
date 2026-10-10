import Foundation

struct GeminiAPIKeyStore: Sendable {
    static let applicationSupportFolderName = "Orbit Agent"
    static let fileName = "gemini-api-key"
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    func save(_ apiKey: String) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directory.path
        )
        try Data(apiKey.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: fileURL.path
        )
    }

    func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let key = String(data: data, encoding: .utf8) else {
            throw GeminiAPIKeyStoreError.invalidEncoding
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

private enum GeminiAPIKeyStoreError: LocalizedError {
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "\(TaskPilotIdentity.displayName)'s saved Gemini API key file is not valid UTF-8. Clear it and paste the key again."
        }
    }
}

enum GeminiModelCheckState: Equatable, Sendable {
    case waiting
    case checking
    case working(String)
    case temporary(String)
    case failed(String)
}

struct GeminiModelCheck: Identifiable, Equatable, Sendable {
    let model: String
    var state: GeminiModelCheckState

    var id: String { model }
}

struct GeminiModelVerifier: Sendable {
    var runtimeURL = BundledRuntimeLocator().executableURL
    var openClawURL: URL? = OpenClawService.firstExecutable(from: OpenClawService.candidateExecutableURLs())

    static func configurationData(apiKey: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "kind": "runtime_configuration", "gemini_api_key": apiKey
        ])
        data.append(0x0A)
        return data
    }

    static func checks(from data: Data, models: [String]) -> [GeminiModelCheck] {
        var result: [String: GeminiModelCheckState] = [:]
        var error: String?
        for line in data.split(separator: 0x0A) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if message["kind"] as? String == "error" { error = message["message"] as? String }
            guard message["kind"] as? String == "model_checks",
                  let checks = message["checks"] as? [[String: Any]] else { continue }
            for check in checks {
                guard let model = check["model"] as? String else { continue }
                let detail = check["detail"] as? String ?? ""
                switch check["state"] as? String {
                case "verified": result[model] = .working(detail)
                case "temporary": result[model] = .temporary(detail)
                case "repair": result[model] = .failed(detail)
                default: result[model] = .waiting
                }
            }
        }
        if result.isEmpty, let error, let first = models.first { result[first] = .failed(error) }
        return models.map { GeminiModelCheck(model: $0, state: result[$0] ?? .waiting) }
    }

    func verify(apiKey: String, models: [String], readOnly: Bool = false) async -> [GeminiModelCheck] {
        await Task.detached {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = runtimeURL
            process.arguments = [readOnly ? "--read-readiness" : "--check-models"]
            if let openClawURL { process.arguments?.append(contentsOf: ["--openclaw-path", openClawURL.path]) }
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Self.configurationData(apiKey: apiKey))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return Self.checks(from: data, models: models)
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                return models.enumerated().map { index, model in
                    GeminiModelCheck(model: model, state: index == 0 ? .failed("TaskPilot could not check its runtime: \(error.localizedDescription)") : .waiting)
                }
            }
        }.value
    }
}
