import XCTest
@testable import OrbitAgent

final class AgentTaskContinuationTests: XCTestCase {
    private let sourceGeneration = "source-generation"

    private var fileReference: AgentTaskInputReference {
        AgentTaskInputReference(kind: .file, utf8Start: 5, utf8Length: 18, value: "/fixture/input.pdf")
    }

    private func message(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "kind": "task_continuation_checkpoint",
            "task_generation_id": sourceGeneration,
            "version": 1,
            "eligible": true,
            "task_sha256": AgentTaskContinuationCheckpoint.requestFingerprint("request"),
            "input_references_sha256": AgentTaskContinuationCheckpoint.inputReferencesFingerprint([fileReference]),
            "source_task_generation_id": sourceGeneration,
            "instruction_revision": 0,
            "revision": 1,
            "requirements": [[
                "id": "r1", "source": "Create a report", "description": "Create report.pdf",
                "check": ["type": "file_contents", "path": "/tmp/report.pdf", "content": "verified contents"],
                "depends_on": [], "previously_proven": true
            ]],
            "observation_targets": [:],
            "expected_file_identities": ["r1": ["file_identity": String(repeating: "a", count: 64)]],
            "expected_web_destinations": [:],
            "batch": NSNull(),
            "result_summaries": [["kind": "file", "name": "report.pdf", "location": "/tmp"]],
            "unresolved_receipts": 0
        ]
        value.merge(overrides) { _, new in new }
        return value
    }

    func testInputReferenceFingerprintMatchesPythonLengthPrefixedEncoding() {
        XCTAssertEqual(AgentTaskContinuationCheckpoint.inputReferencesFingerprint([fileReference]),
                       "b3f933536ba32458083bd227d1bc5a5e166ed2da3fabe8e87e86f696ef47a981")
    }

    func testParsesBoundedEligibleCheckpointAndSanitizedResultSummary() throws {
        let checkpoint = try XCTUnwrap(AgentTaskContinuationCheckpoint.parse(message(), generationID: sourceGeneration))
        XCTAssertTrue(checkpoint.isEligible)
        XCTAssertEqual(checkpoint.priorVerifiedRequirementCount, 1)
        XCTAssertEqual(checkpoint.unfinishedRequirementCount, 0)
        XCTAssertEqual(checkpoint.results.map(\.name), ["report.pdf"])
        XCTAssertTrue(checkpoint.explanation.contains("Recheck report.pdf"))
        XCTAssertLessThan(checkpoint.estimatedByteCount, AgentTaskContinuationCheckpoint.maximumBytes)
    }

    func testRejectsStaleGenerationMalformedReferencesAndUnsupportedIdentity() {
        XCTAssertNil(AgentTaskContinuationCheckpoint.parse(message(), generationID: "another-generation"))

        var malformedReferences = message()
        malformedReferences["input_references_sha256"] = String(repeating: "0", count: 64)
        let mismatched = AgentTaskContinuationCheckpoint.parse(malformedReferences, generationID: sourceGeneration)
        XCTAssertFalse(mismatched?.matches(AgentTaskSubmission(request: "request", exactInputReferences: [fileReference])) ?? true)
        let matching = AgentTaskContinuationCheckpoint.parse(message(), generationID: sourceGeneration)
        XCTAssertTrue(matching?.matches(AgentTaskSubmission(request: "request", exactInputReferences: [fileReference])) ?? false)

        var unsupportedIdentity = message()
        unsupportedIdentity["expected_file_identities"] = ["r1": ["old_path": "/tmp/report.pdf"]]
        XCTAssertNil(AgentTaskContinuationCheckpoint.parse(unsupportedIdentity, generationID: sourceGeneration))
    }

    func testUnresolvedReceiptsCannotBecomeContinuationEligibility() throws {
        let checkpoint = try XCTUnwrap(AgentTaskContinuationCheckpoint.parse(
            message(["unresolved_receipts": 1]), generationID: sourceGeneration))
        XCTAssertFalse(checkpoint.isEligible)
        XCTAssertEqual(checkpoint.unresolvedReceiptCount, 1)
    }

    func testWebDestinationFingerprintMustReferToAPreviouslyVerifiedWindowRequirement() {
        let validWindowRequirement: [String: Any] = [
            "id": "r1", "source": "Open the example page", "description": "Leave the page visible",
            "check": ["type": "window_active", "pid": 42, "title": "Example Domain"],
            "depends_on": [], "previously_proven": true
        ]
        let valid = message([
            "requirements": [validWindowRequirement],
            "observation_targets": ["r1": ["pid": 42, "name": "Safari", "bundle_id": "com.apple.Safari"]],
            "expected_file_identities": [:],
            "expected_web_destinations": ["r1": String(repeating: "b", count: 64)]
        ])
        XCTAssertNotNil(AgentTaskContinuationCheckpoint.parse(valid, generationID: sourceGeneration))

        var invalid = valid
        invalid["expected_web_destinations"] = ["r2": String(repeating: "b", count: 64)]
        XCTAssertNil(AgentTaskContinuationCheckpoint.parse(invalid, generationID: sourceGeneration))

        invalid["expected_web_destinations"] = ["r1": "https://example.com/"]
        XCTAssertNil(AgentTaskContinuationCheckpoint.parse(invalid, generationID: sourceGeneration))
    }
}
