import Foundation
import UserNotifications

/// ローカル通知を管理
class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    /// 通知権限をリクエスト
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
#if !APP_EXTENSION
            Task { @MainActor in await AnnouncementService.shared.refresh() }
#endif
            if granted {
                print("通知が許可されました")
            } else if let error = error {
                print("通知の許可エラー: \(error)")
            }
        }
    }
    
    /// シフト追加通知
    func sendShiftAddedNotification(_ shift: Shift) {
        let content = UNMutableNotificationContent()
        content.title = "🆕 新しいシフト"
        content.body = "\(shift.dateString)(\(shift.dayOfWeek)) \(shift.timeRangeString) - \(shift.location)"
        content.sound = .default
        
        scheduleNotification(content: content, identifier: "shift-added-\(shift.uid)")
    }
    
    /// シフト変更通知
    func sendShiftChangedNotification(old: Shift, new: Shift) {
        let content = UNMutableNotificationContent()
        content.title = "📝 シフト変更"
        content.body = "\(new.dateString)(\(new.dayOfWeek)): \(old.timeRangeString) → \(new.timeRangeString)"
        content.sound = .default
        
        scheduleNotification(content: content, identifier: "shift-changed-\(new.uid)")
    }
    
    /// シフト削除通知
    func sendShiftRemovedNotification(_ shift: Shift) {
        let content = UNMutableNotificationContent()
        content.title = "🗑️ シフト削除"
        content.body = "\(shift.dateString)(\(shift.dayOfWeek)) \(shift.timeRangeString) - \(shift.location)"
        content.sound = .default
        
        scheduleNotification(content: content, identifier: "shift-removed-\(shift.uid)")
    }
    
    /// 同期完了通知
    func sendSyncCompleteNotification(result: SyncResult) {
        let content = UNMutableNotificationContent()
        content.title = "✅ シフト同期完了"
        content.body = result.notificationBody
        content.sound = .default
        
        scheduleNotification(content: content, identifier: "sync-complete-\(Date().timeIntervalSince1970)")
    }
    
    /// 同期エラー通知
    func sendSyncErrorNotification(error: Error) {
        let content = UNMutableNotificationContent()
        content.title = "❌ シフト同期エラー"
        content.body = error.localizedDescription
        content.sound = .default
        
        scheduleNotification(content: content, identifier: "sync-error-\(Date().timeIntervalSince1970)")
    }
    
    private func scheduleNotification(content: UNMutableNotificationContent, identifier: String) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("通知のスケジュールエラー: \(error)")
            }
        }
    }
}
