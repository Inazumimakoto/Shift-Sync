import Foundation
import XCTest
@testable import ShiftSync

final class RetirementAlarmPolicyTests: XCTestCase {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func shift(
        _ uid: String = "original",
        start: String = "2026-09-20T09:00:00+09:00",
        end: String = "2026-09-20T19:45:00+09:00",
        location: String = "店舗A"
    ) -> RetirementAlarmShift {
        RetirementAlarmShift(uid: uid, start: date(start), end: date(end), location: location)
    }

    func testOnly1945TokyoEndIsEligible() {
        XCTAssertTrue(RetirementAlarmPolicy.isEligible(shift()))
        XCTAssertFalse(RetirementAlarmPolicy.isEligible(shift(end: "2026-09-20T19:30:00+09:00")))
        XCTAssertTrue(RetirementAlarmPolicy.isEligible(shift(end: "2026-09-20T10:45:00Z")))
        XCTAssertFalse(RetirementAlarmPolicy.isEligible(shift(end: "2026-09-20T19:45:00Z")))
    }

    func testPastConsumedAndDisabledShiftsAreNotScheduled() {
        var account = RetirementAlarmAccount()
        account.isEnabled = true
        account.hasCurrentSnapshot = true
        account.records = [RetirementAlarmRecord(shift: shift())]
        XCTAssertEqual(RetirementAlarmPolicy.desiredRecords(in: account, now: date("2026-09-20T19:44:59+09:00")).count, 1)
        XCTAssertTrue(RetirementAlarmPolicy.desiredRecords(in: account, now: date("2026-09-20T19:45:00+09:00")).isEmpty)
        account.records[0].isConsumed = true
        XCTAssertTrue(RetirementAlarmPolicy.desiredRecords(in: account, now: date("2026-09-19T00:00:00Z")).isEmpty)
        account.records[0].isConsumed = false
        account.records[0].overrideEnabled = false
        XCTAssertTrue(RetirementAlarmPolicy.desiredRecords(in: account, now: date("2026-09-19T00:00:00Z")).isEmpty)
    }

    func testUniqueTimeChangeKeepsOverrideAndAlarmIdentity() {
        var prior = RetirementAlarmRecord(shift: shift())
        prior.overrideEnabled = false
        let changed = shift("changed", start: "2026-09-20T10:00:00+09:00", location: " 店舗A ")
        let result = RetirementAlarmPolicy.merging([changed], into: [prior])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, prior.id)
        XCTAssertEqual(result[0].overrideEnabled, false)
        XCTAssertEqual(result[0].knownUIDs, ["original", "changed"])
    }

    func testExactUIDWinsOverOtherShiftOnSameDay() {
        var exact = RetirementAlarmRecord(shift: shift())
        exact.overrideEnabled = false
        let other = shift("other", start: "2026-09-20T12:00:00+09:00")
        let result = RetirementAlarmPolicy.merging([other, shift()], into: [exact])
        XCTAssertEqual(result.first { $0.shift.uid == "original" }?.overrideEnabled, false)
        XCTAssertNil(result.first { $0.shift.uid == "other" }?.overrideEnabled)
    }

    func testAmbiguousSplitShiftsDoNotInheritOverrides() {
        var first = RetirementAlarmRecord(shift: shift())
        first.overrideEnabled = false
        let second = RetirementAlarmRecord(shift: shift("second", start: "2026-09-20T12:00:00+09:00"))
        let changed = shift("changed", start: "2026-09-20T11:00:00+09:00")
        let result = RetirementAlarmPolicy.merging([changed], into: [first, second])
        XCTAssertEqual(result.filter(\.isPresent).count, 1)
        XCTAssertNil(result.first { $0.isPresent }?.overrideEnabled)
        XCTAssertNotEqual(result.first { $0.isPresent }?.id, first.id)
    }

    func testCurrentUIDWinsWhenAnOldAliasReturnsAsASeparateShift() {
        var prior = RetirementAlarmRecord(shift: shift("current"))
        prior.knownUIDs.insert("old")
        prior.overrideEnabled = false
        let result = RetirementAlarmPolicy.merging([shift("old"), shift("current")], into: [prior])
        XCTAssertEqual(result.first { $0.shift.uid == "current" }?.id, prior.id)
        XCTAssertEqual(result.first { $0.shift.uid == "current" }?.overrideEnabled, false)
        XCTAssertNil(result.first { $0.shift.uid == "old" }?.overrideEnabled)
    }

    func testRemovedAndReappearingUIDPreservesTombstone() {
        var record = RetirementAlarmRecord(shift: shift())
        record.isConsumed = true
        let removed = RetirementAlarmPolicy.merging([], into: [record])
        XCTAssertFalse(removed[0].isPresent)
        let restored = RetirementAlarmPolicy.merging([shift()], into: removed)
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].isConsumed)
    }

    func testMissingReservationBecomesConsumedButOwnCancellationDoesNot() {
        var fired = RetirementAlarmRecord(shift: shift())
        fired.scheduledDate = fired.shift.end
        let cancelled = RetirementAlarmRecord(shift: shift("cancelled"))
        let result = RetirementAlarmPolicy.observing(registeredIDs: [], records: [fired, cancelled])
        XCTAssertTrue(result[0].isConsumed)
        XCTAssertNil(result[0].scheduledDate)
        XCTAssertFalse(result[1].isConsumed)
    }

    func testGlobalOffAndLoggedOutSnapshotDoNotEraseIndividualPreferences() {
        var account = RetirementAlarmAccount()
        var record = RetirementAlarmRecord(shift: shift())
        record.overrideEnabled = false
        account.records = [record]
        account.hasCurrentSnapshot = true
        XCTAssertTrue(RetirementAlarmPolicy.desiredRecords(in: account, now: .distantPast).isEmpty)
        XCTAssertEqual(account.records[0].overrideEnabled, false)
        account.isEnabled = true
        account.hasCurrentSnapshot = false
        account.records[0].overrideEnabled = true
        XCTAssertTrue(RetirementAlarmPolicy.desiredRecords(in: account, now: .distantPast).isEmpty)
    }

    func testDuplicateFetchRowsCreateOnlyOneReservation() {
        let result = RetirementAlarmPolicy.merging([shift(), shift()], into: [])
        XCTAssertEqual(result.count, 1)
    }
}
