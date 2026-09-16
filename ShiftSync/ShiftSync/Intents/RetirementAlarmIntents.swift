import AppIntents
import Foundation

struct StopRetirementAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "退勤アラームを停止"
    static var supportedModes: IntentModes = .background
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "アラームID") var alarmID: String

    init() { alarmID = "" }
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        await AlarmCoordinator.shared.markConsumed(alarmID: alarmID)
        return .result()
    }
}

struct OpenRetirementTimecardIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "退勤ページを開く"
    static var supportedModes: IntentModes = .foreground(.immediate)
    static var isDiscoverable = false

    @Parameter(title: "アラームID") var alarmID: String

    init() { alarmID = "" }
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        await MainActor.run { AppRouter.shared.open(.timecard) }
        await AlarmCoordinator.shared.markConsumed(alarmID: alarmID)
        return .result()
    }
}
