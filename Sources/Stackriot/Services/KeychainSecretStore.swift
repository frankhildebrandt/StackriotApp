import Foundation
import Security

enum KeychainSecretStore {
    static let jiraService = "Stackriot.Jira"
    static let jiraTokenAccount = "api-token"

    static func storeString(_ value: String, service: String, account: String) throws {
        try store(Data(value.utf8), service: service, account: account)
    }

    static func loadString(service: String, account: String) throws -> String {
        let data = try load(service: service, account: account)
        guard let value = String(data: data, encoding: .utf8) else {
            throw StackriotError.keyMaterialInvalid
        }
        return value
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func store(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw StackriotError.keyMaterialInvalid
            }
            return
        }

        guard status == errSecSuccess else {
            throw StackriotError.keyMaterialInvalid
        }
    }

    private static func load(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw StackriotError.keyMaterialInvalid
        }
        return data
    }
}
