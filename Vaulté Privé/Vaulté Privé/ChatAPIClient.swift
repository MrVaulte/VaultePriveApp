//
//  ChatAPIClient.swift
//  Vaulté Privé
//

import CommonCrypto
import CryptoKit
import Foundation

/// Fixed relay for this build (no manual server entry in the app UI).
/// Configure via Secrets.xcconfig — see Secrets.example.xcconfig for the required keys.
enum VaulteRelayConfiguration {
    private static func stringValue(infoKey: String, envKey: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let env = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.isEmpty ? nil : env
    }

    static let baseURL: URL = {
        let raw = stringValue(infoKey: "VAULTE_RELAY_BASE_URL", envKey: "VAULTE_RELAY_BASE_URL") ?? ""
        return URL(string: raw.isEmpty ? "https://localhost" : raw)!
    }()
    /// Keep `false` for Personal Team builds. Enable only on paid Apple Developer accounts with Push Notifications capability.
    static let pushNotificationsEnabled = false

    /// When the relay sets `RELAY_API_KEY`, set the same value here (or inject via build settings).
    static let apiKey: String? = stringValue(infoKey: "VAULTE_RELAY_API_KEY", envKey: "VAULTE_RELAY_API_KEY")
    /// Must equal relay env `RELAY_HMAC_SECRET` when the server enforces `X-Relay-Timestamp` / `X-Relay-Signature`.
    static let hmacSecret: String? = stringValue(infoKey: "VAULTE_RELAY_HMAC_SECRET", envKey: "VAULTE_RELAY_HMAC_SECRET")
    /// Must match relay `RELAY_USERNAME_PEPPER` for encrypted @username lookup.
    static let usernameLookupPepper: String? = stringValue(
        infoKey: "VAULTE_RELAY_USERNAME_LOOKUP_PEPPER",
        envKey: "VAULTE_RELAY_USERNAME_LOOKUP_PEPPER"
    )

    /// Pepper used for username HMAC lookup (explicit pepper, else HMAC secret).
    static var effectiveUsernameLookupPepper: String? {
        let pepper = usernameLookupPepper?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pepper.isEmpty { return pepper }
        let secret = hmacSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return secret.isEmpty ? nil : secret
    }

    /// SHA-256 hashes of allowed relay TLS certificate public keys (SPKI, base64-encoded).
    /// When non-empty, connections to any host NOT matching one of these hashes are rejected.
    ///
    /// Generate for your relay:
    ///   openssl s_client -connect <host>:443 </dev/null 2>/dev/null \
    ///     | openssl x509 -pubkey -noout \
    ///     | openssl pkey -pubin -outform der \
    ///     | openssl dgst -sha256 -binary \
    ///     | base64
    ///
    /// Add the result to Secrets.xcconfig as VAULTE_PINNED_KEY_HASHES (comma-separated for backup pins)
    /// and inject it here. An empty array disables pinning — acceptable only during development.
    static let pinnedPublicKeyHashes: [String] = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "VAULTE_PINNED_KEY_HASHES") as? String else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }()
}

// MARK: - Certificate pinning delegate

final class PinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = PinnedSessionDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        guard method == NSURLAuthenticationMethodServerTrust else {
            // Relay uses X-API-Key / HMAC-SHA256 headers — never HTTP Basic/Digest auth.
            completionHandler(.rejectProtectionSpace, nil)
            return
        }

        let pins = VaulteRelayConfiguration.pinnedPublicKeyHashes
        guard !pins.isEmpty else {
            // No pins configured — fall back to OS certificate validation.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust,
              SecTrustEvaluateWithError(serverTrust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Walk all certificates in the chain and check SPKI hash against pinset.
        var matched = false
        let certCount = SecTrustGetCertificateCount(serverTrust)
        outer: for i in 0..<certCount {
            guard let cert = SecTrustGetCertificateAtIndex(serverTrust, i) else { continue }
            // Extract DER-encoded SPKI by round-tripping through a temporary SecKey
            guard let pubKey = SecCertificateCopyKey(cert) else { continue }
            var cfError: Unmanaged<CFError>?
            guard let spkiData = SecKeyCopyExternalRepresentation(pubKey, &cfError) as Data? else { continue }

            // Prepend the ASN.1 SubjectPublicKeyInfo header appropriate for the key type.
            // SecKeyCopyExternalRepresentation returns the raw key bytes; we need the SPKI wrapper.
            // For Render/Let's Encrypt the leaf is EC P-256; add the standard SPKI header.
            let spkiHeader: [UInt8]
            let attributes = SecKeyCopyAttributes(pubKey) as? [String: Any]
            let keyType = attributes?[kSecAttrKeyType as String] as? String
            if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
                // EC P-256 SPKI header (RFC 5480)
                spkiHeader = [
                    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
                ]
            } else if keyType == (kSecAttrKeyTypeRSA as String) {
                // RSA-2048 SPKI header (RFC 3279) — covers Render and most CDN certs
                spkiHeader = [
                    0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7,
                    0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
                ]
            } else {
                continue
            }

            var fullSPKI = Data(spkiHeader)
            fullSPKI.append(spkiData)
            let hash = fullSPKI.withUnsafeBytes { ptr -> String in
                var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                CC_SHA256(ptr.baseAddress, CC_LONG(fullSPKI.count), &digest)
                return Data(digest).base64EncodedString()
            }

            if pins.contains(hash) {
                matched = true
                break outer
            }
        }

        if matched {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Single shared URLSession for all relay traffic. Avoids leaking transient sessions
/// (which get cancelled with -999 when their owner struct deallocates mid-request).
enum VaulteRelaySession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config,
                          delegate: PinnedSessionDelegate.shared,
                          delegateQueue: nil)
    }()
}

struct NetworkMessageDTO: Codable, Sendable, Equatable {
    let messageId: UUID
    let conversationId: UUID
    let senderId: UUID
    let recipientId: UUID
    let padId: UUID
    let ciphertextBase64: String
    let createdAt: Date
    /// Set by relay when recipient sends POST /messages/:id/ack
    let deliveredAt: Date?

    init(messageId: UUID, conversationId: UUID, senderId: UUID, recipientId: UUID,
         padId: UUID, ciphertextBase64: String, createdAt: Date, deliveredAt: Date? = nil) {
        self.messageId = messageId
        self.conversationId = conversationId
        self.senderId = senderId
        self.recipientId = recipientId
        self.padId = padId
        self.ciphertextBase64 = ciphertextBase64
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
    }
}

struct InitialX3DHMessageDTO: Codable, Sendable, Equatable {
    let messageId: UUID
    let conversationId: UUID
    let senderId: UUID
    let recipientId: UUID
    let identityKey: String  // Base64 encoded identity key
    let ephemeralKey: String  // Base64 encoded ephemeral key
    let signedPrekeyId: Int?  // ID of the signed prekey used
    let oneTimePrekeyId: Int?  // ID of the one-time prekey used (optional)
    let ciphertextBase64: String  // Encrypted initial message
    let createdAt: Date
}

struct RelayUserDTO: Codable, Sendable, Equatable, Identifiable {
    let userId: UUID
    let username: String
    let displayName: String?
    /// Profile photo as base64 (decrypted locally; on wire may be inside `profile_ciphertext_b64`).
    let avatarB64: String?
    let updatedAt: Date
    /// AES-GCM(JSON profile) keyed from the user's published X25519 identity public key.
    let profileCiphertextB64: String?
    var id: UUID { userId }

    /// JSON keys match Postgres / Express (`user_id`, …) — decoded with `keyDecodingStrategy = .useDefaultKeys`.
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case avatarB64 = "avatar_b64"
        case updatedAt = "updated_at"
        case profileCiphertextB64 = "profile_ciphertext_b64"
    }

    /// Returns display_name if set, otherwise falls back to @username.
    var bestDisplayName: String {
        if let d = displayName, !d.isEmpty { return d }
        if !username.isEmpty { return "@\(username)" }
        return "Vaulté User"
    }
}

struct RelayIdentityKeyDTO: Codable, Sendable, Equatable, Identifiable {
    let userId: UUID
    let keyType: String
    let publicKeyBase64: String
    let updatedAt: Date
    var id: UUID { userId }
}

/// Visually distinct badge tiers.
/// - `verified`: white crown, premium/purchasable
/// - `official`: white checkmark, admin-granted
/// - `diamond`: white diamond, platform owner / inner circle (admin-granted)
enum BadgeType: String, Codable, Sendable, Equatable {
    case verified   // white crown — premium
    case official   // white checkmark — admin only
    case diamond    // white diamond — owner tier, admin only
}

struct RelayBadgeDTO: Codable, Sendable {
    let userId: UUID
    let badgeType: BadgeType?
    let grantedBy: String?
    let grantedAt: Date?
}

struct RelayPadBatchRequest: Codable, Sendable, Equatable {
    let conversationId: UUID
    let direction: String
    let pads: [OTPQRPadEntry]
    let ownerUserId: UUID?
    let ttlSeconds: Int?
}

struct RelayPadBatchCreateResponse: Codable, Sendable, Equatable {
    let token: String
    let expiresAt: Date
}

struct RelayPadBatchDTO: Codable, Sendable, Equatable {
    let token: String
    let conversationId: UUID
    let direction: String
    let pads: [OTPQRPadEntry]
    let ownerUserId: UUID?
    let expiresAt: Date
}

private struct RelayPadBatchConsumeRequest: Codable, Sendable, Equatable {
    let requesterUserId: UUID?
}

struct SignedPrekeyDTO: Codable, Sendable {
    let keyId: Int
    let publicKeyBase64: String
    let signatureBase64: String
}

struct OneTimePrekeyDTO: Codable, Sendable {
    let keyId: Int
    let publicKeyBase64: String
}

struct PrekeyBundleDTO: Codable, Sendable {
    let identityKey: String
    let identityKeyType: String
    let signingPublicKey: String?
    let signedPrekey: SignedPrekeyDTO?
    let oneTimePrekey: OneTimePrekeyDTO?
}

struct OTPrekeyCountDTO: Codable, Sendable {
    let count: Int
}

struct RelayAuthChallengeDTO: Codable, Sendable, Equatable {
    let challengeId: String
    let userId: UUID
    let origin: String
    let redirectURI: String
    let state: String
    let icons: [String]
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case userId = "user_id"
        case origin
        case redirectURI = "redirect_uri"
        case state
        case icons
        case expiresAt = "expires_at"
    }
}

struct RelayAuthChallengeApprovalDTO: Codable, Sendable, Equatable {
    let result: String
    let code: String?
    let redirectURI: String?
    let state: String?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case result
        case code
        case redirectURI = "redirect_uri"
        case state
        case expiresAt = "expires_at"
    }
}

struct RelayAuthChallengeCreateDTO: Codable, Sendable, Equatable {
    let challengeId: String
    let userId: UUID
    let origin: String
    let icons: [String]
    let correctIcon: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case userId = "user_id"
        case origin
        case icons
        case correctIcon = "correct_icon"
        case expiresAt = "expires_at"
    }
}

struct RelayAuthTokenDTO: Codable, Sendable, Equatable {
    let userId: UUID
    let challengeId: String
    let origin: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case challengeId = "challenge_id"
        case origin
        case state
    }
}

enum RelayAPIError: Error, Sendable, Equatable {
    case notFound
    case usernameTaken
    case invalidUsername
    case unauthorized
    case forbidden
    case relayError(String)
    case badResponse
}

/// Minimal relay client. The server only stores opaque ciphertext and routing metadata.
struct ChatAPIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    private struct RelayErrorDTO: Decodable {
        let error: String
    }

    private func makeJSONDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = formatter.date(from: s) { return d }
            formatter.formatOptions = [.withInternetDateTime]
            guard let d2 = formatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "date")
            }
            return d2
        }
        return dec
    }

    /// Decodes `RelayUserDTO` where CodingKeys use explicit snake_case (matches relay JSON exactly).
    private func makeRelayUserJSONDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .useDefaultKeys
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = formatter.date(from: s) { return d }
            formatter.formatOptions = [.withInternetDateTime]
            guard let d2 = formatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "date")
            }
            return d2
        }
        return dec
    }

    /// Relay `avatar_b64` may use URL-safe alphabet or stray whitespace — normalize before `UIImage`.
    static func imageDataFromRelayAvatarBase64(_ b64: String) -> Data? {
        let trimmed = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let d = Data(base64Encoded: trimmed) { return d }
        return Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters])
    }

    /// Matches JS `URLSearchParams(...).toString()` used by the relay for HMAC signing.
    private static func formURLEncodedComponent(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return raw
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? raw
    }

    /// Same path canonicalization as `relay-server/server.js` `canonicalizeURL` (sorted query keys).
    private static func canonicalRelayHTTPPath(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            let p = url.path
            return p.isEmpty ? "/" : p
        }
        var path = components.path
        if path.isEmpty { path = "/" }
        guard let items = components.queryItems, !items.isEmpty else { return path }
        let sorted = items.sorted { a, b in
            if a.name != b.name { return a.name < b.name }
            return (a.value ?? "") < (b.value ?? "")
        }
        let q = sorted
            .map { item in
                let name = formURLEncodedComponent(item.name)
                let value = formURLEncodedComponent(item.value ?? "")
                return "\(name)=\(value)"
            }
            .joined(separator: "&")
        guard !q.isEmpty else { return path }
        return "\(path)?\(q)"
    }

    /// `RELAY_HMAC_SECRET` relay middleware: `hex(HMAC_SHA256(secret, ts + "." + METHOD + "." + path + "." + rawBody))`.
    private func applyRelayHMACSignature(_ req: inout URLRequest) {
        guard let secret = VaulteRelayConfiguration.hmacSecret, !secret.isEmpty,
              let url = req.url
        else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let method = (req.httpMethod ?? "GET").uppercased()
        let rawBody = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        let canonicalPath = Self.canonicalRelayHTTPPath(for: url)
        let canonical = "\(ts).\(method).\(canonicalPath).\(rawBody)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        let sig = Data(mac).map { String(format: "%02x", $0) }.joined()
        req.setValue(String(ts), forHTTPHeaderField: "X-Relay-Timestamp")
        req.setValue(sig, forHTTPHeaderField: "X-Relay-Signature")
    }

    private func applyAuthHeaders(_ req: inout URLRequest) {
        if let key = VaulteRelayConfiguration.apiKey, !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        applyRelayHMACSignature(&req)
    }

    private func applyHMACHeaders(_ req: inout URLRequest) {
        _ = req
    }

    private func checkRelayHTTP(data: Data, response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        if !(200 ..< 300).contains(http.statusCode) {
            if let relayErr = try? makeJSONDecoder().decode(RelayErrorDTO.self, from: data) {
                throw RelayAPIError.relayError(relayErr.error)
            }
            throw RelayAPIError.badResponse
        }
        return http
    }

    init(baseURL: URL, session: URLSession? = nil) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw URLError(.unsupportedURL)
        }
        self.baseURL = baseURL
        self.session = session ?? VaulteRelaySession.shared
    }

    func send(_ message: NetworkMessageDTO) async throws {
        let url = baseURL.appendingPathComponent("messages", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        enc.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        req.httpBody = try enc.encode(message)
        applyAuthHeaders(&req)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw RelayAPIError.badResponse
        }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        if !(200 ..< 300).contains(http.statusCode) {
            if let relayErr = try? makeJSONDecoder().decode(RelayErrorDTO.self, from: data) {
                throw RelayAPIError.relayError(relayErr.error)
            }
            throw RelayAPIError.badResponse
        }
    }

    func sendInitialX3DHMessage(_ message: InitialX3DHMessageDTO) async throws {
        let url = baseURL.appendingPathComponent("messages", isDirectory: false)
            .appendingPathComponent("initial-x3dh", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        enc.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        req.httpBody = try enc.encode(message)
        applyAuthHeaders(&req)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw RelayAPIError.badResponse
        }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        if !(200 ..< 300).contains(http.statusCode) {
            if let relayErr = try? makeJSONDecoder().decode(RelayErrorDTO.self, from: data) {
                throw RelayAPIError.relayError(relayErr.error)
            }
            throw RelayAPIError.badResponse
        }
    }

    /// - Parameter viewerUserId: when set, relay returns only rows where this user is sender or recipient (needed for group threads).
    func fetchMessages(conversationId: UUID, viewerUserId: UUID? = nil) async throws -> [NetworkMessageDTO] {
        let isoEncoder = ISO8601DateFormatter()
        isoEncoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var collected: [NetworkMessageDTO] = []
        var seenIds = Set<UUID>()
        var sinceISO = "1970-01-01T00:00:00.000Z"

        while true {
            var components = URLComponents(
                url: baseURL
                    .appendingPathComponent("conversations", isDirectory: false)
                    .appendingPathComponent(conversationId.uuidString, isDirectory: false)
                    .appendingPathComponent("messages", isDirectory: false),
                resolvingAgainstBaseURL: false
            )
            var qItems: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "since", value: sinceISO),
            ]
            if let viewerUserId {
                qItems.append(URLQueryItem(name: "user_id", value: viewerUserId.uuidString))
            }
            components?.queryItems = qItems
            guard let url = components?.url else {
                throw URLError(.badURL)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            applyAuthHeaders(&req)

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw RelayAPIError.badResponse
            }
            if http.statusCode == 401 { throw RelayAPIError.unauthorized }
            if http.statusCode == 403 { throw RelayAPIError.forbidden }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw RelayAPIError.badResponse
            }

            let dec = makeJSONDecoder()

            let batch = try dec.decode([NetworkMessageDTO].self, from: data)
            if batch.isEmpty { break }

            let countBefore = collected.count
            for m in batch where seenIds.insert(m.messageId).inserted {
                collected.append(m)
            }
            if batch.count < 200 { break }

            if batch.count == 200, collected.count == countBefore {
                break
            }

            guard let lastDate = batch.last?.createdAt else { break }
            sinceISO = isoEncoder.string(from: lastDate)
        }

        return collected
    }

    func fetchInitialX3DHMessages(recipientId: UUID) async throws -> [InitialX3DHMessageDTO] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("messages", isDirectory: false)
                .appendingPathComponent("initial-x3dh", isDirectory: false),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "recipient_id", value: recipientId.uuidString),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "since", value: "1970-01-01T00:00:00.000Z"),
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        return try makeJSONDecoder().decode([InitialX3DHMessageDTO].self, from: data)
    }

    func consumeInitialX3DHMessage(messageId: UUID, userId: UUID) async throws {
        let url = baseURL.appendingPathComponent("messages", isDirectory: false)
            .appendingPathComponent("initial-x3dh", isDirectory: false)
            .appendingPathComponent(messageId.uuidString, isDirectory: false)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user_id", value: userId.uuidString)]
        guard let finalURL = components?.url else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: finalURL)
        req.httpMethod = "DELETE"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        if http.statusCode == 404 {
            if let relayErr = try? makeJSONDecoder().decode(RelayErrorDTO.self, from: data) {
                throw RelayAPIError.relayError(relayErr.error)
            }
        }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
    }

    func fetchInboxMessages(recipientId: UUID) async throws -> [NetworkMessageDTO] {
        let isoEncoder = ISO8601DateFormatter()
        isoEncoder.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var collected: [NetworkMessageDTO] = []
        var seenIds = Set<UUID>()
        var sinceISO = "1970-01-01T00:00:00.000Z"

        while true {
            var components = URLComponents(
                url: baseURL
                    .appendingPathComponent("messages", isDirectory: false)
                    .appendingPathComponent("inbox", isDirectory: false)
                    .appendingPathComponent(recipientId.uuidString, isDirectory: false),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "since", value: sinceISO),
            ]
            guard let url = components?.url else {
                throw URLError(.badURL)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            applyAuthHeaders(&req)

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
            if http.statusCode == 401 { throw RelayAPIError.unauthorized }
            if http.statusCode == 403 { throw RelayAPIError.forbidden }
            guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }

            let batch = try makeJSONDecoder().decode([NetworkMessageDTO].self, from: data)
            if batch.isEmpty { break }

            let countBefore = collected.count
            for m in batch where seenIds.insert(m.messageId).inserted {
                collected.append(m)
            }
            if batch.count < 200 { break }
            if batch.count == 200, collected.count == countBefore { break }

            guard let lastDate = batch.last?.createdAt else { break }
            sinceISO = isoEncoder.string(from: lastDate)
        }

        return collected
    }

    /// Delivery ACK — on minimal-metadata relay the server deletes the ciphertext row.
    func ackMessageDelivered(messageId: UUID, recipientId: UUID) async throws {
        let url = baseURL
            .appendingPathComponent("messages", isDirectory: false)
            .appendingPathComponent(messageId.uuidString, isDirectory: false)
            .appendingPathComponent("ack", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["recipient_id": recipientId.uuidString]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthHeaders(&req)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return }
    }


    func fetchUser(userId: UUID) async throws -> RelayUserDTO? {
        guard let raw = try await fetchUserWire(userId: userId) else { return nil }
        return try await decryptRelayUserIfNeeded(raw)
    }

    private func fetchUserWire(userId: UUID) async throws -> RelayUserDTO? {
        let url = baseURL
            .appendingPathComponent("users", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        return try decodeRelayUserDTO(from: data)
    }

    private func decryptRelayUserIfNeeded(_ dto: RelayUserDTO) async throws -> RelayUserDTO {
        guard let ct = dto.profileCiphertextB64, !ct.isEmpty else { return dto }
        guard let identity = try await fetchIdentityKey(userId: dto.userId) else { return dto }
        let plain = try VaulteRelayEncryptedProfile.decrypt(
            ciphertextBase64: ct,
            identityPublicKeyBase64: identity.publicKeyBase64
        )
        return VaulteRelayEncryptedProfile.relayUserDTO(
            userId: dto.userId,
            updatedAt: dto.updatedAt,
            plaintext: plain
        )
    }

    /// Decodes user JSON; if `avatar_b64` fails structured decode, falls back to raw JSON (some relay/pg clients vary slightly).
    private func decodeRelayUserDTO(from data: Data) throws -> RelayUserDTO {
        let dec = makeRelayUserJSONDecoder()
        let dto = try dec.decode(RelayUserDTO.self, from: data)
        if let a = dto.avatarB64, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return dto
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = obj["avatar_b64"] as? String,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RelayUserDTO(
                userId: dto.userId,
                username: dto.username,
                displayName: dto.displayName,
                avatarB64: s,
                updatedAt: dto.updatedAt,
                profileCiphertextB64: dto.profileCiphertextB64
            )
        }
        return dto
    }

    /// Uploads encrypted profile (username + optional name/avatar). Plaintext never stored on relay.
    func syncEncryptedProfile(
        userId: UUID,
        username: String,
        displayName: String? = nil,
        avatarBase64: String? = nil
    ) async throws -> RelayUserDTO {
        // Profile is decrypted via GET /keys — must use the same X25519 identity as X3DH (LocalIdentityStore).
        let identityPub: String
        if let pair = LocalIdentityStore.loadIdentityKey() {
            identityPub = pair.publicKey.rawRepresentation.base64EncodedString()
        } else {
            identityPub = try await IdentityKeyExchange.shared.localPublicKeyBase64()
        }
        let plain = RelayProfilePlaintext(username: username, displayName: displayName, avatarB64: avatarBase64)
        let ciphertext = try VaulteRelayEncryptedProfile.encrypt(plain, identityPublicKeyBase64: identityPub)
        let lookupKey = try VaulteRelayEncryptedProfile.usernameLookupKey(for: username)

        let url = baseURL
            .appendingPathComponent("users", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "username": username,
            "username_lookup_key": lookupKey,
            "profile_ciphertext_b64": ciphertext,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 {
            if let code = Self.relayErrorCode(from: data), code == "user_search_disabled" {
                throw RelayAPIError.relayError(code)
            }
            throw RelayAPIError.forbidden
        }
        if http.statusCode == 409 { throw RelayAPIError.usernameTaken }
        if http.statusCode == 400 {
            if let code = Self.relayErrorCode(from: data), code != "invalid_username" {
                throw RelayAPIError.relayError(code)
            }
            throw RelayAPIError.invalidUsername
        }
        if http.statusCode == 413 {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.relayError("payload_too_large")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
        let wire = try decodeRelayUserDTO(from: data)
        return try await decryptRelayUserIfNeeded(wire)
    }

    func createAuthChallenge(username: String, redirectURI: String, origin: String, state: String? = nil) async throws -> RelayAuthChallengeCreateDTO {
        let url = baseURL
            .appendingPathComponent("auth", isDirectory: false)
            .appendingPathComponent("challenges", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "redirect_uri": redirectURI.trimmingCharacters(in: .whitespacesAndNewlines),
            "origin": origin.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let state, !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["state"] = state.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.forbidden
        }
        if http.statusCode == 404 { throw RelayAPIError.notFound }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
        return try decodeAuthChallengeCreateDTO(from: data)
    }

    func fetchAuthChallenge(challengeId: String) async throws -> RelayAuthChallengeDTO {
        let url = baseURL
            .appendingPathComponent("auth", isDirectory: false)
            .appendingPathComponent("challenges", isDirectory: false)
            .appendingPathComponent(challengeId, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.forbidden
        }
        if http.statusCode == 404 { throw RelayAPIError.notFound }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
        return try makeJSONDecoder().decode(RelayAuthChallengeDTO.self, from: data)
    }

    func approveAuthChallenge(challengeId: String, userId: UUID, selectedIcon: String) async throws -> RelayAuthChallengeApprovalDTO {
        let url = baseURL
            .appendingPathComponent("auth", isDirectory: false)
            .appendingPathComponent("challenges", isDirectory: false)
            .appendingPathComponent(challengeId, isDirectory: false)
            .appendingPathComponent("approve", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId.uuidString,
            "selected_icon": selectedIcon,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.forbidden
        }
        if http.statusCode == 404 { throw RelayAPIError.notFound }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
        return try makeJSONDecoder().decode(RelayAuthChallengeApprovalDTO.self, from: data)
    }

    func exchangeAuthCode(code: String) async throws -> RelayAuthTokenDTO {
        let url = baseURL
            .appendingPathComponent("auth", isDirectory: false)
            .appendingPathComponent("token", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.forbidden
        }
        if http.statusCode == 404 { throw RelayAPIError.notFound }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
        return try decodeAuthTokenDTO(from: data)
    }

    private static func relayErrorCode(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    private static func authString(_ dict: [String: Any], _ key: String, default defaultValue: String? = nil) -> String? {
        if let value = dict[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultValue : trimmed
        }
        return defaultValue
    }

    private func decodeAuthChallengeCreateDTO(from data: Data) throws -> RelayAuthChallengeCreateDTO {
        if let decoded = try? makeJSONDecoder().decode(RelayAuthChallengeCreateDTO.self, from: data) {
            return decoded
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challengeId = Self.authString(json, "challenge_id"),
              let userIdRaw = Self.authString(json, "user_id"),
              let userId = UUID(uuidString: userIdRaw),
              let correctIcon = Self.authString(json, "correct_icon"),
              let icons = json["icons"] as? [String],
              let expiresAtRaw = Self.authString(json, "expires_at")
        else {
            throw RelayAPIError.badResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.date(from: expiresAtRaw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: expiresAtRaw)
        }()
        guard let expiresAt else { throw RelayAPIError.badResponse }
        return RelayAuthChallengeCreateDTO(
            challengeId: challengeId,
            userId: userId,
            origin: Self.authString(json, "origin", default: "Vaulté Privé") ?? "Vaulté Privé",
            icons: icons,
            correctIcon: correctIcon,
            expiresAt: expiresAt
        )
    }

    private func decodeAuthTokenDTO(from data: Data) throws -> RelayAuthTokenDTO {
        if let decoded = try? makeJSONDecoder().decode(RelayAuthTokenDTO.self, from: data) {
            return decoded
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userIdRaw = Self.authString(json, "user_id"),
              let userId = UUID(uuidString: userIdRaw),
              let challengeId = Self.authString(json, "challenge_id")
        else {
            throw RelayAPIError.badResponse
        }
        return RelayAuthTokenDTO(
            userId: userId,
            challengeId: challengeId,
            origin: Self.authString(json, "origin", default: "Vaulté Privé") ?? "Vaulté Privé",
            state: Self.authString(json, "state", default: "") ?? ""
        )
    }

    func deleteMessage(messageId: UUID, requesterId: UUID) async throws {
        var url = baseURL
            .appendingPathComponent("messages", isDirectory: false)
            .appendingPathComponent(messageId.uuidString, isDirectory: false)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user_id", value: requesterId.uuidString)]
        url = components.url!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuthHeaders(&req)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        // 404 means already deleted — treat as success
        guard (200 ..< 300).contains(http.statusCode) || http.statusCode == 404 else {
            throw RelayAPIError.badResponse
        }
    }

    func hardResetAccount(userId: UUID) async throws {
        let url = baseURL
            .appendingPathComponent("users", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("hard-reset", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuthHeaders(&req)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
    }

    func registerAPNsDeviceToken(userId: UUID, deviceTokenHex: String, bundleId: String? = nil) async throws {
        let url = baseURL
            .appendingPathComponent("users", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("push-devices", isDirectory: false)
            .appendingPathComponent("apns", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = ["device_token": deviceTokenHex]
        if let bundleId, !bundleId.isEmpty {
            payload["bundle_id"] = bundleId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        if !(200 ..< 300).contains(http.statusCode) {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
    }

    func deleteAPNsDeviceToken(userId: UUID, deviceTokenHex: String) async throws {
        let url = baseURL
            .appendingPathComponent("users", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("push-devices", isDirectory: false)
            .appendingPathComponent("apns", isDirectory: false)
            .appendingPathComponent(deviceTokenHex, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        if !(200 ..< 300).contains(http.statusCode) {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.badResponse
        }
    }

    func resolveUsername(_ username: String) async throws -> RelayUserDTO? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/resolve", isDirectory: false),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "username", value: username)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 400 { throw RelayAPIError.invalidUsername }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        let wire = try decodeRelayUserDTO(from: data)
        return try await decryptRelayUserIfNeeded(wire)
    }

    func searchUsers(query: String, limit: Int = 20) async throws -> [RelayUserDTO] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/search", isDirectory: false),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 400 { return [] }
        if http.statusCode == 403 { return [] }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        return try makeRelayUserJSONDecoder().decode([RelayUserDTO].self, from: data)
    }

    func fetchIdentityKey(userId: UUID) async throws -> RelayIdentityKeyDTO? {
        let url = baseURL
            .appendingPathComponent("keys", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        return try makeJSONDecoder().decode(RelayIdentityKeyDTO.self, from: data)
    }

    func upsertIdentityKey(userId: UUID, publicKeyBase64: String, signingPublicKeyBase64: String? = nil) async throws -> RelayIdentityKeyDTO {
        let url = baseURL
            .appendingPathComponent("keys", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = ["key_type": "x25519", "public_key_base64": publicKeyBase64]
        if let signing = signingPublicKeyBase64 {
            payload["signing_public_key_base64"] = signing
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        _ = try checkRelayHTTP(data: data, response: resp)
        return try makeJSONDecoder().decode(RelayIdentityKeyDTO.self, from: data)
    }

    // MARK: - Prekeys

    func uploadSignedPrekey(userId: UUID, keyId: Int, publicKeyBase64: String, signatureBase64: String) async throws {
        let url = baseURL
            .appendingPathComponent("keys", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("signed-prekey", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "key_id": keyId,
            "public_key_base64": publicKeyBase64,
            "signature_base64": signatureBase64
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        _ = try checkRelayHTTP(data: data, response: resp)
    }

    func uploadOneTimePrekeys(
        userId: UUID,
        keys: [(keyId: Int, publicKeyBase64: String)],
        replaceExisting: Bool = false
    ) async throws {
        let url = baseURL
            .appendingPathComponent("keys", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("one-time-prekeys", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let keysPayload = keys.map { ["key_id": $0.keyId, "public_key_base64": $0.publicKeyBase64] as [String: Any] }
        let payload: [String: Any] = [
            "keys": keysPayload,
            "replace_existing": replaceExisting,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        _ = try checkRelayHTTP(data: data, response: resp)
    }

    func fetchPrekeyBundle(userId: UUID) async throws -> PrekeyBundleDTO? {
        let url = baseURL
            .appendingPathComponent("keys", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("bundle", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        return try makeJSONDecoder().decode(PrekeyBundleDTO.self, from: data)
    }

    func fetchOneTimePrekeyCount(userId: UUID) async throws -> Int {
        let url = baseURL
            .appendingPathComponent("keys", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
            .appendingPathComponent("one-time-prekeys", isDirectory: false)
            .appendingPathComponent("count", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        _ = try checkRelayHTTP(data: data, response: resp)
        let dto = try makeJSONDecoder().decode(OTPrekeyCountDTO.self, from: data)
        return dto.count
    }

    // MARK: - Badges

    func fetchBadge(userId: UUID) async throws -> BadgeType? {
        let url = baseURL
            .appendingPathComponent("badges", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        let dto = try makeJSONDecoder().decode(RelayBadgeDTO.self, from: data)
        return dto.badgeType
    }

    func fetchAllBadges() async throws -> [UUID: BadgeType] {
        let url = baseURL.appendingPathComponent("badges", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        struct ListResponse: Codable { let badges: [RelayBadgeDTO] }
        let list = try makeJSONDecoder().decode(ListResponse.self, from: data)
        var map: [UUID: BadgeType] = [:]
        for b in list.badges {
            if let t = b.badgeType { map[b.userId] = t }
        }
        return map
    }

    func grantBadge(userId: UUID, badgeType: BadgeType, adminUserId: UUID) async throws {
        let url = baseURL
            .appendingPathComponent("badges", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(adminUserId.uuidString, forHTTPHeaderField: "X-Admin-User-Id")
        let payload: [String: String] = ["badge_type": badgeType.rawValue, "granted_by": "admin"]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.relayError("http_\(http.statusCode)")
        }
    }

    func revokeBadge(userId: UUID, adminUserId: UUID) async throws {
        let url = baseURL
            .appendingPathComponent("badges", isDirectory: false)
            .appendingPathComponent(userId.uuidString, isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(adminUserId.uuidString, forHTTPHeaderField: "X-Admin-User-Id")
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        guard (200 ..< 300).contains(http.statusCode) else {
            if let code = Self.relayErrorCode(from: data) { throw RelayAPIError.relayError(code) }
            throw RelayAPIError.relayError("http_\(http.statusCode)")
        }
    }

    func createPadBatchToken(request: RelayPadBatchRequest) async throws -> RelayPadBatchCreateResponse {
        let url = baseURL.appendingPathComponent("pad-batches", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        enc.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        req.httpBody = try enc.encode(request)
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        return try makeJSONDecoder().decode(RelayPadBatchCreateResponse.self, from: data)
    }

    func consumePadBatch(token: String, requesterUserId: UUID?) async throws -> RelayPadBatchDTO {
        let url = baseURL
            .appendingPathComponent("pad-batches", isDirectory: false)
            .appendingPathComponent(token, isDirectory: false)
            .appendingPathComponent("consume", isDirectory: false)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(RelayPadBatchConsumeRequest(requesterUserId: requesterUserId))
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 404 { throw RelayAPIError.notFound }
        if !(200 ..< 300).contains(http.statusCode) {
            if let relayErr = try? makeJSONDecoder().decode(RelayErrorDTO.self, from: data) {
                throw RelayAPIError.relayError(relayErr.error)
            }
            throw RelayAPIError.badResponse
        }
        return try makeJSONDecoder().decode(RelayPadBatchDTO.self, from: data)
    }

    func deleteConversationMessages(conversationId: UUID, requesterUserId: UUID) async throws {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("conversations", isDirectory: false)
                .appendingPathComponent(conversationId.uuidString, isDirectory: false)
                .appendingPathComponent("messages", isDirectory: false),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: requesterUserId.uuidString),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuthHeaders(&req)

        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 401 { throw RelayAPIError.unauthorized }
        if http.statusCode == 403 { throw RelayAPIError.forbidden }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
    }

    // MARK: - X3DH Keys (scoped by userId)

    // MARK: - Sealed sender / stealth delivery

    /// Publish our X25519 scan public key so others can compute stealth addresses for us.
    func publishScanPubkey(_ b64: String, userId: UUID) async throws {
        let url = baseURL.appendingPathComponent("users/\(userId.uuidString)/scan-pubkey")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["scan_pubkey_b64": b64])
        req.setValue(userId.uuidString.lowercased(), forHTTPHeaderField: "X-Caller-User-Id")
        applyAuthHeaders(&req)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RelayAPIError.badResponse
        }
    }

    /// Fetch another user's scan public key to compute their stealth address.
    func fetchScanPubkey(userId: UUID) async throws -> String? {
        let url = baseURL.appendingPathComponent("users/\(userId.uuidString)/scan-pubkey")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["scan_pubkey_b64"] as? String
    }

    /// Send a sealed (metadata-private) envelope. Relay sees only a one-time stealth tag.
    func sendSealedEnvelope(_ envelope: SealedEnvelope) async throws {
        let url = baseURL.appendingPathComponent("messages/sealed")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "envelope_id": envelope.envelopeId.uuidString.lowercased(),
            "recipient_tag": envelope.recipientTag,
            "ephemeral_pubkey_b64": envelope.ephemeralPubkeyB64,
            "sealed_ciphertext_b64": envelope.sealedCiphertextB64,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthHeaders(&req)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RelayAPIError.badResponse
        }
    }

    /// Scan recent sealed envelopes — returns headers only (no ciphertext).
    /// Caller checks tags locally; fetches full envelope only on match.
    func scanSealedEnvelopes(since: Date, limit: Int = 200) async throws -> [SealedScanEntry] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var comps = URLComponents(url: baseURL.appendingPathComponent("messages/sealed/scan"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "since", value: iso.string(from: since)),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RelayAPIError.badResponse
        }
        struct Wrapper: Decodable { let envelopes: [SealedScanEntry] }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Wrapper.self, from: data))?.envelopes ?? []
    }

    /// Fetch full sealed envelope ciphertext after confirming tag match.
    func fetchSealedEnvelope(envelopeId: UUID) async throws -> (ephemeralPubkeyB64: String, sealedCiphertextB64: String)? {
        let url = baseURL.appendingPathComponent("messages/sealed/\(envelopeId.uuidString.lowercased())")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuthHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayAPIError.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw RelayAPIError.badResponse }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let epk = json?["ephemeral_pubkey_b64"] as? String,
              let ct  = json?["sealed_ciphertext_b64"] as? String else { return nil }
        return (epk, ct)
    }

    /// Acknowledge delivery of a sealed envelope — relay deletes it.
    func ackSealedEnvelope(envelopeId: UUID) async throws {
        let url = baseURL.appendingPathComponent("messages/sealed/\(envelopeId.uuidString.lowercased())/ack")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuthHeaders(&req)
        _ = try? await session.data(for: req)
    }
}

extension RelayAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound: return VaulteL.t("relay.api.not_found")
        case .usernameTaken: return VaulteL.t("relay.api.username_taken")
        case .invalidUsername: return VaulteL.t("relay.api.invalid_username")
        case .unauthorized: return VaulteL.t("relay.api.unauthorized")
        case .forbidden: return VaulteL.t("relay.api.forbidden")
        case .relayError(let code): return Self.localizedRelayServerError(code)
        case .badResponse: return VaulteL.t("relay.api.bad_response")
        }
    }

    private static func localizedRelayServerError(_ code: String) -> String {
        switch code {
        case "db_error": return VaulteL.t("relay.api.db_error")
        case "invalid_badge_type": return VaulteL.t("relay.api.invalid_badge_type")
        case "invalid_user_id": return VaulteL.t("relay.api.invalid_user_id")
        case "admin_badge_protected": return VaulteL.t("relay.api.admin_badge_protected")
        case "payload_too_large": return VaulteL.t("relay.api.payload_too_large")
        case "avatar_too_large": return VaulteL.t("relay.api.avatar_too_large")
        case let c where c.hasPrefix("http_"):
            return VaulteL.tf1("relay.api.http_status_fmt", String(c.dropFirst(5)))
        default:
            return VaulteL.tf1("relay.api.server_fmt", code)
        }
    }
}
