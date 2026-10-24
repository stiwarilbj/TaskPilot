import SwiftUI

struct TaskDestinationAddressView: View {
    let snapshot: AgentTaskDestinationSnapshot
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: snapshot.isMismatch ? "exclamationmark.triangle" : "folder")
                        .accessibilityHidden(true)
                    Text(snapshot.collapsedTitle)
                        .font(.caption)
                        .foregroundStyle(snapshot.isMismatch ? Color.orange : Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("task-destination-disclosure")
            .accessibilityLabel("\(snapshot.collapsedTitle). Destination details")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides destination details" : "Shows the full available path and requested filename")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Status", statusText)
                    if let plannedPath = snapshot.plannedPath {
                        detail("Planned", plannedPath, selectable: true)
                    }
                    if let actualPath = snapshot.actualPath {
                        detail("Selected", actualPath, selectable: true)
                    } else if let selectedFilename = snapshot.selectedFilename {
                        detail("Selected filename", selectedFilename, selectable: true)
                        detail("Location", "Selected destination not confirmed")
                    }
                    if let requestedFilename = snapshot.requestedFilename {
                        detail("Requested filename", requestedFilename, selectable: true)
                    }
                    if snapshot.destinationExists == true {
                        detail("File", "Existing file")
                        detail("Instruction", snapshot.instruction ?? "No explicit overwrite instruction")
                    }
                    if snapshot.isMismatch {
                        detail("Warning", "The selected destination differs from the planned destination")
                    }
                }
                .padding(.leading, 22)
                .accessibilityIdentifier("task-destination-details")
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: expanded)
        .accessibilityIdentifier("task-destination-address")
    }

    private var statusText: String {
        switch snapshot.state {
        case .planned: "Planned destination"
        case .selected: "Destination selected in the save dialog; no save action is confirmed"
        case .selectedUnconfirmed: "Selected destination not confirmed"
        case .preparing: "Destination identified; action delivery is not confirmed"
        case .checking: "Destination action delivered; the requested result is not confirmed"
        case .cleared: "Destination details cleared"
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(label):").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                detailValue(value, selectable: selectable)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label):").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                detailValue(value, selectable: selectable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    @ViewBuilder
    private func detailValue(_ value: String, selectable: Bool) -> some View {
        if selectable {
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
