import Foundation
import Security

class KeychainService {
    static let shared = KeychainService()
    
    private let webService = "shift-sync-ams"
    private let icloudService = "shift-sync-icloud"
    
    private init() {}
    
    // MARK: - ShiftWeb Credentials
    
    func saveShiftWebCredentials(id: String, password: String) throws {
        try save(service: webService, account: id, password: password)
    }
    
    func getShiftWebCredentials() throws -> (id: String, password: String) {
        let accounts = try getAccounts(service: webService)
        guard let account = accounts.first else {
            throw KeychainError.notFound
        }
        let password = try getPassword(service: webService, account: account)
        return (account, password)
    }
    
    func deleteShiftWebCredentials() throws {
        try delete(service: webService)
    }
    
    // MARK: - iCloud Credentials
    
    func saveICloudCredentials(appleId: String, appPassword: String) throws {
        try save(service: icloudService, account: appleId, password: appPassword)
    }
    
    func getICloudCredentials() throws -> (appleId: String, appPassword: String) {
        let accounts = try getAccounts(service: icloudService)
        guard let account = accounts.first else {
            throw KeychainError.notFound
        }
        let password = try getPassword(service: icloudService, account: account)
        return (account, password)
    }
    
    // MARK: - Generic Keychain Operations
    
    private func save(service: String, account: String, password: String) throws {
        let passwordData = password.data(using: .utf8)!
        
        // 既存のエントリを削除
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 新しいエントリを追加
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    private func getPassword(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }
        
        return password
    }
    
    private func getAccounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
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
    
    private func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        
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
