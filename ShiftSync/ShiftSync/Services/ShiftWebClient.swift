import Foundation
import SwiftSoup

/// ShiftWebサイトからシフト情報を取得するクライアント
/// Go版の loginShiftWeb, fetchShiftPageForMonth を移植
class ShiftWebClient {
    static let shared = ShiftWebClient()
    
    private let baseURL = "https://ams-app.club"
    private let loginPageURL = "https://ams-app.club/login.php"
    private let loginAPIURL = "https://ams-app.club/cont/login/check_login.php"
    private let shiftURL = "https://ams-app.club/shift.php"
    
    private var session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        self.session = URLSession(configuration: config)
    }
    
    private var userAgent: String {
        UserDefaults.standard.string(forKey: "UserAgent") ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
    
    /// ShiftWebにログイン
    /// Go版: loginShiftWeb (main.go:669-707)
    func login(id: String, password: String) async throws {
        // 1. ログインページにアクセスしてCookieを取得
        let loginPageRequest = URLRequest(url: URL(string: "\(loginPageURL)?err=1")!)
        let _ = try await session.data(for: loginPageRequest)
        
        // 2. ログインAPIにPOST
        var request = URLRequest(url: URL(string: "\(loginAPIURL)?\(id)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(baseURL, forHTTPHeaderField: "Origin")
        request.setValue("\(baseURL)/login.php?err=1", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let body = "id=\(id.urlEncoded)&password=\(password.urlEncoded)&savelogin=1"
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode < 400 else {
            throw ShiftWebError.loginFailed
        }
        
        let responseText = String(data: data, encoding: .utf8) ?? ""
        print("login API response: \(responseText)")
    }
    
    /// 指定月のシフトページを取得
    /// Go版: fetchShiftPageForMonth (main.go:709-738)
    func fetchShiftPage(year: Int, month: Int) async throws -> String {
        let date2 = String(format: "%04d-%02d", year, month)
        var components = URLComponents(string: shiftURL)!
        components.queryItems = [
            URLQueryItem(name: "mod", value: "look"),
            URLQueryItem(name: "date2", value: date2)
        ]
        
        var request = URLRequest(url: components.url!)
        request.setValue(shiftURL, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode < 400 else {
            throw ShiftWebError.fetchFailed(year: year, month: month)
        }
        
        let html = String(data: data, encoding: .utf8) ?? ""
        print("shift status (\(date2)): \(httpResponse.statusCode)")
        return html
    }
    
    /// 先月・今月・来月のシフトを取得
    func fetchCurrentAndNextMonthShifts() async throws -> [Shift] {
        let calendar = Calendar.current
        let now = Date()
        let thisYear = calendar.component(.year, from: now)
        let thisMonth = calendar.component(.month, from: now)
        
        let prevMonth = thisMonth == 1 ? 12 : thisMonth - 1
        let prevYear = thisMonth == 1 ? thisYear - 1 : thisYear
        
        let nextMonth = thisMonth == 12 ? 1 : thisMonth + 1
        let nextYear = thisMonth == 12 ? thisYear + 1 : thisYear
        
        // 先月のシフト
        let htmlPrev = try await fetchShiftPage(year: prevYear, month: prevMonth)
        let shiftsPrev = try ShiftParser.parseShifts(html: htmlPrev)
        print("先月のシフト件数: \(shiftsPrev.count)")
        
        // 今月のシフト
        let htmlThis = try await fetchShiftPage(year: thisYear, month: thisMonth)
        let shiftsThis = try ShiftParser.parseShifts(html: htmlThis)
        print("今月のシフト件数: \(shiftsThis.count)")
        
        // 来月のシフト
        let htmlNext = try await fetchShiftPage(year: nextYear, month: nextMonth)
        let shiftsNext = try ShiftParser.parseShifts(html: htmlNext)
        print("来月のシフト件数: \(shiftsNext.count)")
        
        let allShifts = shiftsPrev + shiftsThis + shiftsNext
        print("合計シフト件数: \(allShifts.count)")
        
        return allShifts
    }
    
    /// 指定した年月のシフトを取得（複数月対応）
    func fetchShiftsForMonths(_ months: [(year: Int, month: Int)]) async throws -> [Shift] {
        var allShifts: [Shift] = []
        for (year, month) in months {
            let html = try await fetchShiftPage(year: year, month: month)
            let shifts = try ShiftParser.parseShifts(html: html)
            print("\(year)年\(month)月のシフト件数: \(shifts.count)")
            allShifts.append(contentsOf: shifts)
        }
        return allShifts
    }
}

enum ShiftWebError: Error, LocalizedError {
    case loginFailed
    case fetchFailed(year: Int, month: Int)
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .loginFailed:
            return "ShiftWebへのログインに失敗しました"
        case .fetchFailed(let year, let month):
            return "\(year)年\(month)月のシフト取得に失敗しました"
        case .parseFailed(let reason):
            return "シフトの解析に失敗しました: \(reason)"
        }
    }
}

private extension String {
    var urlEncoded: String {
        self.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
