import AppIntents
import Foundation

/// ショートカットから呼び出せる「シフトを同期」アクション
@available(iOS 16.0, *)
struct SyncShiftsIntent: AppIntent {
    static var title: LocalizedStringResource = "シフトを同期"
    static var description = IntentDescription("ShiftWebからシフトを取得してカレンダーに同期します")
    
    // ショートカットアプリでの表示設定
    static var openAppWhenRun: Bool = false  // アプリを開かない！
    
    func perform() async throws -> some IntentResult {
        // ログイン確認
        guard let _ = try? await KeychainService.shared.getShiftWebCredentials() else {
            // エラー通知のみ
            await MainActor.run {
                NotificationManager.shared.sendSyncErrorNotification(
                    error: NSError(domain: "ShiftSync", code: 401, userInfo: [NSLocalizedDescriptionKey: "ShiftWebにログインしてください"])
                )
            }
            return .result()
        }
        
        do {
            // 同期実行
            let result = try await BackgroundTaskManager.shared.performSync(source: .automation)
            
            // 変更があれば通知を送信
            if result.hasNotifiableChanges {
                await MainActor.run {
                    NotificationManager.shared.sendSyncCompleteNotification(result: result)
                }
            }
            
            return .result()  // ダイアログなし
        } catch {
            await MainActor.run {
                NotificationManager.shared.sendSyncErrorNotification(error: error)
            }
            return .result()  // ダイアログなし
        }
    }
}

/// アプリのショートカットを定義
@available(iOS 16.0, *)
struct ShiftSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncShiftsIntent(),
            phrases: [
                "\(.applicationName)で同期",
                "\(.applicationName)のシフトを同期",
                "\(.applicationName)を実行"
            ],
            shortTitle: "シフトを同期",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
