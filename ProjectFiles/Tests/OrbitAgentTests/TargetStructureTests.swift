import XCTest
@testable import OrbitAgent

final class TargetStructureTests: XCTestCase {
    private func node(identity: UInt = 7, role: String = "AXGroup", label: String = "Accounts",
                      bounds: CGRect = CGRect(x: 0, y: 0, width: 300, height: 200),
                      labels: [String] = ["Work account"]) -> AutomationStructureNode {
        AutomationStructureNode(identity: identity, role: role, label: label, bounds: bounds, labels: labels)
    }

    private func target(_ structure: [AutomationStructureNode]) -> AutomationTargetIdentity {
        AutomationTargetIdentity(application: AutomationApplicationIdentity(pid: 42, bundleID: "fixture", bundlePath: nil,
            name: "Fixture", launchDate: nil), role: "AXButton", subrole: "", label: "Save",
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30), windowTitle: "Settings",
            windowBounds: CGRect(x: 0, y: 0, width: 600, height: 400), structure: structure)
    }

    func testSameControlAndSurroundingStructureDeliverOnce() throws {
        var delivered = 0
        let expected = target([node()])
        try AutomationTargetPolicy.deliver(preflight: {
            try AutomationTargetPolicy.validate(observed: expected, current: expected, sameWindow: true,
                enabled: true, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        }, event: { delivered += 1 })
        XCTAssertEqual(delivered, 1)
    }

    func testReplacementReparentingRelabelingAndMovingPanelRejectBeforeDelivery() {
        let expected = target([node()])
        let changed = [[node(identity: 8)], [node(role: "AXSheet")], [node(label: "Other panel")],
                       [node(bounds: CGRect(x: 1, y: 0, width: 300, height: 200))], [node(labels: ["Personal account"])],
                       [node(), node(identity: 9)], []]
        var delivered = 0
        for structure in changed {
            XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: {
                try AutomationTargetPolicy.validate(observed: expected, current: self.target(structure), sameWindow: true,
                    enabled: true, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
            }, event: { delivered += 1 })) { error in
                XCTAssertEqual((error as? AccessibilityActionError)?.code, "stale_target")
            }
        }
        XCTAssertEqual(delivered, 0)
    }

    func testUnrelatedCoordinateCandidatesRejectWithoutDelivery() {
        var delivered = 0
        XCTAssertThrowsError(try AutomationTargetPolicy.deliver(preflight: {
            try AutomationTargetPolicy.validateCoordinateCandidates(count: 2) { _, _ in false }
        }, event: { delivered += 1 })) { error in
            XCTAssertEqual((error as? AccessibilityActionError)?.code, "ambiguous_target")
        }
        XCTAssertEqual(delivered, 0)
    }

    func testDescendantLabelAndSingleOrMissingCoordinateCandidatesRemainSupported() throws {
        try AutomationTargetPolicy.validateCoordinateCandidates(count: 2) { _, _ in true }
        try AutomationTargetPolicy.validateCoordinateCandidates(count: 1) { _, _ in XCTFail(); return false }
        try AutomationTargetPolicy.validateCoordinateCandidates(count: 0) { _, _ in XCTFail(); return false }
    }

    func testCaptureConsistencyIncludesSurroundingStructure() throws {
        let base: [String: Any] = ["id": "r:e1", "pid": 42, "role": "AXButton", "title": "Save", "structure": [node().dictionary]]
        var changed = base
        changed["structure"] = [node(labels: ["Personal account"]).dictionary]
        XCTAssertNotEqual(try ObservationConsistency.controlSignature(elements: [base], applications: []),
                          try ObservationConsistency.controlSignature(elements: [changed], applications: []))
    }
}
