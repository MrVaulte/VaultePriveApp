//
//  ConversationKeyStore.swift
//  Vaulté Privé
//

import CryptoKit
import Foundation
import Security

/// Keychain-backed store for per-conversation cryptographic material:
///   • Legacy AES-256 symmetric key (e1: messages)
///   • Double-Ratchet session state as JSON (e2: messages)
enum ConversationKeyStore {

    // ── AES key (e1:) ─────────────────────────────────────────
    private static let aesService     = "com.vaulteprive.convkey"
    // ── Ratchet state (e2:) ───────────────────────────────────
    private static let ratchetService = "com.vaulteprive.ratchet"
    // ── E2E+ outer contexts ───────────────────────────────────
    private static let e2ePlusService = "com.vaulteprive.e2eplus"

    struct E2EPlusContext: Codable, Sendable, Equatable {
        let contextId: UUID
        let conversationId: UUID
        let keyBase64: String
        let createdAt: Date

        var keyData: Data? { Data(base64Encoded: keyBase64) }
    }

    // MARK: - AES-256 key (legacy / fallback)

    static func save(key: SymmetricKey, for conversationId: UUID) {
        let account  = conversationId.uuidString.lowercased()
        let keyData  = key.withUnsafeBytes { Data($0) }
        keychainWrite(data: keyData, service: aesService, account: account)
    }

    /// Save an AES key and simultaneously register the peer→conversation index.
    static func save(key: SymmetricKey, for conversationId: UUID, peer peerId: UUID) {
        save(key: key, for: conversationId)
        registerConversation(conversationId, forPeer: peerId)
    }

    static func load(for conversationId: UUID) -> SymmetricKey? {
        let account = conversationId.uuidString.lowercased()
        guard let data = keychainRead(service: aesService, account: account),
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func delete(for conversationId: UUID) {
        keychainDelete(service: aesService, account: conversationId.uuidString.lowercased())
    }

    // MARK: - Double-Ratchet session state

    static func saveRatchetState(_ state: VaulteRatchetState, for conversationId: UUID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let account = "ratchet.\(conversationId.uuidString.lowercased())"
        keychainWrite(data: data, service: ratchetService, account: account)
    }

    static func loadRatchetState(for conversationId: UUID) -> VaulteRatchetState? {
        let account = "ratchet.\(conversationId.uuidString.lowercased())"
        guard let data = keychainRead(service: ratchetService, account: account) else { return nil }
        return try? JSONDecoder().decode(VaulteRatchetState.self, from: data)
    }

    static func deleteRatchetState(for conversationId: UUID) {
        keychainDelete(service: ratchetService,
                       account: "ratchet.\(conversationId.uuidString.lowercased())")
    }

    static func deleteAll() {
        keychainDeleteAll(service: aesService)
        keychainDeleteAll(service: ratchetService)
        keychainDeleteAll(service: e2ePlusService)
        keychainDeleteAll(service: peerIndexService)
    }

    // MARK: - Peer → Conversation index
    // Stores a local mapping of peerId → conversationId so that incoming calls
    // can look up the conversation key without trusting the caller-supplied conversationId.

    private static let peerIndexService = "com.vaulteprive.peerconv"

    /// Record that a conversation belongs to a specific peer (call once when key material is first established).
    static func registerConversation(_ conversationId: UUID, forPeer peerId: UUID) {
        keychainWrite(
            data: Data(conversationId.uuidString.lowercased().utf8),
            service: peerIndexService,
            account: peerId.uuidString.lowercased()
        )
    }

    /// Returns the locally-known conversationId for a peer, or nil if not registered.
    static func conversationId(forPeer peerId: UUID) -> UUID? {
        guard let data = keychainRead(service: peerIndexService, account: peerId.uuidString.lowercased()),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: str)
    }

    // MARK: - E2E+ outer context

    @discardableResult
    static func ensureActiveE2EPlusContext(for conversationId: UUID) throws -> E2EPlusContext {
        if let existing = loadActiveE2EPlusContext(for: conversationId) {
            return existing
        }
        let keyData = try SecureRandom.bytes(count: 32)
        let key = keyData.base64EncodedString()
        let context = E2EPlusContext(
            contextId: UUID(),
            conversationId: conversationId,
            keyBase64: key,
            createdAt: Date()
        )
        saveE2EPlusContext(context)
        keychainWrite(
            data: Data(context.contextId.uuidString.lowercased().utf8),
            service: e2ePlusService,
            account: "active.\(conversationId.uuidString.lowercased())"
        )
        return context
    }

    static func activateDerivedE2EPlusContext(for conversationId: UUID, seed: Data) -> E2EPlusContext {
        let keyMaterial = Data("vaulte.e2eplus.outer.key".utf8) + seed + Data(conversationId.uuidString.lowercased().utf8)
        let idMaterial = Data("vaulte.e2eplus.outer.id".utf8) + seed + Data(conversationId.uuidString.lowercased().utf8)
        let key = Data(SHA256.hash(data: keyMaterial)).base64EncodedString()
        let context = E2EPlusContext(
            contextId: uuidFromHash(Data(SHA256.hash(data: idMaterial))),
            conversationId: conversationId,
            keyBase64: key,
            createdAt: Date()
        )
        saveE2EPlusContext(context)
        keychainWrite(
            data: Data(context.contextId.uuidString.lowercased().utf8),
            service: e2ePlusService,
            account: "active.\(conversationId.uuidString.lowercased())"
        )
        return context
    }

    static func loadActiveE2EPlusContext(for conversationId: UUID) -> E2EPlusContext? {
        let account = "active.\(conversationId.uuidString.lowercased())"
        guard let data = keychainRead(service: e2ePlusService, account: account),
              let raw = String(data: data, encoding: .utf8),
              let contextId = UUID(uuidString: raw)
        else { return nil }
        return loadE2EPlusContext(id: contextId)
    }

    static func loadE2EPlusContext(id: UUID) -> E2EPlusContext? {
        let account = "ctx.\(id.uuidString.lowercased())"
        guard let data = keychainRead(service: e2ePlusService, account: account) else { return nil }
        return try? JSONDecoder().decode(E2EPlusContext.self, from: data)
    }

    static func archiveActiveE2EPlusContext(for conversationId: UUID) {
        keychainDelete(service: e2ePlusService, account: "active.\(conversationId.uuidString.lowercased())")
    }

    private static func saveE2EPlusContext(_ context: E2EPlusContext) {
        guard let data = try? JSONEncoder().encode(context) else { return }
        keychainWrite(
            data: data,
            service: e2ePlusService,
            account: "ctx.\(context.contextId.uuidString.lowercased())"
        )
    }

    private static func uuidFromHash(_ hash: Data) -> UUID {
        var bytes = Array(hash.prefix(16))
        while bytes.count < 16 { bytes.append(0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    // MARK: - Keychain primitives

    private static func keychainWrite(data: Data, service: String, account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var insert: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        insert[kSecUseDataProtectionKeychain as String] = true
        #endif
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func keychainRead(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private static func keychainDelete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainDeleteAll(service: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
