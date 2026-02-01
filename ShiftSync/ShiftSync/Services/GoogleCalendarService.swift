import Foundation
import GoogleSignIn

/// Google Calendar APIを使用してシフトを同期
class GoogleCalendarService {
    static let shared = GoogleCalendarService()
    
    // Google Cloud Consoleで取得したClient ID
    static let clientID = "786430344398-1gs9lon65olqi5ba08aeme75te5lrcb6.apps.googleusercontent.com"
    
    private var accessToken: String?
    private var currentUser: GIDGoogleUser?
    
    private init() {}
    
    // MARK: - Authentication
    
    /// Google Sign-In が設定済みかどうか
    var isConfigured: Bool {
        Self.clientID != "YOUR_CLIENT_ID.apps.googleusercontent.com"
    }
    
    /// ログイン済みかどうか
    var isSignedIn: Bool {
        GIDSignIn.sharedInstance.currentUser != nil
    }
    
    /// 現在のユーザー名
    var userName: String? {
        GIDSignIn.sharedInstance.currentUser?.profile?.name
    }
    
    /// Google Sign-In を実行
    @MainActor
    func signIn(presenting viewController: UIViewController) async throws {
        guard isConfigured else {
            throw GoogleCalendarError.notConfigured
        }
        
        // GoogleSignIn SDK v9の新しいAPI
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: viewController,
            hint: nil,
            additionalScopes: ["https://www.googleapis.com/auth/calendar"]
        )
        
        currentUser = result.user
        accessToken = result.user.accessToken.tokenString
    }
    
    /// 以前のセッションを復元
    func restorePreviousSignIn() async throws {
        try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        currentUser = GIDSignIn.sharedInstance.currentUser
        accessToken = currentUser?.accessToken.tokenString
    }
    
    /// サインアウト
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        accessToken = nil
    }
    
    // MARK: - Calendar API
    
    /// カレンダー一覧を取得
    func getCalendars() async throws -> [GoogleCalendar] {
        guard let token = await getValidAccessToken() else {
            throw GoogleCalendarError.notAuthenticated
        }
        
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.apiError("カレンダー一覧の取得に失敗しました")
        }
        
        let result = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        
        // 書き込み可能なカレンダーのみ返す
        return result.items.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
    }
    
    /// シフトを同期
    func syncShifts(_ shifts: [Shift], to calendarId: String) async throws -> SyncResult {
        guard let token = await getValidAccessToken() else {
            throw GoogleCalendarError.notAuthenticated
        }
        
        var result = SyncResult()
        
        // 既存のシフトイベントを取得
        let existingEvents = try await getExistingShiftEvents(calendarId: calendarId, token: token)
        let existingUIDs = Set(existingEvents.compactMap { extractShiftUID(from: $0) })
        let desiredUIDs = Set(shifts.map { $0.uid })
        
        // 削除するイベント
        let now = Date()
        let toDelete = existingEvents.filter { event in
            guard let uid = extractShiftUID(from: event) else { return false }
            // 過去のイベントは削除対象から除外（履歴を保持）
            if let endDate = eventEndDate(event), endDate < now { return false }
            return !desiredUIDs.contains(uid)
        }
        
        for event in toDelete {
            try await deleteEvent(eventId: event.id, calendarId: calendarId, token: token)
            result.deleted += 1
        }
        
        // 追加・更新するシフト
        for shift in shifts {
            if existingUIDs.contains(shift.uid) {
                // 既存イベントを更新
                if let existingEvent = existingEvents.first(where: { extractShiftUID(from: $0) == shift.uid }) {
                    try await updateEvent(eventId: existingEvent.id, shift: shift, calendarId: calendarId, token: token)
                    result.updated += 1
                }
            } else {
                // 新規イベント作成
                try await createEvent(shift: shift, calendarId: calendarId, token: token)
                result.added += 1
            }
        }
        
        return result
    }
    
    // MARK: - Private Helpers
    
    private func getValidAccessToken() async -> String? {
        guard let user = GIDSignIn.sharedInstance.currentUser else { return nil }
        
        // トークンをリフレッシュ
        do {
            try await user.refreshTokensIfNeeded()
            return user.accessToken.tokenString
        } catch {
            print("Token refresh failed: \(error)")
            return nil
        }
    }
    
    private func getExistingShiftEvents(calendarId: String, token: String) async throws -> [GoogleEvent] {
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .month, value: -1, to: now)!
        let endDate = Calendar.current.date(byAdding: .month, value: 3, to: now)!
        
        let formatter = ISO8601DateFormatter()
        let timeMin = formatter.string(from: startDate)
        let timeMax = formatter.string(from: endDate)
        
        var urlComponents = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)/events")!
        urlComponents.queryItems = [
            URLQueryItem(name: "timeMin", value: timeMin),
            URLQueryItem(name: "timeMax", value: timeMax),
            URLQueryItem(name: "maxResults", value: "500"),
            URLQueryItem(name: "singleEvents", value: "true")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode(EventListResponse.self, from: data)
        
        // shift-uidを含むイベントのみ返す
        return result.items.filter { $0.description?.contains("shift-uid:") == true }
    }
    
    private func extractShiftUID(from event: GoogleEvent) -> String? {
        guard let description = event.description,
              let range = description.range(of: "shift-uid:") else { return nil }
        let start = range.upperBound
        let remaining = description[start...]
        if let end = remaining.firstIndex(of: "\n") {
            return String(remaining[..<end])
        }
        return String(remaining)
    }
    
    private func eventEndDate(_ event: GoogleEvent) -> Date? {
        guard let end = event.end else { return nil }
        if let dateTime = end.dateTime {
            return parseGoogleDateTime(dateTime)
        }
        if let date = end.date {
            return parseGoogleDate(date)
        }
        return nil
    }
    
    private func parseGoogleDateTime(_ dateTime: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateTime) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateTime)
    }
    
    private func parseGoogleDate(_ date: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.date(from: date)
    }
    
    private func createEvent(shift: Shift, calendarId: String, token: String) async throws {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)/events")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let event = createEventBody(for: shift)
        request.httpBody = try JSONEncoder().encode(event)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.apiError("イベントの作成に失敗しました")
        }
    }
    
    private func updateEvent(eventId: String, shift: Shift, calendarId: String, token: String) async throws {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)/events/\(eventId)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let event = createEventBody(for: shift)
        request.httpBody = try JSONEncoder().encode(event)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.apiError("イベントの更新に失敗しました")
        }
    }
    
    private func deleteEvent(eventId: String, calendarId: String, token: String) async throws {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)/events/\(eventId)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.apiError("イベントの削除に失敗しました")
        }
    }
    
    private func createEventBody(for shift: Shift) -> GoogleEventRequest {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        return GoogleEventRequest(
            summary: shift.title,
            location: shift.location,
            description: "shift-uid:\(shift.uid)\(shift.memo.isEmpty ? "" : "\n\(shift.memo)")",
            start: EventDateTime(dateTime: formatter.string(from: shift.start)),
            end: EventDateTime(dateTime: formatter.string(from: shift.end))
        )
    }
}

// MARK: - Error Types

enum GoogleCalendarError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Calendar APIが設定されていません"
        case .notAuthenticated:
            return "Googleにログインしてください"
        case .apiError(let message):
            return message
        }
    }
}

// MARK: - API Response Models

struct CalendarListResponse: Codable {
    let items: [GoogleCalendar]
}

struct GoogleCalendar: Codable, Identifiable, Hashable {
    let id: String
    let summary: String
    let accessRole: String
    
    var title: String { summary }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: GoogleCalendar, rhs: GoogleCalendar) -> Bool {
        lhs.id == rhs.id
    }
}

struct EventListResponse: Codable {
    let items: [GoogleEvent]
}

struct GoogleEvent: Codable {
    let id: String
    let summary: String?
    let description: String?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?
}

struct GoogleEventDateTime: Codable {
    let dateTime: String?
    let date: String?
}

struct GoogleEventRequest: Codable {
    let summary: String
    let location: String
    let description: String
    let start: EventDateTime
    let end: EventDateTime
}

struct EventDateTime: Codable {
    let dateTime: String
    let timeZone: String = "Asia/Tokyo"
}
