//
//  SealedSender.swift
//  Vaulté Privé
//
//  Metadata-private message delivery — relay sees neither sender nor recipient.
//
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │  PRIVACY MODEL                                                           │
//  │                                                                          │
//  │  Classic send:  relay sees  sender_id → recipient_id  (full social graph)│
//  │  Sealed send:   relay sees  envelope_id → stealth_tag  (nothing useful)  │
//  │                                                                          │
//  │  Stealth tag = HKDF(ECDH(ephemeral_priv, recipient_scan_pubkey),         │
//  │                     "vaulte.stealth.tag.v1")                             │
//  │  — one-time, 32 bytes, looks random, not linkable to recipient identity  │
//  │                                                                          │
//  │  Sealed ciphertext = ChaCha20-Poly1305(                                  │
//  │      key  = HKDF(shared_secret, "vaulte.stealth.enc.v1"),               │
//  │      plain = real_message_ciphertext_b64 + "\n" + sender_id_string       │
//  │  )                                                                        │
//  │                                                                          │
//  │  Timing jitter: sender waits 0–jitterMax seconds before posting.         │
//  └─────────────────────────────────────────────────────────────────────────┘

import CryptoKit
import Foundation

// MARK: - Stealth envelope (what the relay stores)

struct SealedEnvelope: Codable {
    let envelopeId: UUID
    let recipientTag: String          // 32-byte hex
    let ephemeralPubkeyB64: String    // sender ephemeral X25519 public key
    let sealedCiphertextB64: String   // encrypted (real message + sender_id)
}

// MARK: - Scan result (no ciphertext — just enough to check tag)

struct SealedScanEntry: Codable {
    let envelopeId: UUID
    let ephemeralPubkeyB64: String
    let recipientTag: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case envelopeId = "envelope_id"
        case ephemeralPubkeyB64 = "ephemeral_pubkey_b64"
        case recipientTag = "recipient_tag"
        case createdAt = "created_at"
    }
}

// MARK: - Opened envelope (after tag match + full fetch)

struct OpenedSealedEnvelope {
    let envelopeId: UUID
    let senderId: UUID
    let innerCiphertextB64: String    // the real Double Ratchet / OTP ciphertext
}

// MARK: - SealedSender

enum SealedSenderError: LocalizedError {
    case missingRecipientScanKey
    case tagDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case malformedPlaintext

    var errorDescription: String? {
        switch self {
        case .missingRecipientScanKey: return "Recipient has not published a scan key (stealth mode unavailable)."
        case .tagDerivationFailed:    return "Stealth tag derivation failed."
        case .encryptionFailed:       return "Sealed envelope encryption failed."
        case .decryptionFailed:       return "Sealed envelope decryption failed — not addressed to us."
        case .malformedPlaintext:     return "Sealed envelope inner plaintext is malformed."
        }
    }
}

enum SealedSender {

    // MARK: - Key constants

    private static let tagInfo  = Data("vaulte.stealth.tag.v1".utf8)
    private static let encInfo  = Data("vaulte.stealth.enc.v1".utf8)

    // MARK: - Seal (sender side)

    /// Encrypt a message for delivery without revealing sender or recipient to the relay.
    ///
    /// - Parameters:
    ///   - innerCiphertextB64: The already-E2E-encrypted message ciphertext (Double Ratchet / OTP output).
    ///   - senderId: Our own user ID — sealed inside the envelope so only the recipient learns it.
    ///   - recipientScanPubkeyB64: Recipient's published X25519 scan public key (fetched from relay).
    ///   - jitterMax: Maximum random delay in seconds before the caller should POST the envelope (0 = immediate).
    /// - Returns: A `SealedEnvelope` ready to POST and the recommended send delay.
    static func seal(
        innerCiphertextB64: String,
        senderId: UUID,
        recipientScanPubkeyB64: String,
        jitterMaxSeconds: Double = 15
    ) throws -> (envelope: SealedEnvelope, sendAfter: Date) {
        // 1. Parse recipient scan pubkey
        guard let scanPubData = Data(base64Encoded: recipientScanPubkeyB64),
              let recipientScanKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: scanPubData)
        else { throw SealedSenderError.missingRecipientScanKey }

        // 2. Generate ephemeral key pair (never stored — forward secrecy)
        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub  = ephemeralPriv.publicKey

        // 3. ECDH → shared secret
        guard let sharedSecret = try? ephemeralPriv.sharedSecretFromKeyAgreement(with: recipientScanKey) else {
            throw SealedSenderError.tagDerivationFailed
        }

        // 4. Derive stealth tag (32 bytes → hex, used as relay address)
        let tagKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: tagInfo,
            outputByteCount: 32
        )
        let tagHex = tagKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()

        // 5. Derive encryption key (different context → different key)
        let encKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: encInfo,
            outputByteCount: 32
        )

        // 6. Encrypt: plaintext = "<inner_ciphertext_b64>\n<sender_id>"
        let plaintext = "\(innerCiphertextB64)\n\(senderId.uuidString.lowercased())"
        guard let plaintextData = plaintext.data(using: .utf8),
              let sealed = try? ChaChaPoly.seal(plaintextData, using: encKey)
        else { throw SealedSenderError.encryptionFailed }
        let combined = sealed.combined

        // 7. Timing jitter — random delay so relay arrival time ≠ user send time
        let jitter = jitterMaxSeconds > 0
            ? Double.random(in: 0 ... jitterMaxSeconds)
            : 0
        let sendAfter = Date().addingTimeInterval(jitter)

        let envelope = SealedEnvelope(
            envelopeId: UUID(),
            recipientTag: tagHex,
            ephemeralPubkeyB64: ephemeralPub.rawRepresentation.base64EncodedString(),
            sealedCiphertextB64: combined.base64EncodedString()
        )
        return (envelope, sendAfter)
    }

    // MARK: - Try-open (recipient side)

    /// Attempt to open a scan entry using our scan private key.
    /// Returns nil silently if the tag doesn't match (not addressed to us).
    static func tryOpenScanEntry(
        _ entry: SealedScanEntry,
        ourScanPrivkey: Curve25519.KeyAgreement.PrivateKey
    ) -> String? {
        guard let ephData = Data(base64Encoded: entry.ephemeralPubkeyB64),
              let ephPub  = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData),
              let shared  = try? ourScanPrivkey.sharedSecretFromKeyAgreement(with: ephPub)
        else { return nil }

        let tagKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: tagInfo,
            outputByteCount: 32
        )
        let expectedTag = tagKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        return expectedTag == entry.recipientTag ? entry.envelopeId.uuidString : nil
    }

    /// Open a full sealed envelope after confirming tag match.
    static func open(
        envelopeId: UUID,
        ephemeralPubkeyB64: String,
        sealedCiphertextB64: String,
        ourScanPrivkey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> OpenedSealedEnvelope {
        guard let ephData = Data(base64Encoded: ephemeralPubkeyB64),
              let ephPub  = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData),
              let shared  = try? ourScanPrivkey.sharedSecretFromKeyAgreement(with: ephPub)
        else { throw SealedSenderError.decryptionFailed }

        let encKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: encInfo,
            outputByteCount: 32
        )

        guard let combined = Data(base64Encoded: sealedCiphertextB64),
              let box      = try? ChaChaPoly.SealedBox(combined: combined),
              let plain    = try? ChaChaPoly.open(box, using: encKey),
              let text     = String(data: plain, encoding: .utf8)
        else { throw SealedSenderError.decryptionFailed }

        // plaintext = "<inner_ciphertext_b64>\n<sender_id>"
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 2,
              let senderId = UUID(uuidString: parts.last ?? "")
        else { throw SealedSenderError.malformedPlaintext }

        let innerCiphertextB64 = parts.dropLast().joined(separator: "\n")
        return OpenedSealedEnvelope(
            envelopeId: envelopeId,
            senderId: senderId,
            innerCiphertextB64: innerCiphertextB64
        )
    }
}

// MARK: - ScanKey store (Keychain-backed)

enum SealedSenderKeyStore {
    private static let service = "com.vaulteprive.sealedkey"
    private static let scanPrivAccount = "scan_priv_v1"

    /// Load or generate the local scan key pair. The public key should be published to the relay.
    static func loadOrCreateScanKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = keychainRead(),
           let key  = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        try keychainWrite(fresh.rawRepresentation)
        return fresh
    }

    static func scanPubkeyB64() throws -> String {
        let key = try loadOrCreateScanKey()
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    private static func keychainRead() -> Data? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scanPrivAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private static func keychainWrite(_ data: Data) throws {
        let dq: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: scanPrivAccount]
        SecItemDelete(dq as CFDictionary)
        var iq: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scanPrivAccount,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        iq[kSecUseDataProtectionKeychain as String] = true
        #endif
        let s = SecItemAdd(iq as CFDictionary, nil)
        guard s == errSecSuccess else { throw IdentityKeyError.keychainFailure(status: s) }
    }
}
