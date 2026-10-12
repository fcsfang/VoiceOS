import XCTest
import Foundation
@testable import VoiceOSCore

final class ReminderScheduleTests: XCTestCase {
    private let a = ReminderDueDate.dateOnly(localDate: "2026-10-13", timeZone: "Asia/Shanghai")
    private let b = ReminderDueDate.dateOnly(localDate: "2026-10-14", timeZone: "Asia/Shanghai")
    private let c = ReminderDueDate.dateOnly(localDate: "2026-10-15", timeZone: "Asia/Shanghai")
    private func proposal(_ due: ReminderDueDate, _ authority: ScheduleAuthority = .aiFlexible) throws -> ReminderScheduleProposal {
        try .init(due: due, authority: authority, rawExpression: "明天再安排这项普通事务", anchorEventTime: Date(timeIntervalSince1970: 1791820800))
    }
    private func merge(_ base: ReminderDueDate?, _ remote: ReminderDueDate?, _ desired: ReminderScheduleProposal?,
                       authority: ScheduleAuthority = .aiFlexible, allowed: Bool = true,
                       current: Bool = true, unique: Bool = true) throws -> ScheduleMergeDisposition {
        try ReminderScheduleMerge.decide(base: base, baseAuthority: authority, remote: remote, desired: desired,
                                         authorized: allowed, actionCurrent: current, uniqueIdentity: unique).disposition
    }
    func testDateOnlyValidatesLeapYearsAndRoundtripsWithoutUtcConversion() throws {
        for value in [ReminderDueDate.none, a, .dateOnly(localDate: "2024-02-29", timeZone: nil), .dateOnly(localDate: "2026-10-13", timeZone: "Pacific/Kiritimati")] {
            try value.validate()
            XCTAssertEqual(try JSONDecoder().decode(ReminderDueDate.self, from: JSONEncoder().encode(value)), value)
        }
        for value in ["2023-02-29", "2026-13-01", "2026-04-31", "2026-1-02", "0000-01-01", "2026-00-01"] {
            XCTAssertThrowsError(try ReminderDueDate.dateOnly(localDate: value, timeZone: nil).validate())
        }
        XCTAssertThrowsError(try ReminderDueDate.dateOnly(localDate: "2026-10-13", timeZone: "invalid-zone").validate())
    }
    func testInstantRequiresCanonicalUtcAndValidZone() throws {
        try ReminderDueDate.instant(utc: "2026-10-13T02:30:00.000Z", timeZone: "Asia/Shanghai").validate()
        for value in ["2026-10-13T10:30:00.000+08:00", "2026-10-13T02:30:00Z", "not-a-date", "2026-02-30T02:30:00.000Z"] {
            XCTAssertThrowsError(try ReminderDueDate.instant(utc: value, timeZone: "Asia/Shanghai").validate())
        }
    }
    func testComponentReadingDistinguishesNoDeadlineFromUnknownAndAllDay() {
        XCTAssertEqual(ReminderDueDate.reading(nil), .some(.none))
        XCTAssertNil(ReminderDueDate.reading(DateComponents(year: 2026, month: 10)))
        let day = DateComponents(year: 2026, month: 10, day: 13)
        XCTAssertEqual(ReminderDueDate.reading(day), .dateOnly(localDate: "2026-10-13", timeZone: nil))
        XCTAssertNil(ReminderDueDate.reading(DateComponents(year: 2026, month: 2, day: 30)))
        XCTAssertNil(ReminderDueDate.reading(DateComponents(year: Int.max, month: 10, day: 13)))
        var lunar = day; lunar.calendar = Calendar(identifier: .chinese)
        XCTAssertNil(ReminderDueDate.reading(lunar))
    }
    func testTimedReadingRequiresZoneAndRejectsDstGapsAndAmbiguity() {
        var time = DateComponents(year: 2026, month: 10, day: 13, hour: 10, minute: 30)
        XCTAssertNil(ReminderDueDate.reading(time))
        time.timeZone = TimeZone(identifier: "Asia/Shanghai")
        XCTAssertEqual(ReminderDueDate.reading(time), .instant(utc: "2026-10-13T02:30:00.000Z", timeZone: "Asia/Shanghai"))
        var gap = DateComponents(year: 2026, month: 3, day: 8, hour: 2, minute: 30)
        gap.timeZone = TimeZone(identifier: "America/New_York")
        XCTAssertNil(ReminderDueDate.reading(gap))
        var fold = DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30)
        fold.timeZone = TimeZone(identifier: "America/New_York")
        XCTAssertNil(ReminderDueDate.reading(fold))
        time.nanosecond = 100
        XCTAssertNil(ReminderDueDate.reading(time))
    }
    func testThreeWayOrdinaryChangesPreserveExternalEdits() throws {
        XCTAssertEqual(try merge(a, a, proposal(b)), .writeFlexible)
        XCTAssertEqual(try merge(a, b, proposal(a)), .observeRemote)
        XCTAssertEqual(try merge(a, b, proposal(b)), .converged)
        XCTAssertEqual(try merge(a, b, proposal(c)), .replanKeepingRemote)
        XCTAssertEqual(try merge(a, a, proposal(a)), .unchanged)
        XCTAssertEqual(try merge(a, b, nil), .observeRemote)
        XCTAssertEqual(try merge(a, a, nil), .unchanged)
    }
    func testCommitmentManualAndUnknownBasesCannotBeDowngradedToFlexible() throws {
        for authority in [ScheduleAuthority.userCommitment, .externalManual, .unknown] {
            XCTAssertEqual(try merge(a, a, proposal(b), authority: authority), .requiresConfirmation)
            XCTAssertEqual(try merge(a, b, proposal(c), authority: authority), .requiresConfirmation)
        }
        XCTAssertEqual(try merge(a, a, proposal(b, .userCommitment)), .requiresConfirmation)
        XCTAssertEqual(try merge(a, b, proposal(c, .userCommitment)), .requiresConfirmation)
    }
    func testUnknownIdentityScopeAndFrozenActionPreventPlanningAWrite() throws {
        XCTAssertEqual(try merge(a, nil, proposal(b)), .unavailable)
        XCTAssertEqual(try merge(a, a, proposal(b), unique: false), .unavailable)
        XCTAssertEqual(try merge(a, a, proposal(b), allowed: false), .blocked)
        XCTAssertEqual(try merge(a, a, proposal(b), current: false), .blocked)
        XCTAssertEqual(try merge(nil, a, proposal(b)), .captureRemote)
    }
    func testExplicitDeadlineRemovalIsDifferentFromNoProposalOrUnknownRead() throws {
        XCTAssertEqual(try merge(a, a, proposal(.none)), .writeFlexible)
        XCTAssertEqual(try merge(a, a, nil), .unchanged)
        XCTAssertEqual(try merge(a, nil, proposal(.none)), .unavailable)
        XCTAssertEqual(try merge(.some(.none), .some(.none), proposal(b)), .writeFlexible)
    }
    func testLegacySnapshotDecodesAsUnknownNotNoDeadline() throws {
        let json = Data(#"{"id":"fixture","title":"task","completed":false,"marker":"marker"}"#.utf8)
        let old = try JSONDecoder().decode(ReminderSnapshot.self, from: json)
        XCTAssertNil(old.dueDate)
        let known = ReminderSnapshot(id: "fixture", title: "task", completed: false, marker: "marker", dueDate: .some(.none))
        let roundtrip = try JSONDecoder().decode(ReminderSnapshot.self, from: JSONEncoder().encode(known))
        XCTAssertEqual(roundtrip.dueDate, .some(.none))
    }
    func testProposalRejectsMissingEvidenceAndInvalidTime() {
        XCTAssertThrowsError(try ReminderScheduleProposal(due: a, authority: .unknown, rawExpression: "安排一下", anchorEventTime: Date()))
        XCTAssertThrowsError(try ReminderScheduleProposal(due: a, authority: .aiFlexible, rawExpression: " ", anchorEventTime: Date()))
        XCTAssertThrowsError(try ReminderScheduleProposal(due: a, authority: .aiFlexible, rawExpression: "安排一下", anchorEventTime: Date(timeIntervalSince1970: .nan)))
    }
}
