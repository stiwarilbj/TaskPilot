import XCTest
@testable import OrbitAgent

final class ControlCompatibilityTests: XCTestCase {
    private let environment = ControlCompatibilityProfiles.fingerprint(["fixture-runtime", "permissions"])
    private func key(app: String = "fixture.app", version: String = "1", build: String = "10", revision: String = "binary-1",
                     role: String = "AXTextField", subrole: String = "", action: ActionKind = .set_value,
                     capabilities: [String: Bool] = ["value": true], hid: Bool = false, main: Bool = false,
                     environment: String? = nil) -> ControlCompatibilityProfiles.Key {
        .init(appID: app, bundlePath: "/fixture/\(app).app", version: version, build: build, executableRevision: revision,
              role: role, subrole: subrole, action: action, capabilities: capabilities, hid: hid, mainDisplay: main,
              environment: environment ?? self.environment)
    }
    private func fixtureFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskpilot-compatibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("profiles.json")
    }

    func testOnlyVerifiedMethodsOutrankTheDefaultAndNeverExpandPermittedRoutes() {
        let profiles = ControlCompatibilityProfiles(environment: environment), key = key()
        XCTAssertEqual(profiles.preferred(for: key, permitted: [.accessibility_value, .process_event]), .accessibility_value)
        for evidence in [ControlCompatibilityProfiles.Evidence.supported, .unsupported, .unconfirmed] {
            profiles.record(evidence, method: .process_event, for: key)
            XCTAssertEqual(profiles.preferred(for: key, permitted: [.accessibility_value, .process_event]), .accessibility_value)
        }
        profiles.record(.verified, method: .process_event, for: key)
        XCTAssertEqual(profiles.preferred(for: key, permitted: [.accessibility_value, .process_event]), .process_event)
        XCTAssertEqual(profiles.preferred(for: key, permitted: [.accessibility_value]), .accessibility_value)
        XCTAssertNil(profiles.preferred(for: key, permitted: [.hid, .accessibility]))
        profiles.record(.unconfirmed, method: .process_event, for: key)
        XCTAssertEqual(profiles.preferred(for: key, permitted: [.accessibility_value, .process_event]), .accessibility_value)
    }

    func testAppRoleIntentAndInstallationScopesDoNotShareCompatibility() {
        let profiles = ControlCompatibilityProfiles(environment: environment), original = key()
        _ = profiles.preferred(for: original, permitted: [])
        profiles.record(.verified, method: .process_event, for: original)
        for different in [key(app: "other.app"), key(role: "AXTextArea"), key(subrole: "AXSearchField"), key(action: .type_text)] {
            XCTAssertNotEqual(different.subject, original.subject)
            XCTAssertEqual(profiles.preferred(for: different, permitted: [.accessibility_selected_text, .process_event]), .accessibility_selected_text)
        }
    }

    func testRelevantChangesInvalidateAndLateFeedbackCannotResurrectAnOldRevision() {
        for changed in [key(version: "2"), key(build: "11"), key(revision: "binary-2"), key(capabilities: ["value": false]),
                        key(hid: true), key(main: true)] {
            let profiles = ControlCompatibilityProfiles(environment: environment), original = key()
            _ = profiles.preferred(for: original, permitted: [])
            profiles.record(.verified, method: .process_event, for: original)
            XCTAssertEqual(changed.subject, original.subject)
            XCTAssertNotEqual(changed.revision, original.revision)
            XCTAssertEqual(profiles.preferred(for: changed, permitted: [.accessibility_value, .process_event]), .accessibility_value)
            profiles.record(.verified, method: .process_event, for: original)
            XCTAssertNil(profiles.evidence(for: original, method: .process_event))
            XCTAssertNil(profiles.evidence(for: changed, method: .process_event))
        }
    }

    func testPermissionOrRuntimeChangesInvalidateAllProfilesAndPersistedHints() throws {
        let file = try fixtureFile(), profiles = ControlCompatibilityProfiles(fileURL: file, environment: environment), original = key()
        _ = profiles.preferred(for: original, permitted: [])
        profiles.record(.verified, method: .process_event, for: original)
        let changedEnvironment = ControlCompatibilityProfiles.fingerprint(["new-runtime-or-permissions"])
        profiles.prepare(environment: changedEnvironment)
        profiles.record(.verified, method: .process_event, for: original)
        XCTAssertEqual(profiles.count, 0)
        let reloaded = ControlCompatibilityProfiles(fileURL: file, environment: changedEnvironment)
        XCTAssertEqual(reloaded.count, 0)
        XCTAssertNil(reloaded.preferred(for: original, permitted: [.process_event]))
    }

    func testIndividualMethodExpiryCannotBeExtendedByOtherRecentFeedback() {
        var date = Date(timeIntervalSince1970: 1_000_000)
        let profiles = ControlCompatibilityProfiles(environment: environment, now: { date }), original = key()
        _ = profiles.preferred(for: original, permitted: [])
        profiles.record(.verified, method: .process_event, for: original)
        date += ControlCompatibilityProfiles.lifetime / 2
        profiles.record(.unsupported, method: .accessibility_value, for: original)
        date += ControlCompatibilityProfiles.lifetime / 2 + 1
        XCTAssertEqual(profiles.preferred(for: original, permitted: [.accessibility_value, .process_event]), .accessibility_value)
        XCTAssertNil(profiles.evidence(for: original, method: .process_event))
        XCTAssertEqual(profiles.evidence(for: original, method: .accessibility_value), .unsupported)
    }

    func testStorageIsBoundedAndEvictsTheLeastRecentlyUsedProfile() {
        var date = Date(timeIntervalSince1970: 1_000_000)
        let profiles = ControlCompatibilityProfiles(environment: environment, now: { date })
        let first = key(app: "first"), retained = key(app: "retained")
        _ = profiles.preferred(for: first, permitted: []); profiles.record(.verified, method: .process_event, for: first)
        date += 1
        _ = profiles.preferred(for: retained, permitted: []); profiles.record(.verified, method: .process_event, for: retained)
        for index in 0..<ControlCompatibilityProfiles.maximumProfiles - 2 {
            date += 1
            let context = key(app: "fixture-\(index)")
            _ = profiles.preferred(for: context, permitted: []); profiles.record(.supported, method: .process_event, for: context)
        }
        date += 1; _ = profiles.preferred(for: retained, permitted: [])
        date += 1; _ = profiles.preferred(for: key(app: "extra"), permitted: [])
        XCTAssertEqual(profiles.count, ControlCompatibilityProfiles.maximumProfiles)
        XCTAssertNil(profiles.evidence(for: first, method: .process_event))
        XCTAssertEqual(profiles.evidence(for: retained, method: .process_event), .verified)
    }

    func testPersistenceContainsOnlyHashedMetadataMethodEvidenceAndTimestamps() throws {
        let file = try fixtureFile(), profiles = ControlCompatibilityProfiles(fileURL: file, environment: environment), context = key()
        _ = profiles.preferred(for: context, permitted: [])
        profiles.record(.verified, method: .process_event, for: context)
        let data = try Data(contentsOf: file), json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertLessThanOrEqual(data.count, ControlCompatibilityProfiles.maximumFileBytes)
        XCTAssertEqual(Set(json.keys), ["version", "environment", "profiles"])
        let rows = try XCTUnwrap(json["profiles"] as? [String: [String: Any]])
        let row = try XCTUnwrap(rows[context.subject])
        XCTAssertEqual(Set(row.keys), ["revision", "methods", "lastUsed"])
        let methods = try XCTUnwrap(row["methods"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(methods["process_event"]).keys), ["evidence", "observedAt"])
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["fixture.app", "/fixture/", "AXTextField", "coordinates", "credential", "command", "text", "pid"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reloaded = ControlCompatibilityProfiles(fileURL: file, environment: environment)
        XCTAssertEqual(reloaded.preferred(for: context, permitted: [.accessibility_value, .process_event]), .process_event)
    }

    func testCorruptOversizedAndSymbolicCacheFilesDoNotAffectActionsOrOtherFiles() throws {
        let file = try fixtureFile(), context = key()
        for bytes in [Data("{malformed".utf8), Data(repeating: 65, count: ControlCompatibilityProfiles.maximumFileBytes + 1)] {
            try bytes.write(to: file)
            let profiles = ControlCompatibilityProfiles(fileURL: file, environment: environment)
            XCTAssertEqual(profiles.count, 0)
            XCTAssertEqual(profiles.preferred(for: context, permitted: [.accessibility_value, .process_event]), .accessibility_value)
        }
        let other = file.deletingLastPathComponent().appendingPathComponent("keep")
        try Data("untouched".utf8).write(to: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        let profiles = ControlCompatibilityProfiles(fileURL: file, environment: environment)
        _ = profiles.preferred(for: context, permitted: []); profiles.record(.verified, method: .process_event, for: context)
        XCTAssertEqual(try Data(contentsOf: other), Data("untouched".utf8))
    }

    func testStoppedTaskCannotCommitFeedbackIntoANewerProfile() throws {
        let profiles = ControlCompatibilityProfiles(environment: environment), context = key()
        _ = profiles.preferred(for: context, permitted: []); profiles.record(.verified, method: .accessibility_value, for: context)
        let lease = TaskLease(); lease.revoke()
        XCTAssertThrowsError(try TaskOwnership.$current.withValue(lease) {
            try ControlCompatibilityProfiles.owned { profiles.record(.unconfirmed, method: .accessibility_value, for: context) }
        })
        XCTAssertEqual(profiles.evidence(for: context, method: .accessibility_value), .verified)
    }

    func testProfileMetadataDoesNotMarkAnActionReceiptDispatched() throws {
        let profiles = ControlCompatibilityProfiles(environment: environment), context = key(), lease = TaskLease()
        guard case .new(let token) = try lease.actionReceipts.begin(id: UUID().uuidString, payload: ["type": "fixture"]) else {
            return XCTFail("Expected a new receipt")
        }
        try TaskOwnership.$current.withValue(lease) {
            try TaskOwnership.$actionReceipt.withValue(token) {
                _ = try ControlCompatibilityProfiles.owned { profiles.preferred(for: context, permitted: []) }
                try ControlCompatibilityProfiles.owned { profiles.record(.supported, method: .process_event, for: context) }
            }
        }
        XCTAssertEqual(token.receipt["state"] as? String, "pending")
    }

    func testControlEvidenceRequiresASpecificBoundControlChange() {
        XCTAssertFalse(ControlInteractionState().verifies(ControlInteractionState()))
        XCTAssertFalse(ControlInteractionState(selected: true).verifies(ControlInteractionState(selected: true)))
        XCTAssertFalse(ControlInteractionState().verifies(ControlInteractionState(selected: true)))
        XCTAssertTrue(ControlInteractionState(selected: false).verifies(ControlInteractionState(selected: true)))
        XCTAssertTrue(ControlInteractionState(expanded: false).verifies(ControlInteractionState(expanded: true)))
        XCTAssertTrue(ControlInteractionState(toggle: true).verifies(ControlInteractionState(toggle: false)))
        XCTAssertTrue(ControlInteractionState(editableFocused: false).verifies(ControlInteractionState(editableFocused: true)))
    }

    func testRecordedDeliveryMethodsMatchTheNativeRoutesIncludingSemanticFallback() {
        for hid in [false, true] {
            XCTAssertEqual(ControlDeliveryMethod.delivered(action: .press, coordinatePress: false, hid: hid), .accessibility)
            XCTAssertEqual(ControlDeliveryMethod.delivered(action: .press, coordinatePress: true, hid: hid), hid ? .hid : .session_event)
            XCTAssertEqual(ControlDeliveryMethod.delivered(action: .double_click, coordinatePress: false, hid: hid), hid ? .hid : .session_event)
            XCTAssertEqual(ControlDeliveryMethod.delivered(action: .scroll, coordinatePress: false, hid: hid), .session_event)
            XCTAssertEqual(ControlDeliveryMethod.delivered(action: .key, coordinatePress: false, hid: hid), .process_event)
        }
    }
}
