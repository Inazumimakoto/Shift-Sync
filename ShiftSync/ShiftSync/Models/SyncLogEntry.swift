import Foundation

/// 同期ソースの種類
enum SyncSource: String, Codable, CaseIterable {
    case manualButton = "手動ボタン"
    case launchAuto = "起動時自動"
    case reloginRetry = "再ログイン後"
    case initialSetup = "初期設定完了時"
    case settings = "設定画面"
    case widgetButton = "ウィジェットボタン"
    case shortcut = "ショートカット"
    case urlScheme = "URLスキーム"
    case manual = "手動"
    case background = "バックグラウンド"
    case automation = "オートメーション"
    case fullHistory = "全履歴同期"
    
    var icon: String {
        switch self {
        case .manualButton, .manual: return "hand.tap"
        case .launchAuto: return "arrow.clockwise"
        case .reloginRetry: return "person.crop.circle.badge.checkmark"
        case .initialSetup: return "checkmark.seal"
        case .settings: return "gearshape"
        case .widgetButton: return "square.grid.2x2"
        case .shortcut, .automation: return "clock.arrow.circlepath"
        case .urlScheme: return "link"
        case .background: return "arrow.clockwise.circle"
        case .fullHistory: return "calendar.badge.clock"
        }
    }
}

enum SyncPhase: String, Codable, Equatable {
    case start
    case login
    case fetchMonth
    case parseMonth
    case calendarSync
    case saveStorage
    case fullHistory
    case finish
    case unknown

    var label: String {
        switch self {
        case .start: return "開始"
        case .login: return "ログイン"
        case .fetchMonth: return "シフト取得"
        case .parseMonth: return "解析"
        case .calendarSync: return "カレンダー同期"
        case .saveStorage: return "保存"
        case .fullHistory: return "全履歴同期"
        case .finish: return "終了"
        case .unknown: return "不明"
        }
    }
}

enum SyncStepStatus: String, Codable, Equatable {
    case info
    case started
    case success
    case failure

    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .started: return "circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }
}

enum SyncPageKind: String, Codable, Equatable {
    case loginPage
    case shiftPage
    case emptyPage
    case unknown

    var label: String {
        switch self {
        case .loginPage: return "ログインページ"
        case .shiftPage: return "シフトページ"
        case .emptyPage: return "空のページ"
        case .unknown: return "不明"
        }
    }
}

struct SyncMonth: Codable, Hashable, Equatable, Identifiable {
    let year: Int
    let month: Int

    var id: String { key }
    var key: String { String(format: "%04d-%02d", year, month) }
    var label: String { "\(year)年\(month)月" }
}

struct ShiftPageDiagnostics: Codable, Equatable {
    let pageKind: SyncPageKind
    let hasShiftTable: Bool
    let headerText: String?
    let titleText: String?
    let htmlSize: Int
}

struct SyncMonthLog: Codable, Equatable, Identifiable {
    let id: UUID
    let month: SyncMonth
    var httpStatus: Int?
    var finalURL: String?
    var htmlSize: Int?
    var pageKind: SyncPageKind?
    var hasShiftTable: Bool?
    var headerText: String?
    var fetchSucceeded: Bool?
    var parseSucceeded: Bool?
    var shiftCount: Int?
    var errorMessage: String?

    init(id: UUID = UUID(), month: SyncMonth) {
        self.id = id
        self.month = month
    }
}

struct SyncLogStep: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let phase: SyncPhase
    let status: SyncStepStatus
    let message: String
    let month: SyncMonth?
    let httpStatus: Int?
    let finalURL: String?
    let htmlSize: Int?
    let pageKind: SyncPageKind?
    let hasShiftTable: Bool?
    let headerText: String?
    let shiftCount: Int?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        phase: SyncPhase,
        status: SyncStepStatus,
        message: String,
        month: SyncMonth? = nil,
        httpStatus: Int? = nil,
        finalURL: String? = nil,
        htmlSize: Int? = nil,
        pageKind: SyncPageKind? = nil,
        hasShiftTable: Bool? = nil,
        headerText: String? = nil,
        shiftCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.date = date
        self.phase = phase
        self.status = status
        self.message = message
        self.month = month
        self.httpStatus = httpStatus
        self.finalURL = finalURL
        self.htmlSize = htmlSize
        self.pageKind = pageKind
        self.hasShiftTable = hasShiftTable
        self.headerText = headerText
        self.shiftCount = shiftCount
        self.errorMessage = errorMessage
    }
}

/// 同期結果のサマリー（Codable用）
struct SyncResultSummary: Codable, Equatable {
    let added: Int
    let updated: Int
    let deleted: Int
    
    var hasChanges: Bool {
        added > 0 || updated > 0 || deleted > 0
    }
    
    var shortDescription: String {
        if !hasChanges {
            return "変更なし"
        }
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if updated > 0 { parts.append("↻\(updated)") }
        if deleted > 0 { parts.append("-\(deleted)") }
        return parts.joined(separator: " ")
    }
}

/// 同期履歴のエントリ
struct SyncLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let source: SyncSource
    let result: SyncResultSummary
    let success: Bool
    let errorMessage: String?
    let runID: String?
    let startedAt: Date?
    let endedAt: Date?
    let failurePhase: SyncPhase?
    let failureMonth: SyncMonth?
    let concurrentRunIDs: [String]
    let steps: [SyncLogStep]
    let monthLogs: [SyncMonthLog]
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: SyncSource,
        result: SyncResultSummary,
        success: Bool = true,
        errorMessage: String? = nil,
        runID: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        failurePhase: SyncPhase? = nil,
        failureMonth: SyncMonth? = nil,
        concurrentRunIDs: [String] = [],
        steps: [SyncLogStep] = [],
        monthLogs: [SyncMonthLog] = []
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.result = result
        self.success = success
        self.errorMessage = errorMessage
        self.runID = runID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.failurePhase = failurePhase
        self.failureMonth = failureMonth
        self.concurrentRunIDs = concurrentRunIDs
        self.steps = steps
        self.monthLogs = monthLogs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case source
        case result
        case success
        case errorMessage
        case runID
        case startedAt
        case endedAt
        case failurePhase
        case failureMonth
        case concurrentRunIDs
        case steps
        case monthLogs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        source = try container.decodeIfPresent(SyncSource.self, forKey: .source) ?? .manual
        result = try container.decodeIfPresent(SyncResultSummary.self, forKey: .result) ?? SyncResultSummary(added: 0, updated: 0, deleted: 0)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        failurePhase = try container.decodeIfPresent(SyncPhase.self, forKey: .failurePhase)
        failureMonth = try container.decodeIfPresent(SyncMonth.self, forKey: .failureMonth)
        concurrentRunIDs = try container.decodeIfPresent([String].self, forKey: .concurrentRunIDs) ?? []
        steps = try container.decodeIfPresent([SyncLogStep].self, forKey: .steps) ?? []
        monthLogs = try container.decodeIfPresent([SyncMonthLog].self, forKey: .monthLogs) ?? []
    }
    
    /// 成功エントリを作成
    static func success(source: SyncSource, added: Int, updated: Int, deleted: Int) -> SyncLogEntry {
        SyncLogEntry(
            source: source,
            result: SyncResultSummary(added: added, updated: updated, deleted: deleted),
            success: true
        )
    }
    
    /// 失敗エントリを作成
    static func failure(source: SyncSource, error: Error) -> SyncLogEntry {
        SyncLogEntry(
            source: source,
            result: SyncResultSummary(added: 0, updated: 0, deleted: 0),
            success: false,
            errorMessage: error.localizedDescription
        )
    }
    
    // MARK: - Formatting
    
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }
    
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d(E) HH:mm"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    var displayRunID: String {
        runID ?? "旧履歴"
    }

    var durationText: String? {
        guard let startedAt, let endedAt else { return nil }
        return String(format: "%.1f秒", endedAt.timeIntervalSince(startedAt))
    }

    var failureSummary: String? {
        guard !success else { return nil }
        var parts: [String] = []
        if let failurePhase {
            parts.append(failurePhase.label)
        }
        if let failureMonth {
            parts.append(failureMonth.label)
        }
        if parts.isEmpty {
            return errorMessage
        }
        return parts.joined(separator: " / ")
    }
}
