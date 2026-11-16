import Foundation
import Security

public enum Keychain {
    private static let service = "app.chatslaughter.credentials"
    public static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SweepError.unavailable("Keychain: \(status)") }
        return result as? Data
    }

    public static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; values.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SweepError.unavailable("Keychain: \(added)") }
        } else if status != errSecSuccess { throw SweepError.unavailable("Keychain: \(status)") }
    }

    public static func databaseKey() throws -> Data {
        if let key = try read("database-key") { return key }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SweepError.unavailable("Не удалось создать ключ базы данных")
        }
        let key = Data(bytes); try write(key, account: "database-key"); return key
    }
}
