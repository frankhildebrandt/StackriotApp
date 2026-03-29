import Foundation
import Security
enum KeychainSSHKeyStore {
    static let service = "DevVault.SSHKeys"

    static func store(privateKeyData: Data, reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecValueData as String: privateKeyData,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: reference,
            ]
            let attributes: [String: Any] = [kSecValueData as String: privateKeyData]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw DevVaultError.keyMaterialInvalid
            }
            return
        }

        guard status == errSecSuccess else {
            throw DevVaultError.keyMaterialInvalid
        }
    }

    static func load(reference: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw DevVaultError.keyMaterialInvalid
        }
        return data
    }

    static func delete(reference: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
