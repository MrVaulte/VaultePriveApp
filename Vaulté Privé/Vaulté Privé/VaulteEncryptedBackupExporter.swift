//
//  VaulteEncryptedBackupExporter.swift
//  Vaulté Privé
//
//  Creates a passphrase-protected archive of the local SQLite DB (ciphertext + metadata only on disk).
//

import CommonCrypto
import CryptoKit
import Foundation

enum VaulteEncryptedBackupExporter {

    struct ExportResult: Sendable {
        let fileURL: URL
        let byteCount: Int
    }

    /// Wraps `store.sqlite3` in AES-GCM using a key from PBKDF2-HMAC-SHA256(passphrase, salt).
    static func exportEncryptedArchive(passphrase: String) throws -> ExportResult {
        let src = try OTPStore.defaultStoreSQLiteURL()
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw ExportError.storeMissing
        }
        let plain = try Data(contentsOf: src)
        let salt = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
        let keyMaterial = try pbkdf2SHA256(password: passphrase, salt: salt, iterations: 210_000, keyByteCount: 32)
        let key = SymmetricKey(data: keyMaterial)
        let sealed = try AES.GCM.seal(plain, using: key)
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        let body = nonce + sealed.ciphertext + sealed.tag
        var out = Data()
        out.append("VAULTBACK1".data(using: .utf8)!)
        out.append(salt)
        out.append(body)

        let outDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let name = "VaultePrive_Backup_\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).vaultbackup"
        let dest = outDir.appendingPathComponent(name, isDirectory: false)
        try out.write(to: dest, options: [.atomic])
        return ExportResult(fileURL: dest, byteCount: out.count)
    }

    private static func pbkdf2SHA256(password: String, salt: Data, iterations: UInt32, keyByteCount: Int) throws -> Data {
        var derived = Data(count: keyByteCount)
        let pw = password.data(using: .utf8) ?? Data()
        let status: Int32 = derived.withUnsafeMutableBytes { derivedPtr in
            pw.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pw.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ExportError.kdfFailed }
        return derived
    }

    enum ExportError: Error {
        case storeMissing
        case kdfFailed
    }
}
