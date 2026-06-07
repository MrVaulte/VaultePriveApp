//
//  OTPKeychainStorage.swift
//  Vaulté Privé
//

import Foundation
import Security

/// Stores raw pad bytes in the system Keychain. Does not log payloads.
final class OTPKeychainStorage: Sendable {
    private let service: String

    init(service: String = "com.vaulteprive.otppads") {
        self.service = service
    }

    func save(padId: UUID, data: Data) throws {
        try delete(padId: padId)

        let account = padId.uuidString
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OTPError.keychainFailure(status: status)
        }
    }

    func load(padId: UUID) throws -> Data {
        let account = padId.uuidString
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
            throw OTPError.keychainFailure(status: status)
        }
        return data
    }

    func delete(padId: UUID) throws {
        let account = padId.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAllKnown(padIds: [UUID]) {
        for id in padIds {
            try? delete(padId: id)
        }
    }

    func saveData(account: String, data: Data) throws {
        try deleteData(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OTPError.keychainFailure(status: status)
        }
    }

    func loadData(account: String) throws -> Data {
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
            throw OTPError.keychainFailure(status: status)
        }
        return data
    }

    func deleteData(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
