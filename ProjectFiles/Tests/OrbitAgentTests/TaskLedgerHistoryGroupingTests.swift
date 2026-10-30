import Foundation
import XCTest
@testable import OrbitAgent

final class TaskLedgerHistoryGroupingTests: XCTestCase {
    private final class PreviousWork {
        var sourceSorts = 0
        var groupKeySorts = 0
        var yearComponentReads = 0
        var monthComponentReads = 0
        var dayBoundaryReads = 0
        var groupedEntryAppends = 0
        var fullEntryBucketArraysCreated = 0
        var perDaySorts = 0
        var perDaySortedEntries = 0
        var perDaySortedArraysCreated = 0
    }

    func testOrderedBuilderMatchesPreviousCompleteGroupsForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let origin = calendar.date(from: DateComponents(year: 1995, month: 1, day: 1))!
        let entries = (0..<20_000).map { index in
            let day = calendar.date(byAdding: .day, value: index % 9_000, to: origin)!
            let timestamp = calendar.date(byAdding: .second, value: (index * 37) % 86_400, to: day)!
            return entry("entry-\(index)", finishedAt: timestamp)
        }

        let previousWork = PreviousWork()
        let expected = previousGrouping(entries, calendar: calendar, work: previousWork)
        let measured = AgentTaskHistoryGrouping.measuredYears(from: entries, calendar: calendar)

        XCTAssertEqual(measured.groups, expected)
        XCTAssertEqual(measured.work.sourceEntriesSorted, entries.count)
        XCTAssertEqual(measured.work.sourceSorts, 1)
        XCTAssertEqual(measured.work.dateComponentReads, entries.count)
        XCTAssertEqual(measured.work.dayBoundaryReads, entries.count)
        XCTAssertEqual(measured.work.groupedEntryAppends, entries.count)
        XCTAssertEqual(measured.work.perDaySorts, 0)
        XCTAssertEqual(measured.work.perDaySortedEntries, 0)

        // The prior code inserted each record into year, month and day bucket
        // arrays, then allocated and filled a sorted array for every day.
        let distinctDays = Set(expected.flatMap { $0.months.flatMap { $0.days.map(\.dayStart) } }).count
        XCTAssertGreaterThan(distinctDays, 8_000)
        XCTAssertEqual(measured.work.dayEntryBucketArraysCreated, distinctDays)
        let previousCalendarReads = previousWork.yearComponentReads + previousWork.monthComponentReads + previousWork.dayBoundaryReads
        let currentCalendarReads = measured.work.dateComponentReads + measured.work.dayBoundaryReads
        XCTAssertEqual(previousWork.yearComponentReads, entries.count)
        XCTAssertEqual(previousWork.monthComponentReads, entries.count)
        XCTAssertEqual(previousWork.dayBoundaryReads, entries.count)
        XCTAssertEqual(previousCalendarReads, entries.count * 3)
        XCTAssertEqual(currentCalendarReads, entries.count * 2)
        XCTAssertLessThan(currentCalendarReads, previousCalendarReads)
        XCTAssertEqual(previousWork.fullEntryBucketArraysCreated,
                       distinctDays + expected.reduce(0) { $0 + $1.months.count } + expected.count,
                       "The reference counts one full-record bucket array per year, month, and day.")
        XCTAssertEqual(previousWork.perDaySorts, distinctDays)
        XCTAssertEqual(previousWork.perDaySortedArraysCreated, distinctDays)
        XCTAssertGreaterThan(previousWork.perDaySortedArraysCreated, 8_000)
        XCTAssertEqual(previousWork.perDaySortedEntries, entries.count)
        XCTAssertEqual(previousWork.groupedEntryAppends, entries.count * 3,
                       "Previous grouping performed three full-record bucket passes.")
        let monthGroups = expected.reduce(0) { $0 + $1.months.count }
        XCTAssertEqual(previousWork.sourceSorts, 1)
        XCTAssertEqual(previousWork.groupKeySorts, 1 + expected.count + monthGroups)
        XCTAssertEqual(previousWork.sourceSorts + previousWork.groupKeySorts + previousWork.perDaySorts,
                       2 + expected.count + monthGroups + distinctDays)
        XCTAssertEqual(distinctDays, expected.reduce(0) { $0 + $1.months.reduce(0) { $0 + $1.days.count } })
    }

    func testDSTBoundariesAndNonGregorianYearResetsMatchCalendarGrouping() {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "America/New_York")!
        let daylightSavingEntries = [
            entry("spring-before", finishedAt: date(2025, 3, 9, 1, 59, calendar: gregorian)),
            entry("spring-after", finishedAt: date(2025, 3, 9, 3, 1, calendar: gregorian)),
            entry("autumn-before", finishedAt: date(2025, 11, 2, 1, 15, calendar: gregorian)),
            entry("autumn-after", finishedAt: date(2025, 11, 2, 2, 15, calendar: gregorian))
        ]
        XCTAssertEqual(AgentTaskHistoryGrouping.years(from: daylightSavingEntries, calendar: gregorian),
                       previousGrouping(daylightSavingEntries, calendar: gregorian))
        let springDay = gregorian.startOfDay(for: daylightSavingEntries[0].finishedAt)
        XCTAssertEqual(AgentTaskHistoryGrouping.years(from: daylightSavingEntries, calendar: gregorian)
            .flatMap { $0.months }.flatMap { $0.days }.filter { $0.dayStart == springDay }.first?.entries.count, 2)

        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(secondsFromGMT: 0)!
        let eraEntries = [
            entry("heisei", finishedAt: date(2019, 4, 30, 12, 0, calendar: gregorian)),
            entry("reiwa", finishedAt: date(2019, 5, 1, 12, 0, calendar: gregorian)),
            entry("later", finishedAt: date(2020, 1, 1, 12, 0, calendar: gregorian))
        ]
        let actual = AgentTaskHistoryGrouping.years(from: eraEntries, calendar: japanese)
        XCTAssertEqual(actual, previousGrouping(eraEntries, calendar: japanese))
        XCTAssertEqual(actual.map(\.year), actual.map(\.year).sorted(by: >))
    }

    func testEqualTimestampsKeepInputOrderAndRepeatedEntriesStayGrouped() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = date(2026, 7, 24, 18, 30, calendar: calendar)
        let sameTime = [entry("first", finishedAt: timestamp), entry("second", finishedAt: timestamp),
                        entry("third", finishedAt: timestamp)]
        let grouped = AgentTaskHistoryGrouping.years(from: sameTime, calendar: calendar)
        XCTAssertEqual(grouped.first?.months.first?.days.first?.entries.map(\.request), ["first", "second", "third"])

        let repeatedAcrossDays = [sameTime[0], entry("earlier-day", finishedAt: timestamp.addingTimeInterval(-86_400)), sameTime[1]]
        let repeatedGrouped = AgentTaskHistoryGrouping.years(from: repeatedAcrossDays, calendar: calendar)
        let sameDayEntries = repeatedGrouped.flatMap(\.months).flatMap(\.days)
            .first { $0.dayStart == calendar.startOfDay(for: timestamp) }?.entries.map(\.request)
        XCTAssertEqual(sameDayEntries, ["first", "second"])
    }

    private func previousGrouping(_ entries: [AgentTaskHistoryEntry], calendar: Calendar,
                                  work: PreviousWork? = nil) -> [AgentTaskHistoryYearGroup] {
        if !entries.isEmpty { work?.sourceSorts += 1 }
        let sorted = entries.sorted { $0.finishedAt > $1.finishedAt }
        let yearBuckets = Dictionary(grouping: sorted) {
            work?.yearComponentReads += 1
            work?.groupedEntryAppends += 1
            return calendar.component(.year, from: $0.finishedAt)
        }
        work?.fullEntryBucketArraysCreated += yearBuckets.count
        if !yearBuckets.isEmpty { work?.groupKeySorts += 1 }
        return yearBuckets.keys.sorted(by: >).map { year in
            let monthBuckets = Dictionary(grouping: yearBuckets[year] ?? []) {
                work?.monthComponentReads += 1
                work?.groupedEntryAppends += 1
                return calendar.component(.month, from: $0.finishedAt)
            }
            work?.fullEntryBucketArraysCreated += monthBuckets.count
            if !monthBuckets.isEmpty { work?.groupKeySorts += 1 }
            let months = monthBuckets.keys.sorted(by: >).map { month in
                let dayBuckets = Dictionary(grouping: monthBuckets[month] ?? []) {
                    work?.dayBoundaryReads += 1
                    work?.groupedEntryAppends += 1
                    return calendar.startOfDay(for: $0.finishedAt)
                }
                work?.fullEntryBucketArraysCreated += dayBuckets.count
                if !dayBuckets.isEmpty { work?.groupKeySorts += 1 }
                let days = dayBuckets.keys.sorted(by: >).map { dayStart in
                    let dayEntries = dayBuckets[dayStart] ?? []
                    work?.perDaySorts += 1
                    work?.perDaySortedArraysCreated += 1
                    work?.perDaySortedEntries += dayEntries.count
                    return AgentTaskHistoryDayGroup(dayStart: dayStart, entries: dayEntries.sorted {
                        $0.finishedAt > $1.finishedAt
                    })
                }
                return AgentTaskHistoryMonthGroup(year: year, month: month, days: days)
            }
            return AgentTaskHistoryYearGroup(year: year, months: months)
        }
    }

    private func entry(_ request: String, finishedAt: Date) -> AgentTaskHistoryEntry {
        AgentTaskHistoryEntry(request: request, responseTitle: "Result", response: "Saved",
            outcome: .completed, startedAt: finishedAt.addingTimeInterval(-30), finishedAt: finishedAt, wasQueued: false)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
