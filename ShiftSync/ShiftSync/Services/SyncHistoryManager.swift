import Foundation

/// 同期履歴を管理するマネージャー
/// 直近20件の履歴をUserDefaultsに保存
class SyncHistoryManager {
    static let shared = SyncHistoryManager()
    
    private let maxEntries = 20
    private let storageKey = "syncHistory"
    private let activeRunsKey = "activeSyncRuns"
    private let lock = NSLock()
    private var activeRunIDs: Set<String> = []
    
    private init() {}
    
    // MARK: - Public API

    func beginRun(source: SyncSource) -> SyncRunLogger {
        let runID = Self.makeRunID()
        lock.lock()
        var activeRuns = loadActiveRuns().filter { Date().timeIntervalSince($0.startedAt) < 15 * 60 }
        activeRunIDs = Set(activeRuns.map(\.runID))
        let concurrentRunIDs = Array(activeRunIDs).sorted()
        activeRunIDs.insert(runID)
        activeRuns.append(ActiveSyncRun(runID: runID, startedAt: Date()))
        saveActiveRuns(activeRuns)
        lock.unlock()

        let logger = SyncRunLogger(
            runID: runID,
            source: source,
            concurrentRunIDs: concurrentRunIDs,
            manager: self
        )
        if concurrentRunIDs.isEmpty {
            logger.addStep(phase: .start, status: .started, message: "同期開始")
        } else {
            logger.addStep(
                phase: .start,
                status: .started,
                message: "同期開始（同時実行: \(concurrentRunIDs.joined(separator: ", "))）"
            )
        }
        return logger
    }
    
    /// 履歴を取得（新しい順）
    func getHistory() -> [SyncLogEntry] {
        let defaults = SharedStorage.sharedDefaults ?? UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([SyncLogEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.date > $1.date }
    }
    
    /// 成功した同期を記録
    func logSuccess(source: SyncSource, result: SyncResult) {
        let entry = SyncLogEntry.success(
            source: source,
            added: result.added,
            updated: result.updated,
            deleted: result.deleted
        )
        addEntry(entry)
    }
    
    /// 失敗した同期を記録
    func logFailure(source: SyncSource, error: Error) {
        let entry = SyncLogEntry.failure(source: source, error: error)
        addEntry(entry)
    }

    func completeRun(_ runID: String, entry: SyncLogEntry) {
        lock.lock()
        activeRunIDs.remove(runID)
        let activeRuns = loadActiveRuns().filter { $0.runID != runID }
        saveActiveRuns(activeRuns)
        lock.unlock()
        addEntry(entry)
    }
    
    // MARK: - Private
    
    private func addEntry(_ entry: SyncLogEntry) {
        var entries = getHistory()
        entries.insert(entry, at: 0)
        
        // 最大件数を超えたら古いエントリを削除
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        
        saveEntries(entries)
    }
    
    private func saveEntries(_ entries: [SyncLogEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            let defaults = SharedStorage.sharedDefaults ?? UserDefaults.standard
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let suffix = UUID().uuidString.prefix(4).uppercased()
        return "\(formatter.string(from: Date()))-\(suffix)"
    }

    private func loadActiveRuns() -> [ActiveSyncRun] {
        let defaults = SharedStorage.sharedDefaults ?? UserDefaults.standard
        guard let data = defaults.data(forKey: activeRunsKey),
              let runs = try? JSONDecoder().decode([ActiveSyncRun].self, from: data) else {
            return []
        }
        return runs
    }

    private func saveActiveRuns(_ runs: [ActiveSyncRun]) {
        let defaults = SharedStorage.sharedDefaults ?? UserDefaults.standard
        if let data = try? JSONEncoder().encode(runs) {
            defaults.set(data, forKey: activeRunsKey)
        }
    }
}

private struct ActiveSyncRun: Codable {
    let runID: String
    let startedAt: Date
}

final class SyncRunLogger {
    let runID: String
    let source: SyncSource
    let startedAt: Date
    let concurrentRunIDs: [String]

    private weak var manager: SyncHistoryManager?
    private let lock = NSLock()
    private var steps: [SyncLogStep] = []
    private var monthLogsByKey: [String: SyncMonthLog] = [:]
    private var failurePhase: SyncPhase?
    private var failureMonth: SyncMonth?
    private var completed = false

    init(
        runID: String,
        source: SyncSource,
        concurrentRunIDs: [String],
        manager: SyncHistoryManager
    ) {
        self.runID = runID
        self.source = source
        self.concurrentRunIDs = concurrentRunIDs
        self.manager = manager
        self.startedAt = Date()
    }

    func addStep(
        phase: SyncPhase,
        status: SyncStepStatus,
        message: String,
        month: SyncMonth? = nil,
        httpStatus: Int? = nil,
        finalURL: String? = nil,
        htmlSize: Int? = nil,
        pageKind: SyncPageKind? = nil,
        hasShiftTable: Bool? = nil,
        headerText: String? = nil,
        shiftCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        let step = SyncLogStep(
            phase: phase,
            status: status,
            message: message,
            month: month,
            httpStatus: httpStatus,
            finalURL: finalURL,
            htmlSize: htmlSize,
            pageKind: pageKind,
            hasShiftTable: hasShiftTable,
            headerText: headerText,
            shiftCount: shiftCount,
            errorMessage: errorMessage
        )
        lock.lock()
        steps.append(step)
        if status == .failure {
            failurePhase = phase
            failureMonth = month
        }
        lock.unlock()
    }

    func recordLoginStart() {
        addStep(phase: .login, status: .started, message: "ログイン開始")
    }

    func recordLoginSuccess(cookie: Bool?) {
        let suffix = cookie.map { " cookie=\($0)" } ?? ""
        addStep(phase: .login, status: .success, message: "ログイン成功\(suffix)")
    }

    func recordLoginFailure(_ error: Error) {
        addStep(
            phase: .login,
            status: .failure,
            message: "ログイン失敗",
            errorMessage: error.localizedDescription
        )
    }

    func recordMonthFetchSuccess(
        year: Int,
        month: Int,
        httpStatus: Int,
        finalURL: String?,
        diagnostics: ShiftPageDiagnostics
    ) {
        let syncMonth = SyncMonth(year: year, month: month)
        updateMonthLog(syncMonth) { log in
            log.httpStatus = httpStatus
            log.finalURL = finalURL
            log.htmlSize = diagnostics.htmlSize
            log.pageKind = diagnostics.pageKind
            log.hasShiftTable = diagnostics.hasShiftTable
            log.headerText = diagnostics.headerText
            log.fetchSucceeded = true
        }
        addStep(
            phase: .fetchMonth,
            status: .success,
            message: "\(syncMonth.label) 取得成功",
            month: syncMonth,
            httpStatus: httpStatus,
            finalURL: finalURL,
            htmlSize: diagnostics.htmlSize,
            pageKind: diagnostics.pageKind,
            hasShiftTable: diagnostics.hasShiftTable,
            headerText: diagnostics.headerText
        )
    }

    func recordMonthFetchFailure(
        year: Int,
        month: Int,
        httpStatus: Int?,
        finalURL: String?,
        diagnostics: ShiftPageDiagnostics?,
        error: Error
    ) {
        let syncMonth = SyncMonth(year: year, month: month)
        updateMonthLog(syncMonth) { log in
            log.httpStatus = httpStatus
            log.finalURL = finalURL
            log.htmlSize = diagnostics?.htmlSize
            log.pageKind = diagnostics?.pageKind
            log.hasShiftTable = diagnostics?.hasShiftTable
            log.headerText = diagnostics?.headerText
            log.fetchSucceeded = false
            log.errorMessage = error.localizedDescription
        }
        addStep(
            phase: .fetchMonth,
            status: .failure,
            message: "\(syncMonth.label) 取得失敗",
            month: syncMonth,
            httpStatus: httpStatus,
            finalURL: finalURL,
            htmlSize: diagnostics?.htmlSize,
            pageKind: diagnostics?.pageKind,
            hasShiftTable: diagnostics?.hasShiftTable,
            headerText: diagnostics?.headerText,
            errorMessage: error.localizedDescription
        )
    }

    func recordMonthParseSuccess(year: Int, month: Int, shiftCount: Int) {
        let syncMonth = SyncMonth(year: year, month: month)
        updateMonthLog(syncMonth) { log in
            log.parseSucceeded = true
            log.shiftCount = shiftCount
        }
        addStep(
            phase: .parseMonth,
            status: .success,
            message: "\(syncMonth.label) 解析成功 / \(shiftCount)件",
            month: syncMonth,
            shiftCount: shiftCount
        )
    }

    func recordMonthParseFailure(
        year: Int,
        month: Int,
        diagnostics: ShiftPageDiagnostics?,
        error: Error
    ) {
        let syncMonth = SyncMonth(year: year, month: month)
        updateMonthLog(syncMonth) { log in
            log.htmlSize = diagnostics?.htmlSize ?? log.htmlSize
            log.pageKind = diagnostics?.pageKind ?? log.pageKind
            log.hasShiftTable = diagnostics?.hasShiftTable ?? log.hasShiftTable
            log.headerText = diagnostics?.headerText ?? log.headerText
            log.parseSucceeded = false
            log.errorMessage = error.localizedDescription
        }
        addStep(
            phase: .parseMonth,
            status: .failure,
            message: "\(syncMonth.label) 解析失敗",
            month: syncMonth,
            htmlSize: diagnostics?.htmlSize,
            pageKind: diagnostics?.pageKind,
            hasShiftTable: diagnostics?.hasShiftTable,
            headerText: diagnostics?.headerText,
            errorMessage: error.localizedDescription
        )
    }

    func finishSuccess(result: SyncResult) {
        finish(
            success: true,
            result: SyncResultSummary(added: result.added, updated: result.updated, deleted: result.deleted),
            errorMessage: nil
        )
    }

    func finishFailure(error: Error, phase: SyncPhase? = nil, month: SyncMonth? = nil) {
        lock.lock()
        if let phase {
            failurePhase = phase
        }
        if let month {
            failureMonth = month
        }
        lock.unlock()
        finish(
            success: false,
            result: SyncResultSummary(added: 0, updated: 0, deleted: 0),
            errorMessage: error.localizedDescription
        )
    }

    private func finish(success: Bool, result: SyncResultSummary, errorMessage: String?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let endedAt = Date()
        let capturedSteps = steps
        let capturedMonthLogs = monthLogsByKey.values.sorted { $0.month.key < $1.month.key }
        let capturedFailurePhase = failurePhase
        let capturedFailureMonth = failureMonth
        lock.unlock()

        let finalMessage = success ? "同期完了" : "同期失敗"
        addStep(
            phase: .finish,
            status: success ? .success : .failure,
            message: finalMessage,
            errorMessage: errorMessage
        )

        lock.lock()
        let finalSteps = steps
        lock.unlock()

        let entry = SyncLogEntry(
            date: startedAt,
            source: source,
            result: result,
            success: success,
            errorMessage: errorMessage,
            runID: runID,
            startedAt: startedAt,
            endedAt: endedAt,
            failurePhase: capturedFailurePhase,
            failureMonth: capturedFailureMonth,
            concurrentRunIDs: concurrentRunIDs,
            steps: finalSteps.isEmpty ? capturedSteps : finalSteps,
            monthLogs: capturedMonthLogs
        )
        manager?.completeRun(runID, entry: entry)
    }

    private func updateMonthLog(_ month: SyncMonth, _ update: (inout SyncMonthLog) -> Void) {
        lock.lock()
        var log = monthLogsByKey[month.key] ?? SyncMonthLog(month: month)
        update(&log)
        monthLogsByKey[month.key] = log
        lock.unlock()
    }
}
