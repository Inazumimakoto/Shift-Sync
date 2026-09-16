import AlarmKit
import Combine
import CryptoKit
import Foundation
import OSLog

/// AlarmKit ownership stays in the containing app, including App Intent executions.
@MainActor
final class AlarmCoordinator: ObservableObject {
    private static let appBundleID = "com.inazumimakoto.ShiftSync"
    static let shared = AlarmCoordinator(
        client: AlarmKitRetirementAlarmClient(),
        store: RetirementAlarmStore(),
        accountIdentifier: { (try? KeychainService.shared.getShiftWebCredentials())?.id },
        isAppProcess: Bundle.main.bundleIdentifier == appBundleID,
        observeSystem: true
    )

    @Published private(set) var isEnabled = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var isBusy = false
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var nextAlarmDate: Date?
    @Published private(set) var scheduledCount = 0
    @Published private(set) var pendingCount = 0

    private let client: any RetirementAlarmClient
    private let store: RetirementAlarmStore
    private let accountIdentifier: () -> String?
    private let isAppProcess: Bool
    private let authorizationTimeout: Duration
    private var state: RetirementAlarmState
    private var operationTail: Task<Void, Never>?
    private var alarmObservation: Task<Void, Never>?
    private var authorizationObservation: Task<Void, Never>?
    private var observationReconcileTask: Task<Void, Never>?
    private var observationNeedsReconcile = false
    private var lastObservedAlarms: [Alarm]?
    private var lastObservedAuthorization: AlarmManager.AuthorizationState?
    private var preferenceRevision = 0
    private var pendingAuthorization: PendingAuthorization?
    private static let logger = Logger(subsystem: appBundleID, category: "RetirementAlarm")

    private enum AuthorizationOutcome {
        case authorized, denied, failed, timedOut, superseded
    }

    private final class PendingAuthorization {
        var outcome: AuthorizationOutcome?
        var waiters: [CheckedContinuation<AuthorizationOutcome, Never>] = []
        var requestTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    init(
        client: any RetirementAlarmClient,
        store: RetirementAlarmStore,
        accountIdentifier: @escaping () -> String?,
        isAppProcess: Bool,
        observeSystem: Bool = false,
        authorizationTimeout: Duration = .seconds(30)
    ) {
        self.client = client
        self.store = store
        self.accountIdentifier = accountIdentifier
        self.isAppProcess = isAppProcess
        self.authorizationTimeout = authorizationTimeout
        state = store.load()
        isAuthorized = client.authorizationState == .authorized
        isEnabled = activeAccount?.isEnabled ?? false
        guard isAppProcess, observeSystem else { return }

        let manager = AlarmManager.shared
        alarmObservation = Task { [weak self, manager] in
            for await alarms in manager.alarmUpdates {
                guard let self else { return }
                self.alarmInventoryDidChange(alarms)
            }
        }
        authorizationObservation = Task { [weak self, manager] in
            for await authorization in manager.authorizationUpdates {
                guard let self else { return }
                self.authorizationDidChange(authorization)
            }
        }
    }

    static func isEligible(_ shift: Shift) -> Bool {
        RetirementAlarmPolicy.isEligible(snapshot(shift))
    }

    func isEnabled(for shift: Shift) -> Bool {
        isEnabled && isIndividuallyEnabled(for: shift)
    }

    /// Preserve the displayed per-day choice while the global switch is off.
    func isIndividuallyEnabled(for shift: Shift) -> Bool {
        guard Self.isEligible(shift), shift.end > Date() else { return false }
        let records = activeAccount?.records ?? []
        let record = RetirementAlarmPolicy.recordIndex(uid: shift.uid, in: records).map { records[$0] }
        return record?.overrideEnabled != false && record?.isConsumed != true
    }

    func setEnabled(_ enabled: Bool) async {
        guard isAppProcess else { return }
        preferenceRevision += 1
        let revision = preferenceRevision
        if enabled {
            guard accountIdentifier() != nil else {
                statusMessage = "ShiftWebにログインするとアラームを設定できます。"
                return
            }
            // Permission UI must not hold the queue used by inventory updates.
            let outcome = await authorizationForUserAction()
            guard revision == preferenceRevision else { return }
            guard case .authorized = outcome else {
                showAuthorizationOutcome(outcome)
                return
            }
        } else if let pendingAuthorization {
            finishAuthorizationWait(pendingAuthorization, outcome: .superseded)
        }
        await serialized { [self] in
            guard revision == preferenceRevision else { return }
            if enabled {
                guard activateAccount(shifts: nil, explicitEnable: true) else { return }
                isAuthorized = client.authorizationState == .authorized
                guard isAuthorized else {
                    updateActiveAccount { $0.isEnabled = false }
                    persist()
                    isEnabled = false
                    statusMessage = "アラームが許可されていません。iPhoneの設定から許可してください。"
                    return
                }
            }
            updateActiveAccount { $0.isEnabled = enabled }
            if !enabled, let id = state.debugAlarmID {
                do {
                    try client.cancel(id: id)
                    state.debugAlarmID = nil
                } catch {
                    // Keep the ID so logout or a later disable can retry cleanup.
                }
            }
            persist()
            await reconcileCurrentState()
        }
    }

    func setEnabled(_ enabled: Bool, for shift: Shift) async {
        await serialized { [self] in
            guard isAppProcess, activateAccount(shifts: nil),
                  Self.isEligible(shift), shift.end > Date() else { return }
            updateActiveAccount { account in
                if let index = RetirementAlarmPolicy.recordIndex(uid: shift.uid, in: account.records) {
                    account.records[index].overrideEnabled = enabled
                    // An explicit user action may re-arm a future alarm; automatic sync never does.
                    if enabled { account.records[index].isConsumed = false }
                } else {
                    var record = RetirementAlarmRecord(shift: Self.snapshot(shift))
                    record.overrideEnabled = enabled
                    account.records.append(record)
                }
            }
            persist()
            await reconcileCurrentState()
        }
    }

    /// Supply shifts only after a successful fetch and merge. With nil, use the
    /// last account-bound snapshot, never another account's shared cache.
    func reconcile(shifts: [Shift]? = nil) async {
        await serialized { [self] in
            guard isAppProcess else { return }
            if state.isSuspendedForLogout && shifts == nil {
                await reconcileCurrentState()
                return
            }
            guard activateAccount(shifts: shifts) else { return }
            await reconcileCurrentState()
        }
    }

    func suspendForLogout() async {
        preferenceRevision += 1
        if let pendingAuthorization {
            finishAuthorizationWait(pendingAuthorization, outcome: .superseded)
        }
        await serialized { [self] in
            guard isAppProcess else { return }
            state.isSuspendedForLogout = true
            for key in Array(state.accounts.keys) {
                state.accounts[key]?.hasCurrentSnapshot = false
            }
            persist()
            await reconcileCurrentState()
        }
    }

    /// Called by both alarm buttons. Persist before attempting system cleanup so
    /// a subsequent background sync cannot resurrect the reservation.
    func markConsumed(alarmID: String) async {
        await serialized { [self] in
            guard isAppProcess, let id = UUID(uuidString: alarmID) else { return }
            for key in Array(state.accounts.keys) {
                if let index = state.accounts[key]?.records.firstIndex(where: { $0.id == id }) {
                    state.accounts[key]?.records[index].isConsumed = true
                    state.accounts[key]?.records[index].scheduledDate = nil
                }
            }
            if state.debugAlarmID == id { state.debugAlarmID = nil }
            persist()
            // AlarmKit may already have stopped the one-shot alarm before this intent runs.
            try? client.stop(id: id)
            await reconcileCurrentState()
        }
    }

#if DEBUG
    func scheduleTestAlarm() async {
        guard isAppProcess else { return }
        let revision = preferenceRevision
        let outcome = await authorizationForUserAction()
        guard revision == preferenceRevision else { return }
        guard case .authorized = outcome else {
            showAuthorizationOutcome(outcome)
            return
        }
        await serialized { [self] in
            guard revision == preferenceRevision else { return }
            isAuthorized = client.authorizationState == .authorized
            guard isAuthorized else {
                statusMessage = "テストするにはアラームの許可が必要です。"
                return
            }
            if let previous = state.debugAlarmID {
                do {
                    if try client.reservations().contains(where: { $0.id == previous }) {
                        try client.cancel(id: previous)
                    }
                } catch {
                    statusMessage = "前のテスト用アラームを取り消せませんでした。もう一度お試しください。"
                    return
                }
            }
            let id = UUID()
            state.debugAlarmID = id
            persist()
            do {
                try await client.schedule(
                    id: id,
                    date: Date().addingTimeInterval(10),
                    isTest: true
                )
                statusMessage = "10秒後にテスト用アラームが鳴ります。"
            } catch {
                state.debugAlarmID = nil
                persist()
                statusMessage = "テスト用アラームを予約できませんでした。"
            }
        }
    }
#endif

    /// Drain the system sequence promptly. In particular, don't await the same
    /// mutation queue whose caller is waiting for the system permission response.
    func authorizationDidChange(_ authorization: AlarmManager.AuthorizationState) {
        Self.logger.info("Authorization event: \(String(describing: authorization), privacy: .public)")
        isAuthorized = authorization == .authorized
        if let pendingAuthorization {
            switch authorization {
            case .authorized: finishAuthorizationWait(pendingAuthorization, outcome: .authorized)
            case .denied: finishAuthorizationWait(pendingAuthorization, outcome: .denied)
            case .notDetermined: break
            @unknown default: break
            }
        }
        guard authorization != lastObservedAuthorization else { return }
        lastObservedAuthorization = authorization
        enqueueObservationReconcile()
    }

    private func alarmInventoryDidChange(_ alarms: [Alarm]) {
        // Ignore repeated snapshots, including those caused by our own reads.
        let prior = lastObservedAlarms.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
        let current = Dictionary(uniqueKeysWithValues: alarms.map { ($0.id, $0) })
        let unchanged = prior?.count == current.count && current.allSatisfy { id, alarm in
            guard let old = prior?[id] else { return false }
            return old.schedule == alarm.schedule && old.state == alarm.state
                && old.countdownDuration == alarm.countdownDuration
        }
        guard !unchanged else { return }
        lastObservedAlarms = alarms
        Self.logger.info("Inventory event: \(alarms.count, privacy: .public) alarms")
        enqueueObservationReconcile()
    }

    private func enqueueObservationReconcile() {
        observationNeedsReconcile = true
        guard observationReconcileTask == nil else { return }
        observationReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.observationReconcileTask = nil }
            repeat {
                self.observationNeedsReconcile = false
                await self.reconcile()
            } while self.observationNeedsReconcile
        }
    }

    private func authorizationForUserAction() async -> AuthorizationOutcome {
        switch client.authorizationState {
        case .authorized:
            isAuthorized = true
            return .authorized
        case .denied:
            isAuthorized = false
            return .denied
        case .notDetermined:
            break
        @unknown default:
            return .failed
        }
        let pending: PendingAuthorization
        if let existing = pendingAuthorization {
            if let outcome = existing.outcome { return outcome }
            pending = existing
        } else {
            pending = PendingAuthorization()
            pendingAuthorization = pending
            isRequestingAuthorization = true
            statusMessage = "iPhoneの確認画面でアラームの利用を許可してください。"
            Self.logger.info("Permission request begin")
            pending.requestTask = Task { @MainActor [weak self, weak pending] in
                guard let self, let pending else { return }
                let outcome: AuthorizationOutcome
                do {
                    try await self.client.requestAuthorization()
                    outcome = self.client.authorizationState == .authorized ? .authorized : .denied
                    Self.logger.info("Permission request returned")
                } catch {
                    outcome = .failed
                    Self.logger.error("Permission request failed: \(error.localizedDescription, privacy: .private)")
                }
                self.finishAuthorizationWait(pending, outcome: outcome)
                self.isAuthorized = self.client.authorizationState == .authorized
                if self.pendingAuthorization === pending { self.pendingAuthorization = nil }
                // The preference is committed only by the original, revision-checked caller.
            }
            pending.timeoutTask = Task { @MainActor [weak self, weak pending] in
                guard let self, let pending else { return }
                do { try await Task.sleep(for: self.authorizationTimeout) } catch { return }
                Self.logger.error("Permission response timed out")
                self.finishAuthorizationWait(pending, outcome: .timedOut)
                // Keep the underlying request tracked. Cancellation does not guarantee
                // that AlarmKit finishes, and launching another prompt could duplicate it.
            }
        }
        return await withCheckedContinuation { pending.waiters.append($0) }
    }

    private func finishAuthorizationWait(_ pending: PendingAuthorization, outcome: AuthorizationOutcome) {
        guard pendingAuthorization === pending, pending.outcome == nil else { return }
        pending.outcome = outcome
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        isRequestingAuthorization = false
        let waiters = pending.waiters
        pending.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    private func showAuthorizationOutcome(_ outcome: AuthorizationOutcome) {
        switch outcome {
        case .authorized, .superseded:
            break
        case .denied:
            isAuthorized = false
            statusMessage = "アラームが許可されていません。iPhoneの設定から許可してください。"
        case .failed:
            statusMessage = "アラームの許可を確認できませんでした。もう一度お試しください。"
        case .timedOut:
            statusMessage = "iPhoneから許可の応答を確認できませんでした。設定のアラーム許可を確認して、もう一度オンにしてください。"
        }
    }

    private var activeAccount: RetirementAlarmAccount? {
        guard let accountID = state.activeAccountID else { return nil }
        return state.accounts[accountID]
    }

    private func activateAccount(shifts: [Shift]?, explicitEnable: Bool = false) -> Bool {
        guard let identifier = accountIdentifier() else {
            isAuthorized = client.authorizationState == .authorized
            statusMessage = "ShiftWebにログインするとアラームを設定できます。"
            return false
        }
        let accountID = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let isFirstMigration = state.accounts.isEmpty && !state.isSuspendedForLogout
        let didChangeAccount = state.activeAccountID != nil && state.activeAccountID != accountID
        if state.accounts[accountID] == nil {
            state.accounts[accountID] = RetirementAlarmAccount()
        }
        state.activeAccountID = accountID
        if didChangeAccount {
            state.accounts[accountID]?.hasCurrentSnapshot = false
        }
        if let shifts {
            state.isSuspendedForLogout = false
            updateActiveAccount {
                $0.records = RetirementAlarmPolicy.merging(shifts.map(Self.snapshot), into: $0.records)
                $0.hasCurrentSnapshot = true
            }
        } else if isFirstMigration {
            updateActiveAccount {
                $0.records = RetirementAlarmPolicy.merging(SharedStorage.loadShifts().map(Self.snapshot), into: $0.records)
                $0.hasCurrentSnapshot = true
            }
        } else if explicitEnable {
            // Re-enabling after logout needs a fresh sync before any cached shifts can alert.
            state.isSuspendedForLogout = false
        }
        persist()
        return true
    }

    private func reconcileCurrentState() async {
        isEnabled = activeAccount?.isEnabled ?? false
        isAuthorized = client.authorizationState == .authorized
        statusMessage = nil
        let registered: [RetirementAlarmReservation]
        do {
            registered = try client.reservations()
        } catch {
            // Do not assume an unreadable inventory is empty or cancel existing alarms.
            statusMessage = "予約済みアラームを確認できませんでした。既存の予約は変更していません。"
            return
        }
        var registeredByID = Dictionary(uniqueKeysWithValues: registered.map { ($0.id, $0) })
        if isAuthorized {
            for key in Array(state.accounts.keys) {
                if let records = state.accounts[key]?.records {
                    state.accounts[key]?.records = RetirementAlarmPolicy.observing(
                        registeredIDs: Set(registeredByID.keys), records: records
                    )
                }
            }
        } else {
            // Revoking permission can remove system reservations. That is not a
            // Stop action; future shifts may be reserved again after permission returns.
            for key in Array(state.accounts.keys) {
                guard let records = state.accounts[key]?.records else { continue }
                for index in records.indices where registeredByID[records[index].id] == nil {
                    state.accounts[key]?.records[index].scheduledDate = nil
                }
            }
        }

        let desired = (!state.isSuspendedForLogout && isAuthorized)
            ? activeAccount.map { RetirementAlarmPolicy.desiredRecords(in: $0, now: Date()) } ?? []
            : []
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        var failures = 0
        var cancellationFailures = 0
        var hitLimit = false
        let managedIDs = Set(state.accounts.values.flatMap { $0.records.map(\.id) })
        for id in managedIDs {
            guard let alarm = registeredByID[id] else { continue }
            let desiredRecord = desiredByID[id]
            let sameDate = desiredRecord.map { alarm.date == $0.shift.end } ?? false
            // AlarmKit may still report .scheduled while a due alarm begins firing.
            // Preserve that unchanged reservation so a sync at 19:45 cannot silence it.
            if shouldPreserveDueAlarm(alarm) { continue }
            guard !sameDate else {
                updateScheduledDate(id: id, date: desiredRecord?.shift.end)
                continue
            }
            do {
                try client.cancel(id: id)
                registeredByID.removeValue(forKey: id)
                updateScheduledDate(id: id, date: nil)
            } catch {
                failures += 1
                cancellationFailures += 1
            }
        }

        if state.isSuspendedForLogout {
            if let id = state.debugAlarmID, registeredByID[id] != nil {
                do {
                    try client.cancel(id: id)
                    registeredByID.removeValue(forKey: id)
                    state.debugAlarmID = nil
                } catch {
                    failures += 1
                    cancellationFailures += 1
                }
            }
        }
        // Save cancellation state before scheduling or any await can yield.
        persist()

        for candidate in desired {
            guard candidate.shift.end > Date(), registeredByID[candidate.id] == nil else { continue }
            do {
                try await client.schedule(
                    id: candidate.id,
                    date: candidate.shift.end,
                    isTest: false
                )
                registeredByID[candidate.id] = RetirementAlarmReservation(
                    id: candidate.id, date: candidate.shift.end, isAlerting: false
                )
                updateScheduledDate(id: candidate.id, date: candidate.shift.end)
                persist()
            } catch AlarmManager.AlarmError.maximumLimitReached {
                hitLimit = true
                break
            } catch {
                failures += 1
            }
        }

        let confirmed = desired.filter {
            guard let alarm = registeredByID[$0.id] else { return false }
            return alarm.date == $0.shift.end
        }
        scheduledCount = confirmed.count
        pendingCount = desired.count - confirmed.count
        nextAlarmDate = confirmed.map(\.shift.end).min()
        if cancellationFailures > 0 {
            statusMessage = "\(cancellationFailures)件のアラームを取り消せず、予約が残っています。もう一度お試しください。"
        } else if failures > 0 || hitLimit {
            statusMessage = hitLimit
                ? "アラームの予約上限に達しました。近い日程から予約し、\(pendingCount)件が未予約です。"
                : "一部のアラームを更新できませんでした。未予約\(pendingCount)件。設定を確認して再試行してください。"
        } else if state.isSuspendedForLogout {
            statusMessage = "ログアウト中はアラームを停止しています。"
        } else if isEnabled && !isAuthorized {
            statusMessage = "アラームが許可されていません。iPhoneの設定から許可してください。"
        } else if isEnabled && activeAccount?.hasCurrentSnapshot != true {
            statusMessage = "シフトを同期すると、対象日のアラームを予約します。"
        }
        persist()
    }

    private func shouldPreserveDueAlarm(_ alarm: RetirementAlarmReservation) -> Bool {
        guard !state.isSuspendedForLogout, isEnabled, isAuthorized,
              activeAccount?.hasCurrentSnapshot == true,
              let record = activeAccount?.records.first(where: { $0.id == alarm.id }),
              alarm.date == record.shift.end,
              alarm.isAlerting || record.shift.end <= Date() else { return false }
        return record.isPresent && record.overrideEnabled != false && !record.isConsumed
            && RetirementAlarmPolicy.isEligible(record.shift)
    }

    private func updateScheduledDate(id: UUID, date: Date?) {
        for key in Array(state.accounts.keys) {
            if let index = state.accounts[key]?.records.firstIndex(where: { $0.id == id }) {
                state.accounts[key]?.records[index].scheduledDate = date
            }
        }
    }

    private func updateActiveAccount(_ update: (inout RetirementAlarmAccount) -> Void) {
        guard let id = state.activeAccountID, var account = state.accounts[id] else { return }
        update(&account)
        state.accounts[id] = account
    }

    private func persist() {
        store.save(state)
    }

    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let predecessor = operationTail
        let task = Task { @MainActor [self] in
            await predecessor?.value
            Self.logger.info("Alarm update begin")
            isBusy = true
            defer {
                isBusy = false
                Self.logger.info("Alarm update finished")
            }
            await operation()
        }
        operationTail = task
        await task.value
    }

    private static func snapshot(_ shift: Shift) -> RetirementAlarmShift {
        RetirementAlarmShift(uid: shift.uid, start: shift.start, end: shift.end, location: shift.location)
    }
}
