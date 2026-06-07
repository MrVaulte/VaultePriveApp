//
//  VaulteSendRetryQueue.swift
//  Vaulté Privé
//
//  Persists failed relay POSTs so we can retry without re-encrypting (ratchet state already advanced).
//

import Foundation

private let queueFilename = "pending_message_sends.json"

struct VaultePendingRelaySend: Codable, Sendable, Equatable {
    var messageId: UUID
    var conversationIdWire: UUID
    var senderId: UUID
    var recipientId: UUID
    var padId: UUID
    var ciphertextBase64: String
    var createdAt: Date
    /// Local conversation row used for SQLite `messages.conversation_id`.
    var localConversationId: UUID
    var plaintext: String
    var disappearingSecondsAtEnqueue: Int
    var verifiedOtpBundleId: UUID?
    var verifiedOtpSequence: Int?
    var verifiedOtpOffset: Int?
    var verifiedOtpLength: Int?
}

enum VaulteSendRetryQueue {
    private static func fileURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VaultePrive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(queueFilename, isDirectory: false)
    }

    static func enqueue(_ item: VaultePendingRelaySend) throws {
        var list = (try? loadAll()) ?? []
        if list.contains(where: { $0.messageId == item.messageId }) { return }
        list.append(item)
        try saveAll(list)
    }

    static func loadAll() throws -> [VaultePendingRelaySend] {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([VaultePendingRelaySend].self, from: data)
    }

    private static func saveAll(_ list: [VaultePendingRelaySend]) throws {
        let url = try fileURL()
        let data = try JSONEncoder().encode(list)
        try data.write(to: url, options: [.atomic])
    }

    /// Retries POST /messages for each pending row; on success writes local placeholder + ciphertext rows (same as a successful send).
    static func flushIfPossible(store: OTPStore, baseURL: URL) async {
        let pending: [VaultePendingRelaySend]
        do {
            pending = try loadAll()
        } catch {
            return
        }
        guard !pending.isEmpty else { return }

        guard let client = try? ChatAPIClient(baseURL: baseURL) else { return }

        var remaining: [VaultePendingRelaySend] = []
        for item in pending {
            let dto = NetworkMessageDTO(
                messageId: item.messageId,
                conversationId: item.conversationIdWire,
                senderId: item.senderId,
                recipientId: item.recipientId,
                padId: item.padId,
                ciphertextBase64: item.ciphertextBase64,
                createdAt: item.createdAt
            )
            do {
                try await client.send(dto)
                try await store.appendOutgoingPlaceholder(
                    messageId: item.messageId,
                    conversationId: item.localConversationId,
                    senderId: item.senderId,
                    recipientId: item.recipientId,
                    padId: item.localConversationId,
                    plaintext: item.plaintext,
                    createdAt: item.createdAt
                )
                try await store.upsertServerMessage(
                    messageId: item.messageId,
                    conversationId: item.localConversationId,
                    senderId: item.senderId,
                    recipientId: item.recipientId,
                    padId: item.localConversationId,
                    ciphertextBase64: item.ciphertextBase64,
                    createdAt: item.createdAt,
                    relayDeliveredAt: nil
                )
                if item.disappearingSecondsAtEnqueue > 0 {
                    let exp = item.createdAt.addingTimeInterval(TimeInterval(item.disappearingSecondsAtEnqueue))
                    try? await store.setMessageExpiresAt(messageId: item.messageId, expiresAt: exp)
                }
            } catch {
                remaining.append(item)
            }
        }
        try? saveAll(remaining)
    }
}
