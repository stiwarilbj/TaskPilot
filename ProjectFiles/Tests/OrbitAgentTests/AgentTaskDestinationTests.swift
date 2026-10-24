import Foundation
import XCTest
@testable import OrbitAgent

final class AgentTaskDestinationTests: XCTestCase {
    private func message(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "kind": "task_destination", "task_generation_id": "generation",
            "instruction_revision": 0, "working_document_revision": 0,
            "version": 1, "revision": 1, "operation_id": 1,
            "state": "planned", "planned_path": "/Users/test/Downloads/Reports/October.pdf",
            "actual_path": NSNull(), "requested_filename": "October.pdf",
            "selected_filename": NSNull(), "destination_exists": NSNull(),
            "instruction": NSNull(), "observation_revision": NSNull()
        ]
        value.merge(overrides) { _, new in new }
        return value
    }

    func testPlannedAndSelectedDestinationsHaveClearLabels() throws {
        let planned = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message(), generationID: "generation"))
        XCTAssertEqual(planned.collapsedTitle, "Planned destination: Downloads › Reports › October.pdf")
        XCTAssertFalse(planned.isMismatch)

        let selected = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "state": "selected", "planned_path": NSNull(), "actual_path": "/Users/test/Downloads/Reports/October.pdf",
            "requested_filename": NSNull(), "selected_filename": "October.pdf",
            "observation_revision": "obs-4"
        ]), generationID: "generation"))
        XCTAssertEqual(selected.collapsedTitle, "Selected destination: Downloads › Reports › October.pdf")
    }

    func testSelectedPathAndRequestedFilenameDifferencesAreVisible() throws {
        let mismatch = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "state": "preparing", "actual_path": "/Users/test/Downloads/Other/November.pdf",
            "selected_filename": "November.pdf"
        ]), generationID: "generation"))
        XCTAssertTrue(mismatch.isMismatch)
        XCTAssertTrue(mismatch.collapsedTitle.hasPrefix("Destination differs:"))

        let filenameMismatch = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "state": "preparing", "actual_path": "/Users/test/Downloads/Reports/November.pdf",
            "selected_filename": "November.pdf", "planned_path": NSNull()
        ]), generationID: "generation"))
        XCTAssertTrue(filenameMismatch.isMismatch)

        let selectedMismatch = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "state": "selected", "actual_path": "/Users/test/Downloads/Other/October.pdf",
            "selected_filename": "October.pdf"
        ]), generationID: "generation"))
        XCTAssertTrue(selectedMismatch.collapsedTitle.hasPrefix("Destination differs:"))

        let selectedInsideFolder = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "state": "preparing", "planned_path": "/Users/test/Downloads/Reports",
            "actual_path": "/Users/test/Downloads/Reports/October.pdf", "requested_filename": NSNull(),
            "selected_filename": "October.pdf"
        ]), generationID: "generation"))
        XCTAssertFalse(selectedInsideFolder.isMismatch)
    }

    func testMalformedOrStaleSnapshotsAreRejected() {
        XCTAssertNil(AgentTaskDestinationSnapshot.parse(message(), generationID: "other"))
        XCTAssertNil(AgentTaskDestinationSnapshot.parse(message(["instruction_revision": 1.5]), generationID: "generation"))
        XCTAssertNil(AgentTaskDestinationSnapshot.parse(message(["actual_path": "relative/October.pdf"]), generationID: "generation"))
        XCTAssertNil(AgentTaskDestinationSnapshot.parse(message(["instruction": "secret=never-display"]), generationID: "generation"))
        XCTAssertNil(AgentTaskDestinationSnapshot.parse(message(["state": "checking"]), generationID: "generation"))
    }

    func testClearedSnapshotCarriesNoDestinationDetails() throws {
        let cleared = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "state": "cleared", "planned_path": NSNull(), "requested_filename": NSNull(),
            "selected_filename": NSNull()
        ]), generationID: "generation"))
        XCTAssertEqual(cleared.state, .cleared)
        XCTAssertEqual(cleared.collapsedTitle, "")
    }

    func testDestinationSnapshotsCoalesceOnlyWhenMeaningIsUnchanged() throws {
        var filter = RuntimeSnapshotFilter()
        let first = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message(), generationID: "generation"))
        let sameMeaning = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message(["revision": 2]), generationID: "generation"))
        let changedPath = try XCTUnwrap(AgentTaskDestinationSnapshot.parse(message([
            "revision": 3, "actual_path": "/Users/test/Downloads/Other/October.pdf", "state": "preparing"
        ]), generationID: "generation"))
        XCTAssertTrue(filter.shouldSchedule(.taskDestination(first)))
        XCTAssertFalse(filter.shouldSchedule(.taskDestination(sameMeaning)))
        XCTAssertTrue(filter.shouldSchedule(.taskDestination(changedPath)))
    }
}
