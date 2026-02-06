import Foundation
import BackgroundTasks
import EventKit

/// バックグラウンドでのシフト同期を管理
class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    static let taskIdentifier = "com.inazumi.shiftsync.refresh"
    
    private init() {}
    
    /// バックグラウンドタスクを登録
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    /// 次回のバックグラウンド更新をスケジュール
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
    func performSync(source: SyncSource = .manual) async throws -> SyncResult {
        do {
            // Keychainからパスワードを取得
            let credentials = try KeychainService.shared.getShiftWebCredentials()
            
            // ShiftWebにログイン
            try await ShiftWebClient.shared.login(id: credentials.id, password: credentials.password)
            
            // シフトを取得
            let newShifts = try await ShiftWebClient.shared.fetchCurrentAndNextMonthShifts()
            
            // 前回のシフトと比較して変更を検出
            let previousShifts = loadPreviousShifts()
            let changes = detectChanges(previous: previousShifts, new: newShifts)
            
            // 変更があれば通知
            notifyChanges(changes)
            
            // カレンダーに同期
            var result = SyncResult()
            let iCloudEnabled = UserDefaults.standard.object(forKey: "iCloudEnabled") as? Bool ?? true
            let googleEnabled = UserDefaults.standard.bool(forKey: "googleEnabled")
            
            // iCloud カレンダー同期
            if iCloudEnabled,
               CalendarService.shared.hasAccess,
               let calendarID = UserDefaults.standard.string(forKey: "selectedICloudCalendar"),
               let calendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == calendarID }) {
                result = try CalendarService.shared.syncShifts(newShifts, to: calendar)
            }
            
            // Google カレンダー同期
            if googleEnabled,
               GoogleCalendarService.shared.isSignedIn,
               let googleCalendarID = UserDefaults.standard.string(forKey: "selectedGoogleCalendar") {
                let googleResult = try await GoogleCalendarService.shared.syncShifts(newShifts, to: googleCalendarID)
                result.added += googleResult.added
                result.updated += googleResult.updated
                result.deleted += googleResult.deleted
                result.addedShifts = mergeUniqueShifts(result.addedShifts, googleResult.addedShifts)
                result.updatedShifts = mergeUniqueShifts(result.updatedShifts, googleResult.updatedShifts)
                result.deletedShifts = mergeUniqueShifts(result.deletedShifts, googleResult.deletedShifts)
            }
            
            // 新しいシフトを保存（取得範囲内は置き換え）
            let syncRange = currentSyncRange()
            let updatedShifts = replaceShifts(
                existing: previousShifts,
                incoming: newShifts,
                rangeStart: syncRange.start,
                rangeEnd: syncRange.end
            )
            savePreviousShifts(updatedShifts)
            
            // 最終同期日時を更新
            UserDefaults.standard.set(Date(), forKey: "lastSyncDate")
            
            // 同期履歴を記録
            SyncHistoryManager.shared.logSuccess(source: source, result: result)
            
            return result
        } catch {
            // エラー時も履歴を記録
            SyncHistoryManager.shared.logFailure(source: source, error: error)
            throw error
        }
    }
    
    // MARK: - Change Detection
    
    private func loadPreviousShifts() -> [Shift] {
        guard let data = UserDefaults.standard.data(forKey: "savedShifts"),
              let shifts = try? JSONDecoder().decode([Shift].self, from: data) else {
            return []
        }
        return shifts
    }
    
    private func savePreviousShifts(_ shifts: [Shift]) {
        if let data = try? JSONEncoder().encode(shifts) {
            UserDefaults.standard.set(data, forKey: "savedShifts")
        }
    }
    
    private func replaceShifts(existing: [Shift], incoming: [Shift], rangeStart: Date, rangeEnd: Date) -> [Shift] {
        let kept = existing.filter { $0.start < rangeStart || $0.start >= rangeEnd }
        return (kept + incoming).sorted { $0.start < $1.start }
    }
    
    private func currentSyncRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startOfPrevMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)!
        let startOfMonthAfterNext = calendar.date(byAdding: .month, value: 2, to: startOfThisMonth)!
        return (start: startOfPrevMonth, end: startOfMonthAfterNext)
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
