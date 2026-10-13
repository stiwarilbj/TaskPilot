import XCTest
import ApplicationServices
@testable import OrbitAgent

final class ObservationControlAttributesTests: XCTestCase {
    private final class World {
        var time: Double = 0
        var retries = 0, batches = 0
        var singles = [String]()
        var timeouts = [Float]()
        var issues = [(reason: String, attribute: String?, code: Int?)]()
        var values = ObservationControlAttributesTests.validValues()
        var batchError = AXError.success
        var batchValues: [AnyObject]?
        var omitBatchValues = false
        var retryable = false
        var onBatch: (() -> Void)?
        var onSingle: ((String) -> (AXError, AnyObject?))?
        let element = AXUIElementCreateApplication(2_147_483_647)
        lazy var context = makeContext()

        func makeContext() -> ObservationAccessibilityReads.Context {
            .init(deadline: 1, now: { self.time },
                  report: { self.issues.append(($0, $1, $2)) },
                  retried: { self.retries += 1 }, shouldRetry: { self.retryable },
                  setTimeout: { _, timeout in self.timeouts.append(timeout) })
        }
        var backend: ObservationControlAttributes.Backend {
            .init(multiple: { _, names in
                self.batches += 1
                XCTAssertEqual(names, ObservationControlAttributes.names)
                self.onBatch?()
                return (self.batchError, self.omitBatchValues ? nil : self.batchValues ?? names.map { self.values[$0] ?? kCFNull! })
            }, single: { _, name in
                self.singles.append(name)
                if let onSingle = self.onSingle { return onSingle(name) }
                return self.values[name].map { (.success, $0) } ?? (.noValue, nil)
            })
        }
        func read(pid: pid_t = 42, context: ObservationAccessibilityReads.Context? = nil) throws -> ObservationControlAttributes {
            try .read(element, pid: pid, context: context ?? self.context, backend: backend)
        }
    }

    private static func validValues() -> [String: AnyObject] {
        var point = CGPoint(x: 23, y: 44), size = CGSize(width: 120, height: 32)
        return [kAXRoleAttribute: "AXButton" as NSString, kAXSubroleAttribute: "" as NSString,
                kAXTitleAttribute: "Save" as NSString, kAXDescriptionAttribute: "Description" as NSString,
                kAXHelpAttribute: "Help" as NSString,
                kAXPositionAttribute: AXValueCreate(.cgPoint, &point)!, kAXSizeAttribute: AXValueCreate(.cgSize, &size)!,
                kAXEnabledAttribute: kCFBooleanFalse!, kAXFocusedAttribute: kCFBooleanTrue!]
    }
    private func errorValue(_ error: AXError) -> AXValue {
        var error = error
        return AXValueCreate(.axError, &error)!
    }

    func testHealthyMetadataUsesOneBatchAndSharesItsValues() throws {
        let world = World(), result = try world.read()
        XCTAssertEqual(world.batches, 1); XCTAssertTrue(world.singles.isEmpty)
        XCTAssertEqual(result.role, "AXButton"); XCTAssertEqual(result.title, "Save")
        XCTAssertEqual(result.bounds, CGRect(x: 23, y: 44, width: 120, height: 32))
        XCTAssertFalse(result.enabled); XCTAssertTrue(result.focused); XCTAssertFalse(result.requiresSecureMask)
        XCTAssertTrue(world.issues.isEmpty); XCTAssertEqual(world.retries, 0)
        XCTAssertEqual(world.timeouts, [0.08, 0])
    }

    func testLabelFallbackUsesBatchedDescriptionAndHelp() throws {
        let world = World(); world.values[kAXTitleAttribute] = "" as NSString
        XCTAssertEqual(try world.read().title, "Description")
        world.values[kAXDescriptionAttribute] = kCFNull!
        XCTAssertEqual(try world.read().title, "Help")
        XCTAssertTrue(world.singles.isEmpty)
    }

    func testOptionalNullsAndEncodedAbsencePreserveSuccessfulNeighbors() throws {
        let world = World()
        world.values[kAXSubroleAttribute] = errorValue(.attributeUnsupported)
        world.values[kAXTitleAttribute] = kCFNull!
        world.values[kAXHelpAttribute] = errorValue(.noValue)
        let result = try world.read()
        XCTAssertEqual(result.title, "Description"); XCTAssertFalse(result.requiresSecureMask)
        XCTAssertEqual(result.bounds?.origin.x, 23); XCTAssertFalse(result.enabled)
        XCTAssertTrue(world.issues.isEmpty); XCTAssertTrue(world.singles.isEmpty)
    }

    func testIndividualErrorRetainsExactAttributeAndCode() throws {
        let world = World(); world.values[kAXEnabledAttribute] = errorValue(.apiDisabled)
        let result = try world.read()
        XCTAssertEqual(result.title, "Save"); XCTAssertTrue(result.enabled)
        XCTAssertFalse(result.requiresSecureMask) // Unrelated errors do not change secure identity.
        XCTAssertEqual(world.issues.count, 1)
        XCTAssertEqual(world.issues[0].reason, "accessibility_permission_unavailable")
        XCTAssertEqual(world.issues[0].attribute, kAXEnabledAttribute)
        XCTAssertEqual(world.issues[0].code, Int(AXError.apiDisabled.rawValue))
        XCTAssertTrue(world.singles.isEmpty)
    }

    func testMissingRoleAndRoleErrorAreDistinguished() throws {
        let world = World(); world.values[kAXRoleAttribute] = kCFNull!
        XCTAssertNil(try world.read().role)
        XCTAssertEqual(world.issues[0].reason, "accessibility_incomplete")
        XCTAssertEqual(world.issues[0].attribute, kAXRoleAttribute); XCTAssertNil(world.issues[0].code)
        world.issues.removeAll(); world.values[kAXRoleAttribute] = errorValue(.noValue)
        XCTAssertNil(try world.read().role)
        XCTAssertEqual(world.issues[0].code, Int(AXError.noValue.rawValue))
        XCTAssertTrue(world.singles.isEmpty)
    }

    func testMalformedIdentityDoesNotExposeSecureValues() throws {
        let world = World(); world.values[kAXRoleAttribute] = 17 as NSNumber
        XCTAssertNil(try world.read().role)
        XCTAssertEqual(world.issues.last?.attribute, kAXRoleAttribute)
        world.values[kAXRoleAttribute] = "AXTextField" as NSString
        world.values[kAXSubroleAttribute] = 19 as NSNumber
        XCTAssertTrue(try world.read().requiresSecureMask)
        XCTAssertEqual(world.issues.last?.attribute, kAXSubroleAttribute)
        world.values[kAXSubroleAttribute] = errorValue(.cannotComplete)
        XCTAssertTrue(try world.read().requiresSecureMask)
        world.values[kAXSubroleAttribute] = "AXSecureTextField" as NSString
        XCTAssertTrue(try world.read().requiresSecureMask)
        XCTAssertFalse(ObservationControlAttributes.names.contains(kAXValueAttribute))
        XCTAssertFalse(ObservationControlAttributes.names.contains(kAXSelectedTextAttribute))
        XCTAssertFalse(ObservationControlAttributes.names.contains(kAXSelectedTextRangeAttribute))
        XCTAssertTrue(world.singles.isEmpty)
    }

    func testErrorAndWrongTypedBoundsNeverBecomeCoordinates() throws {
        let world = World(); world.values[kAXPositionAttribute] = errorValue(.invalidUIElement)
        XCTAssertNil(try world.read().bounds)
        XCTAssertEqual(world.issues.last?.attribute, kAXPositionAttribute)
        world.values[kAXPositionAttribute] = "23,44" as NSString
        XCTAssertNil(try world.read().bounds)
        world.values[kAXPositionAttribute] = world.values[kAXSizeAttribute]
        XCTAssertNil(try world.read().bounds)
    }

    func testUnsupportedBatchUsesBoundedIndividualReadsOnlyForThatStagingApp() throws {
        for error in [AXError.notImplemented, .attributeUnsupported] {
            let world = World(); world.batchError = error
            XCTAssertEqual(try world.read().title, "Save")
            XCTAssertEqual(world.batches, 1); XCTAssertEqual(world.singles, ObservationControlAttributes.names)
            _ = try world.read()
            XCTAssertEqual(world.batches, 1); XCTAssertEqual(world.singles.count, 18)
            _ = try world.read(pid: 43); XCTAssertEqual(world.batches, 2)
            _ = try world.read(context: world.makeContext()); XCTAssertEqual(world.batches, 3)
            XCTAssertTrue(world.issues.isEmpty)
        }
    }

    func testMalformedBatchCannotMisalignAttributesAndFallsBack() throws {
        for count in [0, 1, 8, 10] {
            let world = World(); world.batchValues = Array(repeating: "wrong" as NSString, count: count)
            let result = try world.read()
            XCTAssertEqual(result.role, "AXButton"); XCTAssertEqual(result.title, "Save")
            XCTAssertEqual(world.singles, ObservationControlAttributes.names)
            XCTAssertEqual(world.issues.map(\.reason), ["accessibility_incomplete"])
            XCTAssertEqual(world.issues[0].attribute, "AXMultipleAttributes")
        }
        let missing = World(); missing.omitBatchValues = true
        XCTAssertEqual(try missing.read().title, "Save")
        XCTAssertEqual(missing.singles, ObservationControlAttributes.names)
        XCTAssertEqual(missing.issues.map(\.reason), ["accessibility_incomplete"])
    }

    func testMissingRecoveredRoleIsReportedAndNeverInvented() throws {
        let world = World(); world.retryable = true
        world.values[kAXRoleAttribute] = errorValue(.cannotComplete)
        world.onSingle = { _ in (.success, nil) }
        XCTAssertNil(try world.read().role)
        XCTAssertEqual(world.singles, [kAXRoleAttribute])
        XCTAssertEqual(world.issues.map(\.reason), ["accessibility_incomplete"])
        XCTAssertEqual(world.issues[0].attribute, kAXRoleAttribute); XCTAssertNil(world.issues[0].code)
    }

    func testUnsupportedBatchStopsFallbackWhenRoleCannotBeRead() throws {
        let world = World(); world.batchError = .notImplemented
        world.onSingle = { _ in (.noValue, nil) }
        XCTAssertNil(try world.read().role)
        XCTAssertEqual(world.singles, [kAXRoleAttribute])
        XCTAssertEqual(world.issues.map(\.attribute), [kAXRoleAttribute])
    }

    func testErrorWrappersFromSingleReadAreNotMistakenForValues() throws {
        let world = World(); world.retryable = true
        world.values[kAXTitleAttribute] = errorValue(.cannotComplete)
        world.onSingle = { _ in (.success, self.errorValue(.apiDisabled)) }
        XCTAssertEqual(try world.read().title, "Description")
        XCTAssertEqual(world.issues[0].code, Int(AXError.apiDisabled.rawValue))
        world.issues.removeAll(); world.batchError = .notImplemented
        world.onSingle = { name in (.success, name == kAXTitleAttribute ? self.errorValue(.apiDisabled) : world.values[name]) }
        XCTAssertEqual(try world.read().title, "Description")
        XCTAssertEqual(world.issues[0].attribute, kAXTitleAttribute)
        XCTAssertEqual(world.issues[0].code, Int(AXError.apiDisabled.rawValue))
    }

    func testGlobalFailuresDoNotFanOutToIndividualReads() throws {
        for error in [AXError.apiDisabled, .invalidUIElement, .cannotComplete, .failure, .illegalArgument] {
            let world = World(); world.batchError = error
            XCTAssertNil(try world.read().role)
            XCTAssertEqual(world.batches, 1); XCTAssertTrue(world.singles.isEmpty)
            XCTAssertEqual(world.issues.count, 1)
            XCTAssertEqual(world.issues[0].attribute, "AXMultipleAttributes")
            XCTAssertEqual(world.issues[0].code, Int(error.rawValue))
        }
    }

    func testTransientBatchRetriesWithinExistingSharedBudget() throws {
        let world = World(); world.retryable = true
        world.onBatch = { world.batchError = world.batches == 1 ? .cannotComplete : .success }
        XCTAssertEqual(try world.read().title, "Save")
        XCTAssertEqual(world.batches, 2); XCTAssertEqual(world.retries, 1)
        XCTAssertTrue(world.singles.isEmpty); XCTAssertTrue(world.issues.isEmpty)
    }

    func testTransientIndividualErrorRetriesOnlyFailedAttribute() throws {
        let world = World(); world.retryable = true
        world.values[kAXTitleAttribute] = errorValue(.cannotComplete)
        world.onSingle = { name in XCTAssertEqual(name, kAXTitleAttribute); return (.success, "Recovered" as NSString) }
        let result = try world.read()
        XCTAssertEqual(result.title, "Recovered"); XCTAssertEqual(result.role, "AXButton")
        XCTAssertEqual(world.singles, [kAXTitleAttribute]); XCTAssertEqual(world.retries, 1)
        XCTAssertEqual(world.batches, 1); XCTAssertTrue(world.issues.isEmpty)
    }

    func testFailedIndividualRetryReportsFinalErrorOnceAndKeepsNeighbors() throws {
        let world = World(); world.retryable = true
        world.values[kAXTitleAttribute] = errorValue(.cannotComplete)
        world.onSingle = { _ in (.apiDisabled, "Discard me" as NSString) }
        XCTAssertEqual(try world.read().title, "Description")
        XCTAssertEqual(world.issues.count, 1)
        XCTAssertEqual(world.issues[0].attribute, kAXTitleAttribute)
        XCTAssertEqual(world.issues[0].code, Int(AXError.apiDisabled.rawValue))
        _ = try world.read()
        XCTAssertEqual(world.singles.count, 1); XCTAssertEqual(world.retries, 1)
        XCTAssertEqual(world.issues.last?.code, Int(AXError.cannotComplete.rawValue))
    }

    func testBatchAndIndividualRetriesShareEightAttemptLimit() throws {
        let world = World(); world.retryable = true
        for name in ObservationControlAttributes.names { world.values[name] = errorValue(.failure) }
        world.onSingle = { _ in (.failure, nil) }
        _ = try world.read()
        XCTAssertEqual(world.retries, 8); XCTAssertEqual(world.singles.count, 8)
        _ = try world.read()
        XCTAssertEqual(world.retries, 8); XCTAssertEqual(world.singles.count, 8)
        world.batchError = .cannotComplete
        _ = try world.read()
        XCTAssertEqual(world.retries, 8); XCTAssertEqual(world.batches, 3)
    }

    func testIndividualFallbackPreservesErrorCodesAndNullSemantics() throws {
        let world = World(); world.batchError = .notImplemented
        world.onSingle = { name in
            if name == kAXEnabledAttribute { return (.apiDisabled, nil) }
            if name == kAXSubroleAttribute { return (.noValue, nil) }
            return (.success, world.values[name])
        }
        let result = try world.read()
        XCTAssertEqual(result.title, "Save"); XCTAssertFalse(result.requiresSecureMask)
        XCTAssertEqual(world.issues.count, 1)
        XCTAssertEqual(world.issues[0].attribute, kAXEnabledAttribute)
        XCTAssertEqual(world.issues[0].code, Int(AXError.apiDisabled.rawValue))
    }

    func testDeadlineBeforeAndDuringBatchDiscardsValuesWithoutFallback() throws {
        let before = World(); before.time = 2
        XCTAssertNil(try before.read().role); XCTAssertEqual(before.batches, 0)
        XCTAssertEqual(before.issues.map(\.reason), ["collection_timeout"])
        let during = World(); during.retryable = true
        during.onBatch = { during.time = 2; during.batchError = .notImplemented }
        XCTAssertNil(try during.read().role); XCTAssertEqual(during.batches, 1)
        XCTAssertTrue(during.singles.isEmpty); XCTAssertEqual(during.retries, 0)
        XCTAssertEqual(during.issues.map(\.reason), ["collection_timeout"])
        XCTAssertEqual(during.timeouts.last, 0)
    }

    func testIndividualFallbackStopsAtDeadline() throws {
        let world = World(); world.batchError = .notImplemented
        world.onSingle = { _ in world.time = 2; return (.success, "AXButton" as NSString) }
        XCTAssertNil(try world.read().role)
        XCTAssertEqual(world.singles, [kAXRoleAttribute])
        XCTAssertEqual(world.issues.map(\.reason), ["collection_timeout"])
    }

    func testRevocationBeforeAndDuringBatchPreventsPublishingOrFallback() throws {
        let before = World(), old = TaskLease(); old.revoke()
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(old) { try before.read() })
        XCTAssertEqual(before.batches, 0)
        for error in [AXError.success, .notImplemented, .cannotComplete] {
            let world = World(), lease = TaskLease(); world.retryable = true
            world.onBatch = { lease.revoke(); world.batchError = error }
            XCTAssertThrowsError(try TaskOwnership.$current.withValue(lease) { try world.read() })
            XCTAssertEqual(world.batches, 1); XCTAssertTrue(world.singles.isEmpty)
            XCTAssertEqual(world.retries, 0); XCTAssertEqual(world.timeouts.last, 0)
        }
    }

    func testRevocationDuringAttributeRecoveryStopsRemainingReads() throws {
        let world = World(), lease = TaskLease(); world.retryable = true
        world.values[kAXRoleAttribute] = errorValue(.cannotComplete)
        world.onSingle = { _ in lease.revoke(); return (.success, "AXButton" as NSString) }
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(lease) { try world.read() })
        XCTAssertEqual(world.singles, [kAXRoleAttribute]); XCTAssertEqual(world.retries, 1)
        XCTAssertEqual(world.timeouts.last, 0)
    }

    func testValuesAreNotCachedBetweenFreshStagedSnapshots() throws {
        let world = World()
        let first = try world.read()
        world.values[kAXTitleAttribute] = "Cancel" as NSString
        let second = try world.read()
        XCTAssertEqual(first.title, "Save"); XCTAssertEqual(second.title, "Cancel")
        XCTAssertEqual(world.batches, 2)
    }
}
