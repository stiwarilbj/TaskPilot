import SwiftUI

struct TaskWaitDisclosureView: View {
    let status: String
    let snapshot: AgentTaskWaitSnapshot
    let symbol: AnyView
    @Binding var expandedIdentity: String?
    var reduceMotionOverride: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var isExpanded: Bool {
        expandedIdentity == snapshot.disclosureIdentity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    expandedIdentity = isExpanded ? nil : snapshot.disclosureIdentity
                }
            } label: {
                HStack(spacing: 12) {
                    symbol.accessibilityHidden(true)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("task-status-disclosure")
            .accessibilityLabel("Task status: \(status)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded
                ? "Hides the current wait details"
                : "Shows what TaskPilot confirmed and what it is waiting for")

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    detailRow("Last confirmed:", snapshot.lastConfirmed, identifier: "task-wait-last-confirmed")
                    detailRow("Waiting for:", snapshot.waitingFor, identifier: "task-wait-waiting-for")
                    detailRow("Your attention:", snapshot.attention.description, identifier: "task-wait-attention")
                }
                .padding(.leading, 30)
                .accessibilityIdentifier("task-status-details")
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, identifier: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                rowLabel(label)
                    .frame(width: 94, alignment: .leading)
                rowValue(value)
            }

            VStack(alignment: .leading, spacing: 1) {
                rowLabel(label)
                rowValue(value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityIdentifier(identifier)
    }

    private func rowLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func rowValue(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
