import Foundation
import EventKit

/// EventKitを使用してiCloudカレンダーにシフトを同期
class CalendarService {
    static let shared = CalendarService()
    
    private let eventStore = EKEventStore()
    
    private init() {}
    
    // MARK: - Authorization
    
    func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await eventStore.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }
    
    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess ||
        EKEventStore.authorizationStatus(for: .event) == .authorized
    }
    
    // MARK: - Calendar Management
    
    func getCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter { calendar in
            calendar.allowsContentModifications
        }
    }
    
    func getICloudCalendars() -> [EKCalendar] {
        getCalendars().filter { $0.source.sourceType == .calDAV }
    }
    
    /// 新しいiCloudカレンダーを作成
    func createCalendar(title: String) throws -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = title
        
        // iCloudソースを探す
        if let iCloudSource = eventStore.sources.first(where: { $0.sourceType == .calDAV }) {
            calendar.source = iCloudSource
        } else if let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) {
            // iCloudがなければローカルを使用
            calendar.source = localSource
        } else {
            throw NSError(domain: "CalendarService", code: 1, userInfo: [NSLocalizedDescriptionKey: "利用可能なカレンダーソースがありません"])
        }
        
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }
    
    // MARK: - Sync
    
    /// シフトをカレンダーに同期
    /// Go版: syncShiftsToCalDAV (main.go:1058-1148) のロジックを移植
    func syncShifts(_ shifts: [Shift], to calendar: EKCalendar) throws -> SyncResult {
        let range = defaultSyncRange()
        return try syncShifts(shifts, to: calendar, searchStart: range.start, searchEnd: range.end)
    }
    
    /// 指定範囲で既存イベントを検索して同期
    func syncShifts(_ shifts: [Shift], to calendar: EKCalendar, searchStart: Date, searchEnd: Date) throws -> SyncResult {
        var result = SyncResult()
        
        // 既存のshift-*イベントを取得
        var existingEvents = getExistingShiftEvents(in: calendar, startDate: searchStart, endDate: searchEnd)
        
        // 同一UIDの重複イベントを整理してから同期する
        existingEvents = try deduplicateShiftEvents(existingEvents)
        let existingUIDs = Set(existingEvents.compactMap { extractShiftUID(from: $0) })
        
        // 必要なUIDのセット
        let desiredUIDs = Set(shifts.map { $0.uid })
        
        // 削除するイベント（過去のイベントは削除しない）
        let now = Date()
        let toDelete = existingEvents.filter { event in
            guard let uid = extractShiftUID(from: event) else { return false }
            // 過去のイベントは削除対象から除外（履歴を保持）
            if event.endDate < now { return false }
            return !desiredUIDs.contains(uid)
        }
        
        for event in toDelete {
            // 削除されたシフトの情報を作成
            if let uid = extractShiftUID(from: event) {
                let deletedShift = Shift(
                    uid: uid,
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    location: event.location ?? "",
                    memo: ""
                )
                result.deletedShifts.append(deletedShift)
            }
            try eventStore.remove(event, span: .thisEvent)
            result.deleted += 1
        }
        
        // 追加・更新するシフト
        for shift in shifts {
            if existingUIDs.contains(shift.uid) {
                // 既存イベントを更新（内容が変わった場合のみ）
                if let existingEvent = existingEvents.first(where: { extractShiftUID(from: $0) == shift.uid }) {
                    if needsUpdate(existingEvent, with: shift) {
                        updateEvent(existingEvent, with: shift)
                        try eventStore.save(existingEvent, span: .thisEvent)
                        result.updated += 1
                        result.updatedShifts.append(shift)
                    }
                    // 変更なしの場合はスキップ（カウントしない）
                }
            } else {
                // 新規イベント作成
                let event = createEvent(for: shift, in: calendar)
                try eventStore.save(event, span: .thisEvent)
                result.added += 1
                result.addedShifts.append(shift)
            }
        }
        
        // 同時実行で重複が紛れたケースも最終的に自己修復
        _ = try deduplicateShiftEvents(
            getExistingShiftEvents(in: calendar, startDate: searchStart, endDate: searchEnd)
        )
        
        return result
    }
    
    /// 指定カレンダーから全シフトイベントを削除
    func deleteAllShiftEvents(from calendar: EKCalendar) throws {
        let events = getExistingShiftEvents(in: calendar)
        for event in events {
            try eventStore.remove(event, span: .thisEvent)
        }
    }
    
    /// 指定範囲のシフトイベントを削除
    func deleteAllShiftEvents(from calendar: EKCalendar, searchStart: Date, searchEnd: Date) throws {
        let events = getExistingShiftEvents(in: calendar, startDate: searchStart, endDate: searchEnd)
        for event in events {
            try eventStore.remove(event, span: .thisEvent)
        }
    }
    
    /// イベントの内容が変わったかチェック
    private func needsUpdate(_ event: EKEvent, with shift: Shift) -> Bool {
        // タイトル、開始時刻、終了時刻、場所を比較
        if event.title != shift.title { return true }
        if event.startDate != shift.start { return true }
        if event.endDate != shift.end { return true }
        if event.location != shift.location { return true }
        return false
    }
    
    // MARK: - Private Helpers
    
    private func getExistingShiftEvents(in calendar: EKCalendar) -> [EKEvent] {
        let range = defaultSyncRange()
        return getExistingShiftEvents(in: calendar, startDate: range.start, endDate: range.end)
    }
    
    private func getExistingShiftEvents(in calendar: EKCalendar, startDate: Date, endDate: Date) -> [EKEvent] {
        
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [calendar]
        )
        
        return eventStore.events(matching: predicate).filter { event in
            event.notes?.contains("shift-uid:") == true
        }
    }
    
    private func defaultSyncRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startOfPrevMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth)!
        let startOfMonthAfterNext = calendar.date(byAdding: .month, value: 2, to: startOfThisMonth)!
        return (start: startOfPrevMonth, end: startOfMonthAfterNext)
    }
    
    /// 同じshift-uidを持つ重複イベントを削除し、ユニークな一覧を返す
    private func deduplicateShiftEvents(_ events: [EKEvent]) throws -> [EKEvent] {
        var selectedByUID: [String: EKEvent] = [:]
        var duplicatesToDelete: [EKEvent] = []
        
        for event in events {
            guard let uid = extractShiftUID(from: event) else { continue }
            
            if let existing = selectedByUID[uid] {
                let preferred = preferredEvent(existing, comparedTo: event)
                let obsolete = (preferred === existing) ? event : existing
                selectedByUID[uid] = preferred
                duplicatesToDelete.append(obsolete)
            } else {
                selectedByUID[uid] = event
            }
        }
        
        for duplicate in duplicatesToDelete {
            try eventStore.remove(duplicate, span: .thisEvent)
        }
        
        return selectedByUID.values.sorted { $0.startDate < $1.startDate }
    }
    
    /// 重複イベントから残す1件を選ぶ
    private func preferredEvent(_ lhs: EKEvent, comparedTo rhs: EKEvent) -> EKEvent {
        let lhsModified = lhs.lastModifiedDate ?? .distantPast
        let rhsModified = rhs.lastModifiedDate ?? .distantPast
        if lhsModified != rhsModified {
            return lhsModified > rhsModified ? lhs : rhs
        }
        
        let lhsScore = eventQualityScore(lhs)
        let rhsScore = eventQualityScore(rhs)
        if lhsScore != rhsScore {
            return lhsScore >= rhsScore ? lhs : rhs
        }
        
        return lhs.startDate <= rhs.startDate ? lhs : rhs
    }
    
    private func eventQualityScore(_ event: EKEvent) -> Int {
        var score = 0
        if let title = event.title, !title.isEmpty { score += 1 }
        if let location = event.location, !location.isEmpty { score += 1 }
        if event.startDate < event.endDate { score += 1 }
        return score
    }
    
    private func extractShiftUID(from event: EKEvent) -> String? {
        guard let notes = event.notes,
              let range = notes.range(of: "shift-uid:") else { return nil }
        let start = range.upperBound
        let remaining = notes[start...]
        if let end = remaining.firstIndex(of: "\n") {
            return String(remaining[..<end])
        }
        return String(remaining)
    }
    
    private func createEvent(for shift: Shift, in calendar: EKCalendar) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = shift.title
        event.startDate = shift.start
        event.endDate = shift.end
        event.location = shift.location
        event.notes = "shift-uid:\(shift.uid)"
        if !shift.memo.isEmpty {
            event.notes = "\(event.notes ?? "")\n\(shift.memo)"
        }
        return event
    }
    
    private func updateEvent(_ event: EKEvent, with shift: Shift) {
        event.title = shift.title
        event.startDate = shift.start
        event.endDate = shift.end
        event.location = shift.location
    }
}

struct SyncResult {
    var added: Int = 0
    var updated: Int = 0
    var deleted: Int = 0
    var addedShifts: [Shift] = []
    var updatedShifts: [Shift] = []
    var deletedShifts: [Shift] = []
    
    var hasChanges: Bool {
        added > 0 || updated > 0 || deleted > 0
    }
    
    /// 今月以降のシフト変更があるか
    var hasNotifiableChanges: Bool {
        let future = futureChanges
        if !future.added.isEmpty || !future.updated.isEmpty || !future.deleted.isEmpty {
            return true
        }
        
        // iCloudの詳細が存在するのに今月以降が空なら通知しない
        if !addedShifts.isEmpty || !updatedShifts.isEmpty || !deletedShifts.isEmpty {
            return false
        }
        
        // Google同期など詳細がない場合は件数ベースで通知
        return hasChanges
    }
    
    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("追加: \(added)件") }
        if updated > 0 { parts.append("更新: \(updated)件") }
        if deleted > 0 { parts.append("削除: \(deleted)件") }
        return parts.isEmpty ? "変更なし" : parts.joined(separator: ", ")
    }
    
    /// 通知に表示する本文
    var notificationBody: String {
        let detailed = detailedSummary
        if detailed != "変更なし" {
            return detailed
        }
        if hasNotifiableChanges {
            return summary
        }
        return "変更なし"
    }
    
    var detailedSummary: String {
        var lines: [String] = []
        
        let futureAddedShifts = futureChanges.added
        let futureUpdatedShifts = futureChanges.updated
        let futureDeletedShifts = futureChanges.deleted
        
        // 追加
        if !futureAddedShifts.isEmpty {
            if futureAddedShifts.count <= 2 {
                for shift in futureAddedShifts {
                    lines.append("🆕 \(shift.dateString)(\(shift.dayOfWeek)) \(shift.timeRangeString)")
                }
            } else {
                let first = futureAddedShifts.first!
                let last = futureAddedShifts.last!
                lines.append("🆕 \(futureAddedShifts.count)件追加 (\(first.dateString)〜\(last.dateString))")
            }
        }
        
        // 更新
        for shift in futureUpdatedShifts {
            lines.append("📝 \(shift.dateString)(\(shift.dayOfWeek)) \(shift.timeRangeString)")
        }
        
        // 削除
        for shift in futureDeletedShifts {
            lines.append("🗑️ \(shift.dateString)(\(shift.dayOfWeek)) \(shift.timeRangeString)")
        }
        
        return lines.isEmpty ? "変更なし" : lines.joined(separator: "\n")
    }
    
    private var futureChanges: (added: [Shift], updated: [Shift], deleted: [Shift]) {
        // 今月の初日を計算（先月分のシフトを通知から除外するため）
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        
        return (
            added: addedShifts.filter { $0.start >= startOfMonth },
            updated: updatedShifts.filter { $0.start >= startOfMonth },
            deleted: deletedShifts.filter { $0.start >= startOfMonth }
        )
    }
}
