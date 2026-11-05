import Foundation
import Security

struct StoredCredentials {
    let username: String
    let password: String
    let portalURL: String
}

enum KeychainServiceError: LocalizedError {
    case operationFailed(OSStatus)
    case invalidStoredCredentials

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain işlemi başarısız: \(message ?? "bilinmeyen hata")"
        case .invalidStoredCredentials:
            return "Keychain'deki giriş bilgileri okunamadı"
        }
    }
}

struct KeychainService {
    private let service = "com.gokturk.GokturkOBS.credentials"
    private let activeAccountKey = "activeCredentialAccount"

    func save(username: String, password: String, portalURL: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainServiceError.invalidStoredCredentials
        }

        let accountKey = "\(portalURL)|\(username)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainServiceError.operationFailed(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainServiceError.operationFailed(status)
        }

        UserDefaults.standard.set(accountKey, forKey: activeAccountKey)
    }

    func load() throws -> StoredCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        if let activeAccount = UserDefaults.standard.string(forKey: activeAccountKey) {
            query[kSecAttrAccount as String] = activeAccount
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainServiceError.operationFailed(status)
        }
        guard let item = result as? [String: Any],
              let accountKey = item[kSecAttrAccount as String] as? String,
              let passwordData = item[kSecValueData as String] as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            throw KeychainServiceError.invalidStoredCredentials
        }
        let separator = accountKey.lastIndex(of: "|")
        let portalURL = separator.map { String(accountKey[..<$0]) } ?? (UserDefaults.standard.string(forKey: "portalBaseURL") ?? "https://tedemkolejiobs.com")
        let username = separator.map { String(accountKey[accountKey.index(after: $0)...]) } ?? accountKey
        return StoredCredentials(username: username, password: password, portalURL: portalURL)
    }

    func delete() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let activeAccount = UserDefaults.standard.string(forKey: activeAccountKey) {
            query[kSecAttrAccount as String] = activeAccount
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.operationFailed(status)
        }
        UserDefaults.standard.removeObject(forKey: activeAccountKey)
    }
}
