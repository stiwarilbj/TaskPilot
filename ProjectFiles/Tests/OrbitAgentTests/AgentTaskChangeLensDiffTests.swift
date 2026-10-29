import Foundation
import XCTest
@testable import OrbitAgent

final class AgentTaskChangeLensDiffTests: XCTestCase {
    private struct Fixtures: Decodable {
        let version: Int
        let cases: [Fixture]
    }

    private struct Fixture: Decodable {
        struct Line: Decodable {
            let number: Int
            let text: String
            let changed: Bool
            var value: AgentTaskChangeLensLine { .init(number: number, text: text, changed: changed) }
        }
        struct Hunk: Decodable {
            let before: [Line]
            let after: [Line]
            let affectedStart: Int
            let affectedEnd: Int
            var value: AgentTaskChangeLensHunk {
                .init(before: before.map(\.value), after: after.map(\.value),
                      affectedBaselineLines: affectedStart..<affectedEnd)
            }
        }
        let name: String
        let before: String?
        let after: String
        let request: String
        let hunks: [Hunk]
        let scope: String
        let outside: [Bool?]
    }

    func testGoldenComparisonsPreserveRepeatedLineTiesOffsetsAndScopeWarnings() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/change-lens-diff-cases.json")
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixtures.version, 1)
        XCTAssertEqual(fixtures.cases.count, 22)
        let assessments: [String: AgentTaskChangeLensScope.Assessment] = [
            "unrestricted": .unrestricted, "checked": .checked,
            "potentialMismatch": .potentialMismatch, "imprecise": .imprecise,
        ]
        for fixture in fixtures.cases {
            let expected = fixture.hunks.map(\.value)
            let result = AgentTaskChangeLensDiff.build(before: fixture.before, after: fixture.after)
            XCTAssertEqual(result, .hunks(expected), fixture.name)
            guard case .hunks(let actual) = result else { continue }
            XCTAssertEqual(AgentTaskChangeLensScope.assess(request: fixture.request,
                before: fixture.before, hunks: actual), assessments[fixture.scope], fixture.name)
            if let before = fixture.before {
                XCTAssertEqual(actual.map { AgentTaskChangeLensScope.hunkIsOutside(
                    request: fixture.request, before: before, hunk: $0) }, fixture.outside, fixture.name)
            }
        }
    }

    func testUnchangedNormalizedTextKeepsExistingLineLimit() {
        let text = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(AgentTaskChangeLensDiff.build(before: text, after: text), .hunks([]))
        XCTAssertEqual(AgentTaskChangeLensDiff.build(before: text.replacingOccurrences(of: "\n", with: "\r\n"),
                                                    after: text), .hunks([]))
        XCTAssertEqual(AgentTaskChangeLensDiff.build(before: text + "\n", after: text + "\n"),
                       .unavailable("This text has too many lines for a bounded comparison."))
    }

    func testLocalizedEditPreservesFullDocumentContextAndOriginalNumbers() {
        let lines = (0..<1_000).map { "line \($0)" }
        var changed = lines
        changed[500] = "updated 500"
        guard case .hunks(let hunks) = AgentTaskChangeLensDiff.build(
            before: lines.joined(separator: "\n"), after: changed.joined(separator: "\n")) else {
            return XCTFail("Expected a localized comparison")
        }
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.affectedBaselineLines, 501..<502)
        XCTAssertEqual(hunks.first?.before.map(\.number), Array(498...504))
        XCTAssertEqual(hunks.first?.after.map(\.number), Array(498...504))
        XCTAssertEqual(hunks.first?.before.filter(\.changed).map(\.text), ["line 500"])
        XCTAssertEqual(hunks.first?.after.filter(\.changed).map(\.text), ["updated 500"])
    }

    func testCancelledComparisonsStillCancelOnFastPaths() async {
        for (before, after) in [("same", "same"), ("same\r\n", "same\n"),
                                ("head\nold\ntail", "head\nnew\ntail")] {
            let work = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return AgentTaskChangeLensDiff.build(before: before, after: after)
            }
            let result = await work.value
            XCTAssertEqual(result, .unavailable("Comparison cancelled."))
        }
    }
}
