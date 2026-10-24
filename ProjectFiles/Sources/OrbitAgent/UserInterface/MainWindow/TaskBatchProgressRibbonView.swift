import AppKit
import SwiftUI

enum TaskBatchProgressPresentation {
    static func state(for item: AgentTaskBatchItem, lifecycle: AgentTaskProgressLifecycle) -> AgentTaskBatchItemState {
        if item.state == .verified || item.state == .needsRecheck { return item.state }
        switch lifecycle {
        case .completed, .failed, .stopped:
            return .unfinished
        case .paused, .waitingForUser, .stopping:
            return item.state == .working ? .waiting : item.state
        case .running:
            return item.state
        }
    }

    static func labels(for items: [AgentTaskBatchItem]) -> [String] {
        let base = items.map(displayLabel)
        let groups = Dictionary(grouping: items.indices, by: { base[$0].localizedLowercase })
        var result = base
        for indices in groups.values where indices.count > 1 {
            let paths = Dictionary(uniqueKeysWithValues: indices.map { ($0, parentComponents(items[$0])) })
            for index in indices {
                let components = paths[index] ?? []
                let suffix = (1...max(1, components.count)).first { count in
                    let candidate = components.suffix(count).joined(separator: "/")
                    return indices.filter { $0 != index }.allSatisfy {
                        let other = paths[$0] ?? []
                        return other.suffix(count).joined(separator: "/").localizedLowercase != candidate.localizedLowercase
                    }
                }
                if let suffix, suffix > 0 {
                    result[index] = components.suffix(suffix).joined(separator: "/") + "/" + base[index]
                } else if !components.isEmpty {
                    result[index] = components.joined(separator: "/") + "/" + base[index]
                } else {
                    result[index] = base[index] + " · " + String(index + 1)
                }
            }
        }
        return result
    }

    private static func displayLabel(_ item: AgentTaskBatchItem) -> String {
        if item.kind == "url", let components = URLComponents(string: item.reference),
           let host = components.host {
            let last = components.path.split(separator: "/").last.map(String.init)
            return last.map { host + "/" + $0 } ?? host
        }
        let path = (item.reference as NSString).expandingTildeInPath
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? item.reference : name
    }

    private static func parentComponents(_ item: AgentTaskBatchItem) -> [String] {
        if item.kind == "url", let components = URLComponents(string: item.reference) {
            return ([components.host].compactMap { $0 } + components.path.split(separator: "/").dropLast().map(String.init))
        }
        let path = (item.reference as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents.filter { $0 != "/" }
    }
}

struct TaskBatchProgressRibbonView: View {
    let map: TaskProgressMap
    let batch: AgentTaskBatchProgress
    let surface: Color
    let border: Color
    let accent: Color

    @State private var isPresented = false
    @State private var selectedItemID: String?

    private var labels: [String] { TaskBatchProgressPresentation.labels(for: batch.items) }
    private var selectedItem: AgentTaskBatchItem? { batch.items.first(where: { $0.id == selectedItemID }) }
    private var handledCount: Int { batch.items.filter { state(for: $0) == .verified }.count }

    var body: some View {
        Group {
            if batch.items.count <= 5 {
                ViewThatFits(in: .horizontal) {
                    inlineItems
                    summaryButton
                }
            } else {
                summaryButton
            }
        }
        .padding(.vertical, 2)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent
                .frame(width: 340, alignment: .leading)
                .frame(maxHeight: 390)
                .padding(14)
                .background(surface)
                .onExitCommand { closePopover() }
        }
        .onChange(of: map.generationID) { _, _ in closePopover() }
        .onChange(of: batch.items.map(\.id)) { _, ids in
            if let selectedItemID, !ids.contains(selectedItemID) { closePopover() }
        }
    }

    private var inlineItems: some View {
        HStack(spacing: 8) {
            ForEach(Array(batch.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                itemButton(item, label: labels[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Input batch progress")
    }

    private var summaryButton: some View {
        Button {
            selectedItemID = nil
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(summary)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityHint("Shows every supplied input and its current step")
    }

    private var summary: String {
        let workingIndex = batch.items.firstIndex(where: { state(for: $0) == .working })
        let waitingIndex = batch.items.firstIndex(where: { state(for: $0) == .waiting || state(for: $0) == .unfinished })
        let targetIndex = workingIndex ?? waitingIndex
        let progress = "\(handledCount) of \(batch.items.count) inputs handled"
        if batch.needsDeclaration { return "Rechecking input coverage · \(progress)" }
        if map.lifecycle == .paused { return "Paused · \(progress)" }
        if map.lifecycle == .waitingForUser { return "Waiting for you · \(progress)" }
        if map.lifecycle == .stopping { return "Finishing safely · \(progress)" }
        if let targetIndex {
            let label = labels[targetIndex]
            if map.lifecycle == .running, workingIndex != nil { return "Working on \(label) · \(progress)" }
            if map.lifecycle == .running { return "Next: \(label) · \(progress)" }
        }
        return progress
    }

    private func itemButton(_ item: AgentTaskBatchItem, label: String) -> some View {
        Button {
            selectedItemID = item.id
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                stateSymbol(state(for: item))
                Text(stateLabel(state(for: item)).lowercased())
                    .font(.caption2)
                    .foregroundStyle(foreground(for: state(for: item)))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground(for: state(for: item)))
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(stateLabel(state(for: item)))")
        .accessibilityHint("Shows the current step and verified outcomes for this input")
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let item = selectedItem {
            itemDetails(item)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Input progress", systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Spacer()
                    Button { closePopover() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close input progress")
                }
                if batch.needsDeclaration {
                    Text("Rechecking which outcomes belong to each input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(batch.items.enumerated()), id: \.element.id) { index, item in
                            itemButton(item, label: labels[index])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 290)
                .accessibilityLabel("All supplied inputs")
            }
        }
    }

    private func itemDetails(_ item: AgentTaskBatchItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Button {
                    selectedItemID = nil
                } label: {
                    Label("All inputs", systemImage: "chevron.left")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { closePopover() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close input details")
            }
            Text(displayLabel(for: item))
                .font(.headline)
                .lineLimit(2)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text("Input reference")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.reference)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(stateLabel(state(for: item)), systemImage: symbolName(state(for: item)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground(for: state(for: item)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Current step")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(currentStep(for: item))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.outcomes.isEmpty {
                Divider()
                Text("Requested outcomes")
                    .font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(item.outcomes) { outcome in
                            outcomeRow(outcome)
                        }
                    }
                }
                .frame(maxHeight: 170)
            } else {
                Text("Requested outcomes are being reassessed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if map.lifecycle != .running && map.lifecycle != .completed && map.lifecycle != .failed && map.lifecycle != .stopped {
                Text("Progress is suspended while this run is \(lifecycleDescription).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: AgentTaskBatchOutcome) -> some View {
        if let requirement = map.requirements.first(where: { $0.id == outcome.id }) {
            let state = state(for: requirement)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 7) {
                    stateSymbol(state)
                    Text(outcome.label)
                        .font(.caption)
                    Spacer(minLength: 4)
                    Text(stateLabel(state))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(foreground(for: state))
                }
                if state == .verified {
                    ForEach(Array(requirement.evidence.enumerated()), id: \.offset) { _, evidence in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(evidence.label).font(.caption2.weight(.medium))
                            if !evidence.detail.isEmpty {
                                Text(evidence.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 19)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func state(for item: AgentTaskBatchItem) -> AgentTaskBatchItemState {
        TaskBatchProgressPresentation.state(for: item, lifecycle: map.lifecycle)
    }

    private func state(for requirement: AgentTaskProgressRequirement) -> AgentTaskBatchItemState {
        switch requirement.state {
        case .proven: return AgentTaskBatchItemState.verified
        case .invalidated: return AgentTaskBatchItemState.needsRecheck
        case .pending:
            if requirement.active && map.lifecycle == .running { return .working }
            if map.lifecycle == .completed || map.lifecycle == .failed || map.lifecycle == .stopped { return .unfinished }
            return AgentTaskBatchItemState.waiting
        }
    }

    private func currentStep(for item: AgentTaskBatchItem) -> String {
        let effective = state(for: item)
        if effective == .waiting && item.state == .working { return "Waiting for the task to resume." }
        if effective == .unfinished { return "This input was not completed in this run." }
        return item.currentStep
    }

    private func displayLabel(for item: AgentTaskBatchItem) -> String {
        if let index = batch.items.firstIndex(where: { $0.id == item.id }), labels.indices.contains(index) {
            return labels[index]
        }
        return item.reference
    }

    @ViewBuilder
    private func stateSymbol(_ state: AgentTaskBatchItemState) -> some View {
        Image(systemName: symbolName(state))
            .foregroundStyle(foreground(for: state))
            .accessibilityHidden(true)
    }

    private func symbolName(_ state: AgentTaskBatchItemState) -> String {
        switch state {
        case .waiting: "minus.circle"
        case .working: "circle.dotted"
        case .verified: "checkmark.circle.fill"
        case .needsRecheck: "arrow.clockwise.circle.fill"
        case .unfinished: "circle"
        }
    }

    private func stateLabel(_ state: AgentTaskBatchItemState) -> String {
        switch state {
        case .waiting: "Waiting"
        case .working: "Working"
        case .verified: "Verified"
        case .needsRecheck: "Needs recheck"
        case .unfinished: "Unfinished"
        }
    }

    private func foreground(for state: AgentTaskBatchItemState) -> Color {
        switch state {
        case .waiting, .unfinished: .secondary
        case .working: accent
        case .verified: .green
        case .needsRecheck: .orange
        }
    }

    private var lifecycleDescription: String {
        switch map.lifecycle {
        case .paused: "paused"
        case .waitingForUser: "waiting for your input"
        case .stopping: "finishing safely"
        case .running, .completed, .failed, .stopped: "not running"
        }
    }

    private func closePopover() {
        isPresented = false
        selectedItemID = nil
    }
}
