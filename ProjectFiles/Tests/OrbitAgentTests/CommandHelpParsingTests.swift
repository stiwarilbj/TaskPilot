import Foundation
import XCTest
@testable import OrbitAgent

final class CommandHelpParsingTests: XCTestCase {
    private struct Options: Equatable {
        var long: Set<String>
        var short: Set<String>
        var values: [String: Int]
    }

    private let helpFixtures = [
        "",
        "-g, --glob <GLOB>  Match pattern\n  --arg name value\n  -h, --help\n",
        "\t-a,\t--alpha=<ONE>\r\n\u{00a0}-b, --beta  <FIRST> <SECOND>\n--tab\t<TAB>\n--new\n<LINE>\n",
        "🧭 Résumé e\u{0301}\n  -é --éclair\n  -9, --unicode <文字>\n  --space\u{2003}<VALUE>\n",
        "Examples: tool --example=literal -x\nquoted '--quoted <VALUE>'\nword--embedded x-y -- --1bad ---triple --under_score\n",
        "-c, --config filename JSON; -n, --name name;\n--output filename text\n--literal NAME\n--pair <A> <B>\n--many <1> <2> <3> <4> <5>\n",
        "--same <ONE>\n-s, --same <FIRST> <SECOND>\n--next <THIRD>\n",
        "-v -q --verbose\r--quiet\r\n--dash-value name value; examples: --other --value\n"
    ]

    private func cached(_ help: String) -> Options {
        Options(long: CommandCapabilities.longOptions(help), short: CommandCapabilities.shortOptions(help),
                values: CommandCapabilities.valueOptions(help))
    }

    /// Frozen pre-cache extraction, including recompilation for short aliases.
    /// Examples remain untrusted help text; this pass does not change parsing.
    private func uncached(_ help: String) throws -> Options {
        func flags(_ pattern: String, in text: String) throws -> Set<String> {
            let expression = try NSRegularExpression(pattern: pattern)
            return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            })
        }
        let long = try flags("(?<![A-Za-z0-9_-])--[A-Za-z][A-Za-z0-9-]*", in: help)
        let shortPattern = "(?<![A-Za-z0-9_-])-[A-Za-z0-9](?![A-Za-z0-9_-])"
        let short = try flags(shortPattern, in: help)
        let expression = try NSRegularExpression(pattern: "(--[A-Za-z][A-Za-z0-9-]*)[ =]+((?:<[^>\\r\\n]+>[ ]*)+|(?:name|filename)[ ]+(?:value|JSON|text)|(?:name|filename)(?=[ ;]))")
        var values: [String: Int] = [:]
        for match in expression.matches(in: help, range: NSRange(help.startIndex..., in: help)) {
            guard let flagRange = Range(match.range(at: 1), in: help), let valueRange = Range(match.range(at: 2), in: help) else { continue }
            let placeholders = String(help[valueRange])
            let count = placeholders.contains("<") ? placeholders.filter { $0 == "<" }.count : placeholders.split(separator: " ").count
            values[String(help[flagRange])] = min(4, count)
            let start = help.range(of: "\n", options: .backwards, range: help.startIndex..<flagRange.lowerBound)?.upperBound ?? help.startIndex
            for alias in try flags(shortPattern, in: String(help[start..<flagRange.lowerBound])) { values[alias] = min(4, count) }
        }
        return Options(long: long, short: short, values: values)
    }

    func testCachedPatternsMatchPreviousFlagsAndValueCounts() throws {
        for (index, help) in helpFixtures.enumerated() {
            XCTAssertEqual(cached(help), try uncached(help), "Fixture \(index)")
        }
        let values = CommandCapabilities.valueOptions("-g, --glob <GLOB>\n--arg name JSON\n--many <A> <B> <C> <D> <E>")
        XCTAssertEqual(values, ["--glob": 1, "-g": 1, "--arg": 2, "--many": 4])
    }

    func testEachHelpTextProducesFreshOptionSetsAndValueCounts() throws {
        var edited = cached("-s, --same <ONE>")
        edited.long.insert("--injected"); edited.short.removeAll(); edited.values["--same"] = 4
        let helps = ["-s, --same <ONE>", "-p, --same <FIRST> <SECOND>", "--other", ""]
        for _ in 0..<10 {
            for help in helps { XCTAssertEqual(cached(help), try uncached(help)) }
        }
        XCTAssertFalse(cached(helps[0]).long.contains("--injected"))
        XCTAssertEqual(edited.values["--same"], 4)
    }

    func testConcurrentHelpInspectionsKeepResultsIndependent() throws {
        let expected = try helpFixtures.map(uncached)
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            let fixture = index % helpFixtures.count
            XCTAssertEqual(cached(helpFixtures[fixture]), expected[fixture])
        }
    }
}
