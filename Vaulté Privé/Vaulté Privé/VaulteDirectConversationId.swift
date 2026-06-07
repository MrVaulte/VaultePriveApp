//
//  VaulteDirectConversationId.swift
//  Vaulté Privé
//
//  Deterministic 1:1 conversation UUID from two user UUIDs (order-independent).
//

import CryptoKit
import Foundation

enum VaulteDirectConversationId {
    /// Same value for `(A,B)` and `(B,A)`. Used for DM thread id + keychain ratchet/AES scope.
    static func uuid(between userA: UUID, and userB: UUID) -> UUID {
        let ordered = [userA.uuidString.lowercased(), userB.uuidString.lowercased()].sorted()
        let seed = Data("vaulte.shared.conversation.v1|\(ordered[0])|\(ordered[1])".utf8)
        let digest = SHA256.hash(data: seed)
        var bytes = Array(Data(digest).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }
}
