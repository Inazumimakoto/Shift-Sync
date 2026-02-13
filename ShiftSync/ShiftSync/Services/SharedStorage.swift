import Foundation

enum SharedStorage {
    // App Group ID (Signing & Capabilitiesでも同じ値を設定)
    static let appGroupID = "group.com.inazumimakoto.shiftsync"

    static let savedShiftsKey = "savedShifts"
    static let lastSyncDateKey = "lastSyncDate"
    static let iCloudEnabledKey = "iCloudEnabled"
    static let googleEnabledKey = "googleEnabled"
    static let selectedICloudCalendarKey = "selectedICloudCalendar"
    static let selectedGoogleCalendarKey = "selectedGoogleCalendar"

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

    static func boolSetting(forKey key: String, default defaultValue: Bool = false) -> Bool {
        if let shared = sharedDefaults, shared.object(forKey: key) != nil {
            return shared.bool(forKey: key)
        }
        if UserDefaults.standard.object(forKey: key) != nil {
            let value = UserDefaults.standard.bool(forKey: key)
            sharedDefaults?.set(value, forKey: key)
            return value
        }
        return defaultValue
    }

    static func stringSetting(forKey key: String) -> String? {
        if let shared = sharedDefaults, let value = shared.string(forKey: key) {
            return value
        }
        if let value = UserDefaults.standard.string(forKey: key) {
            sharedDefaults?.set(value, forKey: key)
            return value
        }
        return nil
    }

    static func setBoolSetting(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        sharedDefaults?.set(value, forKey: key)
    }

    static func setStringSetting(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
            sharedDefaults?.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            sharedDefaults?.removeObject(forKey: key)
        }
    }

    static func replaceShiftsInCurrentSyncRange(
        existing: [Shift],
        incoming: [Shift],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Shift] {
        let syncRange = currentSyncRange(now: now, calendar: calendar)
        let kept = existing.filter { $0.start < syncRange.start || $0.start >= syncRange.end }
        return (kept + incoming).sorted { $0.start < $1.start }
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

        let boolKeys = [iCloudEnabledKey, googleEnabledKey]
        for key in boolKeys where shared.object(forKey: key) == nil {
            if let value = UserDefaults.standard.object(forKey: key) as? Bool {
                shared.set(value, forKey: key)
            }
        }

        let stringKeys = [selectedICloudCalendarKey, selectedGoogleCalendarKey]
        for key in stringKeys where shared.object(forKey: key) == nil {
            if let value = UserDefaults.standard.string(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
    }

    private static func currentSyncRange(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startOfPrevMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)!
        let startOfMonthAfterNext = calendar.date(byAdding: .month, value: 2, to: startOfThisMonth)!
        return (start: startOfPrevMonth, end: startOfMonthAfterNext)
    }
}
