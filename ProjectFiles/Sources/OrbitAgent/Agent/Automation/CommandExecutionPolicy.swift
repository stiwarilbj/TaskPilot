import CoreFoundation
import Darwin
import Foundation

/// Validates everything before launching a process. Literal argv entries never
/// pass through a shell; shell source is preserved and checked separately.
struct CommandExecutionPolicy {
    let workingDirectory: URL
    let executable: URL
    let arguments: [String]
    let shellSource: String?
    let displayCommand: String
    let timeout: TimeInterval
    let checks: [Check]

    struct Check {
        let type: String
        let path: URL?
        let expected: Data?
        let text: String?

        func evaluate(stdout: String, stdoutTruncated: Bool) -> [String: Any] {
            var result: [String: Any] = ["type": type, "verified": false]
            if let path { result["path"] = path.path }
            do {
                let matches: Bool
                switch type {
                case "stdout_equals":
                    matches = !stdoutTruncated && stdout == text
                case "path_absent":
                    var info = stat()
                    let status = Darwin.lstat(path!.path, &info)
                    matches = status != 0 && (errno == ENOENT || errno == ENOTDIR)
                case "file_exists", "directory_exists", "file_contents":
                    let values = try path!.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    if type == "directory_exists" {
                        matches = values.isDirectory == true
                    } else if type == "file_exists" {
                        matches = values.isRegularFile == true
                    } else if values.isRegularFile == true {
                        let handle = try FileHandle(forReadingFrom: path!)
                        defer { try? handle.close() }
                        // Bound reads and reject a matching prefix of a larger file.
                        let bytes = try handle.read(upToCount: expected!.count + 1) ?? Data()
                        matches = bytes == expected!
                    } else {
                        matches = false
                    }
                default:
                    matches = false
                }
                result["verified"] = matches
                if !matches { result["reason"] = "The requested outcome did not match" }
            } catch {
                result["reason"] = "The requested outcome could not be inspected"
            }
            return result
        }
    }

    init(action: [String: Any], environment: [String: String]) throws {
        workingDirectory = try Self.absolutePath(action["working_directory"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                                 field: "working_directory").resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue, Darwin.access(workingDirectory.path, R_OK | X_OK) == 0 else {
            throw TaskToolError.invalidAction("working_directory must be an accessible existing directory")
        }
        if let value = action["timeout_seconds"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0.2...900).contains(number.doubleValue) else {
                throw TaskToolError.invalidAction("timeout_seconds must be a finite number between 0.2 and 900")
            }
            timeout = number.doubleValue
        } else { timeout = 120 }
        guard (action["command"] != nil) != (action["argv"] != nil) else {
            throw TaskToolError.invalidAction("run_command requires exactly one of command or argv")
        }
        if let raw = action["command"] {
            let source = try Self.string(raw, field: "command", nonempty: true)
            guard source.utf8.count <= TaskToolExecutor.maximumCommandLength else {
                throw TaskToolError.invalidAction("command exceeds the 16384-byte limit")
            }
            shellSource = source
            executable = URL(fileURLWithPath: "/bin/zsh")
            arguments = ["-f", "-c", source]
            displayCommand = source
        } else {
            guard let values = action["argv"] as? [Any], !values.isEmpty, values.count <= 256 else {
                throw TaskToolError.invalidAction("argv must contain 1 to 256 strings")
            }
            let argv = try values.enumerated().map { try Self.string($0.element, field: "argv[\($0.offset)]", nonempty: $0.offset == 0) }
            guard argv.reduce(0, { $0 + $1.utf8.count + 1 }) <= TaskToolExecutor.maximumCommandLength else {
                throw TaskToolError.invalidAction("argv exceeds the 16384-byte limit")
            }
            executable = try Self.resolveExecutable(argv[0], cwd: workingDirectory, environment: environment)
            arguments = Array(argv.dropFirst())
            shellSource = nil
            displayCommand = argv.map(Self.quoteLiteral).joined(separator: " ")
        }
        if let raw = action["checks"] {
            guard let values = raw as? [[String: Any]], !values.isEmpty, values.count <= 16 else {
                throw TaskToolError.invalidAction("checks must contain 1 to 16 outcome checks")
            }
            checks = try values.enumerated().map { index, value in
                let field = "checks[\(index)]"
                let type = try Self.string(value["type"], field: field + ".type", nonempty: true)
                guard ["file_exists", "directory_exists", "path_absent", "file_contents", "stdout_equals"].contains(type) else {
                    throw TaskToolError.invalidAction(field + ".type is unsupported")
                }
                let allowed: Set<String> = type == "stdout_equals" ? ["type", "text"] :
                    type == "file_contents" ? ["type", "path", "content", "encoding"] : ["type", "path"]
                guard Set(value.keys).isSubset(of: allowed) else {
                    throw TaskToolError.invalidAction(field + " contains unsupported parameters")
                }
                if type == "stdout_equals" {
                    let text = try Self.string(value["text"], field: field + ".text")
                    guard text.utf8.count <= TaskToolExecutor.maximumCommandOutputBytes else {
                        throw TaskToolError.invalidAction(field + ".text exceeds the output limit")
                    }
                    return Check(type: type, path: nil, expected: nil, text: text)
                }
                let path = try Self.absolutePath(value["path"], field: field + ".path")
                var expected: Data?
                if type == "file_contents" {
                    let content = try Self.string(value["content"], field: field + ".content", allowNUL: true)
                    let encoding = try Self.string(value["encoding"] ?? "utf-8", field: field + ".encoding")
                    if encoding == "utf-8" || encoding == "utf8" { expected = Data(content.utf8) }
                    else if encoding == "base64", let bytes = Data(base64Encoded: content) { expected = bytes }
                    else { throw TaskToolError.invalidAction(field + " requires utf-8 or valid base64 content") }
                    guard expected!.count <= TaskToolExecutor.maximumWriteBytes else {
                        throw TaskToolError.invalidAction(field + ".content exceeds the 2 MiB limit")
                    }
                }
                return Check(type: type, path: path, expected: expected, text: nil)
            }
        } else { checks = [] }
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

    private static func resolveExecutable(_ name: String, cwd: URL, environment: [String: String]) throws -> URL {
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
        throw TaskToolError.invalidAction("argv[0] must identify an existing executable")
    }
}
