//
//  OTPCodec.swift
//  Vaulté Privé
//

import Foundation
import CryptoKit

// MARK: - Legacy key derivation helpers (kept for v1/v2 backward compat)

enum SuperVaulteRatchet: Sendable {
    static func messageKey(
        rootKey: Data,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID,
        messageId: UUID
    ) -> Data {
        var material = Data()
        material.append(Data("super.vaulte.ratchet.v1|".utf8))
        material.append(Data(conversationId.uuidString.lowercased().utf8))
        material.append(Data("|".utf8))
        material.append(Data(senderId.uuidString.lowercased().utf8))
        material.append(Data("|".utf8))
        material.append(Data(recipientId.uuidString.lowercased().utf8))
        material.append(Data("|".utf8))
        material.append(Data(messageId.uuidString.lowercased().utf8))
        let key = SymmetricKey(data: rootKey)
        let mac = HMAC<SHA256>.authenticationCode(for: material, using: key)
        return Data(mac)
    }

    static func messageKeyPair(
        rootKey: Data,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID,
        messageId: UUID
    ) -> (inner: Data, outer: Data) {
        let salt = contextSalt(
            conversationId: conversationId,
            senderId: senderId,
            recipientId: recipientId,
            messageId: messageId
        )
        let shared = SymmetricKey(data: rootKey).withUnsafeBytes { Data($0) }
        let innerKey = hkdfDerive(inputKey: shared, salt: salt, info: Data("svr2.inner.chacha.v2".utf8), outputByteCount: 32)
        let outerKey = hkdfDerive(inputKey: shared, salt: salt, info: Data("svr2.outer.aesgcm.v2".utf8), outputByteCount: 32)
        return (innerKey, outerKey)
    }

    static func keyCommitment(_ keyData: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("svr2.commit|".utf8))
        hasher.update(data: keyData)
        return Data(hasher.finalize())
    }

    private static func contextSalt(
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID,
        messageId: UUID
    ) -> Data {
        var salt = Data("super.vaulte.ratchet.v2|".utf8)
        salt.append(Data(conversationId.uuidString.lowercased().utf8))
        salt.append(Data("|".utf8))
        salt.append(Data(senderId.uuidString.lowercased().utf8))
        salt.append(Data("|".utf8))
        salt.append(Data(recipientId.uuidString.lowercased().utf8))
        salt.append(Data("|".utf8))
        salt.append(Data(messageId.uuidString.lowercased().utf8))
        return salt
    }

    static func hkdfDerive(
        inputKey: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int
    ) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKey),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Message padding

enum MessagePadding: Sendable {
    static let blockSize = 256
    static let magicByte: UInt8 = 0x80

    static func pad(_ plaintext: Data) -> Data {
        let needed = blockSize - ((plaintext.count + 1) % blockSize)
        let paddingLength = (needed == blockSize) ? 0 : needed
        var padded = plaintext
        padded.append(magicByte)
        padded.append(Data(repeating: 0x00, count: paddingLength))
        return padded
    }

    static func unpad(_ padded: Data) -> Data? {
        guard !padded.isEmpty else { return nil }
        var idx = padded.count - 1
        while idx >= 0 && padded[idx] == 0x00 { idx -= 1 }
        guard idx >= 0 && padded[idx] == magicByte else { return nil }
        return padded.prefix(idx)
    }
}

// MARK: - OTPCodec (legacy XOR)

enum OTPCodec: Sendable {
    static func seal(plaintext: Data, pad: Data) throws -> Data {
        guard plaintext.count <= pad.count else {
            throw OTPError.padTooShort(plaintextBytes: plaintext.count, padBytes: pad.count)
        }
        var out = Data(count: plaintext.count)
        out.withUnsafeMutableBytes { outPtr in
            plaintext.withUnsafeBytes { pPtr in
                pad.withUnsafeBytes { kPtr in
                    let o = outPtr.bindMemory(to: UInt8.self).baseAddress!
                    let p = pPtr.bindMemory(to: UInt8.self).baseAddress!
                    let k = kPtr.bindMemory(to: UInt8.self).baseAddress!
                    for i in 0 ..< plaintext.count { o[i] = p[i] ^ k[i] }
                }
            }
        }
        return out
    }

    static func open(ciphertext: Data, pad: Data) throws -> Data {
        guard ciphertext.count <= pad.count else {
            throw OTPError.invalidCiphertextLength
        }
        var out = Data(count: ciphertext.count)
        out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { cPtr in
                pad.withUnsafeBytes { kPtr in
                    let o = outPtr.bindMemory(to: UInt8.self).baseAddress!
                    let c = cPtr.bindMemory(to: UInt8.self).baseAddress!
                    let k = kPtr.bindMemory(to: UInt8.self).baseAddress!
                    for i in 0 ..< ciphertext.count { o[i] = c[i] ^ k[i] }
                }
            }
        }
        return out
    }
}

enum VerifiedOtpCodec: Sendable {
    private static let mode = "verified_otp"
    private static let headerDomain = Data("vaulte.verifiedotp.envelope.v1|".utf8)

    static func seal(
        innerPayload: String,
        bundle: VerifiedOtpBundleRecord,
        padBytes: Data,
        reservation: VerifiedOtpSendReservation,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> String {
        let plaintext = Data(innerPayload.utf8)
        guard reservation.offset + plaintext.count <= padBytes.count else {
            throw OTPError.verifiedOtpBundleExhausted
        }
        let slice = padBytes.subdata(in: reservation.offset ..< reservation.offset + plaintext.count)
        let ciphertext = try OTPCodec.seal(plaintext: plaintext, pad: slice)
        let macKey = SuperVaulteRatchet.hkdfDerive(
            inputKey: slice,
            salt: Data(bundle.bundleId.uuidString.lowercased().utf8),
            info: Data("vaulte.verifiedotp.slice.mac.v1".utf8),
            outputByteCount: 32
        )
        let aad = envelopeAAD(
            bundleId: bundle.bundleId,
            sequence: reservation.sequence,
            offset: reservation.offset,
            length: ciphertext.count,
            messageId: messageId,
            conversationId: conversationId,
            senderId: senderId,
            recipientId: recipientId
        )
        let mac = HMAC<SHA256>.authenticationCode(for: aad + ciphertext, using: SymmetricKey(data: macKey))
        let envelope = VerifiedOtpEnvelope(
            schemaVersion: 1,
            mode: mode,
            bundleId: bundle.bundleId.uuidString.lowercased(),
            sequence: reservation.sequence,
            offset: reservation.offset,
            ciphertextB64: ciphertext.base64EncodedString(),
            macB64: Data(mac).base64EncodedString()
        )
        let data = try JSONEncoder().encode(envelope)
        return data.base64EncodedString()
    }

    static func looksLikeEnvelope(_ payloadB64: String) -> Bool {
        guard let data = Data(base64Encoded: payloadB64),
              let env = try? JSONDecoder().decode(VerifiedOtpEnvelope.self, from: data)
        else { return false }
        return env.schemaVersion == 1 && env.mode == mode
    }

    static func open(
        payloadB64: String,
        bundle: VerifiedOtpBundleRecord,
        padBytes: Data,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> (innerPayload: String, envelope: VerifiedOtpEnvelope) {
        guard let data = Data(base64Encoded: payloadB64) else {
            throw OTPError.verifiedOtpInvalidBundle
        }
        let envelope = try JSONDecoder().decode(VerifiedOtpEnvelope.self, from: data)
        guard envelope.schemaVersion == 1,
              envelope.mode == mode,
              envelope.bundleId == bundle.bundleId.uuidString.lowercased(),
              let ciphertext = Data(base64Encoded: envelope.ciphertextB64),
              let mac = Data(base64Encoded: envelope.macB64)
        else {
            throw OTPError.verifiedOtpInvalidBundle
        }
        if VerifiedOtpRangeTracker.containsReplay(
            rangesJSON: bundle.consumedRangesJSON,
            start: envelope.offset,
            length: ciphertext.count
        ) {
            throw OTPError.verifiedOtpReplayDetected
        }
        guard envelope.offset >= 0,
              envelope.offset + ciphertext.count <= padBytes.count
        else {
            throw OTPError.verifiedOtpInvalidBundle
        }
        let slice = padBytes.subdata(in: envelope.offset ..< envelope.offset + ciphertext.count)
        let macKey = SuperVaulteRatchet.hkdfDerive(
            inputKey: slice,
            salt: Data(bundle.bundleId.uuidString.lowercased().utf8),
            info: Data("vaulte.verifiedotp.slice.mac.v1".utf8),
            outputByteCount: 32
        )
        let aad = envelopeAAD(
            bundleId: bundle.bundleId,
            sequence: envelope.sequence,
            offset: envelope.offset,
            length: ciphertext.count,
            messageId: messageId,
            conversationId: conversationId,
            senderId: senderId,
            recipientId: recipientId
        )
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(for: aad + ciphertext, using: SymmetricKey(data: macKey)))
        guard expectedMac == mac else {
            throw OTPError.verifiedOtpAuthenticationFailed
        }
        let plaintext = try OTPCodec.open(ciphertext: ciphertext, pad: slice)
        guard let inner = String(data: plaintext, encoding: .utf8) else {
            throw OTPError.utf8DecodeFailed
        }
        return (inner, envelope)
    }

    private static func envelopeAAD(
        bundleId: UUID,
        sequence: Int,
        offset: Int,
        length: Int,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) -> Data {
        var data = headerDomain
        data.append(Data(bundleId.uuidString.lowercased().utf8))
        data.append(Data("|".utf8))
        data.append(Data(String(sequence).utf8))
        data.append(Data("|".utf8))
        data.append(Data(String(offset).utf8))
        data.append(Data("|".utf8))
        data.append(Data(String(length).utf8))
        data.append(Data("|".utf8))
        data.append(Data(messageId.uuidString.lowercased().utf8))
        data.append(Data("|".utf8))
        data.append(Data(conversationId.uuidString.lowercased().utf8))
        data.append(Data("|".utf8))
        data.append(Data(senderId.uuidString.lowercased().utf8))
        data.append(Data("|".utf8))
        data.append(Data(recipientId.uuidString.lowercased().utf8))
        return data
    }
}

// MARK: - Legacy envelope types (kept for backward compat decryption only)

private struct E2EPlusEnvelopeV1: Codable, Sendable {
    let version: Int
    let mode: String
    let nonceB64: String
    let ciphertextB64: String
    let tagB64: String
}

private struct E2EPlusEnvelopeV2: Codable, Sendable {
    let version: Int
    let mode: String
    let innerNonceB64: String
    let innerCiphertextB64: String
    let innerTagB64: String
    let outerNonceB64: String
    let outerCiphertextB64: String
    let outerTagB64: String
    let commitB64: String
}

struct RoutedE2EPlusEnvelopeV3: Codable, Sendable {
    let version: Int
    let mode: String
    let contextId: String
    let nonceB64: String
    let ciphertextB64: String
    let tagB64: String
}

enum RoutedE2EPlusCodec: Sendable {
    private static let mode = "routed_e2e_plus"

    static func seal(
        innerPayload: String,
        context: ConversationKeyStore.E2EPlusContext,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> String {
        guard let keyData = context.keyData, keyData.count == 32 else {
            throw OTPError.e2ePlusEnvelopeInvalid
        }
        let nonce = try ChaChaPoly.Nonce()
        let aad = outerAAD(
            contextId: context.contextId,
            messageId: messageId,
            conversationId: conversationId,
            senderId: senderId,
            recipientId: recipientId
        )
        let sealed = try ChaChaPoly.seal(Data(innerPayload.utf8), using: SymmetricKey(data: keyData), nonce: nonce, authenticating: aad)
        let env = RoutedE2EPlusEnvelopeV3(
            version: 3,
            mode: mode,
            contextId: context.contextId.uuidString.lowercased(),
            nonceB64: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertextB64: sealed.ciphertext.base64EncodedString(),
            tagB64: sealed.tag.base64EncodedString()
        )
        let payload = try JSONEncoder().encode(env)
        return payload.base64EncodedString()
    }

    static func looksLikeEnvelope(_ payloadB64: String) -> Bool {
        guard let data = Data(base64Encoded: payloadB64),
              let env = try? JSONDecoder().decode(RoutedE2EPlusEnvelopeV3.self, from: data)
        else { return false }
        return env.version == 3 && env.mode == mode
    }

    static func looksLikeDecodedEnvelopeJSONString(_ plaintext: String) -> Bool {
        guard let data = plaintext.data(using: .utf8),
              let env = try? JSONDecoder().decode(RoutedE2EPlusEnvelopeV3.self, from: data)
        else { return false }
        return env.version == 3 && env.mode == mode
    }

    static func open(
        payloadB64: String,
        contextLoader: (UUID) -> ConversationKeyStore.E2EPlusContext?,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> String {
        guard let data = Data(base64Encoded: payloadB64) else {
            throw OTPError.e2ePlusEnvelopeInvalid
        }
        let env = try JSONDecoder().decode(RoutedE2EPlusEnvelopeV3.self, from: data)
        guard env.version == 3, env.mode == mode,
              let contextId = UUID(uuidString: env.contextId),
              let context = contextLoader(contextId),
              let keyData = context.keyData,
              keyData.count == 32,
              let nonceData = Data(base64Encoded: env.nonceB64),
              let ciphertext = Data(base64Encoded: env.ciphertextB64),
              let tag = Data(base64Encoded: env.tagB64)
        else {
            throw OTPError.e2ePlusEnvelopeInvalid
        }
        let aad = outerAAD(
            contextId: contextId,
            messageId: messageId,
            conversationId: conversationId,
            senderId: senderId,
            recipientId: recipientId
        )
        let sealed = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        let inner = try ChaChaPoly.open(sealed, using: SymmetricKey(data: keyData), authenticating: aad)
        guard let innerString = String(data: inner, encoding: .utf8) else {
            throw OTPError.e2ePlusEnvelopeInvalid
        }
        return innerString
    }

    private static func outerAAD(
        contextId: UUID,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) -> Data {
        Data("ve3|\(contextId.uuidString.lowercased())|\(messageId.uuidString.lowercased())|\(conversationId.uuidString.lowercased())|\(senderId.uuidString.lowercased())|\(recipientId.uuidString.lowercased())".utf8)
    }
}

// MARK: - Legacy E2E+ Codec (decryption only for v1/v2 messages)

enum E2EPlusCodec: Sendable {
    private static let modeV1 = "e2e_plus"
    private static let modeV2 = "svr2_double_aead"

    static func open(
        payload: Data,
        pad: Data,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> Data {
        if let env = try? JSONDecoder().decode(E2EPlusEnvelopeV2.self, from: payload),
           env.version == 2, env.mode == modeV2 {
            return try openV2(env: env, pad: pad, messageId: messageId, conversationId: conversationId, senderId: senderId, recipientId: recipientId)
        }
        return try openV1(payload: payload, pad: pad, messageId: messageId, conversationId: conversationId, senderId: senderId, recipientId: recipientId)
    }

    private static func openV2(
        env: E2EPlusEnvelopeV2,
        pad: Data,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> Data {
        guard let outerNonceData = Data(base64Encoded: env.outerNonceB64),
              let outerCT = Data(base64Encoded: env.outerCiphertextB64),
              let outerTag = Data(base64Encoded: env.outerTagB64),
              let commitData = Data(base64Encoded: env.commitB64)
        else { throw OTPError.e2ePlusEnvelopeInvalid }

        let keys = SuperVaulteRatchet.messageKeyPair(
            rootKey: pad, conversationId: conversationId,
            senderId: senderId, recipientId: recipientId, messageId: messageId
        )
        let localCommit = SuperVaulteRatchet.keyCommitment(keys.inner + keys.outer)
        guard localCommit == commitData else { throw OTPError.e2ePlusAuthenticationFailed }

        let outerKey = SymmetricKey(data: keys.outer)
        let baseAAD = aad(messageId: messageId, conversationId: conversationId, senderId: senderId, recipientId: recipientId)
        var outerAAD = Data("svr2.outer|".utf8)
        outerAAD.append(baseAAD)
        outerAAD.append(commitData)

        let outerNonce = try AES.GCM.Nonce(data: outerNonceData)
        let outerSealed = try AES.GCM.SealedBox(nonce: outerNonce, ciphertext: outerCT, tag: outerTag)
        let innerBundle = try AES.GCM.open(outerSealed, using: outerKey, authenticating: outerAAD)

        guard innerBundle.count > 28 else { throw OTPError.e2ePlusEnvelopeInvalid }
        let innerNonceData = innerBundle.prefix(12)
        let innerTag = innerBundle.suffix(16)
        let innerCT = innerBundle.dropFirst(12).dropLast(16)

        let innerKey = SymmetricKey(data: keys.inner)
        var innerAAD = baseAAD
        innerAAD.append(commitData)

        let innerNonce = try ChaChaPoly.Nonce(data: innerNonceData)
        let innerSealed = try ChaChaPoly.SealedBox(nonce: innerNonce, ciphertext: innerCT, tag: innerTag)
        let padded = try ChaChaPoly.open(innerSealed, using: innerKey, authenticating: innerAAD)

        guard let unpadded = MessagePadding.unpad(padded) else {
            throw OTPError.e2ePlusEnvelopeInvalid
        }
        return unpadded
    }

    private static func openV1(
        payload: Data,
        pad: Data,
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) throws -> Data {
        let env = try JSONDecoder().decode(E2EPlusEnvelopeV1.self, from: payload)
        guard env.version == 1, env.mode == modeV1,
              let nonceData = Data(base64Encoded: env.nonceB64),
              let ct = Data(base64Encoded: env.ciphertextB64),
              let tag = Data(base64Encoded: env.tagB64)
        else { throw OTPError.e2ePlusEnvelopeInvalid }

        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let key = try deriveKeyV1(pad: pad)
        let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(
            sealed, using: key,
            authenticating: aad(messageId: messageId, conversationId: conversationId, senderId: senderId, recipientId: recipientId)
        )
    }

    static func looksLikeEnvelope(_ payload: Data) -> Bool {
        if let v2 = try? JSONDecoder().decode(E2EPlusEnvelopeV2.self, from: payload),
           v2.version == 2, v2.mode == modeV2 { return true }
        if let v1 = try? JSONDecoder().decode(E2EPlusEnvelopeV1.self, from: payload),
           v1.version == 1, v1.mode == modeV1 { return true }
        return false
    }

    private static func deriveKeyV1(pad: Data) throws -> SymmetricKey {
        guard !pad.isEmpty else {
            throw OTPError.padTooShort(plaintextBytes: 1, padBytes: 0)
        }
        var material = Data("vaulte.e2eplus.v1.key".utf8)
        material.append(pad.prefix(64))
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    private static func aad(
        messageId: UUID, conversationId: UUID,
        senderId: UUID, recipientId: UUID
    ) -> Data {
        Data("v2|\(messageId.uuidString)|\(conversationId.uuidString)|\(senderId.uuidString)|\(recipientId.uuidString)".utf8)
    }
}
