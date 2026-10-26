import ApplicationServices
import Foundation

/// One read-only metadata group. Text values and selections must stay outside
/// the batch until role/subrole establish that the field is not secure.
struct ObservationControlAttributes {
    static let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                        kAXDescriptionAttribute, kAXHelpAttribute, kAXPositionAttribute,
                        kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute]
    private static let batchAttribute = "AXMultipleAttributes"

    enum Attribute {
        case value(AnyObject)
        case missing
        case error(AXError)

        var value: AnyObject? { if case let .value(value) = self { return value }; return nil }
        static func decode(_ value: AnyObject?) -> Self {
            guard let value, CFGetTypeID(value) != CFNullGetTypeID() else { return .missing }
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var error = AXError.failure
                guard AXValueGetValue(value as! AXValue, .axError, &error), error != .success else {
                    return .error(.failure)
                }
                return .error(error)
            }
            return .value(value)
        }
    }

    struct Backend {
        var multiple: (AXUIElement, [String]) -> (AXError, [AnyObject]?)
        var single: (AXUIElement, String) -> (AXError, AnyObject?)
        static let live = Backend(multiple: { element, names in
            var values: CFArray?
            // Zero options preserves all positions, including individual AX
            // errors, instead of stopping at the first unsupported attribute.
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
            return (error, values as? [AnyObject])
        }, single: { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        })
    }

    private let attributes: [String: Attribute]
    var role: String? {
        guard let role = attributes[kAXRoleAttribute]?.value as? String, !role.isEmpty else { return nil }
        return role
    }
    var subrole: String { attributes[kAXSubroleAttribute]?.value as? String ?? "" }
    var title: String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { attributes[$0]?.value as? String }.first { !$0.isEmpty } ?? ""
    }
    var enabled: Bool { attributes[kAXEnabledAttribute]?.value as? Bool ?? true }
    var focused: Bool { attributes[kAXFocusedAttribute]?.value as? Bool ?? false }
    var requiresSecureMask: Bool {
        guard let role else { return true }
        if AutomationTextEntryPolicy.isSecure(role: role, subrole: subrole) { return true }
        switch attributes[kAXSubroleAttribute] ?? .missing {
        case let .value(value): return !(value is String)
        case .missing: return false
        case let .error(error): return error != .attributeUnsupported && error != .noValue && error != .notImplemented
        }
    }
    var bounds: CGRect? {
        guard let position = attributes[kAXPositionAttribute]?.value,
              let size = attributes[kAXSizeAttribute]?.value,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func read(_ element: AXUIElement, pid: pid_t, context: ObservationAccessibilityReads.Context,
                     backend: Backend = .live) throws -> Self {
        try TaskOwnership.check()
        var attributes = [String: Attribute]()
        var individual = context.usesIndividualReads(for: pid)
        let began = context.now()
        if !individual {
            var values: [AnyObject]?
            let error = context.read(element, attribute: batchAttribute, reportErrors: false) {
                let response = backend.multiple(element, names)
                values = response.1
                return response.0
            }
            try TaskOwnership.check()
            if context.now() >= context.deadline { return .init(attributes: [:]) }
            if error == .notImplemented || error == .attributeUnsupported {
                individual = true
                context.requireIndividualReads(for: pid)
            } else if error == .success, values?.count != names.count {
                // Never zip a truncated or misaligned result to executable IDs.
                context.report("accessibility_incomplete", batchAttribute, nil)
                individual = true
                context.requireIndividualReads(for: pid)
            } else if error != .success {
                context.record(error, attribute: batchAttribute, began: began, element: element)
                return .init(attributes: [:]) // No nine-read fanout on transport/permission/stale-element failures.
            } else if let values {
                for (name, value) in zip(names, values) {
                    try TaskOwnership.check()
                    guard context.now() < context.deadline else { return .init(attributes: [:]) }
                    var attribute = Attribute.decode(value)
                    if case let .error(error) = attribute {
                        var recovered: AnyObject?
                        let result = context.resolve(element, attribute: name, required: name == kAXRoleAttribute,
                                                     result: error, began: began) {
                            let response = backend.single(element, name)
                            recovered = response.1
                            return response.0
                        }
                        try TaskOwnership.check()
                        if result == .success {
                            attribute = .decode(recovered)
                            if case let .error(error) = attribute {
                                context.record(error, attribute: name, required: name == kAXRoleAttribute,
                                               began: began, element: element)
                            }
                        }
                        else { attribute = .error(result) }
                    }
                    if case .missing = attribute, name == kAXRoleAttribute {
                        // CFNull does not reveal an AX error code; keep it unknown.
                        context.report("accessibility_incomplete", name, nil)
                    }
                    attributes[name] = attribute
                }
            }
        }
        if individual {
            for name in names {
                try TaskOwnership.check()
                guard context.now() < context.deadline else { return .init(attributes: [:]) }
                var value: AnyObject?
                let error = context.read(element, attribute: name, required: name == kAXRoleAttribute) {
                    let response = backend.single(element, name)
                    value = response.1
                    return response.0
                }
                try TaskOwnership.check()
                let attribute: Attribute = error == .success ? .decode(value) : .error(error)
                if error == .success, case let .error(error) = attribute {
                    context.record(error, attribute: name, required: name == kAXRoleAttribute, began: began, element: element)
                }
                if case .missing = attribute, name == kAXRoleAttribute {
                    context.report("accessibility_incomplete", name, nil)
                }
                attributes[name] = attribute
                if name == kAXRoleAttribute, Self(attributes: attributes).role == nil { break }
            }
        }
        guard context.now() < context.deadline else { return .init(attributes: [:]) }
        let result = Self(attributes: attributes)
        if case .value = attributes[kAXRoleAttribute], result.role == nil {
            context.report("accessibility_incomplete", kAXRoleAttribute, nil)
        }
        if case let .value(value) = attributes[kAXSubroleAttribute], !(value is String) {
            context.report("accessibility_incomplete", kAXSubroleAttribute, nil)
        }
        return result
    }
}
