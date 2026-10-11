import ApplicationServices

enum AutomationPressPolicy {
    /// An explicit unsupported result proves the semantic method delivered no
    /// action. All other ambiguous errors prohibit a second delivery method.
    static func deliver(preflight: () throws -> Void, press: () -> AXError,
                        fallback: () throws -> Void) throws -> String {
        let result = try AutomationTargetPolicy.deliver(preflight: preflight, event: press)
        switch result {
        case .success: return "accessibility"
        case .actionUnsupported, .notImplemented:
            try preflight()
            try fallback() // The caller must validate the current pointer hit.
            return "coordinate"
        case .apiDisabled: throw AccessibilityActionError.permissionDenied
        case .invalidUIElement: throw AccessibilityActionError.staleObservation
        default:
            throw AccessibilityActionError.uncertainDelivery(
                "Accessibility press returned \(result.rawValue); delivery is uncertain, inspect before another action")
        }
    }
}
