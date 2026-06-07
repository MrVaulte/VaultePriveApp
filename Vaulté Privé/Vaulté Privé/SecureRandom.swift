//
//  SecureRandom.swift
//  Vaulté Privé
//

import Foundation
import Security

enum SecureRandom {
    static func bytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else {
            throw OTPError.randomGenerationFailed
        }
        return Data(buffer)
    }
}
