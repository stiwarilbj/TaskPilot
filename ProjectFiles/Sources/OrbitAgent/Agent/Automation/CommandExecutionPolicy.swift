import CoreFoundation
import Darwin
import Foundation
import CryptoKit

/// Validates everything before launching a process. Literal argv entries never
/// pass through a shell; shell source is preserved and checked separately.
struct CommandExecutionPolicy {
    let workingDirectory: URL
    let workingDirectoryInput: URL
    let executable: URL
    let arguments: [String]
    let shellSource: String?
    let displayCommand: String
    let timeout: TimeInterval
    let checks: [Check]
    let outcomeChecks: [[String: Any]]

    struct Check {
        let type: String
        let path: URL?
        let expected: Data?
        let text: String?
        let fileDigestProof: [String: Any]?
        let taskGenerationID: String?

        init(type: String, path: URL?, expected: Data?, text: String?,
             fileDigestProof: [String: Any]? = nil, taskGenerationID: String? = nil) {
            self.type = type
            self.path = path
            self.expected = expected
            self.text = text
            self.fileDigestProof = fileDigestProof
            self.taskGenerationID = taskGenerationID
        }

        static func groups(for checks: [Check]) -> [[Int]] {
            var groups: [String: [Int]] = [:]
            for (index, check) in checks.enumerated() {
                let key = check.path.map { "file:\($0.standardizedFileURL.path)" } ?? "standalone:\(index)"
                groups[key, default: []].append(index)
            }
            return groups.values.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        }

        static func evaluateAll(_ checks: [Check], stdout: String, stdoutTruncated: Bool,
                                downloadStatus: @escaping FileInputAvailability.DownloadStatusReader = FileInputAvailability.downloadStatus) throws -> [[String: Any]] {
            var checkedByIndex = Array<[String: Any]?>(repeating: nil, count: checks.count)
            for indexes in groups(for: checks) {
                let results = try evaluateBatch(indexes.map { checks[$0] }, stdout: stdout,
                    stdoutTruncated: stdoutTruncated, downloadStatus: downloadStatus)
                for (index, result) in zip(indexes, results) { checkedByIndex[index] = result }
            }
            return try checkedByIndex.map { result in
                guard let result else { throw TaskToolError.operationFailed("A local file check did not produce a result") }
                return result
            }
        }

        static func evaluateBatch(_ checks: [Check], stdout: String, stdoutTruncated: Bool,
                                  downloadStatus: @escaping FileInputAvailability.DownloadStatusReader = FileInputAvailability.downloadStatus) throws -> [[String: Any]] {
            guard !checks.isEmpty else { return [] }
            if checks.count == 1 {
                return [try checks[0].evaluate(stdout: stdout, stdoutTruncated: stdoutTruncated,
                                                downloadStatus: downloadStatus)]
            }
            guard let path = checks[0].path,
                  checks.allSatisfy({ $0.path?.standardizedFileURL.path == path.standardizedFileURL.path }),
                  checks.allSatisfy({ OutcomeCheckKind(rawValue: $0.type) != .stdout_equals }) else {
                return try checks.map { try $0.evaluate(stdout: stdout, stdoutTruncated: stdoutTruncated,
                                                        downloadStatus: downloadStatus) }
            }

            do {
                let operation = try BoundFileOperation(path, downloadStatus: downloadStatus)
                let snapshots = try operation.inspectBatch(checks.map {
                    BoundFileOperation.InspectionRequest(kind: $0.type, expected: $0.expected)
                })
                return zip(checks, snapshots).map { check, snapshot in
                    check.result(matches: snapshot.matches, fields: snapshot.fields)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch TaskToolError.fileContentsNotLocal {
                return checks.map { $0.result(reason: TaskToolError.fileContentsNotLocal.localizedDescription) }
            } catch is BoundFileOperation.Conflict {
                return checks.map { $0.result(reason: "Filesystem conflict; fresh inspection is required") }
            } catch {
                return checks.map { $0.result(reason: "The requested outcome could not be inspected") }
            }
        }

        func evaluate(stdout: String, stdoutTruncated: Bool,
                      downloadStatus: @escaping FileInputAvailability.DownloadStatusReader = FileInputAvailability.downloadStatus) throws -> [String: Any] {
            var result: [String: Any] = ["type": type, "verified": false,
                "outcome": "delivered_unconfirmed", "verification_scope": type]
            if let path { result["path"] = path.path }
            do {
                let matches: Bool
                guard let kind = OutcomeCheckKind(rawValue: type) else { return result }
                switch kind {
                case .stdout_equals:
                    matches = !stdoutTruncated && stdout == text
                case .path_absent, .file_exists, .directory_exists, .file_contents:
                    let operation = try BoundFileOperation(path!, downloadStatus: downloadStatus)
                    var reused: [String: Any]?
                    if let fileDigestProof {
                        do {
                            reused = try operation.reuseVerifiedDigest(kind: type, expected: expected,
                                generation: taskGenerationID, proof: fileDigestProof)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // A stale or temporarily unbindable proof cannot
                            // answer the check; fall through to full inspect.
                            reused = nil
                        }
                    }
                    let inspection: (Bool, [String: Any])
                    if let reused {
                        inspection = (true, reused)
                    } else {
                        inspection = try operation.inspect(kind: type, expected: expected)
                    }
                    matches = inspection.0
                    // Preserve current identity metadata even on a content
                    // mismatch so the task cache can discard a stale proof.
                    result.merge(inspection.1) { _, new in new }
                }
                return self.result(matches: matches, fields: result)
            } catch TaskToolError.fileContentsNotLocal {
                return self.result(reason: TaskToolError.fileContentsNotLocal.localizedDescription)
            } catch is BoundFileOperation.Conflict {
                return self.result(reason: "Filesystem conflict; fresh inspection is required")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return self.result(reason: "The requested outcome could not be inspected")
            }
        }

        private func result(matches: Bool? = nil, fields: [String: Any] = [:], reason: String? = nil) -> [String: Any] {
            var result: [String: Any] = ["type": type, "verified": false,
                "outcome": "delivered_unconfirmed", "verification_scope": type]
            if let path { result["path"] = path.path }
            result.merge(fields) { _, new in new }
            if let matches {
                result["verified"] = matches
                result["outcome"] = matches ? "verified" : "delivered_unconfirmed"
                if matches, let expected {
                    result["content_sha256"] = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
                }
                if matches, type == "stdout_equals", let text {
                    result["text_sha256"] = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                }
                if !matches { result["reason"] = "The requested outcome did not match" }
            } else if let reason {
                result["reason"] = reason
            }
            return result
        }
    }

    init(action: [String: Any], environment: [String: String]) throws {
        workingDirectoryInput = try Self.absolutePath(action["working_directory"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                                      field: "working_directory")
        workingDirectory = workingDirectoryInput.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, Darwin.access(workingDirectory.path, R_OK | X_OK) == 0 else {
            throw TaskToolError.invalidAction("working_directory must be an accessible existing directory")
        }
        do { try ActionContract.validateParameters(action, kind: .run_command) }
        catch { throw TaskToolError.invalidAction(error.localizedDescription) }
        timeout = (action["timeout_seconds"] as? NSNumber ?? ActionContract.defaultValue(.run_command, "timeout_seconds") as! NSNumber).doubleValue
        if let source = action["command"] as? String {
            shellSource = source
            executable = URL(fileURLWithPath: "/bin/zsh")
            arguments = ["-f", "-c", source]
            displayCommand = source
        } else {
            let argv = action["argv"] as! [String]
            executable = try Self.resolveExecutable(argv[0], cwd: workingDirectory, environment: environment)
            arguments = Array(argv.dropFirst())
            shellSource = nil
            displayCommand = argv.map(Self.quoteLiteral).joined(separator: " ")
        }
        outcomeChecks = try CommandOperationPreparation.checks(action: action)
        checks = try outcomeChecks.map { value in
            let kind = OutcomeCheckKind(rawValue: value["type"] as! String)!
            switch kind {
            case .stdout_equals:
                return Check(type: kind.rawValue, path: nil, expected: nil, text: value["text"] as? String)
            case .file_exists, .directory_exists, .path_absent, .file_contents:
                let path = try Self.absolutePath(value["path"], field: "checks.path")
                var expected: Data?
                if kind == .file_contents {
                    let content = value["content"] as! String
                    let encoding = value["encoding"] as? String ?? ActionContract.defaultValue(.write_file, "encoding") as! String
                    expected = encoding == "base64" ? Data(base64Encoded: content)! : Data(content.utf8)
                }
                return Check(type: kind.rawValue, path: path, expected: expected, text: nil)
            }
        }
    }

    static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func string(_ value: Any?, field: String, nonempty: Bool = false, allowNUL: Bool = false) throws -> String {
        guard let text = value as? String, allowNUL || !text.contains("\0"),
              !nonempty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskToolError.invalidAction(field + " must be a " + (nonempty ? "nonempty " : "") + "string without NUL bytes")
        }
        return text
    }

    private static func absolutePath(_ value: Any?, field: String) throws -> URL {
        let path = try string(value, field: field, nonempty: true)
        guard path.hasPrefix("/") || path.hasPrefix("~/") else {
            throw TaskToolError.invalidAction(field + " must be an absolute or ~/ path")
        }
        return TaskToolExecutor.expandedFileURL(path)
    }

    static func resolveExecutable(_ name: String, cwd: URL, environment: [String: String]) throws -> URL {
        let candidates: [URL]
        if name.hasPrefix("/") || name.hasPrefix("~/") {
            candidates = [TaskToolExecutor.expandedFileURL(name)]
        } else if name.contains("/") {
            candidates = [cwd.appendingPathComponent(name).standardizedFileURL]
        } else {
            // Do not search an implicit cwd or relative PATH entry.
            candidates = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw TaskToolError.commandCapability("command_tool_missing", "Executable '\(name)' was not found in the inspected PATH or working directory")
    }
}
