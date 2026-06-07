//
//  VaulteRelayEncryptedProfile.swift
//  Vaulté Privé
//

import CryptoKit
import Foundation

/// Cleartext profile fields — only exist on-device or inside AES-GCM blobs.
struct RelayProfilePlaintext: Codable, Equatable {
    let v: Int
    let username: String
    let displayName: String?
    let avatarB64: String?

    init(username: String, displayName: String?, avatarB64: String?) {
        self.v = 1
        self.username = username
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        self.avatarB64 = avatarB64?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? avatarB64?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }
}

enum VaulteRelayEncryptedProfileError: LocalizedError {
    case pepperNotConfigured
    case invalidUsername
    case invalidIdentityKey
    case invalidCiphertext
    case profileTooLarge

    var errorDescription: String? {
        switch self {
        case .pepperNotConfigured: return "Relay username pepper is not configured."
        case .invalidUsername: return "Invalid username."
        case .invalidIdentityKey: return "Invalid identity public key."
        case .invalidCiphertext: return "Invalid encrypted profile."
        case .profileTooLarge: return "Profile is too large to upload."
        }
    }
}

enum VaulteRelayEncryptedProfile {
    private static let hkdfSalt = Data("vaulte-relay-profile-v1".utf8)
    private static let hkdfInfo = Data("profile-aes".utf8)
    private static let maxCiphertextBase64Chars = 3_600_000

    static func normalizedUsername(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let core = t.hasPrefix("@") ? String(t.dropFirst()) : t
        guard core.count >= 3, core.count <= 20 else { return nil }
        guard core.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil else { return nil }
        return core
    }

    static func usernameLookupKey(for username: String) throws -> String {
        let pepper = VaulteRelayConfiguration.effectiveUsernameLookupPepper ?? ""
        guard !pepper.isEmpty else { throw VaulteRelayEncryptedProfileError.pepperNotConfigured }
        guard let normalized = normalizedUsername(username) else { throw VaulteRelayEncryptedProfileError.invalidUsername }
        let key = SymmetricKey(data: Data(pepper.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Derives the AES-GCM key used to encrypt/decrypt a user's relay profile (display name, avatar).
    ///
    /// The key is derived from the user's *public* X25519 identity key via HKDF-SHA256.
    /// This means any party that knows the public key (which the relay publishes) can decrypt
    /// the profile ciphertext. The scheme prevents the relay from storing plaintext profiles
    /// but does NOT protect against a targeted attacker who has the public key.
    /// This is intentional and acceptable for display-name/avatar data; it must NOT be used
    /// for message content or any data that requires peer-only confidentiality.
    static func profileAESKey(identityPublicKeyBase64: String) throws -> SymmetricKey {
        let trimmed = identityPublicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pubData = Data(base64Encoded: trimmed), pubData.count == 32 else {
            throw VaulteRelayEncryptedProfileError.invalidIdentityKey
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pubData),
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: 32
        )
    }

    static func encrypt(
        _ plaintext: RelayProfilePlaintext,
        identityPublicKeyBase64: String
    ) throws -> String {
        let key = try profileAESKey(identityPublicKeyBase64: identityPublicKeyBase64)
        let data = try JSONEncoder().encode(plaintext)
        let sealed = try AES.GCM.seal(data, using: key)
        let b64 = sealed.combined?.base64EncodedString() ?? ""
        guard b64.count <= maxCiphertextBase64Chars else { throw VaulteRelayEncryptedProfileError.profileTooLarge }
        return b64
    }

    static func decrypt(
        ciphertextBase64: String,
        identityPublicKeyBase64: String
    ) throws -> RelayProfilePlaintext {
        let trimmed = ciphertextBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let combined = Data(base64Encoded: trimmed) else {
            throw VaulteRelayEncryptedProfileError.invalidCiphertext
        }
        let key = try profileAESKey(identityPublicKeyBase64: identityPublicKeyBase64)
        let box = try AES.GCM.SealedBox(combined: combined)
        let clear = try AES.GCM.open(box, using: key)
        let decoded = try JSONDecoder().decode(RelayProfilePlaintext.self, from: clear)
        guard decoded.v == 1 else { throw VaulteRelayEncryptedProfileError.invalidCiphertext }
        return decoded
    }

    static func relayUserDTO(
        userId: UUID,
        updatedAt: Date,
        plaintext: RelayProfilePlaintext
    ) -> RelayUserDTO {
        RelayUserDTO(
            userId: userId,
            username: plaintext.username,
            displayName: plaintext.displayName,
            avatarB64: plaintext.avatarB64,
            updatedAt: updatedAt,
            profileCiphertextB64: nil
        )
    }
}
