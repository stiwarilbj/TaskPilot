import CoreFoundation
import Foundation

enum AgentTaskDestinationState: String, Equatable {
    case planned
    case selected
    case selectedUnconfirmed = "selected_unconfirmed"
    case preparing
    case checking
    case cleared
}

struct AgentTaskDestinationSnapshot: Equatable, Identifiable {
    static let version = 1

    let generationID: String
    let instructionRevision: UInt64
    let revision: UInt64
    let operationID: UInt64
    let state: AgentTaskDestinationState
    let plannedPath: String?
    let actualPath: String?
    let requestedFilename: String?
    let selectedFilename: String?
    let destinationExists: Bool?
    let instruction: String?
    let observationRevision: String?

    var id: String { "\(generationID):\(operationID)" }

    var isMismatch: Bool {
        guard let actualPath else { return false }
        if let requestedFilename,
           requestedFilename != URL(fileURLWithPath: actualPath).lastPathComponent { return true }
        if let plannedPath {
            let planned = normalized(plannedPath)
            let actual = normalized(actualPath)
            if planned == actual { return false }
            // If the request named a folder but no filename, a file inside
            // that folder is a valid selection. Do not treat sibling paths as
            // equivalent merely because their strings share a prefix.
            let prefix = planned.hasSuffix("/") ? planned : planned + "/"
            return !actual.hasPrefix(prefix)
        }
        return false
    }

    var collapsedTitle: String {
        switch state {
        case .planned:
            if let plannedPath { return "Planned destination: \(compactPath(plannedPath))" }
            if let requestedFilename { return "Planned filename: \(requestedFilename)" }
            return "Destination not specified"
        case .selected:
            if isMismatch, let actualPath { return "Destination differs: \(compactPath(actualPath))" }
            if let actualPath { return "Selected destination: \(compactPath(actualPath))" }
            return "Destination selected"
        case .selectedUnconfirmed:
            return selectedFilename.map { "Selected filename: \($0) · destination not confirmed" }
                ?? "Selected destination not confirmed"
        case .preparing, .checking:
            if isMismatch, let actualPath { return "Destination differs: \(compactPath(actualPath))" }
            if let actualPath { return "Saving to \(compactPath(actualPath))" }
            return "Destination not confirmed"
        case .cleared:
            return ""
        }
    }

    var disclosureIdentity: String { id }

    static func parse(_ message: [String: Any], generationID: String) -> Self? {
        let keys: Set<String> = ["kind", "task_generation_id", "instruction_revision", "working_document_revision",
            "version", "revision", "operation_id", "state", "planned_path", "actual_path",
            "requested_filename", "selected_filename", "destination_exists", "instruction",
            "observation_revision"]
        guard Set(message.keys) == keys,
              message["kind"] as? String == "task_destination",
              message["task_generation_id"] as? String == generationID,
              let instructionRevision = exactInteger(message["instruction_revision"]),
              let revision = exactInteger(message["revision"]), revision > 0,
              let operationID = exactInteger(message["operation_id"]), operationID > 0,
              exactInteger(message["working_document_revision"]) != nil,
              exactInteger(message["version"]) == UInt64(version),
              let rawState = message["state"] as? String,
              let state = AgentTaskDestinationState(rawValue: rawState),
              let plannedPath = optionalPath(message["planned_path"]),
              let actualPath = optionalPath(message["actual_path"]),
              let requestedFilename = optionalText(message["requested_filename"], maximumBytes: 240),
              let selectedFilename = optionalText(message["selected_filename"], maximumBytes: 240),
              let destinationExists = optionalBoolean(message["destination_exists"]),
              let instruction = optionalInstruction(message["instruction"]),
              let observationRevision = optionalText(message["observation_revision"], maximumBytes: 128) else {
            return nil
        }
        if state == .cleared {
            guard plannedPath == nil, actualPath == nil, requestedFilename == nil,
                  selectedFilename == nil, destinationExists == nil, instruction == nil,
                  observationRevision == nil else { return nil }
        }
        if [.selected, .preparing, .checking].contains(state), actualPath == nil { return nil }
        return Self(generationID: generationID, instructionRevision: instructionRevision,
            revision: revision, operationID: operationID, state: state, plannedPath: plannedPath,
            actualPath: actualPath, requestedFilename: requestedFilename, selectedFilename: selectedFilename,
            destinationExists: destinationExists, instruction: instruction, observationRevision: observationRevision)
    }

    private static func exactInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return UInt64(number.stringValue)
    }

    private static func optionalBoolean(_ value: Any?) -> Bool?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return .some(number.boolValue)
    }

    private static func optionalText(_ value: Any?, maximumBytes: Int) -> String?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximumBytes,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .some(text)
    }

    private static func optionalPath(_ value: Any?) -> String?? {
        guard let text = optionalText(value, maximumBytes: 2_048) else { return nil }
        guard let text else { return .some(nil) }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return .some(text)
    }

    private static func optionalInstruction(_ value: Any?) -> String?? {
        guard let text = optionalText(value, maximumBytes: 64) else { return nil }
        guard let text else { return .some(nil) }
        guard ["Create a new copy", "Replace existing file", "Append"].contains(text) else { return nil }
        return .some(text)
    }

    private func normalized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private func compactPath(_ path: String) -> String {
        let components = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.pathComponents.filter { $0 != "/" }
        if let downloads = components.lastIndex(where: { $0.caseInsensitiveCompare("Downloads") == .orderedSame }) {
            return components[downloads...].joined(separator: " › ")
        }
        let suffix = components.suffix(3).joined(separator: " › ")
        return components.count > 3 ? "… › \(suffix)" : suffix
    }
}
