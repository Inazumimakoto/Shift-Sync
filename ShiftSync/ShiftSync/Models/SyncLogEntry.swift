import Foundation

/// 同期ソースの種類
enum SyncSource: String, Codable, CaseIterable {
    case manual = "手動"
    case background = "バックグラウンド"
    case automation = "オートメーション"
    
    var icon: String {
        switch self {
        case .manual: return "hand.tap"
        case .background: return "arrow.clockwise.circle"
        case .automation: return "clock.arrow.circlepath"
        }
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
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: SyncSource,
        result: SyncResultSummary,
        success: Bool = true,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.result = result
        self.success = success
        self.errorMessage = errorMessage
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
}
