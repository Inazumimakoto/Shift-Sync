import Foundation

nonisolated struct RetirementAlarmState: Codable {
    var version = 1
    var activeAccountID: String?
    var isSuspendedForLogout = false
    var accounts: [String: RetirementAlarmAccount] = [:]
    var debugAlarmID: UUID?
}

/// Only the app process writes this store. The App Group survives app/intent launches.
@MainActor
final class RetirementAlarmStore {
    private let defaults: UserDefaults
    private let key = "retirementAlarmState.v1"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? SharedStorage.sharedDefaults ?? .standard
    }

    func load() -> RetirementAlarmState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(RetirementAlarmState.self, from: data),
              state.version == 1 else {
            return RetirementAlarmState()
        }
        return state
    }

    func save(_ state: RetirementAlarmState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
