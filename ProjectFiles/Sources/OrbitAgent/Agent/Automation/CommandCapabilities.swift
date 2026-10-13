import CryptoKit
import Darwin
import Foundation

/// Private preflight data, never a model-selected action or completion fact.
enum CommandCapabilities {
    static let version = 1
    static let maximumTools = 12
    static let maximumBindings = 64
    static let probeBudget: TimeInterval = 2
    static let outputLimit = 65_536

    struct Identity: Equatable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        let changed: timespec
        let mode: mode_t

        static func == (a: Self, b: Self) -> Bool {
            a.path == b.path && a.device == b.device && a.inode == b.inode && a.size == b.size &&
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec && a.mode == b.mode
        }
        init(_ url: URL, directory: Bool = false) throws {
            path = url.resolvingSymlinksInPath().standardizedFileURL.path
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                  directory || Darwin.access(path, X_OK) == 0 else {
                throw TaskToolError.commandCapability("command_tool_missing", "The inspected executable or working directory is unavailable")
            }
            device = metadata.st_dev; inode = metadata.st_ino; size = directory ? 0 : metadata.st_size
            modified = directory ? timespec() : metadata.st_mtimespec
            changed = directory ? timespec() : metadata.st_ctimespec
            mode = metadata.st_mode
        }
    }

    struct Invocation {
        let name: String
        let arguments: [String?]
        let range: Range<Int>?
        let overrides: [String: String]
    }
    struct Source {
        let invocations: [Invocation]
        let complete: Bool
        let builtinOnly: Bool
        let characters: [Character]?

        func binding(_ paths: [String]) -> String? {
            guard complete, var characters else { return nil }
            for (invocation, path) in zip(invocations, paths).reversed() {
                if let range = invocation.range { characters.replaceSubrange(range, with: CommandExecutionPolicy.quoteLiteral(path)) }
            }
            return String(characters)
        }
    }
    private struct Token { let text: String?; let range: Range<Int>; let separator: String? }
    private static let builtins: Set<String> = [":", "true", "false", "printf", "echo", "pwd", "cd", "exit", "export", "unset", "set", "test"]
    private static let syntax: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "select", "repeat", "eval", "exec", "source", ".", "command", "builtin", "env", "sudo", "!", "time", "nocorrect", "noglob", "coproc"]

    /// Deliberately conservative lexical analysis. It never evaluates source,
    /// substitutions, expansion, redirections or user initialization files.
    /// Only fully recognized literal command positions can be rewritten.
    static func source(_ policy: CommandExecutionPolicy) -> Source {
        guard let source = policy.shellSource else {
            return Source(invocations: [.init(name: policy.executable.path, arguments: policy.arguments.map { $0 }, range: nil, overrides: [:])],
                          complete: true, builtinOnly: false, characters: nil)
        }
        let characters = Array(source)
        var tokens: [Token] = [], index = 0, complete = true
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace && c != "\n" { index += 1; continue }
            if "|;&\n<>".contains(c) {
                let start = index; index += 1
                if index < characters.count && characters[index] == c && c != "\n" { index += 1 }
                tokens.append(.init(text: nil, range: start..<index, separator: String(characters[start..<index])))
                if c == "&" && index - start == 1 { complete = false }
                continue
            }
            if c == "#" { while index < characters.count && characters[index] != "\n" { index += 1 }; continue }
            let start = index
            var value = "", literal = true, quote: Character?
            while index < characters.count {
                let c = characters[index]
                if quote == nil && (c.isWhitespace || "|;&<>".contains(c)) { break }
                if c == "\\", quote != "'" {
                    index += 1
                    guard index < characters.count else { complete = false; break }
                    if quote == "\"", !"$`\"\\\n".contains(characters[index]) { value.append("\\") }
                    if characters[index] != "\n" { value.append(characters[index]) }
                } else if c == "'" || c == "\"" {
                    if quote == c { quote = nil }
                    else if quote == nil { quote = c }
                    else { value.append(c) }
                } else {
                    if quote != "'" && "$`*?[](){}".contains(c) { literal = false }
                    value.append(c)
                }
                index += 1
            }
            if quote != nil { complete = false }
            if !literal { complete = false }
            tokens.append(.init(text: literal ? value : nil, range: start..<index, separator: nil))
        }
        var invocations: [Invocation] = [], segment: [Token] = [], sawCommand = false
        func collect() {
            defer { segment.removeAll() }
            var words: [Token] = [], redirect = false
            for token in segment {
                if let separator = token.separator {
                    if ["<", ">", ">>"].contains(separator) {
                        if let previous = words.last, previous.range.upperBound == token.range.lowerBound,
                           previous.text?.allSatisfy(\.isNumber) == true { words.removeLast() }
                        redirect = true
                    }
                    else { complete = false }
                } else if redirect { redirect = false }
                else { words.append(token) }
            }
            if redirect { complete = false }
            var overrides: [String: String] = [:]
            while let first = words.first, let text = first.text,
                  let equal = text.firstIndex(of: "="), text[..<equal].range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                overrides[String(text[..<equal])] = String(text[text.index(after: equal)...]); words.removeFirst()
            }
            // Standalone assignments can change resolution for later commands.
            guard let head = words.first else { if !overrides.isEmpty { complete = false }; return }
            guard let name = head.text, !name.isEmpty, !syntax.contains(name) else { complete = false; return }
            sawCommand = true
            if ["cd", "export", "unset", "set"].contains(name) { complete = false }
            if builtins.contains(name) { return }
            // Shell tilde expansion depends on quoting and user lookup; argv
            // paths are expanded by the existing contract instead.
            if name.hasPrefix("~") { complete = false }
            if let path = overrides["PATH"], path.split(separator: ":", omittingEmptySubsequences: false).contains(where: { !$0.hasPrefix("/") }) { complete = false }
            invocations.append(.init(name: name, arguments: words.dropFirst().map(\.text), range: head.range, overrides: overrides))
        }
        for token in tokens {
            if let separator = token.separator, ["|", "||", "&&", ";", "\n"].contains(separator) { collect() }
            else { segment.append(token) }
        }
        collect()
        if invocations.count > maximumTools { complete = false }
        // Ambiguous shell grammar can contain text that is not an invocation.
        // Do not resolve guessed heads or rewrite any part of such a script.
        return .init(invocations: complete ? invocations : [], complete: complete,
                     builtinOnly: complete && sawCommand && invocations.isEmpty, characters: characters)
    }

    struct Profile {
        let arguments: [String]
        let context: String
        let exhaustiveLongOptions: Bool
    }
    /// Only established help-only interfaces are executable probes. Unknown
    /// tools/scripts remain usable, but their flags are explicitly unverified.
    static func profile(path: String, arguments: [String?]) -> Profile? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let trusted = ["/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/opt/homebrew/Cellar/", "/usr/local/Cellar/"].contains { path.hasPrefix($0) }
        guard trusted else { return nil }
        if name == "git" {
            let supported: Set<String> = ["status", "diff", "log", "show", "add", "commit", "branch", "checkout", "switch", "restore", "fetch", "push", "pull", "clone", "remote", "rev-parse", "ls-files"]
            var index = 0, prefix: [String] = []
            while index + 1 < arguments.count, arguments[index] == "-C", let directory = arguments[index + 1] {
                prefix += ["-C", directory]; index += 2
            }
            if index < arguments.count, let first = arguments[index], supported.contains(first) {
                return .init(arguments: ["--no-pager"] + prefix + [first, "-h"], context: first, exhaustiveLongOptions: false)
            }
            return .init(arguments: ["--help"], context: "global", exhaustiveLongOptions: false)
        }
        if ["python", "python3", "node", "ruby", "perl", "bash", "zsh"].contains(name) || name.hasPrefix("python3.") {
            return .init(arguments: ["--help"], context: "global", exhaustiveLongOptions: false)
        }
        let groups: [String: Set<String>] = ["swift": ["build", "test", "package", "run"],
            "cargo": ["build", "check", "test", "run", "clippy", "fmt"], "go": ["build", "test", "run", "list", "mod"]]
        if let supported = groups[name] {
            if let first = arguments.first ?? nil, supported.contains(first) {
                return .init(arguments: name == "go" ? ["help", first] : [first, "--help"], context: first, exhaustiveLongOptions: false)
            }
            return .init(arguments: name == "go" ? ["help"] : ["--help"], context: "global", exhaustiveLongOptions: false)
        }
        if ["npm", "pnpm", "yarn", "bun", "rustc", "make"].contains(name) {
            return .init(arguments: ["--help"], context: "global", exhaustiveLongOptions: false)
        }
        if name == "xcodebuild" { return .init(arguments: ["-help"], context: "global", exhaustiveLongOptions: false) }
        if ["rg", "fd", "jq", "curl", "tar", "gzip", "zip", "unzip"].contains(name) {
            let help = ["zip", "unzip"].contains(name) ? "-h" : "--help"
            // Help can omit aliases or implicit --no-* forms, even when all
            // documented options were printed. Absence is not rejection proof.
            return .init(arguments: name == "curl" ? ["--help", "all"] : [help], context: "global", exhaustiveLongOptions: false)
        }
        return nil
    }

    static func longOptions(_ help: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])--[A-Za-z][A-Za-z0-9-]*")
        return Set(pattern.matches(in: help, range: NSRange(help.startIndex..., in: help)).compactMap { Range($0.range, in: help).map { String(help[$0]) } })
    }
    static func shortOptions(_ help: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])-[A-Za-z0-9](?![A-Za-z0-9_-])")
        return Set(pattern.matches(in: help, range: NSRange(help.startIndex..., in: help)).compactMap { Range($0.range, in: help).map { String(help[$0]) } })
    }
    static func valueOptions(_ help: String) -> [String: Int] {
        var values: [String: Int] = [:]
        let pattern = try! NSRegularExpression(pattern: "(--[A-Za-z][A-Za-z0-9-]*)[ =]+((?:<[^>\\r\\n]+>[ ]*)+|(?:name|filename)[ ]+(?:value|JSON|text)|(?:name|filename)(?=[ ;]))")
        for match in pattern.matches(in: help, range: NSRange(help.startIndex..., in: help)) {
            guard let flagRange = Range(match.range(at: 1), in: help), let valueRange = Range(match.range(at: 2), in: help) else { continue }
            let flag = String(help[flagRange]), placeholders = String(help[valueRange])
            let count = placeholders.contains("<") ? placeholders.filter { $0 == "<" }.count : placeholders.split(separator: " ").count
            values[flag] = min(4, count)
            let lineStart = help.range(of: "\n", options: .backwards, range: help.startIndex..<flagRange.lowerBound)?.upperBound ?? help.startIndex
            let prefix = String(help[lineStart..<flagRange.lowerBound])
            for short in shortOptions(prefix) { values[short] = min(4, count) }
        }
        return values
    }
    static func requestedLongOptions(_ arguments: [String?], takingValues: [String: Int] = [:]) -> Set<String> {
        var flags: Set<String> = [], index = 0
        while index < arguments.count {
            guard let argument = arguments[index] else { index += 1; continue }
            if argument == "--" { break }
            let parts = argument.split(separator: "=", maxSplits: 1)
            let flag = parts.first.map(String.init) ?? argument
            if argument.hasPrefix("--") { flags.insert(flag) }
            index += 1 + max(0, (takingValues[flag] ?? 0) - (parts.count > 1 ? 1 : 0))
        }
        return flags
    }
    static func digest(_ object: Any) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }

    struct Tool {
        let invocation: Invocation
        let identity: Identity
        let environment: [String: String]
        let summary: [String: Any]
    }
    struct Binding {
        let id: String
        let created: TimeInterval
        let actionKey: String
        let generation: String?
        let suspension: Int
        let policy: CommandExecutionPolicy
        let environment: [String: String]
        let directory: Identity
        let shell: Identity?
        let tools: [Tool]
        let source: Source
        let result: [String: Any]

        func validate() throws {
            try TaskOwnership.check()
            let currentShell = try shell.map { _ in try Identity(policy.executable) }
            guard generation == TaskOwnership.current?.id, suspension == (TaskOwnership.current?.suspensionRevision ?? 0),
                  ProcessInfo.processInfo.systemUptime - created < 120,
                  try Identity(policy.workingDirectoryInput, directory: true) == directory,
                  currentShell == shell else {
                throw TaskToolError.commandCapability("command_capabilities_changed", "The command environment changed; inspect the tool again before execution")
            }
            for tool in tools {
                let current = try CommandExecutionPolicy.resolveExecutable(tool.invocation.name, cwd: policy.workingDirectory, environment: tool.environment)
                guard try Identity(current) == tool.identity else {
                    throw TaskToolError.commandCapability("command_capabilities_changed", "The executable changed since option inspection; no command was delivered")
                }
            }
        }
        var executable: URL { policy.shellSource == nil ? URL(fileURLWithPath: tools[0].identity.path) : policy.executable }
        var arguments: [String] {
            if let bound = source.binding(tools.map { $0.identity.path }) { return ["-f", "-c", bound] }
            return policy.arguments
        }
    }
}
