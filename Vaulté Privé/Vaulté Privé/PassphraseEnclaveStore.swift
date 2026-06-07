//
//  PassphraseEnclaveStore.swift
//  Vaulté Privé
//

import CommonCrypto
import Foundation
import Security

/// Stores a **salted PBKDF2-SHA256 verifier** in the Keychain — never the raw passphrase.
/// Secure Enclave is not used for this flow (no SE key generation); the name reflects older intent.
/// Migrates legacy plaintext values from `UserDefaults` on first access.
enum PassphraseEnclaveStore {

    enum PassphraseStoreError: Error {
        case randomGenerationFailed
        case derivationFailed
    }

    private static let service = "com.vaulteprive.passphrase"
    private static let legacyPrimaryKey = "vaulte.passphrase.primary"
    private static let legacyPanicKey = "vaulte.passphrase.panic"

    private static let primaryAccount = "primary.pbkdf2"
    private static let panicAccount = "panic.pbkdf2"

    private static let saltLength = 16
    private static let verifyLength = 32
    private static let pbkdf2Iterations: UInt32 = 120_000

    // MARK: - Public API

    static func hasPrimaryVerifier() -> Bool {
        migrateLegacyIfNeeded()
        if keychainRead(account: primaryAccount) != nil { return true }
        let s = UserDefaults.standard.string(forKey: legacyPrimaryKey)
        return s?.isEmpty == false
    }

    static func hasPanicVerifier() -> Bool {
        migrateLegacyIfNeeded()
        if keychainRead(account: panicAccount) != nil { return true }
        let s = UserDefaults.standard.string(forKey: legacyPanicKey)
        return s?.isEmpty == false
    }

    static func savePrimaryVerifier(passphrase: String) throws {
        migrateLegacyIfNeeded()
        try saveVerifier(passphrase: passphrase, account: primaryAccount)
    }

    static func savePanicVerifier(passphrase: String) throws {
        migrateLegacyIfNeeded()
        try saveVerifier(passphrase: passphrase, account: panicAccount)
    }

    static func verifyPrimary(passphrase: String) -> Bool {
        migrateLegacyIfNeeded()
        guard let blob = keychainRead(account: primaryAccount),
              blob.count == saltLength + verifyLength else {
            // Migration not yet complete or Keychain unavailable — fail closed.
            return false
        }
        return matchesVerifier(passphrase: passphrase, blob: blob)
    }

    static func verifyPanic(passphrase: String) -> Bool {
        migrateLegacyIfNeeded()
        guard let blob = keychainRead(account: panicAccount),
              blob.count == saltLength + verifyLength else {
            return false
        }
        return matchesVerifier(passphrase: passphrase, blob: blob)
    }

    static func deleteAllVerifiers() {
        keychainDelete(account: primaryAccount)
        keychainDelete(account: panicAccount)
        UserDefaults.standard.removeObject(forKey: legacyPrimaryKey)
        UserDefaults.standard.removeObject(forKey: legacyPanicKey)
    }

    // MARK: - Core

    private static func saveVerifier(passphrase: String, account: String) throws {
        var salt = Data(count: saltLength)
        let rnd = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, base)
        }
        guard rnd == errSecSuccess else { throw PassphraseStoreError.randomGenerationFailed }

        guard let derived = pbkdf2(passphrase: passphrase, salt: salt) else {
            throw PassphraseStoreError.derivationFailed
        }

        var blob = Data()
        blob.append(salt)
        blob.append(derived)
        keychainWrite(data: blob, account: account)
    }

    private static func matchesVerifier(passphrase: String, blob: Data) -> Bool {
        let salt = blob.prefix(saltLength)
        let expected = blob.suffix(verifyLength)
        guard let derived = pbkdf2(passphrase: passphrase, salt: Data(salt)) else { return false }
        return derived == expected
    }

    private static func pbkdf2(passphrase: String, salt: Data) -> Data? {
        let passwordData = Data(passphrase.utf8)
        var derived = Data(count: verifyLength)
        let status: Int32 = derived.withUnsafeMutableBytes { dBuf in
            guard let dBase = dBuf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return salt.withUnsafeBytes { sBuf in
                guard let sBase = sBuf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return passwordData.withUnsafeBytes { pBuf in
                    guard let pBase = pBuf.bindMemory(to: Int8.self).baseAddress else { return -1 }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pBase,
                        passwordData.count,
                        sBase,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        dBase,
                        verifyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    // MARK: - Legacy UserDefaults migration

    private static func migrateLegacyIfNeeded() {
        migrateLegacyPrimary()
        migrateLegacyPanic()
    }

    private static func migrateLegacyPrimary() {
        if keychainRead(account: primaryAccount) != nil {
            UserDefaults.standard.removeObject(forKey: legacyPrimaryKey)
            return
        }
        guard let plain = UserDefaults.standard.string(forKey: legacyPrimaryKey),
              !plain.isEmpty else { return }
        do {
            try saveVerifier(passphrase: plain, account: primaryAccount)
            UserDefaults.standard.removeObject(forKey: legacyPrimaryKey)
        } catch {
            // Keep legacy until migration succeeds.
        }
    }

    private static func migrateLegacyPanic() {
        if keychainRead(account: panicAccount) != nil {
            UserDefaults.standard.removeObject(forKey: legacyPanicKey)
            return
        }
        guard let plain = UserDefaults.standard.string(forKey: legacyPanicKey),
              !plain.isEmpty else { return }
        do {
            try saveVerifier(passphrase: plain, account: panicAccount)
            UserDefaults.standard.removeObject(forKey: legacyPanicKey)
        } catch {
            // Keep legacy until migration succeeds.
        }
    }

    // MARK: - Keychain

    private static func keychainWrite(data: Data, account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        insert[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func keychainRead(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
