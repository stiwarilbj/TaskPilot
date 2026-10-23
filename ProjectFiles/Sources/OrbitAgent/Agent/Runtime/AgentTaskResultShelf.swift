import AppKit
import CryptoKit
import Darwin
import Foundation
import QuickLookUI
import SwiftUI

enum AgentTaskResultKind: String, Equatable {
    case file
    case folder
    case web
}

enum AgentTaskResultState: String, Equatable {
    case verified
    case needsRecheck = "needs_recheck"
}

struct AgentTaskResultObject: Equatable, Identifiable {
    let id: String
    let kind: AgentTaskResultKind
    let state: AgentTaskResultState
    let name: String
    let location: String
    let path: String?
    let url: String?
    let fileIdentity: String?
    let fileVersion: String?
    let parentIdentity: String?

    var estimatedByteCount: Int {
        id.utf8.count + name.utf8.count + location.utf8.count +
            (path?.utf8.count ?? 0) + (url?.utf8.count ?? 0) +
            (fileIdentity?.utf8.count ?? 0) + (fileVersion?.utf8.count ?? 0) +
            (parentIdentity?.utf8.count ?? 0) + 96
    }

    static func parseList(_ value: Any?) -> [Self]? {
        guard let rows = value as? [[String: Any]], rows.count <= 128 else { return nil }
        var items: [Self] = []
        var identifiers = Set<String>()
        var destinations = Set<String>()
        var byteCount = 0
        for row in rows {
            guard let kind = row["kind"] as? String,
                  let resultKind = AgentTaskResultKind(rawValue: kind),
                  let stateValue = row["state"] as? String,
                  let state = AgentTaskResultState(rawValue: stateValue),
                  let name = row["name"] as? String, !name.isEmpty, name.utf8.count <= 512,
                  let location = row["location"] as? String, !location.isEmpty, location.utf8.count <= 4096,
                  let identifier = row["id"] as? String,
                  identifiers.insert(identifier).inserted else { return nil }

            let item: Self
            switch resultKind {
            case .file, .folder:
                let allowed: Set<String> = ["id", "kind", "state", "name", "location", "path",
                                            "file_identity", "file_version", "parent_identity"]
                guard Set(row.keys).isSubset(of: allowed),
                      Set(row.keys).isSuperset(of: ["id", "kind", "state", "name", "location", "path"]),
                      let path = row["path"] as? String, path.hasPrefix("/"),
                      !path.contains("\0"), path.utf8.count <= 4096,
                      URL(fileURLWithPath: path).standardizedFileURL.path == path,
                      URL(fileURLWithPath: path).lastPathComponent == name,
                      URL(fileURLWithPath: path).deletingLastPathComponent().path == location,
                      identifier == resultID(kind: resultKind, target: path),
                      destinations.insert("\(kind)\0\(path)").inserted else { return nil }
                let identity = row["file_identity"] as? String
                let version = row["file_version"] as? String
                let parent = row["parent_identity"] as? String
                guard validDigest(identity), validDigest(version), validDigest(parent) else { return nil }
                item = Self(id: identifier, kind: resultKind, state: state, name: name, location: location,
                            path: path, url: nil, fileIdentity: identity, fileVersion: version,
                            parentIdentity: parent)
            case .web:
                guard Set(row.keys) == ["id", "kind", "state", "name", "location", "url", "hostname"],
                      let url = row["url"] as? String, url.utf8.count <= 4096,
                      let hostname = row["hostname"] as? String, !hostname.isEmpty, hostname.utf8.count <= 253,
                      safeWebURL(url)?.host?.lowercased() == hostname.lowercased(),
                      identifier == resultID(kind: .web, target: url),
                      destinations.insert("web\0\(url)").inserted else { return nil }
                item = Self(id: identifier, kind: .web, state: state, name: name, location: location,
                            path: nil, url: url, fileIdentity: nil, fileVersion: nil, parentIdentity: nil)
            }
            guard identifiers.contains(item.id) else { return nil }
            byteCount += item.estimatedByteCount
            guard byteCount <= 512 * 1024 else { return nil }
            items.append(item)
        }
        return items
    }

    static func resultID(kind: AgentTaskResultKind, target: String) -> String {
        let prefix = [AgentTaskResultKind.file: "f", .folder: "d", .web: "w"][kind]!
        let digest = SHA256.hash(data: Data((kind.rawValue + "\0" + target).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(prefix):\(digest)"
    }

    private static func validDigest(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    static func safeWebURL(_ value: String) -> URLComponents? {
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return components
    }
}

enum TaskResultShelfAction: String, CaseIterable {
    case quickLook
    case openFolder
    case reveal
    case copyPath
    case openWebsite

    var title: String {
        switch self {
        case .quickLook: "Quick Look"
        case .openFolder: "Open"
        case .reveal: "Reveal"
        case .copyPath: "Copy Path"
        case .openWebsite: "Open"
        }
    }

    var symbol: String {
        switch self {
        case .quickLook: "eye"
        case .openFolder: "arrow.up.forward.app"
        case .reveal: "folder"
        case .copyPath: "doc.on.doc"
        case .openWebsite: "safari"
        }
    }

    static func available(for result: AgentTaskResultObject) -> [TaskResultShelfAction] {
        switch result.kind {
        case .file: [.quickLook, .reveal, .copyPath]
        case .folder: [.openFolder, .reveal, .copyPath]
        case .web: [.openWebsite]
        }
    }
}

enum TaskResultShelfActionOutcome: Equatable {
    case completed
    case preview(URL)
    case unavailable(String)
}

@MainActor
struct TaskResultShelfDispatcher {
    let handler: (TaskResultShelfAction, AgentTaskResultObject) -> TaskResultShelfActionOutcome

    func perform(_ action: TaskResultShelfAction, for item: AgentTaskResultObject) -> TaskResultShelfActionOutcome {
        handler(action, item)
    }
}

enum TaskResultShelfActionService {
    @MainActor
    static func perform(_ action: TaskResultShelfAction, for item: AgentTaskResultObject) -> TaskResultShelfActionOutcome {
        if action == .copyPath {
            guard let path = item.path else { return .unavailable("This result has no local path.") }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(path, forType: .string) else {
                return .unavailable("The verified path could not be copied.")
            }
            return .completed
        }
        if action == .openWebsite {
            guard item.kind == .web, let raw = item.url,
                  let components = AgentTaskResultObject.safeWebURL(raw), let url = components.url,
                  NSWorkspace.shared.open(url) else {
                return .unavailable("TaskPilot could not open this web destination.")
            }
            return .completed
        }
        guard let path = item.path, item.kind != .web,
              TaskResultFileIdentity.matches(item) else {
            return .unavailable("This file or folder changed or disappeared after TaskPilot verified it. Refresh the task result before opening it.")
        }
        let url = URL(fileURLWithPath: path)
        switch action {
        case .quickLook where item.kind == .file:
            return .preview(url)
        case .openFolder where item.kind == .folder:
            return NSWorkspace.shared.open(url) ? .completed : .unavailable("The folder could not be opened.")
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .completed
        default:
            return .unavailable("This action is not available for the selected result.")
        }
    }
}

private enum TaskResultFileIdentity {
    static func matches(_ item: AgentTaskResultObject) -> Bool {
        guard let path = item.path else { return false }
        var target = stat()
        guard path.withCString({ lstat($0, &target) }) == 0 else { return false }
        let fileType = target.st_mode & S_IFMT
        guard (item.kind == .file && fileType == S_IFREG) || (item.kind == .folder && fileType == S_IFDIR) else {
            return false
        }
        let targetIdentity = identity(target)
        if let expected = item.fileIdentity, targetIdentity.object != expected { return false }
        if let expected = item.fileVersion, targetIdentity.version != expected { return false }
        if let expected = item.parentIdentity {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard let resolved = realpath(parent, nil) else { return false }
            defer { free(resolved) }
            var parentInfo = stat()
            guard stat(resolved, &parentInfo) == 0, identity(parentInfo).object == expected else { return false }
        }
        return true
    }

    private static func identity(_ info: stat) -> (object: String, version: String) {
        let birth = info.st_birthtimespec
        let objectInput = "\(info.st_dev):\(info.st_ino):\(birth.tv_sec):\(birth.tv_nsec)"
        let object = SHA256.hash(data: Data(objectInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        let versionInput = "\(object):\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec):\(info.st_mode)"
        let version = SHA256.hash(data: Data(versionInput.utf8)).map { String(format: "%02x", $0) }.joined()
        return (object, version)
    }
}

struct TaskResultShelfView: View {
    typealias ActionHandler = @MainActor (TaskResultShelfAction, AgentTaskResultObject) -> TaskResultShelfActionOutcome

    let results: [AgentTaskResultObject]
    let surface: Color
    let border: Color
    let accent: Color
    let actionHandler: ActionHandler?
    @State private var previewURL: URL?
    @State private var previewTitle = ""
    @State private var actionMessage: String?

    init(results: [AgentTaskResultObject], surface: Color, border: Color, accent: Color,
         actionHandler: ActionHandler? = nil) {
        self.results = results
        self.surface = surface
        self.border = border
        self.accent = accent
        self.actionHandler = actionHandler
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Results", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Verified during this task")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 9) {
                    ForEach(results) { result in
                        resultCard(result)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            .accessibilityLabel("Task result cards; scroll horizontally for more results")
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(actionMessage)
            }
        }
        .onChange(of: results) { _, _ in
            actionMessage = nil
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL {
                TaskResultQuickLookView(url: previewURL)
                    .frame(minWidth: 620, minHeight: 440)
                    .padding(12)
                    .accessibilityLabel("Quick Look preview of \(previewTitle)")
            }
        }
    }

    @ViewBuilder
    private func resultCard(_ result: AgentTaskResultObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: result))
                    .font(.title3)
                    .foregroundStyle(accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .help(result.name)
                    Text(result.location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(result.location)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                if result.state == .needsRecheck {
                    Label("Needs recheck", systemImage: "arrow.clockwise.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Text("Verified during this run")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                ForEach(TaskResultShelfAction.available(for: result), id: \.rawValue) { action in
                    Button(action.title) { perform(action, for: result) }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(accent)
                        .help("\(action.title) \(result.name)")
                        .accessibilityLabel("\(action.title) \(result.name)")
                }
            }
        }
        .padding(10)
        .frame(width: 276, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.kind == .web ? "Website" : result.kind == .folder ? "Folder" : "File"), \(result.name), \(result.location), \(result.state == .verified ? "verified during this task" : "needs recheck")")
    }

    private func icon(for result: AgentTaskResultObject) -> String {
        switch result.kind {
        case .file: "doc"
        case .folder: "folder"
        case .web: "globe"
        }
    }

    private func perform(_ action: TaskResultShelfAction, for result: AgentTaskResultObject) {
        let handler = actionHandler ?? TaskResultShelfActionService.perform
        switch TaskResultShelfDispatcher(handler: handler).perform(action, for: result) {
        case .completed:
            actionMessage = action == .copyPath ? "Path copied." : nil
        case .preview(let url):
            previewURL = url
            previewTitle = result.name
            actionMessage = nil
        case .unavailable(let message):
            actionMessage = message
        }
    }
}

struct TaskResultQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        Self.previewView(for: url)
    }

    static func previewView(for url: URL,
                            factory: (NSRect, QLPreviewViewStyle) -> QLPreviewView? = {
                                QLPreviewView(frame: $0, style: $1)
                            }) -> NSView {
        guard let preview = factory(.zero, .normal) else {
            let message = NSTextField(wrappingLabelWithString: "Quick Look preview is unavailable for this result.")
            message.alignment = .center
            message.setAccessibilityLabel(message.stringValue)
            return message
        }
        preview.previewItem = url as NSURL
        preview.autostarts = true
        preview.shouldCloseWithWindow = true
        return preview
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = view as? QLPreviewView else { return }
        preview.previewItem = url as NSURL
        preview.refreshPreviewItem()
    }
}
