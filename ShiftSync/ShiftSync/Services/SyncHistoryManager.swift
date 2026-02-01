import Foundation

/// 同期履歴を管理するマネージャー
/// 直近20件の履歴をUserDefaultsに保存
class SyncHistoryManager {
    static let shared = SyncHistoryManager()
    
    private let maxEntries = 20
    private let storageKey = "syncHistory"
    
    private init() {}
    
    // MARK: - Public API
    
    /// 履歴を取得（新しい順）
    func getHistory() -> [SyncLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([SyncLogEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.date > $1.date }
    }
    
    /// 成功した同期を記録
    func logSuccess(source: SyncSource, result: SyncResult) {
        let entry = SyncLogEntry.success(
            source: source,
            added: result.added,
            updated: result.updated,
            deleted: result.deleted
        )
        addEntry(entry)
    }
    
    /// 失敗した同期を記録
    func logFailure(source: SyncSource, error: Error) {
        let entry = SyncLogEntry.failure(source: source, error: error)
        addEntry(entry)
    }
    
    // MARK: - Private
    
    private func addEntry(_ entry: SyncLogEntry) {
        var entries = getHistory()
        entries.insert(entry, at: 0)
        
        // 最大件数を超えたら古いエントリを削除
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        
        saveEntries(entries)
    }
    
    private func saveEntries(_ entries: [SyncLogEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
