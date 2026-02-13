import Foundation

enum SharedStorage {
    // App Group ID (Signing & Capabilitiesでも同じ値を設定)
    static let appGroupID = "group.com.inazumimakoto.shiftsync"

    static let savedShiftsKey = "savedShifts"
    static let lastSyncDateKey = "lastSyncDate"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func loadShifts() -> [Shift] {
        if let shared = sharedDefaults,
           let data = shared.data(forKey: savedShiftsKey),
           let shifts = try? JSONDecoder().decode([Shift].self, from: data) {
            return shifts
        }

        guard let data = UserDefaults.standard.data(forKey: savedShiftsKey),
              let shifts = try? JSONDecoder().decode([Shift].self, from: data) else {
            return []
        }
        return shifts
    }

    static func saveShifts(_ shifts: [Shift]) {
        guard let data = try? JSONEncoder().encode(shifts) else {
            return
        }
        UserDefaults.standard.set(data, forKey: savedShiftsKey)
        sharedDefaults?.set(data, forKey: savedShiftsKey)
    }

    static func loadLastSyncDate() -> Date? {
        if let sharedDate = sharedDefaults?.object(forKey: lastSyncDateKey) as? Date {
            return sharedDate
        }
        return UserDefaults.standard.object(forKey: lastSyncDateKey) as? Date
    }

    static func saveLastSyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncDateKey)
        sharedDefaults?.set(date, forKey: lastSyncDateKey)
    }

    static func migrateToSharedIfNeeded() {
        guard let shared = sharedDefaults else {
            return
        }

        if shared.object(forKey: savedShiftsKey) == nil,
           let data = UserDefaults.standard.data(forKey: savedShiftsKey) {
            shared.set(data, forKey: savedShiftsKey)
        }

        if shared.object(forKey: lastSyncDateKey) == nil,
           let date = UserDefaults.standard.object(forKey: lastSyncDateKey) as? Date {
            shared.set(date, forKey: lastSyncDateKey)
        }
    }
}
