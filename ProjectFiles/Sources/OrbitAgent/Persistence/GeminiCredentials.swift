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

    static func configurationData(apiKey: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "kind": "runtime_configuration", "gemini_api_key": apiKey,
            "action_contract_hash": ActionContract.fingerprint,
            "action_contract_version": ActionContract.version
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
        let cancellation = OpenClawCommandCancellation()
        return await withTaskCancellationHandler {
            await Task.detached {
                do {
                    // Resolve at invocation time: installation may have changed
                    // since the settings view/verifier was created.
                    if !readOnly {
                        let resources = Bundle.main.resourceURL!.appendingPathComponent("OpenClaw/managed")
                        let installed = OpenClawService.run(executable:runtimeURL,
                            arguments:["--managed-openclaw", "ensure", "--managed-resources", resources.path],
                            timeout:1200, input:Data((apiKey + "\n").utf8), cancellation:cancellation)
                        guard installed.status == 0 else { throw ManagedOpenClawError.command(installed.output) }
                    }
                    let descriptor = try ManagedOpenClawDescriptor.load()
                    let result = OpenClawService.run(executable: runtimeURL,
                        arguments: [readOnly ? "--read-readiness" : "--check-models",
                                    "--managed-descriptor", ManagedOpenClawDescriptor.url.path],
                        timeout: readOnly ? 30 : 240,
                        input: try Self.configurationData(apiKey: apiKey),
                        environment: descriptor.environment, cancellation: cancellation)
                    if result.status == -2 {
                        return models.enumerated().map { index, model in
                            GeminiModelCheck(model: model, state: index == 0 ? .temporary("Verification ended before a terminal result; no model was declared ready.") : .waiting)
                        }
                    }
                    let checks = Self.checks(from: Data(result.output.utf8), models: models)
                    if !readOnly, !cancellation.isCancelled,
                       !checks.contains(where: { if case .working = $0.state { return true }; return false }),
                       let saved = try? GeminiAPIKeyStore().load(), saved != apiKey {
                        let resources = Bundle.main.resourceURL!.appendingPathComponent("OpenClaw/managed")
                        _ = OpenClawService.run(executable:runtimeURL,
                            arguments:["--managed-openclaw", "ensure", "--managed-resources", resources.path],
                            timeout:1200, input:Data((saved + "\n").utf8), cancellation:cancellation)
                    }
                    return checks
                } catch {
                    return models.enumerated().map { index, model in
                        GeminiModelCheck(model: model, state: index == 0 ? .failed(error.localizedDescription) : .waiting)
                    }
                }
            }.value
        } onCancel: { cancellation.cancel() }
    }
}
