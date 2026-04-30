import Foundation
import EventKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

/// バックグラウンドでのシフト同期を管理
class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    static let taskIdentifier = "com.inazumi.shiftsync.refresh"
    
    private init() {}
    
    /// バックグラウンドタスクを登録
    @available(iOSApplicationExtension, unavailable)
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    /// 次回のバックグラウンド更新をスケジュール
    @available(iOSApplicationExtension, unavailable)
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // 最短4時間後に実行
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("バックグラウンド更新をスケジュールしました")
        } catch {
                print("バックグラウンド更新のスケジュールに失敗: \(error)")
        }
    }
    
    /// バックグラウンドタスクを処理
    @available(iOSApplicationExtension, unavailable)
    private func handleAppRefresh(task: BGAppRefreshTask) {
        // 次回の更新をスケジュール
        scheduleAppRefresh()
        
        // タスクの期限切れ処理
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        // 同期処理を実行
        Task {
            do {
                let result = try await performSync(source: .background)
                task.setTaskCompleted(success: true)
                
                // 変更があれば通知
                if result.hasNotifiableChanges {
                    NotificationManager.shared.sendSyncCompleteNotification(result: result)
                }
            } catch {
                print("バックグラウンド同期エラー: \(error)")
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    /// 同期処理を実行
    /// - Parameter source: 同期ソース（手動/バックグラウンド/オートメーション）
    func performSync(source: SyncSource = .manualButton) async throws -> SyncResult {
        let logger = SyncHistoryManager.shared.beginRun(source: source)
        do {
            // Keychainからパスワードを取得
            let credentials = try KeychainService.shared.getShiftWebCredentials()
            
            // ShiftWebにログイン
            try await ShiftWebClient.shared.login(id: credentials.id, password: credentials.password, logger: logger)
            
            // シフトを取得
            let newShifts = try await ShiftWebClient.shared.fetchCurrentAndNextMonthShifts(logger: logger)
            
            // 前回のシフトと比較して変更を検出
            let previousShifts = loadPreviousShifts()
            let changes = detectChanges(previous: previousShifts, new: newShifts)
            
            // 変更があれば通知
            notifyChanges(changes)
            
            // カレンダーに同期
            var result = SyncResult()
            let iCloudEnabled = SharedStorage.boolSetting(forKey: SharedStorage.iCloudEnabledKey, default: true)
            let googleEnabled = SharedStorage.boolSetting(forKey: SharedStorage.googleEnabledKey, default: false)
            
            // iCloud カレンダー同期
            if iCloudEnabled,
               CalendarService.shared.hasAccess,
               let calendarID = SharedStorage.stringSetting(forKey: SharedStorage.selectedICloudCalendarKey),
               let calendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == calendarID }) {
                logger.addStep(phase: .calendarSync, status: .started, message: "iCloudカレンダー同期開始")
                do {
                    result = try CalendarService.shared.syncShifts(newShifts, to: calendar)
                    logger.addStep(
                        phase: .calendarSync,
                        status: .success,
                        message: "iCloudカレンダー同期成功 / \(result.summary)"
                    )
                } catch {
                    logger.addStep(
                        phase: .calendarSync,
                        status: .failure,
                        message: "iCloudカレンダー同期失敗",
                        errorMessage: error.localizedDescription
                    )
                    throw error
                }
            } else {
                logger.addStep(phase: .calendarSync, status: .info, message: "iCloudカレンダー同期スキップ")
            }
            
            // Google カレンダー同期
            if googleEnabled,
               GoogleCalendarService.shared.isSignedIn,
               let googleCalendarID = SharedStorage.stringSetting(forKey: SharedStorage.selectedGoogleCalendarKey) {
                logger.addStep(phase: .calendarSync, status: .started, message: "Googleカレンダー同期開始")
                let googleResult: SyncResult
                do {
                    googleResult = try await GoogleCalendarService.shared.syncShifts(newShifts, to: googleCalendarID)
                    logger.addStep(
                        phase: .calendarSync,
                        status: .success,
                        message: "Googleカレンダー同期成功 / \(googleResult.summary)"
                    )
                } catch {
                    logger.addStep(
                        phase: .calendarSync,
                        status: .failure,
                        message: "Googleカレンダー同期失敗",
                        errorMessage: error.localizedDescription
                    )
                    throw error
                }
                result.added += googleResult.added
                result.updated += googleResult.updated
                result.deleted += googleResult.deleted
                result.addedShifts = mergeUniqueShifts(result.addedShifts, googleResult.addedShifts)
                result.updatedShifts = mergeUniqueShifts(result.updatedShifts, googleResult.updatedShifts)
                result.deletedShifts = mergeUniqueShifts(result.deletedShifts, googleResult.deletedShifts)
            } else {
                logger.addStep(phase: .calendarSync, status: .info, message: "Googleカレンダー同期スキップ")
            }
            
            // 新しいシフトを保存（取得範囲内は置き換え）
            logger.addStep(phase: .saveStorage, status: .started, message: "保存開始")
            let updatedShifts = SharedStorage.replaceShiftsInCurrentSyncRange(
                existing: previousShifts,
                incoming: newShifts
            )
            savePreviousShifts(updatedShifts)
            
            // 最終同期日時を更新
            let lastSyncDate = Date()
            SharedStorage.saveLastSyncDate(lastSyncDate)
            logger.addStep(phase: .saveStorage, status: .success, message: "保存成功 / \(updatedShifts.count)件")
            
            // 同期履歴を記録
            logger.finishSuccess(result: result)

#if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
#endif
            
            return result
        } catch {
            // エラー時も履歴を記録
            logger.finishFailure(error: error)
            throw error
        }
    }
    
    // MARK: - Change Detection
    
    private func loadPreviousShifts() -> [Shift] {
        SharedStorage.loadShifts()
    }
    
    private func savePreviousShifts(_ shifts: [Shift]) {
        SharedStorage.saveShifts(shifts)
    }
    
    private func mergeUniqueShifts(_ existing: [Shift], _ incoming: [Shift]) -> [Shift] {
        var byUID: [String: Shift] = [:]
        for shift in existing {
            byUID[shift.uid] = shift
        }
        for shift in incoming {
            byUID[shift.uid] = shift
        }
        return byUID.values.sorted { $0.start < $1.start }
    }
    
    private func detectChanges(previous: [Shift], new: [Shift]) -> ShiftChanges {
        let previousUIDs = Set(previous.map { $0.uid })
        let newUIDs = Set(new.map { $0.uid })
        
        let addedUIDs = newUIDs.subtracting(previousUIDs)
        let removedUIDs = previousUIDs.subtracting(newUIDs)
        
        let added = new.filter { addedUIDs.contains($0.uid) }
        let removed = previous.filter { removedUIDs.contains($0.uid) }
        
        // 時間変更の検出
        var modified: [(old: Shift, new: Shift)] = []
        for newShift in new {
            if let oldShift = previous.first(where: { $0.uid == newShift.uid }) {
                if oldShift.start != newShift.start || oldShift.end != newShift.end {
                    modified.append((oldShift, newShift))
                }
            }
        }
        
        return ShiftChanges(added: added, removed: removed, modified: modified)
    }
    
    private func notifyChanges(_ changes: ShiftChanges) {
        // 今月の初日を計算（先月分のシフトを通知から除外するため）
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!

        // 削除+追加のペアを「変更」として扱う（同日・同店舗）
        var added = changes.added
        var removed = changes.removed
        var modified = changes.modified
        
        if !added.isEmpty && !removed.isEmpty {
            var matchedAdded: Set<Int> = []
            var matchedRemoved: Set<Int> = []
            
            for (removedIndex, removedShift) in removed.enumerated() {
                for (addedIndex, addedShift) in added.enumerated() {
                    guard !matchedAdded.contains(addedIndex),
                          !matchedRemoved.contains(removedIndex) else { continue }
                    
                    let sameDay = calendar.isDate(removedShift.start, inSameDayAs: addedShift.start)
                    let sameLocation = removedShift.location.trimmingCharacters(in: .whitespacesAndNewlines)
                        == addedShift.location.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if sameDay && sameLocation {
                        matchedRemoved.insert(removedIndex)
                        matchedAdded.insert(addedIndex)
                        modified.append((old: removedShift, new: addedShift))
                        break
                    }
                }
            }
            
            if !matchedAdded.isEmpty {
                added = added.enumerated()
                    .filter { !matchedAdded.contains($0.offset) }
                    .map { $0.element }
            }
            
            if !matchedRemoved.isEmpty {
                removed = removed.enumerated()
                    .filter { !matchedRemoved.contains($0.offset) }
                    .map { $0.element }
            }
        }
        
        for shift in added {
            // 今月以降のシフトのみ通知
            if shift.start >= startOfMonth {
                NotificationManager.shared.sendShiftAddedNotification(shift)
            }
        }
        
        for (old, new) in modified {
            // 今月以降のシフトのみ通知
            if new.start >= startOfMonth {
                NotificationManager.shared.sendShiftChangedNotification(old: old, new: new)
            }
        }
        
        for shift in removed {
            // 今月以降のシフトのみ通知
            if shift.start >= startOfMonth {
                NotificationManager.shared.sendShiftRemovedNotification(shift)
            }
        }
    }
}

struct ShiftChanges {
    let added: [Shift]
    let removed: [Shift]
    let modified: [(old: Shift, new: Shift)]
    
    var hasChanges: Bool {
        !added.isEmpty || !removed.isEmpty || !modified.isEmpty
    }
}
