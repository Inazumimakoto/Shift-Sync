import AlarmKit
import Foundation
import XCTest
@testable import ShiftSync

final class AlarmCoordinatorTests: XCTestCase {
    @MainActor
    private final class FakeAlarmClient: RetirementAlarmClient {
        enum Failure: Error { case simulated }
        var authorizationState: AlarmManager.AuthorizationState = .authorized
        var registered: [UUID: RetirementAlarmReservation] = [:]
        var scheduleCalls = 0
        var failNextSchedule = false
        var failCancellation = false
        var failInventory = false
        var maximumReservations: Int?
        var authorizationRequestCount = 0
        var holdsAuthorizationRequest = false
        private var authorizationContinuation: CheckedContinuation<Void, Never>?

        func requestAuthorization() async throws {
            authorizationRequestCount += 1
            if holdsAuthorizationRequest {
                await withCheckedContinuation { authorizationContinuation = $0 }
            } else {
                authorizationState = .authorized
            }
        }
        func completeAuthorization(_ state: AlarmManager.AuthorizationState) {
            authorizationState = state
            authorizationContinuation?.resume()
            authorizationContinuation = nil
        }
        func reservations() throws -> [RetirementAlarmReservation] {
            if failInventory { throw Failure.simulated }
            return Array(registered.values)
        }
        func schedule(id: UUID, date: Date, isTest: Bool) async throws {
            scheduleCalls += 1
            await Task.yield()
            if let maximumReservations, registered.count >= maximumReservations {
                throw AlarmManager.AlarmError.maximumLimitReached
            }
            if failNextSchedule {
                failNextSchedule = false
                throw Failure.simulated
            }
            registered[id] = RetirementAlarmReservation(id: id, date: date, isAlerting: false)
        }
        func cancel(id: UUID) throws {
            if failCancellation { throw Failure.simulated }
            registered.removeValue(forKey: id)
        }
        func stop(id: UUID) throws { registered.removeValue(forKey: id) }
    }

    @MainActor
    private func fixture(
        accountIdentifier: @escaping () -> String? = { "test-account" },
        authorizationTimeout: Duration = .seconds(30)
    ) -> (AlarmCoordinator, FakeAlarmClient, RetirementAlarmStore) {
        let defaults = UserDefaults(suiteName: "AlarmCoordinatorTests.\(UUID().uuidString)")!
        let store = RetirementAlarmStore(defaults: defaults)
        let client = FakeAlarmClient()
        let coordinator = AlarmCoordinator(
            client: client,
            store: store,
            accountIdentifier: accountIdentifier,
            isAppProcess: true,
            authorizationTimeout: authorizationTimeout
        )
        return (coordinator, client, store)
    }

    @MainActor
    private func shift(day: Int = 20, uid: String = "test-shift") -> Shift {
        let calendar = RetirementAlarmPolicy.calendar
        let start = calendar.date(from: DateComponents(year: 2099, month: 9, day: day, hour: 9))!
        let end = calendar.date(from: DateComponents(year: 2099, month: 9, day: day, hour: 19, minute: 45))!
        return Shift(uid: uid, title: "テスト", start: start, end: end, location: "テスト店舗", memo: "")
    }

    @MainActor
    func testScheduleFailureRetriesWithoutDuplicatingSuccessfulReservation() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift(), shift(day: 21, uid: "second")])
        client.failNextSchedule = true
        await coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.scheduledCount, 1)
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertNotNil(coordinator.statusMessage)

        await coordinator.reconcile()
        XCTAssertEqual(coordinator.scheduledCount, 2)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(client.registered.count, 2)
        XCTAssertEqual(client.scheduleCalls, 3)
    }

    @MainActor
    func testCancellationFailureRetainsReservationForRetry() async {
        let (coordinator, client, store) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        await coordinator.setEnabled(true)
        client.failCancellation = true
        await coordinator.setEnabled(false)
        XCTAssertEqual(client.registered.count, 1)
        XCTAssertNotNil(store.load().accounts.values.first?.records.first?.scheduledDate)
        XCTAssertTrue(coordinator.statusMessage?.contains("予約が残っています") == true)

        client.failCancellation = false
        await coordinator.reconcile()
        XCTAssertTrue(client.registered.isEmpty)
        XCTAssertNil(store.load().accounts.values.first?.records.first?.scheduledDate)
        XCTAssertEqual(store.load().accounts.values.first?.records.first?.isConsumed, false)
    }

    @MainActor
    func testStoppedAlarmStaysConsumedAfterCoordinatorReload() async {
        let (coordinator, client, store) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        await coordinator.setEnabled(true)
        client.registered.removeAll()
        await coordinator.reconcile()
        XCTAssertEqual(store.load().accounts.values.first?.records.first?.isConsumed, true)

        let reloaded = AlarmCoordinator(
            client: client, store: store, accountIdentifier: { "test-account" }, isAppProcess: true
        )
        await reloaded.reconcile(shifts: [shift()])
        XCTAssertTrue(client.registered.isEmpty)
        XCTAssertEqual(client.scheduleCalls, 1)
    }

    @MainActor
    func testUnreadableSystemInventoryLeavesAcceptedReservationIntact() async {
        let (coordinator, client, store) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        await coordinator.setEnabled(true)
        let accepted = store.load().accounts.values.first?.records.first?.scheduledDate
        client.failInventory = true
        await coordinator.reconcile(shifts: [])
        XCTAssertEqual(client.registered.count, 1)
        XCTAssertEqual(store.load().accounts.values.first?.records.first?.scheduledDate, accepted)

        client.failInventory = false
        await coordinator.reconcile()
        XCTAssertTrue(client.registered.isEmpty)
    }

    @MainActor
    func testGlobalTogglePreservesPerShiftOverride() async {
        let (coordinator, client, _) = fixture()
        let target = shift()
        let defaultEnabled = shift(day: 21, uid: "default-enabled")
        await coordinator.reconcile(shifts: [target, defaultEnabled])
        await coordinator.setEnabled(true)
        await coordinator.setEnabled(false, for: target)
        await coordinator.setEnabled(false)

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(coordinator.isIndividuallyEnabled(for: target))
        XCTAssertTrue(coordinator.isIndividuallyEnabled(for: defaultEnabled))
        XCTAssertFalse(coordinator.isEnabled(for: target))
        XCTAssertFalse(coordinator.isEnabled(for: defaultEnabled))
        XCTAssertTrue(client.registered.isEmpty)

        // A successful refresh while globally disabled must preserve both the
        // explicit off choice and the other shift's default on choice.
        await coordinator.reconcile(shifts: [target, defaultEnabled])
        XCTAssertFalse(coordinator.isIndividuallyEnabled(for: target))
        XCTAssertTrue(coordinator.isIndividuallyEnabled(for: defaultEnabled))
        XCTAssertFalse(coordinator.isEnabled(for: target))
        XCTAssertFalse(coordinator.isEnabled(for: defaultEnabled))
        XCTAssertTrue(client.registered.isEmpty)

        await coordinator.setEnabled(true)
        XCTAssertFalse(coordinator.isIndividuallyEnabled(for: target))
        XCTAssertTrue(coordinator.isIndividuallyEnabled(for: defaultEnabled))
        XCTAssertFalse(coordinator.isEnabled(for: target))
        XCTAssertTrue(coordinator.isEnabled(for: defaultEnabled))
        XCTAssertEqual(client.registered.count, 1)
        XCTAssertEqual(client.registered.values.first?.date, defaultEnabled.end)
    }

    @MainActor
    func testRevokedPermissionDoesNotTreatFutureReservationsAsStopped() async {
        let (coordinator, client, store) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        await coordinator.setEnabled(true)
        client.authorizationState = .denied
        client.registered.removeAll()
        await coordinator.reconcile()
        XCTAssertFalse(coordinator.isAuthorized)
        XCTAssertEqual(store.load().accounts.values.first?.records.first?.isConsumed, false)

        client.authorizationState = .authorized
        await coordinator.reconcile()
        XCTAssertEqual(client.registered.count, 1)
    }

    @MainActor
    func testAccountSwitchCancelsOldAlarmAndDoesNotEnableNewAccount() async {
        var account = "first-account"
        let (coordinator, client, store) = fixture(accountIdentifier: { account })
        await coordinator.reconcile(shifts: [shift()])
        await coordinator.setEnabled(true)
        XCTAssertEqual(client.registered.count, 1)

        account = "second-account"
        await coordinator.reconcile(shifts: [shift()])
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(client.registered.isEmpty)
        XCTAssertEqual(store.load().accounts.count, 2)
    }

    @MainActor
    func testLogoutDoesNotRearmFromCachedShiftsUntilFreshSnapshot() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        await coordinator.setEnabled(true)
        await coordinator.suspendForLogout()
        await coordinator.reconcile()
        XCTAssertTrue(client.registered.isEmpty)
        await coordinator.setEnabled(true)
        XCTAssertTrue(client.registered.isEmpty)
        await coordinator.reconcile(shifts: [shift()])
        XCTAssertEqual(client.registered.count, 1)
    }

    @MainActor
    func testConcurrentEnablingCreatesOnlyOneSystemReservation() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        async let first: Void = coordinator.setEnabled(true)
        async let second: Void = coordinator.setEnabled(true)
        _ = await (first, second)
        XCTAssertEqual(client.registered.count, 1)
        XCTAssertEqual(client.scheduleCalls, 1)
    }

    @MainActor
    func testSystemLimitKeepsNearestShiftAndReportsRemainingCount() async {
        let (coordinator, client, _) = fixture()
        client.maximumReservations = 1
        let nearest = shift()
        await coordinator.reconcile(shifts: [shift(day: 21, uid: "later"), nearest])
        await coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.nextAlarmDate, nearest.end)
        XCTAssertEqual(coordinator.scheduledCount, 1)
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertTrue(coordinator.statusMessage?.contains("予約上限") == true)
    }

    @MainActor
    func testDueScheduledAlarmIsPreservedButAnUpdatedDateReplacesIt() async {
        let (coordinator, client, store) = fixture()
        let calendar = RetirementAlarmPolicy.calendar
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let end = calendar.date(bySettingHour: 19, minute: 45, second: 0, of: yesterday)!
        let due = Shift(
            uid: "due", title: "テスト", start: end.addingTimeInterval(-8 * 3600),
            end: end, location: "テスト店舗", memo: ""
        )
        await coordinator.reconcile(shifts: [due])
        await coordinator.setEnabled(true)
        var persisted = store.load()
        let accountID = persisted.activeAccountID!
        let alarmID = persisted.accounts[accountID]!.records[0].id
        persisted.accounts[accountID]!.records[0].scheduledDate = end
        store.save(persisted)
        client.registered[alarmID] = RetirementAlarmReservation(id: alarmID, date: end, isAlerting: false)
        let reloaded = AlarmCoordinator(
            client: client, store: store, accountIdentifier: { "test-account" }, isAppProcess: true
        )

        await reloaded.reconcile()
        XCTAssertEqual(client.registered[alarmID]?.date, end)
        XCTAssertEqual(client.scheduleCalls, 0)

        let movedEnd = calendar.date(byAdding: .day, value: 3, to: end)!
        let moved = Shift(
            uid: "due", title: "テスト", start: movedEnd.addingTimeInterval(-8 * 3600),
            end: movedEnd, location: "テスト店舗", memo: ""
        )
        await reloaded.reconcile(shifts: [moved])
        XCTAssertEqual(client.registered[alarmID]?.date, movedEnd)
        XCTAssertEqual(client.scheduleCalls, 1)
    }

    @MainActor
    private func waitForAuthorizationRequest(_ client: FakeAlarmClient) async {
        for _ in 0..<100 {
            if client.authorizationRequestCount > 0 { return }
            await Task.yield()
        }
        XCTFail("The permission request did not start")
    }

    @MainActor
    func testAuthorizationWaitDoesNotBlockReconciliation() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        client.authorizationState = .notDetermined
        client.holdsAuthorizationRequest = true
        let enabling = Task { await coordinator.setEnabled(true) }
        await waitForAuthorizationRequest(client)
        XCTAssertTrue(coordinator.isRequestingAuthorization)
        XCTAssertFalse(coordinator.isBusy)

        await coordinator.reconcile()
        XCTAssertFalse(coordinator.isBusy)
        client.completeAuthorization(.authorized)
        await enabling.value
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(client.registered.count, 1)
    }

    @MainActor
    func testPermissionEventCompletesEnableEvenIfRequestDoesNotReturn() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        client.authorizationState = .notDetermined
        client.holdsAuthorizationRequest = true
        let enabling = Task { await coordinator.setEnabled(true) }
        await waitForAuthorizationRequest(client)

        client.authorizationState = .authorized
        coordinator.authorizationDidChange(.authorized)
        await enabling.value
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertFalse(coordinator.isRequestingAuthorization)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(client.scheduleCalls, 1)
        client.completeAuthorization(.authorized)
    }

    @MainActor
    func testUnresponsivePermissionTimesOutWithoutDuplicateRequestOrLateEnable() async {
        let (coordinator, client, _) = fixture(authorizationTimeout: .milliseconds(20))
        await coordinator.reconcile(shifts: [shift()])
        client.authorizationState = .notDetermined
        client.holdsAuthorizationRequest = true
        await coordinator.setEnabled(true)
        XCTAssertFalse(coordinator.isRequestingAuthorization)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(coordinator.statusMessage?.contains("応答を確認できませんでした") == true)

        await coordinator.setEnabled(true)
        XCTAssertEqual(client.authorizationRequestCount, 1)
        client.authorizationState = .authorized
        coordinator.authorizationDidChange(.authorized)
        client.completeAuthorization(.authorized)
        await coordinator.reconcile()
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(client.registered.isEmpty)
    }

    @MainActor
    func testTurningOffReleasesPendingPermissionAndLateGrantCannotReenable() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        client.authorizationState = .notDetermined
        client.holdsAuthorizationRequest = true
        let enabling = Task { await coordinator.setEnabled(true) }
        await waitForAuthorizationRequest(client)
        await coordinator.setEnabled(false)
        await enabling.value
        XCTAssertFalse(coordinator.isRequestingAuthorization)
        XCTAssertFalse(coordinator.isEnabled)

        // The still-running OS request is retained even after the UI wait was
        // cancelled. Retrying must not put up another permission prompt.
        await coordinator.setEnabled(true)
        XCTAssertEqual(client.authorizationRequestCount, 1)
        XCTAssertFalse(coordinator.isEnabled)

        client.authorizationState = .authorized
        coordinator.authorizationDidChange(.authorized)
        client.completeAuthorization(.authorized)
        await coordinator.reconcile()
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(client.registered.isEmpty)
        await coordinator.setEnabled(true)
        XCTAssertEqual(client.registered.count, 1)
    }

    @MainActor
    func testConcurrentPermissionRequestsShareOneSystemPrompt() async {
        let (coordinator, client, _) = fixture()
        await coordinator.reconcile(shifts: [shift()])
        client.authorizationState = .notDetermined
        client.holdsAuthorizationRequest = true
        let first = Task { await coordinator.setEnabled(true) }
        await waitForAuthorizationRequest(client)
        let second = Task { await coordinator.setEnabled(true) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(client.authorizationRequestCount, 1)
        client.completeAuthorization(.authorized)
        await first.value
        await second.value
        XCTAssertEqual(client.scheduleCalls, 1)
    }
}
