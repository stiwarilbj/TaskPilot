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

enum TaskResultShelfEntry: Equatable, Identifiable {
    case result(AgentTaskResultObject)
    case folderStack(id: String, path: String, results: [AgentTaskResultObject])

    var id: String {
        switch self {
        case .result(let result): result.id
        case .folderStack(let id, _, _): id
        }
    }

    var isFolderStack: Bool {
        if case .folderStack = self { return true }
        return false
    }

    var results: [AgentTaskResultObject] {
        switch self {
        case .result(let result): [result]
        case .folderStack(_, _, let results): results
        }
    }

    static func grouped(_ results: [AgentTaskResultObject]) -> [Self] {
        enum PendingEntry {
            case result(AgentTaskResultObject)
            case files(path: String, results: [AgentTaskResultObject])
        }

        var pending: [PendingEntry] = []
        var stackPositions: [String: Int] = [:]

        for result in results {
            guard result.kind == .file, let path = result.path else {
                pending.append(.result(result))
                continue
            }

            let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            if let position = stackPositions[parentPath], case .files(let storedPath, var files) = pending[position] {
                files.append(result)
                pending[position] = .files(path: storedPath, results: files)
            } else {
                stackPositions[parentPath] = pending.count
                pending.append(.files(path: parentPath, results: [result]))
            }
        }

        return pending.map { entry in
            switch entry {
            case .result(let result):
                .result(result)
            case .files(let path, let files) where files.count >= 2:
                .folderStack(id: "stack:\(path)", path: path, results: files)
            case .files(_, let files):
                .result(files[0])
            }
        }
    }
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
    typealias ChangeCorrectionHandler = @MainActor (AgentTaskChangeLensSnapshot, String, String, String, String, String) -> AgentTaskChangeCorrectionOutcome

    let results: [AgentTaskResultObject]
    let changeSnapshots: [String: AgentTaskChangeLensSnapshot]
    let taskRequest: String
    let requirements: [AgentTaskProgressRequirement]
    let taskIsActive: Bool
    let surface: Color
    let border: Color
    let accent: Color
    let actionHandler: ActionHandler?
    let changeCorrectionHandler: ChangeCorrectionHandler?
    @State private var previewResult: AgentTaskResultObject?
    @State private var previewURL: URL?
    @State private var previewSnapshot: AgentTaskChangeLensSnapshot?
    @State private var previewInstruction = ""
    @State private var presentedStack: TaskResultShelfEntry?
    @State private var pendingPreview: (url: URL, result: AgentTaskResultObject)?
    @State private var actionMessages: [String: String] = [:]

    private var entries: [TaskResultShelfEntry] { TaskResultShelfEntry.grouped(results) }

    init(results: [AgentTaskResultObject], changeSnapshots: [String: AgentTaskChangeLensSnapshot] = [:],
         taskRequest: String = "", requirements: [AgentTaskProgressRequirement] = [],
         taskIsActive: Bool = false, surface: Color, border: Color, accent: Color,
         actionHandler: ActionHandler? = nil, changeCorrectionHandler: ChangeCorrectionHandler? = nil) {
        self.results = results
        self.changeSnapshots = changeSnapshots
        self.taskRequest = taskRequest
        self.requirements = requirements
        self.taskIsActive = taskIsActive
        self.surface = surface
        self.border = border
        self.accent = accent
        self.actionHandler = actionHandler
        self.changeCorrectionHandler = changeCorrectionHandler
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Results", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Results from this task")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 9) {
                    ForEach(entries) { entry in
                        resultCard(entry)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            .accessibilityLabel("Task result cards; scroll horizontally for more results")
        }
        .onChange(of: entries) { _, updatedEntries in
            let currentResultIDs = Set(updatedEntries.flatMap(\.results).map(\.id))
            actionMessages = actionMessages.filter { currentResultIDs.contains($0.key) }
            if let previewResult, !currentResultIDs.contains(previewResult.id) {
                self.previewURL = nil
                self.previewResult = nil
                self.previewSnapshot = nil
            }
            if let presentedStack {
                self.presentedStack = updatedEntries.first { $0.id == presentedStack.id && $0.isFolderStack }
            }
        }
        .onChange(of: presentedStack) { oldValue, newValue in
            guard oldValue != nil, newValue == nil, let pendingPreview else { return }
            self.pendingPreview = nil
            preparePreview(pendingPreview.result)
            previewURL = pendingPreview.url
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL, let previewResult {
                TaskResultPreviewSheetView(
                    url: previewURL,
                    result: previewResult,
                    snapshot: previewSnapshot,
                    taskRequest: taskRequest,
                    requirements: requirements,
                    originatingInstruction: previewInstruction,
                    taskIsActive: taskIsActive,
                    surface: surface,
                    border: border,
                    accent: accent,
                    onCorrect: changeCorrectionHandler
                )
                .frame(minWidth: 360, idealWidth: 720, minHeight: 360, idealHeight: 520)
                .padding(12)
            }
        }
        .popover(item: $presentedStack, arrowEdge: .top) { entry in
            if case .folderStack(_, let path, let files) = entry {
                TaskResultShelfStackPopoverView(
                    path: path,
                    files: files,
                    surface: surface,
                    accent: accent,
                    actionMessages: actionMessages,
                    actionHandler: actionHandler ?? TaskResultShelfActionService.perform,
                    onAction: { action, result, outcome in
                        handle(action, for: result, outcome: outcome, fromStack: true)
                    },
                    onDismiss: { presentedStack = nil }
                )
            }
        }
    }

    @ViewBuilder
    private func resultCard(_ entry: TaskResultShelfEntry) -> some View {
        switch entry {
        case .result(let result):
            singleResultCard(result)
        case .folderStack:
            folderStackCard(entry)
        }
    }

    private func singleResultCard(_ result: AgentTaskResultObject) -> some View {
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
            if let message = actionMessages[result.id] {
                actionFeedback(message)
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

    @ViewBuilder
    private func folderStackCard(_ entry: TaskResultShelfEntry) -> some View {
        if case .folderStack(_, let path, let files) = entry {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let needingRecheck = files.filter { $0.state == .needsRecheck }.count
            Button { presentedStack = entry } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.title3)
                            .foregroundStyle(accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(name) · \(files.count) files")
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .help("\(name) · \(files.count) files")
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(path)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    if needingRecheck > 0 {
                        Label("\(needingRecheck) needs recheck", systemImage: "arrow.clockwise.circle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text("Verified during this run")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Show files and actions")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(accent)
                }
                .padding(10)
                .frame(width: 276, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(border, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Show \(files.count) files in \(path)")
            .accessibilityLabel("Folder \(name), \(files.count) files, \(path)\(needingRecheck > 0 ? ", \(needingRecheck) needs recheck" : ", verified during this task")")
            .accessibilityHint("Opens the files and their available actions")
        }
    }

    private func icon(for result: AgentTaskResultObject) -> String {
        switch result.kind {
        case .file: "doc"
        case .folder: "folder"
        case .web: "globe"
        }
    }

    private func actionFeedback(_ message: String) -> some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
    }

    private func perform(_ action: TaskResultShelfAction, for result: AgentTaskResultObject, fromStack: Bool = false) {
        let handler = actionHandler ?? TaskResultShelfActionService.perform
        let outcome = TaskResultShelfDispatcher(handler: handler).perform(action, for: result)
        handle(action, for: result, outcome: outcome, fromStack: fromStack)
    }

    private func handle(_ action: TaskResultShelfAction, for result: AgentTaskResultObject,
                        outcome: TaskResultShelfActionOutcome, fromStack: Bool) {
        switch outcome {
        case .completed:
            actionMessages[result.id] = action == .copyPath ? "Path copied." : nil
        case .preview(let url):
            actionMessages[result.id] = nil
            if fromStack {
                pendingPreview = (url, result)
                presentedStack = nil
            } else {
                preparePreview(result)
                previewURL = url
            }
        case .unavailable(let message):
            actionMessages[result.id] = message
        }
    }

    private func preparePreview(_ result: AgentTaskResultObject) {
        previewResult = result
        let snapshot = changeSnapshots[result.id]
        previewSnapshot = snapshot
        guard let snapshot else {
            previewInstruction = taskRequest
            return
        }
        let bytes = Array(taskRequest.utf8)
        let phrases = requirements.filter { snapshot.requirementIDs.contains($0.id) }.flatMap { requirement in
            requirement.sourceRanges.compactMap { range -> String? in
                guard range.lowerBound >= 0, range.upperBound <= bytes.count, range.lowerBound < range.upperBound else { return nil }
                return String(bytes: bytes[range.lowerBound..<range.upperBound], encoding: .utf8)
            }
        }
        previewInstruction = phrases.isEmpty ? taskRequest : phrases.joined(separator: "\n")
    }
}

struct TaskResultShelfStackPopoverView: View {
    typealias ActionHandler = @MainActor (TaskResultShelfAction, AgentTaskResultObject) -> TaskResultShelfActionOutcome
    typealias ActionUpdate = @MainActor (TaskResultShelfAction, AgentTaskResultObject, TaskResultShelfActionOutcome) -> Void

    let path: String
    let files: [AgentTaskResultObject]
    let surface: Color
    let accent: Color
    let actionMessages: [String: String]
    let actionHandler: ActionHandler
    let onAction: ActionUpdate
    let onDismiss: @MainActor () -> Void

    private var folderName: String { URL(fileURLWithPath: path).lastPathComponent }
    private var popoverHeight: CGFloat { min(max(CGFloat(files.count) * 105 + 58, 190), 440) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(folderName) · \(files.count) files")
                    .font(.headline)
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(path)
            }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        fileRow(file)
                        if index < files.count - 1 { Divider().padding(.leading, 8) }
                    }
                }
            }
            .accessibilityLabel("Files in \(path); scroll vertically for more files")
        }
        .padding(12)
        .frame(width: 390, height: popoverHeight)
        .background(surface)
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files in folder \(path)")
    }

    private func fileRow(_ result: AgentTaskResultObject) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "doc")
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(result.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .help(result.name)
                Spacer(minLength: 0)
                if result.state == .needsRecheck {
                    Label("Needs recheck", systemImage: "arrow.clockwise.circle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Text("Verified")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                ForEach(TaskResultShelfAction.available(for: result), id: \.rawValue) { action in
                    Button(action.title) {
                        let outcome = TaskResultShelfDispatcher(handler: actionHandler).perform(action, for: result)
                        onAction(action, result, outcome)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
                    .help("\(action.title) \(result.name)")
                    .accessibilityLabel("\(action.title) \(result.name)")
                }
            }
            if let message = actionMessages[result.id] {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(message)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File \(result.name), \(result.state == .verified ? "verified" : "needs recheck")")
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
