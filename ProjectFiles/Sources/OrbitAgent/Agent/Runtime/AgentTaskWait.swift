import CoreFoundation
import Foundation

enum AgentTaskWaitPhase: String, Equatable {
    case starting
    case observing
    case planning
    case modelResponse = "model_response"
    case executing
    case reconciling
    case verifying
    case providerCooldown = "provider_cooldown"
    case secureInput = "secure_input"
    case paused
    case draining
}

enum AgentTaskWaitAttention: String, Equatable {
    case none
    case secureInput = "secure_input"
    case resume
    case permission

    var description: String {
        switch self {
        case .none: "Nothing needed."
        case .secureInput: "Enter the requested secure information below."
        case .resume: "Resume TaskPilot to continue."
        case .permission: "Repair the required permission in Setup."
        }
    }
}

struct AgentTaskWaitSnapshot: Equatable {
    static let version = 1

    let generationID: String
    let revision: UInt64
    let operationID: UInt64
    let phase: AgentTaskWaitPhase
    let lastConfirmed: String
    let waitingFor: String
    let attention: AgentTaskWaitAttention
    private let localIdentity: String?

    var disclosureIdentity: String {
        "\(generationID):\(localIdentity ?? String(operationID))"
    }

    init(generationID: String, revision: UInt64, operationID: UInt64, phase: AgentTaskWaitPhase,
         lastConfirmed: String, waitingFor: String, attention: AgentTaskWaitAttention) {
        self.generationID = generationID
        self.revision = revision
        self.operationID = operationID
        self.phase = phase
        self.lastConfirmed = lastConfirmed
        self.waitingFor = waitingFor
        self.attention = attention
        localIdentity = nil
    }

    private init(copying value: Self, phase: AgentTaskWaitPhase, waitingFor: String,
                 attention: AgentTaskWaitAttention, localIdentity: String) {
        generationID = value.generationID
        revision = value.revision
        operationID = value.operationID
        self.phase = phase
        lastConfirmed = value.lastConfirmed
        self.waitingFor = waitingFor
        self.attention = attention
        self.localIdentity = localIdentity
    }

    func withLocalState(phase: AgentTaskWaitPhase, waitingFor: String,
                        attention: AgentTaskWaitAttention, identity: String) -> Self {
        Self(copying: self, phase: phase, waitingFor: waitingFor,
             attention: attention, localIdentity: identity)
    }

    static func parse(_ message: [String: Any], generationID: String) -> Self? {
        let keys: Set<String> = ["kind", "task_generation_id", "version", "revision", "operation_id",
                                 "phase", "last_confirmed", "waiting_for", "attention"]
        guard Set(message.keys) == keys,
              message["kind"] as? String == "task_wait",
              message["task_generation_id"] as? String == generationID,
              exactInteger(message["version"]) == UInt64(version),
              let revision = exactInteger(message["revision"]), revision > 0,
              let operationID = exactInteger(message["operation_id"]), operationID > 0,
              let phaseRaw = message["phase"] as? String,
              let phase = AgentTaskWaitPhase(rawValue: phaseRaw),
              let attentionRaw = message["attention"] as? String,
              let attention = AgentTaskWaitAttention(rawValue: attentionRaw),
              let lastConfirmed = safeText(message["last_confirmed"], maximumBytes: 240),
              let waitingFor = safeText(message["waiting_for"], maximumBytes: 240) else {
            return nil
        }
        return Self(generationID: generationID, revision: revision, operationID: operationID,
                    phase: phase, lastConfirmed: lastConfirmed, waitingFor: waitingFor,
                    attention: attention)
    }

    private static func exactInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return UInt64(number.stringValue)
    }

    private static func safeText(_ value: Any?, maximumBytes: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximumBytes,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}
