import AppIntents
import Foundation

/// ウィジェットから直接シフト取得を実行するIntent（アプリは開かない）
struct WidgetSyncIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "同期"
    static var description = IntentDescription("ShiftWebから最新のシフトを取得します")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
#if APP_EXTENSION
        return .result()
#else
        do {
            _ = try await BackgroundTaskManager.shared.performSync(source: .widgetButton)
            return .result()
        } catch {
            // ボタン操作時は静かに失敗させる（アプリを開かない）
            return .result()
        }
#endif
    }

}
