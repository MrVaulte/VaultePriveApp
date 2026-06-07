import Foundation

enum VerifiedOtpDirection: String, Codable, CaseIterable, Sendable {
    case send
    case receive

    var opposite: VerifiedOtpDirection {
        switch self {
        case .send: return .receive
        case .receive: return .send
        }
    }

    var displayToken: String {
        rawValue.uppercased()
    }
}

enum VerifiedOtpBundleStatus: String, Codable, CaseIterable, Sendable {
    case awaitingImport
    case active
    case lowCapacity
    case exhausted
    case revoked
    case error

    var isUsableForTraffic: Bool {
        self == .active || self == .lowCapacity
    }
}

struct VerifiedOtpBundleFingerprint: Codable, Equatable, Hashable, Sendable {
    let shortCode: String
    let fullHex: String
}

struct VerifiedOtpBundleDescriptor: Codable, Equatable, Sendable {
    let bundleId: UUID
    let conversationId: UUID
    let peerId: UUID
    let ownerUserId: UUID
    let direction: VerifiedOtpDirection
    let createdAt: Date
    let totalBytes: Int
    let fingerprint: VerifiedOtpBundleFingerprint
}

struct VerifiedOtpBundleHeader: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let bundleId: UUID
    let conversationId: UUID
    let peerId: UUID
    let ownerUserId: UUID
    let direction: VerifiedOtpDirection
    let createdAt: Date
    let totalBytes: Int
    let padDigestB64: String
    let senderIdentityPublicKeyB64: String
    let recipientIdentityPublicKeyB64: String
    let senderSigningPublicKeyB64: String
    let wrappedKeySaltB64: String
    let wrappedKeyNonceB64: String
    let wrappedKeyCiphertextB64: String
    let wrappedKeyTagB64: String
    let payloadNonceB64: String
    let payloadCiphertextB64: String
    let payloadTagB64: String
    let fingerprint: VerifiedOtpBundleFingerprint
}

struct VerifiedOtpBundleFile: Codable, Equatable, Sendable {
    let header: VerifiedOtpBundleHeader
    let signatureB64: String
}

struct VerifiedOtpBundleImportResult: Equatable, Sendable {
    let descriptor: VerifiedOtpBundleDescriptor
    let padBytes: Data
    /// Sender's X25519 identity public key (Base64), extracted from the bundle header
    /// during import. Used by TOFU peer-binding verification in ChatViewModel.
    let senderIdentityPublicKeyB64: String
}

struct VerifiedOtpEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let mode: String
    let bundleId: String
    let sequence: Int
    let offset: Int
    let ciphertextB64: String
    let macB64: String
}

struct VerifiedOtpSendReservation: Equatable, Sendable {
    let bundleId: UUID
    let sequence: Int
    let offset: Int
    let length: Int
    let remainingAfterReservation: Int
    let statusAfterReservation: VerifiedOtpBundleStatus
}

struct VerifiedOtpBundleRecord: Identifiable, Equatable, Sendable {
    var id: UUID { bundleId }
    let bundleId: UUID
    let conversationId: UUID
    let peerId: UUID
    let ownerUserId: UUID
    let direction: VerifiedOtpDirection
    let status: VerifiedOtpBundleStatus
    let fingerprintShortCode: String
    let fingerprintFullHex: String
    let totalBytes: Int
    let remainingBytes: Int
    let nextSequence: Int
    let nextOffset: Int
    let importedAt: Date?
    let createdAt: Date
    let fileKeyRef: String
    let padFileURL: URL
    let consumedRangesJSON: String

    var fingerprint: VerifiedOtpBundleFingerprint {
        VerifiedOtpBundleFingerprint(
            shortCode: fingerprintShortCode,
            fullHex: fingerprintFullHex
        )
    }

    var descriptor: VerifiedOtpBundleDescriptor {
        VerifiedOtpBundleDescriptor(
            bundleId: bundleId,
            conversationId: conversationId,
            peerId: peerId,
            ownerUserId: ownerUserId,
            direction: direction,
            createdAt: createdAt,
            totalBytes: totalBytes,
            fingerprint: fingerprint
        )
    }
}

struct VerifiedOtpBundleSummary: Equatable, Sendable {
    let sendBundle: VerifiedOtpBundleRecord?
    let receiveBundle: VerifiedOtpBundleRecord?

    var activeSendBundle: VerifiedOtpBundleRecord? {
        guard let sendBundle, sendBundle.status.isUsableForTraffic else { return nil }
        return sendBundle
    }

    var activeReceiveBundle: VerifiedOtpBundleRecord? {
        guard let receiveBundle, receiveBundle.status.isUsableForTraffic else { return nil }
        return receiveBundle
    }

    var minimumRemainingBytes: Int {
        [activeSendBundle?.remainingBytes, activeReceiveBundle?.remainingBytes]
            .compactMap { $0 }
            .min() ?? 0
    }
}
