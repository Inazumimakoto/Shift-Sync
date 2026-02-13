import Foundation
import Security

class KeychainService {
    static let shared = KeychainService()
    
    private let webService = "shift-sync-ams"
    private let icloudService = "shift-sync-icloud"
    private let sharedGroupSuffix = "com.inazumimakoto.shiftsync.shared"
    private let legacySharedAccessGroup = "V7XG8HDQL4.com.inazumimakoto.shiftsync.shared"
    
    private init() {}
    
    // MARK: - ShiftWeb Credentials
    
    func saveShiftWebCredentials(id: String, password: String) throws {
        try saveCredentials(service: webService, account: id, password: password)
    }
    
    func getShiftWebCredentials() throws -> (id: String, password: String) {
        try getCredentialsPreferringShared(service: webService)
    }
    
    func deleteShiftWebCredentials() throws {
        try deleteCredentials(service: webService)
    }
    
    // MARK: - iCloud Credentials
    
    func saveICloudCredentials(appleId: String, appPassword: String) throws {
        try saveCredentials(service: icloudService, account: appleId, password: appPassword)
    }
    
    func getICloudCredentials() throws -> (appleId: String, appPassword: String) {
        let credentials = try getCredentialsPreferringShared(service: icloudService)
        return (credentials.id, credentials.password)
    }

    /// 旧バージョンで保存した認証情報を共有アクセスグループへ移行
    func migrateLegacyCredentialsToShared() {
        migrateServiceToShared(webService)
        migrateServiceToShared(icloudService)
    }
    
    // MARK: - Generic Keychain Operations
    
    private func migrateServiceToShared(_ service: String) {
        if sharedAccessGroups.contains(where: { (try? getCredentials(service: service, accessGroup: $0)) != nil }) {
            return
        }
        if let legacy = try? getCredentials(service: service, accessGroup: nil) {
            for accessGroup in sharedAccessGroups {
                try? save(service: service, account: legacy.id, password: legacy.password, accessGroup: accessGroup)
            }
        }
    }

    private var sharedAccessGroups: [String] {
        var groups: [String] = []
        if let prefix = appIdentifierPrefix {
            groups.append("\(prefix)\(sharedGroupSuffix)")
        }
        groups.append(legacySharedAccessGroup)
        var seen = Set<String>()
        return groups.filter { seen.insert($0).inserted }
    }

    private var appIdentifierPrefix: String? {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String {
            return prefix
        }
        if let prefixes = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? [String],
           let first = prefixes.first {
            return first
        }
        return nil
    }

    private func saveCredentials(service: String, account: String, password: String) throws {
        var sharedSaveError: Error?
        var savedToShared = false

        for accessGroup in sharedAccessGroups {
            do {
                try save(service: service, account: account, password: password, accessGroup: accessGroup)
                savedToShared = true
                break
            } catch {
                sharedSaveError = error
            }
        }

        do {
            try save(service: service, account: account, password: password, accessGroup: nil)
        } catch {
            if !savedToShared {
                throw sharedSaveError ?? error
            }
        }

        if !savedToShared, let sharedSaveError {
            throw sharedSaveError
        }
    }

    private func getCredentialsPreferringShared(service: String) throws -> (id: String, password: String) {
        for accessGroup in sharedAccessGroups {
            if let shared = try? getCredentials(service: service, accessGroup: accessGroup) {
                return shared
            }
        }

        if let legacy = try? getCredentials(service: service, accessGroup: nil) {
            for accessGroup in sharedAccessGroups {
                try? save(service: service, account: legacy.id, password: legacy.password, accessGroup: accessGroup)
            }
            return legacy
        }

        throw KeychainError.notFound
    }

    private func deleteCredentials(service: String) throws {
        for accessGroup in sharedAccessGroups {
            try? delete(service: service, accessGroup: accessGroup)
        }
        try delete(service: service, accessGroup: nil)
    }

    private func getCredentials(service: String, accessGroup: String?) throws -> (id: String, password: String) {
        let accounts = try getAccounts(service: service, accessGroup: accessGroup)
        guard let account = accounts.first else {
            throw KeychainError.notFound
        }
        let password = try getPassword(service: service, account: account, accessGroup: accessGroup)
        return (account, password)
    }

    private func save(service: String, account: String, password: String, accessGroup: String?) throws {
        let passwordData = password.data(using: .utf8)!
        
        // 既存のエントリを削除
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            deleteQuery[kSecAttrAccessGroup as String] = accessGroup
        }
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 新しいエントリを追加
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let accessGroup {
            addQuery[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    private func getPassword(service: String, account: String, accessGroup: String?) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        
        return password
    }
    
    private func getAccounts(service: String, accessGroup: String?) throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return []
        }
        
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw KeychainError.readFailed(status)
        }
        
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
    
    private func delete(service: String, accessGroup: String?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case notFound
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .notFound:
            return "キーチェーンに認証情報が見つかりません"
        case .saveFailed(let status):
            return "キーチェーンへの保存に失敗しました (status: \(status))"
        case .readFailed(let status):
            return "キーチェーンからの読み込みに失敗しました (status: \(status))"
        case .deleteFailed(let status):
            return "キーチェーンからの削除に失敗しました (status: \(status))"
        }
    }
}
