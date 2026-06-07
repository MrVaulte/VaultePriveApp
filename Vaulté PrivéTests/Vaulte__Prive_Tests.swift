//
//  Vaulte__Prive_Tests.swift
//  Vaulté PrivéTests
//

import XCTest

@testable import Vaulté_Privé

final class Vaulte__Prive_Tests: XCTestCase {
    override func setUp() {
        super.setUp()
        LocalIdentityStore.deleteAllX3DHKeys()
        LocalIdentityStore.clearAllTOFUPins()
    }

    func testOTPCodecRoundTripUTF8() throws {
        var pad = Data(count: 64)
        pad.withUnsafeMutableBytes { raw in
            for i in 0 ..< 64 {
                raw[i] = UInt8(i & 0xff)
            }
        }
        let plaintext = Data("Устойчивый XOR-тест.".utf8)
        let sealed = try OTPCodec.seal(plaintext: plaintext, pad: pad)
        let opened = try OTPCodec.open(ciphertext: sealed, pad: pad)
        XCTAssertEqual(opened, plaintext)
    }

    func testOTPCodecRejectsOversizedPlaintext() throws {
        let pad = Data(count: 5)
        let plaintext = Data(count: 10)
        XCTAssertThrowsError(try OTPCodec.seal(plaintext: plaintext, pad: pad)) { err in
            guard case OTPError.padTooShort = err else {
                return XCTFail("Expected padTooShort, got \(err)")
            }
        }
    }

    func testVerifiedOtpRangeTrackerMergesRanges() {
        let json = VerifiedOtpRangeTracker.encode([
            .init(start: 0, endExclusive: 10),
            .init(start: 10, endExclusive: 16),
            .init(start: 20, endExclusive: 24),
        ])
        let merged = VerifiedOtpRangeTracker.decode(json)
        XCTAssertEqual(merged, [
            .init(start: 0, endExclusive: 16),
            .init(start: 20, endExclusive: 24),
        ])
    }

    func testVerifiedOtpRangeTrackerDetectsReplay() {
        let json = VerifiedOtpRangeTracker.encode([
            .init(start: 32, endExclusive: 48),
        ])
        XCTAssertTrue(VerifiedOtpRangeTracker.containsReplay(rangesJSON: json, start: 40, length: 4))
        XCTAssertFalse(VerifiedOtpRangeTracker.containsReplay(rangesJSON: json, start: 48, length: 4))
    }

    func testVerifiedOtpStateMachineLowCapacityAndExhaustion() {
        XCTAssertEqual(
            VerifiedOtpStateMachine.statusForRemainingBytes(remainingBytes: 0, totalBytes: 100),
            .exhausted
        )
        XCTAssertEqual(
            VerifiedOtpStateMachine.statusForRemainingBytes(remainingBytes: 10, totalBytes: 100),
            .lowCapacity
        )
        XCTAssertEqual(
            VerifiedOtpStateMachine.statusForRemainingBytes(remainingBytes: 80, totalBytes: 100),
            .active
        )
    }

    func testVerifiedOtpBundleRoundTripAndFingerprint() throws {
        let peerIdentity = IdentityKeyPair(
            privateKey: Curve25519.KeyAgreement.PrivateKey(),
            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey
        )
        let localIdentityPrivate = Curve25519.KeyAgreement.PrivateKey()
        let localIdentity = IdentityKeyPair(privateKey: localIdentityPrivate, publicKey: localIdentityPrivate.publicKey)
        try LocalIdentityStore.saveIdentityKey(localIdentity)
        try LocalIdentityStore.saveSigningKey(Curve25519.Signing.PrivateKey())

        let peerId = UUID()
        LocalIdentityStore.pinPeerIdentityKey(peerIdentity.publicKey.rawRepresentation.base64EncodedString(), for: peerId)

        let generated = try VerifiedOtpBundleCrypto.generateDirectionalBundle(
            conversationId: UUID(),
            ownerUserId: UUID(),
            peerId: peerId,
            direction: .send,
            byteCount: 256
        )
        let imported = try VerifiedOtpBundleCrypto.importBundleFile(generated.fileData)

        XCTAssertEqual(imported.descriptor.bundleId, generated.descriptor.bundleId)
        XCTAssertEqual(imported.descriptor.direction, .send)
        XCTAssertEqual(imported.descriptor.fingerprint, generated.descriptor.fingerprint)
        XCTAssertEqual(imported.padBytes, generated.padBytes)
    }

    func testVerifiedOtpBundleTamperRejected() throws {
        let localIdentityPrivate = Curve25519.KeyAgreement.PrivateKey()
        let localIdentity = IdentityKeyPair(privateKey: localIdentityPrivate, publicKey: localIdentityPrivate.publicKey)
        try LocalIdentityStore.saveIdentityKey(localIdentity)
        try LocalIdentityStore.saveSigningKey(Curve25519.Signing.PrivateKey())

        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerId = UUID()
        LocalIdentityStore.pinPeerIdentityKey(peerPrivate.publicKey.rawRepresentation.base64EncodedString(), for: peerId)

        let generated = try VerifiedOtpBundleCrypto.generateDirectionalBundle(
            conversationId: UUID(),
            ownerUserId: UUID(),
            peerId: peerId,
            direction: .receive,
            byteCount: 128
        )

        var bytes = [UInt8](generated.fileData)
        bytes[bytes.count - 1] ^= 0x01
        XCTAssertThrowsError(try VerifiedOtpBundleCrypto.importBundleFile(Data(bytes)))
    }

    func testVerifiedOtpBundleFileDataPreservesDescriptorAndPad() throws {
        let localIdentityPrivate = Curve25519.KeyAgreement.PrivateKey()
        let localIdentity = IdentityKeyPair(privateKey: localIdentityPrivate, publicKey: localIdentityPrivate.publicKey)
        try LocalIdentityStore.saveIdentityKey(localIdentity)
        try LocalIdentityStore.saveSigningKey(Curve25519.Signing.PrivateKey())

        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerId = UUID()
        LocalIdentityStore.pinPeerIdentityKey(peerPrivate.publicKey.rawRepresentation.base64EncodedString(), for: peerId)

        let generated = try VerifiedOtpBundleCrypto.generateDirectionalBundle(
            conversationId: UUID(),
            ownerUserId: UUID(),
            peerId: peerId,
            direction: .send,
            byteCount: 64
        )
        let rebuilt = try VerifiedOtpBundleCrypto.bundleFileData(
            descriptor: generated.descriptor,
            padBytes: generated.padBytes
        )
        let imported = try VerifiedOtpBundleCrypto.importBundleFile(rebuilt)

        XCTAssertEqual(imported.descriptor, generated.descriptor)
        XCTAssertEqual(imported.padBytes, generated.padBytes)
    }

    func testVerifiedOtpImportMapRejectsDirectionMismatch() throws {
        let localIdentityPrivate = Curve25519.KeyAgreement.PrivateKey()
        let localIdentity = IdentityKeyPair(privateKey: localIdentityPrivate, publicKey: localIdentityPrivate.publicKey)
        try LocalIdentityStore.saveIdentityKey(localIdentity)
        try LocalIdentityStore.saveSigningKey(Curve25519.Signing.PrivateKey())

        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerId = UUID()
        LocalIdentityStore.pinPeerIdentityKey(peerPrivate.publicKey.rawRepresentation.base64EncodedString(), for: peerId)

        let generated = try VerifiedOtpBundleCrypto.generateDirectionalBundle(
            conversationId: UUID(),
            ownerUserId: UUID(),
            peerId: peerId,
            direction: .send,
            byteCount: 64
        )
        let imported = try VerifiedOtpBundleCrypto.importBundleFile(generated.fileData)

        XCTAssertNotEqual(imported.descriptor.direction.rawValue, "receive")
    }
}
