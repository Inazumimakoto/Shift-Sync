import AppIntents
import WidgetKit
import Foundation

/// ウィジェットから直接シフト取得を実行するIntent（アプリは開かない）
struct WidgetSyncIntent: AppIntent {
    static var title: LocalizedStringResource = "同期"
    static var description = IntentDescription("ShiftWebから最新のシフトを取得します")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun: Bool = false
    private let widgetKindID = "ShiftSyncSmallWidget"

    func perform() async throws -> some IntentResult {
        do {
            let credentials = try KeychainService.shared.getShiftWebCredentials()
            try await ShiftWebClient.shared.login(id: credentials.id, password: credentials.password)
            let shifts = try await ShiftWebClient.shared.fetchCurrentAndNextMonthShifts()

            SharedStorage.saveShifts(shifts)
            SharedStorage.saveLastSyncDate(Date())
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKindID)
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        } catch {
            // ボタン操作時は静かに失敗させる（アプリを開かない）
            return .result()
        }
    }
}
