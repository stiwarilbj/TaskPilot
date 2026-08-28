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

enum GeminiModelCheckState: Equatable {
    case waiting
    case checking
    case working(String)
    case failed(String)
}

struct GeminiModelCheck: Identifiable, Equatable {
    let model: String
    var state: GeminiModelCheckState

    var id: String { model }
}

struct GeminiModelVerifier {
    static let prompt = "Reply with exactly: OK"

    static func makeRequest(model: String, apiKey: String) throws -> URLRequest {
        let apiModel = model.hasPrefix("google/") ? String(model.dropFirst("google/".count)) : model
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(apiModel):generateContent"
        ) else {
            throw GeminiModelVerifierError.invalidModel(model)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]]
        ])
        return request
    }

    func verify(apiKey: String, models: [String]) async -> [GeminiModelCheck] {
        await withTaskGroup(of: (Int, GeminiModelCheck).self) { group in
            for (index, model) in models.enumerated() {
                group.addTask {
                    let result = await verifyOne(apiKey: apiKey, model: model)
                    return (index, result)
                }
            }
            var ordered = Array(
                repeating: GeminiModelCheck(model: "", state: .waiting),
                count: models.count
            )
            for await (index, result) in group {
                ordered[index] = result
            }
            return ordered
        }
    }

    private func verifyOne(apiKey: String, model: String) async -> GeminiModelCheck {
        do {
            let request = try Self.makeRequest(model: model, apiKey: apiKey)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiModelVerifierError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = Self.apiErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                return GeminiModelCheck(model: model, state: .failed(message))
            }
            guard let responseText = Self.responseText(from: data), !responseText.isEmpty else {
                return GeminiModelCheck(model: model, state: .failed("The model returned no text."))
            }
            return GeminiModelCheck(model: model, state: .working(String(responseText.prefix(80))))
        } catch {
            return GeminiModelCheck(model: model, state: .failed(error.localizedDescription))
        }
    }

    private static func responseText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        return parts.compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return String(message.prefix(180))
    }
}

private enum GeminiModelVerifierError: LocalizedError {
    case invalidModel(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .invalidModel(model):
            return "Invalid Gemini model name: \(model)"
        case .invalidResponse:
            return "Google returned an invalid response."
        }
    }
}
