import AppIntents
import Foundation

/// ウィジェットから直接シフト取得を実行するIntent（アプリは開かない）
struct WidgetSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "同期"
    static var description = IntentDescription("ShiftWebから最新のシフトを取得します")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        do {
            _ = try await BackgroundTaskManager.shared.performSync(source: .manual)
            return .result()
        } catch {
            // ボタン操作時は静かに失敗させる（アプリを開かない）
            return .result()
        }
    }

}
