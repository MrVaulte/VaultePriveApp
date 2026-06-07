import Foundation

enum SecureConversationMode: String, Codable, Sendable {
    case e2e
    case verifiedOtp = "verified_otp"

    /// Maps legacy stored values (including removed `e2e_plus`) to a supported mode.
    static func resolved(from raw: String) -> SecureConversationMode {
        if raw == "e2e_plus" { return .e2e }
        return SecureConversationMode(rawValue: raw) ?? .e2e
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self.resolved(from: raw)
    }

    var badgeTitle: String {
        switch self {
        case .e2e: return "E2E"
        case .verifiedOtp: return "Verified OTP"
        }
    }
}

enum SecureConversationPendingState: String, Codable, Sendable {
    case pendingOutgoing
    case pendingIncoming
}

enum ModeSwitchSignalKind: String, Codable, Sendable {
    case request = "mode_switch_request"
    case accept = "mode_switch_accept"
    case reject = "mode_switch_reject"
}

struct ModeSwitchRequest: Codable, Sendable, Equatable {
    let requestId: UUID
    let from: SecureConversationMode
    let to: SecureConversationMode
    let createdAt: Date
    let expiresAt: Date

    var isExpired: Bool { expiresAt <= Date() }
}

struct ModeSwitchSignalEnvelope: Codable, Sendable, Equatable {
    let kind: ModeSwitchSignalKind
    let requestId: UUID
    let from: SecureConversationMode?
    let to: SecureConversationMode?
    let createdAt: Date
    let expiresAt: Date?
    let protocolVersion: Int

    init(request: ModeSwitchRequest) {
        self.kind = .request
        self.requestId = request.requestId
        self.from = request.from
        self.to = request.to
        self.createdAt = request.createdAt
        self.expiresAt = request.expiresAt
        self.protocolVersion = 1
    }

    init(kind: ModeSwitchSignalKind, requestId: UUID, createdAt: Date = Date()) {
        self.kind = kind
        self.requestId = requestId
        self.from = nil
        self.to = nil
        self.createdAt = createdAt
        self.expiresAt = nil
        self.protocolVersion = 1
    }

    var request: ModeSwitchRequest? {
        guard kind == .request, let from, let to, let expiresAt else { return nil }
        return ModeSwitchRequest(
            requestId: requestId,
            from: from,
            to: to,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

struct SecureConversationModeState: Codable, Sendable, Equatable {
    var activeMode: SecureConversationMode = .e2e
    var pendingState: SecureConversationPendingState?
    var pendingRequest: ModeSwitchRequest?
    var resolvedRequestIds: [UUID] = []
    var updatedAt: Date = .init(timeIntervalSince1970: 0)

    mutating func markResolved(_ requestId: UUID, limit: Int = 32) {
        resolvedRequestIds.removeAll { $0 == requestId }
        resolvedRequestIds.append(requestId)
        if resolvedRequestIds.count > limit {
            resolvedRequestIds.removeFirst(resolvedRequestIds.count - limit)
        }
    }

    /// Normalizes legacy E2E+ state after the mode was removed from the product.
    mutating func migrateLegacyModes() {
        pendingState = nil
        pendingRequest = nil
    }
}
