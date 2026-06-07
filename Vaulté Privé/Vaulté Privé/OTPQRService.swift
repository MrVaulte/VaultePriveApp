//
//  OTPQRService.swift
//  Vaulté Privé
//

import CoreImage
import Foundation
import UIKit

/// Offline import/export of pad batches. JSON is encoded/decoded without logging contents.
struct OTPQRPayload: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var conversationId: UUID
    var direction: OTPDirection
    var pads: [OTPQRPadEntry]
}

struct OTPQRPadEntry: Codable, Equatable, Sendable {
    var id: UUID
    /// Base64-encoded random bytes (not Unicode “otp text”).
    var bytesB64: String
    var createdAt: Date
}

enum OTPQRService {
    private static let batchTokenRegex = try! NSRegularExpression(pattern: #"^VP-[A-Z0-9]{6}-[A-Z0-9]{2}$"#)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Approximate safe size for a single on-screen QR (payload varies by correction level).
    static let recommendedMaxUTF8Bytes = 1_200

    static func validateBatchToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let range = NSRange(location: 0, length: normalized.utf16.count)
        guard range.length > 0 else { return false }
        return batchTokenRegex.firstMatch(in: normalized, options: [], range: range) != nil
    }

    static func encodePayload(_ payload: OTPQRPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> OTPQRPayload {
        try decoder.decode(OTPQRPayload.self, from: data)
    }

    static func decodePayload(from qrString: String) throws -> OTPQRPayload {
        guard let data = qrString.data(using: .utf8) else {
            throw OTPError.importPayloadInvalid
        }
        return try decodePayload(data)
    }

    static func makeQRImage(from string: String, scale: CGFloat = 12) throws -> UIImage {
        let data = try makeQRImageData(from: string, scale: scale)
        guard let image = UIImage(data: data) else {
            throw OTPError.qrEncodeFailure
        }
        return image
    }

    static func makeQRImageData(from string: String, scale: CGFloat) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw OTPError.qrEncodeFailure
        }
        guard data.count <= recommendedMaxUTF8Bytes else {
            throw OTPError.payloadTooLargeForQR(data.count)
        }

        let ctx = CIContext()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw OTPError.qrEncodeFailure
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            throw OTPError.qrEncodeFailure
        }
        guard let falseColor = CIFilter(name: "CIFalseColor") else {
            throw OTPError.qrEncodeFailure
        }
        falseColor.setValue(output, forKey: kCIInputImageKey)
        falseColor.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        falseColor.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor1")
        guard let colored = falseColor.outputImage else {
            throw OTPError.qrEncodeFailure
        }

        let scaled = colored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else {
            throw OTPError.qrEncodeFailure
        }
        let ui = UIImage(cgImage: cg)
        guard let png = ui.pngData() else {
            throw OTPError.qrEncodeFailure
        }
        return png
    }
}
