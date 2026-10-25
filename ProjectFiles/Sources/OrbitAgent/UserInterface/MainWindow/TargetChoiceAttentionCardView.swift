import SwiftUI

struct TargetChoiceAttentionCardView: View {
    let request: AgentTargetChoiceRequest
    let canChoose: Bool
    let canInspectAgain: Bool
    let surface: Color
    let border: Color
    let accent: Color
    let choose: (String) -> Void
    let inspectAgain: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.state {
            case .pending:
                Label(question, systemImage: "questionmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 7) {
                    ForEach(request.candidates) { candidate in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                                choose(candidate.id)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: candidate.kind.symbol)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(accent)
                                    .frame(width: 22, alignment: .center)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.label)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(candidate.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 3)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(border, lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canChoose)
                        .opacity(canChoose ? 1 : 0.65)
                        .accessibilityLabel("Use \(candidate.kind.rawValue): \(candidate.label), \(candidate.detail)")
                        .accessibilityHint("Binds this exact target for the current task. It will not open or change the target.")
                        .accessibilityIdentifier("target-choice-\(candidate.id)")
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    if request.inspectAgainAllowed {
                        Button("Inspect again", systemImage: "arrow.clockwise", action: inspectAgain)
                            .buttonStyle(.borderless)
                            .disabled(!canInspectAgain || !canChoose)
                            .accessibilityHint("Refresh the relevant local evidence once. This does not search the whole filesystem.")
                    } else {
                        Text("Already inspected again. If none fit, use the correction controls to narrow the request.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            case .applying:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Applying selection…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Applying selected target")
            case .applied:
                Label(request.notice ?? appliedSummary, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(request.notice ?? appliedSummary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var question: String {
        let subject: String
        switch request.scope {
        case "source": subject = "source"
        case "destination": subject = "destination"
        default: subject = "document"
        }
        return "Which \(subject) for “\(request.reference)” should I use?"
    }

    private var appliedSummary: String {
        "Using \(request.appliedLabel ?? "selected target") — \(request.appliedDetail ?? "")"
    }
}
