import CryptoKit
import Foundation
import Security

enum IdentityKeyError: Error {
    case invalidPublicKey
    case keychainFailure(status: OSStatus)
}

enum LocalIdentityStore {
    private static let service = "com.vaulteprive.identity"
    private static let account = "local_user_id"

    private static let identityKeyAccount = "identity_key"
    private static let signedPrekeyAccount = "signed_prekey"
    private static let oneTimePrekeysAccount = "one_time_prekeys"
    private static let signingKeyAccount = "signing_key_ed25519"

    // MARK: Ed25519 signing key (signs the signed-prekey)

    static func loadSigningKey() -> Curve25519.Signing.PrivateKey? {
        guard let data = try? readData(account: signingKeyAccount),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        else { return nil }
        return key
    }

    static func saveSigningKey(_ key: Curve25519.Signing.PrivateKey) throws {
        try writeData(key.rawRepresentation, account: signingKeyAccount)
    }

    static func deleteSigningKey() {
        delete(account: signingKeyAccount)
    }

    // MARK: TOFU — peer identity key pinning (Keychain-backed)
    // Stored in Keychain rather than UserDefaults to prevent leakage via unencrypted iCloud/local backups.

    private static let tofuService = "com.vaulteprive.tofu"
    private static let tofuAccount = "peer_pins_v1"

    private static func loadTOFUDict() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tofuService,
            kSecAttrAccount as String: tofuAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveTOFUDict(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tofuService,
            kSecAttrAccount as String: tofuAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        var insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tofuService,
            kSecAttrAccount as String: tofuAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        insert[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemAdd(insert as CFDictionary, nil)
    }

    /// Returns the previously pinned identity public key (Base64) for a peer, or nil if not yet seen.
    static func pinnedPeerIdentityKey(for userId: UUID) -> String? {
        loadTOFUDict()[userId.uuidString.lowercased()]
    }

    /// Pins a peer's identity key. Overwrites any existing pin.
    static func pinPeerIdentityKey(_ b64: String, for userId: UUID) {
        var dict = loadTOFUDict()
        dict[userId.uuidString.lowercased()] = b64
        saveTOFUDict(dict)
    }

    /// Checks the TOFU pin for a peer. Returns `false` if the key matches (or is first-seen and pinned).
    /// Returns `true` if a mismatch is detected — caller should alert the user.
    @discardableResult
    static func checkAndUpdateTOFU(userId: UUID, publicKeyBase64: String) -> Bool {
        if let existing = pinnedPeerIdentityKey(for: userId) {
            return existing != publicKeyBase64
        }
        pinPeerIdentityKey(publicKeyBase64, for: userId)
        return false
    }

    /// Clears all pinned peer identity keys so a fresh account reset does not inherit old TOFU state.
    static func clearAllTOFUPins() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tofuService,
            kSecAttrAccount as String: tofuAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: User ID

    static func readOrCreateUserID() throws -> UUID {
        if let existing = readUserIDIfPresent() { return existing }
        let fresh = UUID()
        try saveUserID(fresh)
        return fresh
    }

    static func readUserIDIfPresent() -> UUID? {
        guard let data = try? readData(account: account),
              let s = String(data: data, encoding: .utf8),
              let u = UUID(uuidString: s)
        else { return nil }
        return u
    }

    static func saveUserID(_ id: UUID) throws {
        try writeData(Data(id.uuidString.utf8), account: account)
    }

    static func deleteUserID() {
        delete(account: account)
    }

    // MARK: Identity key

    static func loadIdentityKey() -> IdentityKeyPair? {
        guard let data = try? readData(account: identityKeyAccount) else { return nil }
        return try? JSONDecoder().decode(IdentityKeyPair.self, from: data)
    }

    static func saveIdentityKey(_ keyPair: IdentityKeyPair) throws {
        let data = try JSONEncoder().encode(keyPair)
        try writeData(data, account: identityKeyAccount)
    }

    static func deleteIdentityKey() {
        delete(account: identityKeyAccount)
    }

    // MARK: Signed prekey

    static func loadSignedPrekey() -> SignedPreKeyPair? {
        guard let data = try? readData(account: signedPrekeyAccount) else { return nil }
        return try? JSONDecoder().decode(SignedPreKeyPair.self, from: data)
    }

    static func saveSignedPrekey(_ keyPair: SignedPreKeyPair) throws {
        let data = try JSONEncoder().encode(keyPair)
        try writeData(data, account: signedPrekeyAccount)
    }

    static func deleteSignedPrekey() {
        delete(account: signedPrekeyAccount)
    }

    // MARK: One-time prekeys

    static func loadOneTimePrekeys() -> [OneTimePreKeyPair] {
        guard let data = try? readData(account: oneTimePrekeysAccount) else { return [] }
        return (try? JSONDecoder().decode([OneTimePreKeyPair].self, from: data)) ?? []
    }

    static func saveOneTimePrekeys(_ keyPairs: [OneTimePreKeyPair]) throws {
        let data = try JSONEncoder().encode(keyPairs)
        try writeData(data, account: oneTimePrekeysAccount)
    }

    static func loadOneTimePrekey(id: Int) -> OneTimePreKeyPair? {
        loadOneTimePrekeys().first { $0.keyId == id }
    }

    @discardableResult
    static func consumeOneTimePrekey(id: Int) throws -> OneTimePreKeyPair? {
        var all = loadOneTimePrekeys()
        guard let index = all.firstIndex(where: { $0.keyId == id }) else { return nil }
        let key = all.remove(at: index)
        try saveOneTimePrekeys(all)
        return key
    }

    static func deleteAllX3DHKeys() {
        deleteIdentityKey()
        deleteSignedPrekey()
        deleteSigningKey()
        delete(account: oneTimePrekeysAccount)
    }

    // MARK: Keychain helpers

    private static func readData(account: String) throws -> Data {
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
            throw IdentityKeyError.keychainFailure(status: status)
        }
        return data
    }

    private static func writeData(_ data: Data, account: String) throws {
        delete(account: account)

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

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityKeyError.keychainFailure(status: status)
        }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}