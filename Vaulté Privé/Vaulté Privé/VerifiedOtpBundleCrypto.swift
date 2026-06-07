import CryptoKit
import Foundation

enum VerifiedOtpBundleCrypto {
    private static let schemaVersion = 1
    private static let fileInfo = Data("vaulte.verifiedotp.bundle.v1".utf8)
    private static let payloadInfo = Data("vaulte.verifiedotp.payload.v1".utf8)
    private static let macInfo = Data("vaulte.verifiedotp.mac.v1".utf8)
    private static let fingerprintInfo = Data("vaulte.verifiedotp.fingerprint.v1".utf8)
    private static let signatureDomain = Data("vaulte.verifiedotp.header-signature.v1|".utf8)

    static func generateDirectionalBundle(
        conversationId: UUID,
        ownerUserId: UUID,
        peerId: UUID,
        direction: VerifiedOtpDirection,
        byteCount: Int,
        now: Date = Date()
    ) throws -> (descriptor: VerifiedOtpBundleDescriptor, padBytes: Data, fileData: Data) {
        guard let localIdentity = LocalIdentityStore.loadIdentityKey() else {
            throw OTPError.verifiedOtpPeerIdentityUnavailable
        }
        guard let signingKey = LocalIdentityStore.loadSigningKey() else {
            throw OTPError.verifiedOtpSigningKeyUnavailable
        }
        guard let pinnedPeerIdentityB64 = LocalIdentityStore.pinnedPeerIdentityKey(for: peerId),
              let pinnedPeerIdentityData = Data(base64Encoded: pinnedPeerIdentityB64),
              let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pinnedPeerIdentityData)
        else {
            throw OTPError.verifiedOtpPeerIdentityUnavailable
        }
        guard byteCount > 0 else {
            throw OTPError.verifiedOtpInvalidBundle
        }

        let bundleId = UUID()
        let padBytes = try SecureRandom.bytes(count: byteCount)
        let padDigest = sha256(padBytes)
        let fingerprint = makeFingerprint(
            conversationId: conversationId,
            peerId: peerId,
            bundleId: bundleId,
            padDigest: padDigest
        )
        let descriptor = VerifiedOtpBundleDescriptor(
            bundleId: bundleId,
            conversationId: conversationId,
            peerId: peerId,
            ownerUserId: ownerUserId,
            direction: direction,
            createdAt: now,
            totalBytes: byteCount,
            fingerprint: fingerprint
        )
        let fileData = try bundleFileData(descriptor: descriptor, padBytes: padBytes)
        return (descriptor, padBytes, fileData)
    }

    static func bundleFileData(
        descriptor: VerifiedOtpBundleDescriptor,
        padBytes: Data
    ) throws -> Data {
        guard let localIdentity = LocalIdentityStore.loadIdentityKey() else {
            throw OTPError.verifiedOtpPeerIdentityUnavailable
        }
        guard let signingKey = LocalIdentityStore.loadSigningKey() else {
            throw OTPError.verifiedOtpSigningKeyUnavailable
        }
        guard let pinnedPeerIdentityB64 = LocalIdentityStore.pinnedPeerIdentityKey(for: descriptor.peerId),
              let pinnedPeerIdentityData = Data(base64Encoded: pinnedPeerIdentityB64),
              let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pinnedPeerIdentityData)
        else {
            throw OTPError.verifiedOtpPeerIdentityUnavailable
        }
        guard descriptor.totalBytes == padBytes.count, descriptor.totalBytes > 0 else {
            throw OTPError.verifiedOtpInvalidBundle
        }

        let padDigest = sha256(padBytes)
        let fingerprint = makeFingerprint(
            conversationId: descriptor.conversationId,
            peerId: descriptor.peerId,
            bundleId: descriptor.bundleId,
            padDigest: padDigest
        )
        guard fingerprint == descriptor.fingerprint else {
            throw OTPError.verifiedOtpBundleMismatch
        }

        let wrapped = try wrapBundleKey(
            localIdentity: localIdentity.privateKey,
            peerIdentity: peerPublicKey,
            bundleId: descriptor.bundleId,
            conversationId: descriptor.conversationId
        )
        let payloadKey = SymmetricKey(data: wrapped.fileKey)
        let payloadNonce = try AES.GCM.Nonce()
        let payloadAAD = try canonicalHeaderAAD(
            bundleId: descriptor.bundleId,
            conversationId: descriptor.conversationId,
            peerId: descriptor.peerId,
            ownerUserId: descriptor.ownerUserId,
            direction: descriptor.direction,
            createdAt: descriptor.createdAt,
            totalBytes: descriptor.totalBytes,
            padDigest: padDigest,
            senderIdentityPublicKeyData: localIdentity.publicKey.rawRepresentation,
            recipientIdentityPublicKeyData: peerPublicKey.rawRepresentation,
            senderSigningPublicKeyData: signingKey.publicKey.rawRepresentation,
            wrappedKeySalt: wrapped.salt,
            wrappedKeyNonce: wrapped.nonceData,
            wrappedKeyCiphertext: wrapped.ciphertext,
            wrappedKeyTag: wrapped.tag,
            payloadNonce: payloadNonce.withUnsafeBytes { Data($0) },
            payloadCiphertext: Data(),
            payloadTag: Data(),
            fingerprint: fingerprint
        )
        let sealed = try AES.GCM.seal(padBytes, using: payloadKey, nonce: payloadNonce, authenticating: payloadAAD)

        let header = VerifiedOtpBundleHeader(
            schemaVersion: schemaVersion,
            bundleId: descriptor.bundleId,
            conversationId: descriptor.conversationId,
            peerId: descriptor.peerId,
            ownerUserId: descriptor.ownerUserId,
            direction: descriptor.direction,
            createdAt: descriptor.createdAt,
            totalBytes: descriptor.totalBytes,
            padDigestB64: padDigest.base64EncodedString(),
            senderIdentityPublicKeyB64: localIdentity.publicKey.rawRepresentation.base64EncodedString(),
            recipientIdentityPublicKeyB64: peerPublicKey.rawRepresentation.base64EncodedString(),
            senderSigningPublicKeyB64: signingKey.publicKey.rawRepresentation.base64EncodedString(),
            wrappedKeySaltB64: wrapped.salt.base64EncodedString(),
            wrappedKeyNonceB64: wrapped.nonceData.base64EncodedString(),
            wrappedKeyCiphertextB64: wrapped.ciphertext.base64EncodedString(),
            wrappedKeyTagB64: wrapped.tag.base64EncodedString(),
            payloadNonceB64: payloadNonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            payloadCiphertextB64: sealed.ciphertext.base64EncodedString(),
            payloadTagB64: sealed.tag.base64EncodedString(),
            fingerprint: fingerprint
        )
        let signature = try signingKey.signature(for: canonicalHeaderData(header))
        let file = VerifiedOtpBundleFile(
            header: header,
            signatureB64: signature.base64EncodedString()
        )
        return try JSONEncoder().encode(file)
    }

    /// Reads conversation id from bundle header without decrypting pad bytes (routing only).
    static func peekConversationId(from fileData: Data) -> UUID? {
        if let bundleMap = try? JSONSerialization.jsonObject(with: fileData) as? [String: String] {
            for raw in bundleMap.values {
                guard let nested = Data(base64Encoded: raw),
                      let id = peekConversationId(fromSingleBundleData: nested)
                else { continue }
                return id
            }
        }
        return peekConversationId(fromSingleBundleData: fileData)
    }

    private static func peekConversationId(fromSingleBundleData data: Data) -> UUID? {
        guard let file = try? JSONDecoder().decode(VerifiedOtpBundleFile.self, from: data) else {
            return nil
        }
        return file.header.conversationId
    }

    static func importBundleFile(_ fileData: Data) throws -> VerifiedOtpBundleImportResult {
        let file = try JSONDecoder().decode(VerifiedOtpBundleFile.self, from: fileData)
        let header = file.header
        guard header.schemaVersion == schemaVersion else {
            throw OTPError.verifiedOtpInvalidBundle
        }
        guard let signature = Data(base64Encoded: file.signatureB64),
              let senderSigningPublicKeyData = Data(base64Encoded: header.senderSigningPublicKeyB64),
              let senderSigningPublicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: senderSigningPublicKeyData)
        else {
            throw OTPError.verifiedOtpInvalidBundle
        }
        guard senderSigningPublicKey.isValidSignature(signature, for: canonicalHeaderData(header)) else {
            throw OTPError.verifiedOtpAuthenticationFailed
        }
        guard let localIdentity = LocalIdentityStore.loadIdentityKey(),
              let senderIdentityPublicKeyData = Data(base64Encoded: header.senderIdentityPublicKeyB64),
              let senderIdentityPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderIdentityPublicKeyData)
        else {
            throw OTPError.verifiedOtpPeerIdentityUnavailable
        }
        guard header.recipientIdentityPublicKeyB64 == localIdentity.publicKey.rawRepresentation.base64EncodedString() else {
            throw OTPError.verifiedOtpBundleMismatch
        }
        let fileKey = try unwrapBundleKey(
            localIdentity: localIdentity.privateKey,
            senderIdentity: senderIdentityPublicKey,
            header: header
        )
        guard let payloadNonceData = Data(base64Encoded: header.payloadNonceB64),
              let payloadNonce = try? AES.GCM.Nonce(data: payloadNonceData),
              let payloadCiphertext = Data(base64Encoded: header.payloadCiphertextB64),
              let payloadTag = Data(base64Encoded: header.payloadTagB64)
        else {
            throw OTPError.verifiedOtpInvalidBundle
        }

        let aad = try canonicalHeaderAAD(
            bundleId: header.bundleId,
            conversationId: header.conversationId,
            peerId: header.peerId,
            ownerUserId: header.ownerUserId,
            direction: header.direction,
            createdAt: header.createdAt,
            totalBytes: header.totalBytes,
            padDigest: Data(base64Encoded: header.padDigestB64) ?? Data(),
            senderIdentityPublicKeyData: senderIdentityPublicKeyData,
            recipientIdentityPublicKeyData: localIdentity.publicKey.rawRepresentation,
            senderSigningPublicKeyData: senderSigningPublicKeyData,
            wrappedKeySalt: Data(base64Encoded: header.wrappedKeySaltB64) ?? Data(),
            wrappedKeyNonce: Data(base64Encoded: header.wrappedKeyNonceB64) ?? Data(),
            wrappedKeyCiphertext: Data(base64Encoded: header.wrappedKeyCiphertextB64) ?? Data(),
            wrappedKeyTag: Data(base64Encoded: header.wrappedKeyTagB64) ?? Data(),
            payloadNonce: payloadNonceData,
            payloadCiphertext: Data(),
            payloadTag: Data(),
            fingerprint: header.fingerprint
        )
        let sealed = try AES.GCM.SealedBox(nonce: payloadNonce, ciphertext: payloadCiphertext, tag: payloadTag)
        let padBytes = try AES.GCM.open(sealed, using: SymmetricKey(data: fileKey), authenticating: aad)
        let padDigest = sha256(padBytes)
        guard padDigest.base64EncodedString() == header.padDigestB64 else {
            throw OTPError.verifiedOtpAuthenticationFailed
        }
        let fingerprint = makeFingerprint(
            conversationId: header.conversationId,
            peerId: header.peerId,
            bundleId: header.bundleId,
            padDigest: padDigest
        )
        guard fingerprint == header.fingerprint else {
            throw OTPError.verifiedOtpBundleMismatch
        }
        let descriptor = VerifiedOtpBundleDescriptor(
            bundleId: header.bundleId,
            conversationId: header.conversationId,
            peerId: header.peerId,
            ownerUserId: header.ownerUserId,
            direction: header.direction,
            createdAt: header.createdAt,
            totalBytes: header.totalBytes,
            fingerprint: fingerprint
        )
        return VerifiedOtpBundleImportResult(descriptor: descriptor, padBytes: padBytes)
    }

    static func fileName(for descriptor: VerifiedOtpBundleDescriptor) -> String {
        let peer = descriptor.peerId.uuidString.lowercased().prefix(8)
        return "vaulte-\(descriptor.direction.rawValue)-\(peer)-\(descriptor.fingerprint.shortCode).vaultepad"
    }

    private struct WrappedBundleKey {
        let fileKey: Data
        let salt: Data
        let nonceData: Data
        let ciphertext: Data
        let tag: Data
    }

    private static func wrapBundleKey(
        localIdentity: Curve25519.KeyAgreement.PrivateKey,
        peerIdentity: Curve25519.KeyAgreement.PublicKey,
        bundleId: UUID,
        conversationId: UUID
    ) throws -> WrappedBundleKey {
        let fileKey = try SecureRandom.bytes(count: 32)
        let salt = try SecureRandom.bytes(count: 32)
        let shared = try localIdentity.sharedSecretFromKeyAgreement(with: peerIdentity)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: fileInfo + Data(bundleId.uuidString.lowercased().utf8) + Data(conversationId.uuidString.lowercased().utf8),
            outputByteCount: 32
        )
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(fileKey, using: wrappingKey, nonce: nonce)
        return WrappedBundleKey(
            fileKey: fileKey,
            salt: salt,
            nonceData: nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    private static func unwrapBundleKey(
        localIdentity: Curve25519.KeyAgreement.PrivateKey,
        senderIdentity: Curve25519.KeyAgreement.PublicKey,
        header: VerifiedOtpBundleHeader
    ) throws -> Data {
        guard let salt = Data(base64Encoded: header.wrappedKeySaltB64),
              let nonceData = Data(base64Encoded: header.wrappedKeyNonceB64),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let ciphertext = Data(base64Encoded: header.wrappedKeyCiphertextB64),
              let tag = Data(base64Encoded: header.wrappedKeyTagB64)
        else {
            throw OTPError.verifiedOtpInvalidBundle
        }
        let shared = try localIdentity.sharedSecretFromKeyAgreement(with: senderIdentity)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: fileInfo + Data(header.bundleId.uuidString.lowercased().utf8) + Data(header.conversationId.uuidString.lowercased().utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealed, using: wrappingKey)
    }

    private static func makeFingerprint(
        conversationId: UUID,
        peerId: UUID,
        bundleId: UUID,
        padDigest: Data
    ) -> VerifiedOtpBundleFingerprint {
        var hasher = SHA256()
        hasher.update(data: fingerprintInfo)
        hasher.update(data: Data(conversationId.uuidString.lowercased().utf8))
        hasher.update(data: Data(peerId.uuidString.lowercased().utf8))
        hasher.update(data: Data(bundleId.uuidString.lowercased().utf8))
        hasher.update(data: padDigest)
        let digest = Data(hasher.finalize())
        let fullHex = digest.map { String(format: "%02x", $0) }.joined()
        let shortCode = stride(from: 0, to: min(24, fullHex.count), by: 4)
            .map { idx in
                let start = fullHex.index(fullHex.startIndex, offsetBy: idx)
                let end = fullHex.index(start, offsetBy: min(4, fullHex.distance(from: start, to: fullHex.endIndex)))
                return String(fullHex[start..<end]).uppercased()
            }
            .joined(separator: " ")
        return VerifiedOtpBundleFingerprint(shortCode: shortCode, fullHex: fullHex)
    }

    static func canonicalHeaderData(_ header: VerifiedOtpBundleHeader) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(header)) ?? Data()
    }

    private static func canonicalHeaderAAD(
        bundleId: UUID,
        conversationId: UUID,
        peerId: UUID,
        ownerUserId: UUID,
        direction: VerifiedOtpDirection,
        createdAt: Date,
        totalBytes: Int,
        padDigest: Data,
        senderIdentityPublicKeyData: Data,
        recipientIdentityPublicKeyData: Data,
        senderSigningPublicKeyData: Data,
        wrappedKeySalt: Data,
        wrappedKeyNonce: Data,
        wrappedKeyCiphertext: Data,
        wrappedKeyTag: Data,
        payloadNonce: Data,
        payloadCiphertext: Data,
        payloadTag: Data,
        fingerprint: VerifiedOtpBundleFingerprint
    ) throws -> Data {
        let header = VerifiedOtpBundleHeader(
            schemaVersion: schemaVersion,
            bundleId: bundleId,
            conversationId: conversationId,
            peerId: peerId,
            ownerUserId: ownerUserId,
            direction: direction,
            createdAt: createdAt,
            totalBytes: totalBytes,
            padDigestB64: padDigest.base64EncodedString(),
            senderIdentityPublicKeyB64: senderIdentityPublicKeyData.base64EncodedString(),
            recipientIdentityPublicKeyB64: recipientIdentityPublicKeyData.base64EncodedString(),
            senderSigningPublicKeyB64: senderSigningPublicKeyData.base64EncodedString(),
            wrappedKeySaltB64: wrappedKeySalt.base64EncodedString(),
            wrappedKeyNonceB64: wrappedKeyNonce.base64EncodedString(),
            wrappedKeyCiphertextB64: wrappedKeyCiphertext.base64EncodedString(),
            wrappedKeyTagB64: wrappedKeyTag.base64EncodedString(),
            payloadNonceB64: payloadNonce.base64EncodedString(),
            payloadCiphertextB64: payloadCiphertext.base64EncodedString(),
            payloadTagB64: payloadTag.base64EncodedString(),
            fingerprint: fingerprint
        )
        return canonicalHeaderData(header)
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
