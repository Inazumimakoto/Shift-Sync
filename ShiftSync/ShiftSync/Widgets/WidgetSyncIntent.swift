import AppIntents
import WidgetKit
import Foundation

/// ウィジェットから直接シフト取得を実行するIntent
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
            let shifts = try await fetchWidgetShifts()

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

    private func fetchWidgetShifts() async throws -> [Shift] {
        let calendar = Calendar.current
        let now = Date()
        let thisYear = calendar.component(.year, from: now)
        let thisMonth = calendar.component(.month, from: now)

        let nextMonth = thisMonth == 12 ? 1 : thisMonth + 1
        let nextYear = thisMonth == 12 ? thisYear + 1 : thisYear

        return try await ShiftWebClient.shared.fetchShiftsForMonths([
            (year: thisYear, month: thisMonth),
            (year: nextYear, month: nextMonth)
        ])
    }
}
