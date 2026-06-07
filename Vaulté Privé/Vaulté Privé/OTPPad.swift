//
//  OTPPad.swift
//  Vaulté Privé
//

import Foundation

enum OTPDirection: String, Codable, CaseIterable, Sendable {
    case outbound
    case inbound
}

struct OTPPad: Identifiable, Equatable, Sendable {
    let id: UUID
    var direction: OTPDirection
    /// Raw key material; keep in memory only as needed.
    var bytes: Data
    var isUsed: Bool
    var createdAt: Date

    var byteLength: Int { bytes.count }
}

struct OTPPadRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationId: UUID
    var direction: OTPDirection
    let byteLength: Int
    var isUsed: Bool
    let createdAt: Date
}

enum OTPError: Error, Equatable, Sendable {
    case padTooShort(plaintextBytes: Int, padBytes: Int)
    case padNotFound
    case padAlreadyUsed
    case invalidCiphertextLength
    case randomGenerationFailed
    case keychainFailure(status: OSStatus)
    case databaseError(String)
    case utf8DecodeFailed
    case payloadTooLargeForQR(Int)
    case qrEncodeFailure
    case importPayloadInvalid
    case e2ePlusEnvelopeInvalid
    case e2ePlusAuthenticationFailed
    case verifiedOtpUnavailable
    case verifiedOtpPeerIdentityUnavailable
    case verifiedOtpSigningKeyUnavailable
    case verifiedOtpInvalidBundle
    case verifiedOtpBundleNotFound
    case verifiedOtpBundleMismatch
    case verifiedOtpBundleExhausted
    case verifiedOtpBundleRevoked
    case verifiedOtpReplayDetected
    case verifiedOtpAuthenticationFailed
    case verifiedOtpStorageFailure
    case verifiedOtpEliteRequired
}
