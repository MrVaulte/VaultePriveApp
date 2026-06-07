//
//  VaulteRatchet.swift
//  Vaulté Privé
//
//  Double Ratchet Algorithm (Signal spec) with X3DH initialization.
//  Initialization via X3DH handshake:
//    - Fetch prekey bundle from server
//    - Perform DH exchanges: IK_A, EK_A, IK_B, SPK_B, OPK_B
//    - Derive shared secret with HKDF
//
//  Wire format for every e2: message:
//    ratchetPub(32) | prevChainLen(4 BE) | msgNum(4 BE) | nonce(12) | ciphertext | tag(16)
//    total overhead: 68 bytes + plaintext length
//

import CryptoKit
import Foundation

// MARK: - X3DH Key Structures

struct IdentityKeyPair: Codable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Curve25519.KeyAgreement.PublicKey
}

struct SignedPreKeyPair: Codable {
    let keyId: Int
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Curve25519.KeyAgreement.PublicKey
    let signature: Data  // Signed by identity key
}

struct OneTimePreKeyPair: Codable {
    let keyId: Int
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Curve25519.KeyAgreement.PublicKey
}

struct PreKeyBundle {
    let identityKey: Curve25519.KeyAgreement.PublicKey
    let signedPreKeyId: Int
    let signedPreKey: Curve25519.KeyAgreement.PublicKey
    let signedPreKeySignature: Data
    let oneTimePreKeyId: Int?
    let oneTimePreKey: Curve25519.KeyAgreement.PublicKey?
}

// MARK: - Codable Extensions for CryptoKit Keys

extension Curve25519.KeyAgreement.PrivateKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        try self.init(rawRepresentation: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawRepresentation)
    }
}

extension Curve25519.KeyAgreement.PublicKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        try self.init(rawRepresentation: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawRepresentation)
    }
}

// MARK: - Session state (Codable → stored as JSON in Keychain)

struct VaulteRatchetState: Codable {
    /// Current root key (32 bytes).
    var rootKey: Data
    /// Send-chain key for the current ratchet epoch (nil for Bob before first recv).
    var sendChainKey: Data?
    /// Receive-chain key for the current ratchet epoch (nil until first recv).
    var recvChainKey: Data?
    /// Our current send-ratchet private key (X25519 raw representation).
    var sendRatchetPriv: Data
    /// Peer's latest ratchet public key (nil for Bob before first recv).
    var recvRatchetPub: Data?
    /// How many messages we have sent on the current send chain.
    var sendCount: UInt32 = 0
    /// How many messages we have received on the current recv chain.
    var recvCount: UInt32 = 0
    /// Length of the *previous* send chain (saved when we do a DH ratchet step).
    var prevSendCount: UInt32 = 0
    /// Out-of-order message keys: "{peerRatchetPubBase64}:{msgNum}" → 32-byte message key.
    var skippedKeys: [String: Data] = [:]

    static let maxSkip: Int = 50
}

// MARK: - Core ratchet

enum VaulteRatchet {

    // ────────────────────────────────────────────────────────────
    // MARK: Initialisation
    // ────────────────────────────────────────────────────────────

    /// Initialise as **Alice** (local UUID < peer UUID).
    /// Alice does an immediate DH-ratchet step to produce her first send-chain.
    static func initAlice(
        masterSecret: Data,
        aliceRatchetPriv: Curve25519.KeyAgreement.PrivateKey,
        bobInitialRatchetPub: Curve25519.KeyAgreement.PublicKey
    ) throws -> VaulteRatchetState {
        let dhOut = try aliceRatchetPriv.sharedSecretFromKeyAgreement(with: bobInitialRatchetPub)
        let (newRK, sendCK) = kdfRK(rootKey: masterSecret, dhOutput: dhOut)
        return VaulteRatchetState(
            rootKey: newRK,
            sendChainKey: sendCK,
            recvChainKey: nil,
            sendRatchetPriv: aliceRatchetPriv.rawRepresentation,
            recvRatchetPub: bobInitialRatchetPub.rawRepresentation
        )
    }

    /// Initialise as **Bob** (local UUID > peer UUID).
    /// Bob's send-chain is nil until he receives Alice's first e2: message.
    static func initBob(
        masterSecret: Data,
        bobRatchetPriv: Curve25519.KeyAgreement.PrivateKey
    ) -> VaulteRatchetState {
        return VaulteRatchetState(
            rootKey: masterSecret,
            sendChainKey: nil,
            recvChainKey: nil,
            sendRatchetPriv: bobRatchetPriv.rawRepresentation,
            recvRatchetPub: nil
        )
    }

    // ────────────────────────────────────────────────────────────
    // MARK: X3DH Initialization
    // ────────────────────────────────────────────────────────────

    /// Initialize session as Alice using X3DH handshake.
    /// Alice fetches Bob's prekey bundle and performs DH exchanges.
    static func initAliceX3DH(
        aliceIdentityKey: IdentityKeyPair,
        aliceEphemeralKey: Curve25519.KeyAgreement.PrivateKey,
        bobPreKeyBundle: PreKeyBundle
    ) throws -> (VaulteRatchetState, Curve25519.KeyAgreement.PrivateKey) {
        // DH1 = DH(IKA, SPKB)
        let dh1 = try aliceIdentityKey.privateKey.sharedSecretFromKeyAgreement(with: bobPreKeyBundle.signedPreKey)

        // DH2 = DH(EKA, IKB)
        let dh2 = try aliceEphemeralKey.sharedSecretFromKeyAgreement(with: bobPreKeyBundle.identityKey)

        // DH3 = DH(EKA, SPKB)
        let dh3 = try aliceEphemeralKey.sharedSecretFromKeyAgreement(with: bobPreKeyBundle.signedPreKey)

        var dh4: SharedSecret?
        if let opk = bobPreKeyBundle.oneTimePreKey {
            // DH4 = DH(EKA, OPKB)
            dh4 = try aliceEphemeralKey.sharedSecretFromKeyAgreement(with: opk)
        }

        // Concatenate DH outputs in order: DH1 || DH2 || DH3 || DH4
        var dhOutputs = dh1.withUnsafeBytes { Data($0) }
        dhOutputs.append(dh2.withUnsafeBytes { Data($0) })
        dhOutputs.append(dh3.withUnsafeBytes { Data($0) })
        if let dh4 = dh4 {
            dhOutputs.append(dh4.withUnsafeBytes { Data($0) })
        }

        // HKDF to derive master secret
        let masterSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOutputs),
            salt: "Vaulté X3DH".data(using: .utf8)!,
            outputByteCount: 32
        )

        // Generate Alice's initial ratchet key
        let aliceRatchetPriv = Curve25519.KeyAgreement.PrivateKey()

        // Initialize as Alice with the master secret
        let state = try initAlice(
            masterSecret: masterSecret.withUnsafeBytes { Data($0) },
            aliceRatchetPriv: aliceRatchetPriv,
            bobInitialRatchetPub: bobPreKeyBundle.signedPreKey  // Use SPK as initial ratchet pub
        )

        return (state, aliceRatchetPriv)
    }

    /// Initialize session as Bob using X3DH handshake.
    /// Bob receives Alice's identity key and ephemeral key.
    static func initBobX3DH(
        bobIdentityKey: IdentityKeyPair,
        bobSignedPreKey: SignedPreKeyPair,
        bobOneTimePreKey: OneTimePreKeyPair?,
        aliceIdentityKey: Curve25519.KeyAgreement.PublicKey,
        aliceEphemeralKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> VaulteRatchetState {
        // DH1 = DH(SPKB, IKA)
        let dh1 = try bobSignedPreKey.privateKey.sharedSecretFromKeyAgreement(with: aliceIdentityKey)
        // DH2 = DH(IKB, EKA)
        let dh2 = try bobIdentityKey.privateKey.sharedSecretFromKeyAgreement(with: aliceEphemeralKey)
        // DH3 = DH(SPKB, EKA)
        let dh3 = try bobSignedPreKey.privateKey.sharedSecretFromKeyAgreement(with: aliceEphemeralKey)
        var dh4: SharedSecret?
        if let opk = bobOneTimePreKey {
            // DH4 = DH(OPKB, EKA)
            dh4 = try opk.privateKey.sharedSecretFromKeyAgreement(with: aliceEphemeralKey)
        }
        var dhOutputs = dh1.withUnsafeBytes { Data($0) }
        dhOutputs.append(dh2.withUnsafeBytes { Data($0) })
        dhOutputs.append(dh3.withUnsafeBytes { Data($0) })
        if let dh4 {
            dhOutputs.append(dh4.withUnsafeBytes { Data($0) })
        }
        let masterSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOutputs),
            salt: Data("Vaulté X3DH".utf8),
            outputByteCount: 32
        )
        // ВАЖНО: Bob должен использовать signedPreKey.privateKey как initial ratchet key
        return initBob(
            masterSecret: masterSecret.withUnsafeBytes { Data($0) },
            bobRatchetPriv: bobSignedPreKey.privateKey
        )
    }

    // ────────────────────────────────────────────────────────────
    // MARK: Encrypt
    // ────────────────────────────────────────────────────────────

    /// Encrypt `plaintext`.  Returns raw wire bytes (no `e2:` prefix).
    /// Throws `VaulteRatchetError.sendChainNotInitialized` if the session
    /// hasn't been bootstrapped yet (Bob hasn't received Alice's first message).
    static func encrypt(plaintext: Data, state: inout VaulteRatchetState) throws -> Data {
        guard let ck = state.sendChainKey else {
            throw VaulteRatchetError.sendChainNotInitialized
        }

        let (newCK, mk) = kdfCK(chainKey: ck)
        state.sendChainKey = newCK

        guard let privKey = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: state.sendRatchetPriv
        ) else {
            throw VaulteRatchetError.invalidRatchetKey
        }
        let ratchetPub = privKey.publicKey.rawRepresentation

        let headerBytes = buildHeader(ratchetPub: ratchetPub,
                                      prevChainLen: state.prevSendCount,
                                      msgNum: state.sendCount)

        let nonce = try AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext,
                                      using: SymmetricKey(data: mk),
                                      nonce: nonce,
                                      authenticating: headerBytes)

        state.sendCount += 1

        // Wire: header(40) | nonce(12) | ciphertext | tag(16)
        var wire = headerBytes
        wire.append(nonce.withUnsafeBytes { Data($0) })
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)
        return wire
    }

    // ────────────────────────────────────────────────────────────
    // MARK: Decrypt
    // ────────────────────────────────────────────────────────────

    /// Decrypt raw wire bytes (no `e2:` prefix).
    static func decrypt(wireData: Data, state: inout VaulteRatchetState) throws -> Data {
        let minSize = 40 + 12 + 16  // header + nonce + tag
        guard wireData.count > minSize else { throw VaulteRatchetError.malformedMessage }

        let headerBytes = wireData.prefix(40)
        guard let (ratchetPub, prevChainLen, msgNum) = parseHeader(headerBytes) else {
            throw VaulteRatchetError.malformedMessage
        }
        let nonceData = wireData[40..<52]
        let ciphertextEnd = wireData.count - 16
        let ciphertext   = wireData[52..<ciphertextEnd]
        let tag          = wireData[ciphertextEnd...]

        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw VaulteRatchetError.malformedMessage
        }

        let pubB64 = ratchetPub.base64EncodedString()
        let skipKey = "\(pubB64):\(msgNum)"

        // ── Check skipped-message cache first ─────────────────
        if let mk = state.skippedKeys[skipKey] {
            state.skippedKeys.removeValue(forKey: skipKey)
            return try open(mk, nonce: nonce, ciphertext: ciphertext, tag: tag, aad: Data(headerBytes))
        }

        let isNewRatchetKey = (state.recvRatchetPub != ratchetPub)

        if isNewRatchetKey {
            // Skip any remaining messages on the old recv chain
            try skipKeys(until: Int(prevChainLen),
                         peerPubB64: state.recvRatchetPub?.base64EncodedString() ?? "",
                         state: &state)
            // DH ratchet step → update recvChainKey + new sendChainKey
            try dhRatchetStep(newRemotePubBytes: ratchetPub, state: &state)
        }

        // Skip to the message's position on the current recv chain
        try skipKeys(until: Int(msgNum), peerPubB64: pubB64, state: &state)

        // Consume next recv-chain key
        guard let ck = state.recvChainKey else { throw VaulteRatchetError.recvChainNotInitialized }
        let (newCK, mk) = kdfCK(chainKey: ck)
        state.recvChainKey = newCK
        state.recvCount += 1

        return try open(mk, nonce: nonce, ciphertext: ciphertext, tag: tag, aad: Data(headerBytes))
    }

    // ────────────────────────────────────────────────────────────
    // MARK: KDF primitives (public so IdentityKeyExchange can reuse)
    // ────────────────────────────────────────────────────────────

    /// KDF_RK(rootKey, dhOutput) → (new_rootKey, chainKey)
    /// Uses HKDF-SHA256; outputs 64 bytes split evenly.
    static func kdfRK(rootKey: Data, dhOutput: SharedSecret) -> (Data, Data) {
        let out = dhOutput.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: rootKey,
            sharedInfo: Data("VaulteRatchet-RK-CK".utf8),
            outputByteCount: 64
        ).withUnsafeBytes { Data($0) }
        return (out.prefix(32), Data(out.suffix(32)))
    }

    /// KDF_CK(chainKey) → (new_chainKey, messageKey)
    /// Uses HMAC-SHA256 constants 0x01 / 0x02 (Signal convention).
    static func kdfCK(chainKey: Data) -> (Data, Data) {
        let key = SymmetricKey(data: chainKey)
        let ck = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key))
        let mk = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key))
        return (ck, mk)
    }

    // ────────────────────────────────────────────────────────────
    // MARK: Private helpers
    // ────────────────────────────────────────────────────────────

    /// Two-step DH ratchet:
    ///  1.  DH(myOldPriv, newRemotePub)  → derive recv-chain key
    ///  2.  Generate new local priv key + DH(newLocalPriv, newRemotePub) → derive send-chain key
    private static func dhRatchetStep(
        newRemotePubBytes: Data,
        state: inout VaulteRatchetState
    ) throws {
        let remotePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: newRemotePubBytes)
        let localPriv  = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.sendRatchetPriv)

        // Step 1 – recv chain
        let dh1 = try localPriv.sharedSecretFromKeyAgreement(with: remotePub)
        let (rk1, recvCK) = kdfRK(rootKey: state.rootKey, dhOutput: dh1)

        // Step 2 – fresh local key + send chain
        let freshPriv = Curve25519.KeyAgreement.PrivateKey()
        let dh2 = try freshPriv.sharedSecretFromKeyAgreement(with: remotePub)
        let (rk2, sendCK) = kdfRK(rootKey: rk1, dhOutput: dh2)

        state.prevSendCount  = state.sendCount
        state.sendCount      = 0
        state.recvCount      = 0
        state.recvRatchetPub = newRemotePubBytes
        state.recvChainKey   = recvCK
        state.rootKey        = rk2
        state.sendChainKey   = sendCK
        state.sendRatchetPriv = freshPriv.rawRepresentation
    }

    /// Store skipped message keys up to (but not including) `msgNum`.
    private static func skipKeys(
        until msgNum: Int,
        peerPubB64: String,
        state: inout VaulteRatchetState
    ) throws {
        guard state.recvChainKey != nil else { return }
        let current = Int(state.recvCount)
        guard msgNum >= current else { return }
        guard msgNum - current <= VaulteRatchetState.maxSkip else {
            throw VaulteRatchetError.tooManySkippedMessages
        }
        var ck = state.recvChainKey!
        for n in current..<msgNum {
            let (newCK, mk) = kdfCK(chainKey: ck)
            state.skippedKeys["\(peerPubB64):\(n)"] = mk
            ck = newCK
        }
        state.recvChainKey = ck
        state.recvCount = UInt32(msgNum)
    }

    /// AEAD open with raw Data message-key and pre-parsed pieces.
    private static func open(
        _ mk: Data,
        nonce: AES.GCM.Nonce,
        ciphertext: Data.SubSequence,
        tag: Data.SubSequence,
        aad: Data
    ) throws -> Data {
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: mk), authenticating: aad)
    }

    // ── Wire header helpers ───────────────────────────────────

    /// Build 40-byte header: ratchetPub(32) | prevChainLen(4 BE) | msgNum(4 BE)
    private static func buildHeader(ratchetPub: Data, prevChainLen: UInt32, msgNum: UInt32) -> Data {
        var d = ratchetPub
        d.append(prevChainLen.bigEndianData)
        d.append(msgNum.bigEndianData)
        return d
    }

    /// Parse 40-byte header.
    private static func parseHeader(_ data: Data) -> (Data, UInt32, UInt32)? {
        guard data.count == 40 else { return nil }
        let pub  = Data(data.prefix(32))
        let prev = UInt32(bigEndianData: data[32..<36])
        let num  = UInt32(bigEndianData: data[36..<40])
        return (pub, prev, num)
    }
}

// MARK: - Error

enum VaulteRatchetError: Error, LocalizedError {
    case sendChainNotInitialized
    case recvChainNotInitialized
    case invalidRatchetKey
    case malformedMessage
    case tooManySkippedMessages
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .sendChainNotInitialized: return "Ratchet send-chain not ready (waiting for peer's first message)."
        case .recvChainNotInitialized: return "Ratchet recv-chain not ready."
        case .invalidRatchetKey:       return "Invalid ratchet key."
        case .malformedMessage:        return "Malformed ratchet message."
        case .tooManySkippedMessages:  return "Too many skipped messages in ratchet."
        case .decryptionFailed:        return "Ratchet decryption failed."
        }
    }
}

// MARK: - UInt32 big-endian helpers

private extension UInt32 {
    var bigEndianData: Data {
        var v = self.bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    init(bigEndianData slice: Data) {
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { ptr in
            slice.copyBytes(to: ptr)
        }
        self = UInt32(bigEndian: v)
    }
}
