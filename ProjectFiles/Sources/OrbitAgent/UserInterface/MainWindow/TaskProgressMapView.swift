import AppKit
import SwiftUI

struct TaskProgressClause: Equatable, Identifiable {
    enum State: Equatable {
        case pending
        case active
        case confirmed
        case needsRecheck
    }

    let range: Range<String.Index>
    let requirementIDs: [String]
    let state: State
    let id: String
}

enum TaskProgressSourceMapper {
    private struct Match {
        var range: Range<String.Index>
        var identifiers: Set<String>
    }

    static func clauses(for map: TaskProgressMap) -> [TaskProgressClause] {
        let request = map.originalRequest
        var matches: [Match] = []
        for requirement in map.requirements {
            for byteRange in requirement.sourceRanges {
                guard let range = stringRange(for: byteRange, in: request) else { continue }
                matches.append(Match(range: range, identifiers: [requirement.id]))
            }
        }
        matches.sort {
            if $0.range.lowerBound == $1.range.lowerBound {
                return $0.range.upperBound < $1.range.upperBound
            }
            return $0.range.lowerBound < $1.range.lowerBound
        }

        var groups: [Match] = []
        for match in matches {
            if let last = groups.indices.last, match.range.lowerBound < groups[last].range.upperBound {
                groups[last].range = groups[last].range.lowerBound..<max(groups[last].range.upperBound, match.range.upperBound)
                groups[last].identifiers.formUnion(match.identifiers)
            } else {
                groups.append(match)
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: map.requirements.map { ($0.id, $0) })
        return groups.enumerated().map { groupIndex, group in
            let requirements = group.identifiers.compactMap { byID[$0] }
            let state: TaskProgressClause.State
            if !requirements.isEmpty && requirements.allSatisfy({ $0.state == .proven }) {
                state = .confirmed
            } else if requirements.contains(where: { $0.state == .invalidated }) {
                state = .needsRecheck
            } else if map.lifecycle == .running && requirements.contains(where: \.active) {
                state = .active
            } else {
                state = .pending
            }
            let ids = group.identifiers.sorted(by: requirementOrder)
            return TaskProgressClause(range: group.range,
                                      requirementIDs: ids, state: state,
                                      id: "\(ids.joined(separator: ",")):\(groupIndex)")
        }
    }

    static func sourceRangesAreValid(_ ranges: [Range<Int>], in request: String) -> Bool {
        let bytes = Array(request.utf8)
        func isScalarBoundary(_ offset: Int) -> Bool {
            offset == bytes.count || (offset >= 0 && offset < bytes.count && bytes[offset] & 0xC0 != 0x80)
        }
        return ranges.allSatisfy { range in
            range.lowerBound >= 0 && range.upperBound <= bytes.count &&
                range.lowerBound < range.upperBound && isScalarBoundary(range.lowerBound) &&
                isScalarBoundary(range.upperBound)
        }
    }

    private static func requirementOrder(_ first: String, _ second: String) -> Bool {
        let firstNumber = Int(first.dropFirst()) ?? Int.max
        let secondNumber = Int(second.dropFirst()) ?? Int.max
        return firstNumber == secondNumber ? first < second : firstNumber < secondNumber
    }

    private static func stringRange(for byteRange: Range<Int>, in request: String) -> Range<String.Index>? {
        guard byteRange.lowerBound >= 0, byteRange.upperBound <= request.utf8.count,
              byteRange.lowerBound < byteRange.upperBound else { return nil }
        let startUTF8 = request.utf8.index(request.utf8.startIndex, offsetBy: byteRange.lowerBound)
        let endUTF8 = request.utf8.index(request.utf8.startIndex, offsetBy: byteRange.upperBound)
        guard let start = String.Index(startUTF8, within: request),
              let end = String.Index(endUTF8, within: request) else { return nil }
        return start..<end
    }
}

struct TaskProgressMapView: View {
    let map: TaskProgressMap
    let surface: Color
    let border: Color
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Bool
    @State private var selectedRequirementIDs: [String] = []
    @State private var revealMessage: String?

    init(map: TaskProgressMap, surface: Color, border: Color, accent: Color,
         initiallyExpanded: Bool = false, initiallySelectedRequirementIDs: [String] = []) {
        self.map = map
        self.surface = surface
        self.border = border
        self.accent = accent
        _expanded = State(initialValue: initiallyExpanded)
        _selectedRequirementIDs = State(initialValue: initiallySelectedRequirementIDs.filter { id in
            map.requirements.contains(where: { $0.id == id })
        })
    }

    private var clauses: [TaskProgressClause] { TaskProgressSourceMapper.clauses(for: map) }
    private var selectedRequirements: [AgentTaskProgressRequirement] {
        selectedRequirementIDs.compactMap { id in map.requirements.first(where: { $0.id == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                changeExpandedState()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    Text("Progress")
                        .font(.callout.weight(.semibold))
                    Text(collapsedSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(lifecycleLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(lifecycleColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse task progress map" : "Expand task progress map")
            .accessibilityValue(collapsedSummary)
            .accessibilityHint("Shows the original request with its current verified progress")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView {
                        requestText
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 156)
                    .accessibilityLabel("Original request and applied corrections")

                    stateLegend

                    if !clauses.isEmpty && map.wholeRequestCoverage == "pending" {
                        Label("Whole request coverage is still being checked", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !selectedRequirements.isEmpty {
                        evidenceDetail
                    }
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(border, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: expanded)
        .onChange(of: map.generationID) { _, _ in
            expanded = false
            selectedRequirementIDs = []
            revealMessage = nil
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "taskpilot-progress", url.host == "select" else { return .systemAction }
            let ids = (url.pathComponents.dropFirst()).flatMap { $0.split(separator: ",").map(String.init) }
            selectedRequirementIDs = ids.filter { id in map.requirements.contains(where: { $0.id == id }) }
            revealMessage = nil
            if !expanded { changeExpandedState(true) }
            return .handled
        })
    }

    private var collapsedSummary: String {
        if let active = clauses.first(where: { $0.state == .active }) {
            return "Active: \(map.originalRequest[active.range])"
        }
        if let unfinished = clauses.first(where: { $0.state != .confirmed }) {
            let state = unfinished.state == .needsRecheck ? "Needs recheck" : "Unfinished"
            return "\(state): \(map.originalRequest[unfinished.range])"
        }
        if clauses.isEmpty {
            return map.originalRequest
        }
        return map.wholeRequestCoverage == "audited"
            ? "Mapped phrases confirmed"
            : "Mapped phrases confirmed · request coverage pending"
    }

    @ViewBuilder
    private var stateLegend: some View {
        let states = clauses.map(\.state)
        if !states.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                if states.contains(.pending) { Label("Unfinished", systemImage: "circle").foregroundStyle(.secondary) }
                if states.contains(.active) { Label("Active", systemImage: "circle.dotted").foregroundStyle(accent) }
                if states.contains(.confirmed) { Label("Confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                if states.contains(.needsRecheck) { Label("Needs recheck", systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange) }
            }
            .font(.caption2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Progress states: \(stateNames(states).joined(separator: ", "))")
        }
    }

    private func stateNames(_ states: [TaskProgressClause.State]) -> [String] {
        [
            states.contains(.pending) ? "unfinished" : nil,
            states.contains(.active) ? "active" : nil,
            states.contains(.confirmed) ? "confirmed" : nil,
            states.contains(.needsRecheck) ? "needs recheck" : nil,
        ].compactMap { $0 }
    }

    private var lifecycleLabel: String {
        switch map.lifecycle {
        case .running: "In progress"
        case .waitingForUser: "Waiting for you"
        case .paused: "Paused"
        case .stopping: "Stopping"
        case .completed: "Run finished"
        case .failed: "Run failed"
        case .stopped: "Run stopped"
        }
    }

    private var lifecycleColor: Color {
        switch map.lifecycle {
        case .running: accent
        case .waitingForUser, .paused, .stopping: .orange
        case .completed: .secondary
        case .failed, .stopped: .secondary
        }
    }

    private var requestText: some View {
        var value = AttributedString(map.originalRequest)
        for clause in clauses {
            guard let range = Range(clause.range, in: value),
                  let url = URL(string: "taskpilot-progress://select/\(clause.requirementIDs.joined(separator: ","))") else { continue }
            value[range].link = url
            value[range].underlineStyle = .single
            value[range].foregroundColor = foreground(for: clause.state)
            value[range].backgroundColor = background(for: clause.state)
        }
        return Text(value)
            .font(.callout)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityHint("Highlighted phrases show task progress. Select a phrase to inspect its evidence.")
    }

    private var evidenceDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Supporting result", systemImage: "checkmark.seal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Button {
                    selectedRequirementIDs = []
                    revealMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close supporting result")
            }

            ForEach(selectedRequirements) { requirement in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        stateSymbol(requirement)
                        Text(stateLabel(requirement))
                            .font(.caption.weight(.semibold))
                    }
                    if requirement.state == .proven {
                        ForEach(Array(requirement.evidence.enumerated()), id: \.offset) { item in
                            let evidence = item.element
                            VStack(alignment: .leading, spacing: 4) {
                                Text(evidence.label)
                                    .font(.caption.weight(.medium))
                                if !evidence.detail.isEmpty {
                                    Text(evidence.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                if let path = evidence.revealPath {
                                    Button {
                                        reveal(path)
                                    } label: {
                                        Label("Reveal in Finder", systemImage: "folder")
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.link)
                                    .accessibilityHint("Opens the verified file location in Finder")
                                }
                            }
                            .padding(.leading, 20)
                        }
                    } else if requirement.state == .invalidated {
                        Text("Earlier evidence needs to be checked again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if requirement.active && map.lifecycle == .running {
                        Text("This request clause is being worked on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No verified supporting result is available yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let revealMessage {
                Text(revealMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(border, lineWidth: 1)
        }
    }

    private func stateSymbol(_ requirement: AgentTaskProgressRequirement) -> some View {
        Group {
            switch requirement.state {
            case .proven: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .invalidated: Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            case .pending: Image(systemName: requirement.active ? "circle.dotted" : "circle").foregroundStyle(accent)
            }
        }
        .accessibilityHidden(true)
    }

    private func stateLabel(_ requirement: AgentTaskProgressRequirement) -> String {
        switch requirement.state {
        case .proven: "Confirmed"
        case .invalidated: "Needs recheck"
        case .pending: requirement.active && map.lifecycle == .running ? "Active" : "Unfinished"
        }
    }

    private func foreground(for state: TaskProgressClause.State) -> Color {
        switch state {
        case .pending: .primary
        case .active: accent
        case .confirmed: .green
        case .needsRecheck: .orange
        }
    }

    private func background(for state: TaskProgressClause.State) -> Color {
        switch state {
        case .pending: .clear
        case .active: accent.opacity(0.12)
        case .confirmed: Color.green.opacity(0.13)
        case .needsRecheck: Color.orange.opacity(0.13)
        }
    }

    private func changeExpandedState(_ value: Bool? = nil) {
        expanded = value ?? !expanded
    }

    private func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            revealMessage = "The verified path is no longer available at that location."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        revealMessage = nil
    }
}
