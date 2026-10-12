import Darwin
import Foundation

/// Local preflight for the generated recipes. It cannot launch a process.
/// Source bytes stay in memory and become bounded, exact outcome checks.
enum CommandOperationPreparation {
    static func checks(action: [String: Any]) throws -> [[String: Any]] {
        var checks = action["checks"] as? [[String: Any]] ?? []
        guard let operation = action["operation"] as? [String: Any] else { return checks }
        let recipe = ActionContract.operationDefinition(operation["type"] as! String)!
        try TaskOwnership.check()
        func url(_ field: String) -> URL { TaskToolExecutor.expandedFileURL(operation[field] as! String) }
        func info(_ field: String, absentAllowed: Bool = false) throws -> stat? {
            var value = stat()
            if Darwin.lstat(url(field).path, &value) == 0 { return value }
            if absentAllowed && (errno == ENOENT || errno == ENOTDIR) { return nil }
            throw TaskToolError.invalidAction("operation.\(field) could not be inspected before execution")
        }
        if let field = recipe["absent"] as? String, try info(field, absentAllowed: true) != nil {
            throw TaskToolError.invalidAction("operation.\(field) already exists; this template never overwrites a destination")
        }
        for key in ["regular_file", "regular_file_if_present"] {
            if let field = recipe[key] as? String, let value = try info(field, absentAllowed: key == "regular_file_if_present"),
               value.st_mode & S_IFMT != S_IFREG {
                throw TaskToolError.invalidAction("operation.\(field) must be a regular file, not a directory or symbolic link")
            }
        }
        if let field = recipe["directory"] as? String, let value = try info(field), value.st_mode & S_IFMT != S_IFDIR {
            throw TaskToolError.invalidAction("operation.\(field) must be a directory, not a symbolic link")
        }
        if let field = recipe["parent_directory"] as? String {
            let parent = url(field).deletingLastPathComponent()
            guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw TaskToolError.invalidAction("operation.\(field) must have an existing parent directory")
            }
        }
        if let snapshot = recipe["snapshot"] as? [String: Any] {
            let source = snapshot["source"] as! String, destination = snapshot["destination"] as! String
            let limit = (snapshot["max_bytes"] as! NSNumber).intValue
            let descriptor = Darwin.open(url(source).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw TaskToolError.invalidAction("operation.\(source) could not be read safely") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat(), after = stat()
            guard Darwin.fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size >= 0, before.st_size <= limit else {
                throw TaskToolError.invalidAction("operation.\(source) must be a regular file of at most \(limit) bytes; use general execution for larger files")
            }
            let bytes = try handle.read(upToCount: limit + 1) ?? Data()
            try TaskOwnership.check()
            guard Darwin.fstat(descriptor, &after) == 0, bytes.count == before.st_size,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw TaskToolError.invalidAction("operation.\(source) changed during preflight; inspect it again before execution")
            }
            let snapshotCheck: [String: Any] = ["type": "file_contents", "path": operation[destination]!,
                                               "content": bytes.base64EncodedString(), "encoding": "base64"]
            if !checks.contains(where: { NSDictionary(dictionary: $0).isEqual(to: snapshotCheck) }) { checks.append(snapshotCheck) }
        }
        try TaskOwnership.check()
        // Check the augmented list against the same bounds as ordinary commands.
        _ = try ActionContract.validate(["type": "run_command", "argv": action["argv"]!, "checks": checks])
        return checks
    }
}
