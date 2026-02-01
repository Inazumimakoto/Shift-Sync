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
                if result.hasChanges {
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
            
            // iCloud カレンダー同期
            if CalendarService.shared.hasAccess,
               let calendarID = UserDefaults.standard.string(forKey: "selectedICloudCalendar"),
               let calendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == calendarID }) {
                result = try CalendarService.shared.syncShifts(newShifts, to: calendar)
            }
            
            // Google カレンダー同期
            if GoogleCalendarService.shared.isSignedIn,
               let googleCalendarID = UserDefaults.standard.string(forKey: "selectedGoogleCalendar") {
                let googleResult = try await GoogleCalendarService.shared.syncShifts(newShifts, to: googleCalendarID)
                result.added += googleResult.added
                result.updated += googleResult.updated
                result.deleted += googleResult.deleted
            }
            
            // 新しいシフトを保存
            let mergedShifts = mergeShifts(existing: previousShifts, incoming: newShifts)
            savePreviousShifts(mergedShifts)
            
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
    
    private func mergeShifts(existing: [Shift], incoming: [Shift]) -> [Shift] {
        var merged: [String: Shift] = [:]
        for shift in existing {
            merged[shift.uid] = shift
        }
        for shift in incoming {
            merged[shift.uid] = shift
        }
        return merged.values.sorted { $0.start < $1.start }
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
        
        for shift in changes.added {
            // 今月以降のシフトのみ通知
            if shift.start >= startOfMonth {
                NotificationManager.shared.sendShiftAddedNotification(shift)
            }
        }
        
        for (old, new) in changes.modified {
            // 今月以降のシフトのみ通知
            if new.start >= startOfMonth {
                NotificationManager.shared.sendShiftChangedNotification(old: old, new: new)
            }
        }
        
        for shift in changes.removed {
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
