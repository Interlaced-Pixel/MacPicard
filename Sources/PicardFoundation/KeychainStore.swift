import Foundation
import Security

public actor KeychainStore {
    private let service: String

    public init(service: String = PicardLogger.subsystem) {
        self.service = service
    }

    public func data(for account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw PicardError.keychain(operation: "read", status: Int32(status))
        }

        guard let data = result as? Data else {
            throw PicardError.keychain(operation: "read invalid data", status: Int32(errSecDecode))
        }

        return data
    }

    public func set(_ data: Data, for account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw PicardError.keychain(operation: "update", status: Int32(updateStatus))
        }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: data
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        guard addStatus == errSecSuccess else {
            throw PicardError.keychain(operation: "insert", status: Int32(addStatus))
        }
    }

    public func remove(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PicardError.keychain(operation: "delete", status: Int32(status))
        }
    }
}
