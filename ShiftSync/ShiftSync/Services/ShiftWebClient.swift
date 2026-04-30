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
    func login(id: String, password: String, logger: SyncRunLogger? = nil) async throws {
        logger?.recordLoginStart()

        do {
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

            let body = "id=\(id.formURLEncoded)&password=\(password.formURLEncoded)&savelogin=1"
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode < 400 else {
                throw ShiftWebError.loginFailed
            }

            let responseText = String(data: data, encoding: .utf8) ?? ""
            print("login API response: \(responseText)")

            guard let loginResponse = try? JSONDecoder().decode(ShiftWebLoginResponse.self, from: data) else {
                throw ShiftWebError.loginFailed
            }

            guard loginResponse.cookie == true else {
                throw ShiftWebError.authenticationFailed(ShiftWebPageInspector.sanitizedMessage(loginResponse.msg))
            }

            logger?.recordLoginSuccess(cookie: loginResponse.cookie)
        } catch {
            logger?.recordLoginFailure(error)
            throw error
        }
    }

    /// 指定月のシフトページを取得
    /// Go版: fetchShiftPageForMonth (main.go:709-738)
    func fetchShiftPage(year: Int, month: Int) async throws -> String {
        try await fetchShiftPageResult(year: year, month: month).html
    }

    func fetchShiftPageResult(year: Int, month: Int, logger: SyncRunLogger? = nil) async throws -> ShiftPageFetchResult {
        let date2 = String(format: "%04d-%02d", year, month)
        var components = URLComponents(string: shiftURL)!
        components.queryItems = [
            URLQueryItem(name: "mod", value: "look"),
            URLQueryItem(name: "date2", value: date2)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(shiftURL, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""
            let diagnostics = ShiftWebPageInspector.diagnostics(for: html)
            let finalURL = response.url?.absoluteString

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode < 400 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let error = ShiftWebError.fetchFailed(year: year, month: month)
                logger?.recordMonthFetchFailure(
                    year: year,
                    month: month,
                    httpStatus: statusCode,
                    finalURL: finalURL,
                    diagnostics: diagnostics,
                    error: error
                )
                throw error
            }

            print("shift status (\(date2)): \(httpResponse.statusCode)")

            if diagnostics.pageKind == .loginPage {
                let error = ShiftWebError.authenticationFailed("ShiftWebの認証が無効です。設定から再ログインしてください。")
                logger?.recordMonthFetchFailure(
                    year: year,
                    month: month,
                    httpStatus: httpResponse.statusCode,
                    finalURL: finalURL,
                    diagnostics: diagnostics,
                    error: error
                )
                throw error
            }

            logger?.recordMonthFetchSuccess(
                year: year,
                month: month,
                httpStatus: httpResponse.statusCode,
                finalURL: finalURL,
                diagnostics: diagnostics
            )

            return ShiftPageFetchResult(
                year: year,
                month: month,
                html: html,
                httpStatus: httpResponse.statusCode,
                finalURL: finalURL,
                diagnostics: diagnostics
            )
        } catch {
            if !(error is ShiftWebError) {
                logger?.recordMonthFetchFailure(
                    year: year,
                    month: month,
                    httpStatus: nil,
                    finalURL: components.url?.absoluteString,
                    diagnostics: nil,
                    error: error
                )
            }
            throw error
        }
    }

    /// 先月・今月・来月のシフトを取得
    func fetchCurrentAndNextMonthShifts(logger: SyncRunLogger? = nil) async throws -> [Shift] {
        let calendar = Calendar.current
        let now = Date()
        let thisYear = calendar.component(.year, from: now)
        let thisMonth = calendar.component(.month, from: now)

        let prevMonth = thisMonth == 1 ? 12 : thisMonth - 1
        let prevYear = thisMonth == 1 ? thisYear - 1 : thisYear

        let nextMonth = thisMonth == 12 ? 1 : thisMonth + 1
        let nextYear = thisMonth == 12 ? thisYear + 1 : thisYear

        // サーバー負荷を抑えるため、3ヶ月分は意図的に直列取得する（並列リクエストしない）
        // 先月のシフト
        let shiftsPrev = try await fetchAndParseMonth(year: prevYear, month: prevMonth, logger: logger)
        print("先月のシフト件数: \(shiftsPrev.count)")

        // 今月のシフト
        let shiftsThis = try await fetchAndParseMonth(year: thisYear, month: thisMonth, logger: logger)
        print("今月のシフト件数: \(shiftsThis.count)")

        // 来月のシフト
        let shiftsNext = try await fetchAndParseMonth(year: nextYear, month: nextMonth, logger: logger)
        print("来月のシフト件数: \(shiftsNext.count)")

        let allShifts = shiftsPrev + shiftsThis + shiftsNext
        print("合計シフト件数: \(allShifts.count)")

        return allShifts
    }

    /// 指定した年月のシフトを取得（複数月対応）
    func fetchShiftsForMonths(_ months: [(year: Int, month: Int)], logger: SyncRunLogger? = nil) async throws -> [Shift] {
        var allShifts: [Shift] = []
        // 負荷集中を避けるため、複数月指定でも1ヶ月ずつ順番に取得する
        for (year, month) in months {
            let shifts = try await fetchAndParseMonth(year: year, month: month, logger: logger)
            print("\(year)年\(month)月のシフト件数: \(shifts.count)")
            allShifts.append(contentsOf: shifts)
        }
        return allShifts
    }

    private func fetchAndParseMonth(year: Int, month: Int, logger: SyncRunLogger?) async throws -> [Shift] {
        let page = try await fetchShiftPageResult(year: year, month: month, logger: logger)
        do {
            let shifts = try ShiftParser.parseShifts(html: page.html, year: year, month: month)
            logger?.recordMonthParseSuccess(year: year, month: month, shiftCount: shifts.count)
            return shifts
        } catch {
            logger?.recordMonthParseFailure(
                year: year,
                month: month,
                diagnostics: page.diagnostics,
                error: error
            )
            throw error
        }
    }
}

enum ShiftWebError: Error, LocalizedError {
    case loginFailed
    case authenticationFailed(String?)
    case fetchFailed(year: Int, month: Int)
    case parseFailed(String)
    case monthParseFailed(year: Int, month: Int, reason: String, diagnostics: ShiftPageDiagnostics)

    var requiresReauthentication: Bool {
        switch self {
        case .authenticationFailed:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .loginFailed:
            return "ログインに失敗しました。再ログインしてください。"
        case .authenticationFailed(let message):
            let base = "ログインに失敗しました。再ログインしてください。"
            guard let message, !message.isEmpty else {
                return base
            }
            return "\(base)\n\(message)"
        case .fetchFailed(let year, let month):
            return "\(year)年\(month)月のシフト取得に失敗しました"
        case .parseFailed(let reason):
            return "シフトの解析に失敗しました: \(reason)"
        case .monthParseFailed(let year, let month, let reason, _):
            return "\(year)年\(month)月のシフト解析に失敗しました: \(reason)"
        }
    }
}

struct ShiftPageFetchResult {
    let year: Int
    let month: Int
    let html: String
    let httpStatus: Int
    let finalURL: String?
    let diagnostics: ShiftPageDiagnostics
}

private struct ShiftWebLoginResponse: Decodable {
    let msg: String?
    let cookie: Bool?
}

enum ShiftWebPageInspector {
    static func isLoginPageHTML(_ html: String) -> Bool {
        html.contains("id=\"loginBody\"") ||
        html.contains("id=\"loginForm2\"") ||
        html.contains("ログインv2")
    }

    static func diagnostics(for html: String) -> ShiftPageDiagnostics {
        let htmlSize = html.utf8.count
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ShiftPageDiagnostics(
                pageKind: .emptyPage,
                hasShiftTable: false,
                headerText: nil,
                titleText: nil,
                htmlSize: htmlSize
            )
        }

        let doc = try? SwiftSoup.parse(html)
        let hasShiftTable: Bool
        let headerText: String?
        let titleText: String?
        if let doc {
            hasShiftTable = (try? doc.select("table#shiftTable").first()) != nil
            headerText = try? doc.select("h3.btn-block").first()?.text()
            titleText = try? doc.select("title").first()?.text()
        } else {
            hasShiftTable = false
            headerText = nil
            titleText = nil
        }
        let pageKind: SyncPageKind
        if isLoginPageHTML(html) {
            pageKind = .loginPage
        } else if hasShiftTable {
            pageKind = .shiftPage
        } else {
            pageKind = .unknown
        }

        return ShiftPageDiagnostics(
            pageKind: pageKind,
            hasShiftTable: hasShiftTable,
            headerText: headerText,
            titleText: titleText,
            htmlSize: htmlSize
        )
    }

    static func sanitizedMessage(_ raw: String?) -> String? {
        guard var raw else { return nil }
        raw = raw.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        raw = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: "&nbsp;", with: " ")
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private extension String {
    var formURLEncoded: String {
        self.addingPercentEncoding(withAllowedCharacters: .formURLQueryAllowed) ?? self
    }
}

private extension CharacterSet {
    static let formURLQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return allowed
    }()
}
