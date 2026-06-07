//
//  VaulteDisplayName.swift
//  Vaulté Privé
//
//  UserDefaults-backed cache of peer display names.
//  Three layers, resolved in priority order:
//    1. nickname   — user-set local alias (highest priority)
//    2. customName — relay display_name fetched from server
//    3. relayUsername — @username from relay (fallback)
//  handle(for:) returns the best available string for UI use.
//

import Foundation

enum VaulteDisplayName {

    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private static func nicknameKey(for id: UUID)     -> String { "vdn.nick.\(id.uuidString.lowercased())" }
    private static func customNameKey(for id: UUID)   -> String { "vdn.name.\(id.uuidString.lowercased())" }
    private static func usernameKey(for id: UUID)     -> String { "vdn.user.\(id.uuidString.lowercased())" }

    // MARK: - Nickname (user-set local alias)

    static func nickname(for id: UUID) -> String? {
        let v = defaults.string(forKey: nicknameKey(for: id))
        return v?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? v : nil
    }

    static func setNickname(_ name: String?, for id: UUID) {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(name, forKey: nicknameKey(for: id))
        } else {
            defaults.removeObject(forKey: nicknameKey(for: id))
        }
    }

    // MARK: - Custom name (relay display_name)

    static func customName(for id: UUID) -> String? {
        let v = defaults.string(forKey: customNameKey(for: id))
        return v?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? v : nil
    }

    static func setCustomName(_ name: String?, for id: UUID) {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(name, forKey: customNameKey(for: id))
        } else {
            defaults.removeObject(forKey: customNameKey(for: id))
        }
    }

    // MARK: - Relay username (@handle)

    static func relayUsername(for id: UUID) -> String? {
        let v = defaults.string(forKey: usernameKey(for: id))
        return v?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? v : nil
    }

    static func setRelayUsername(_ username: String?, for id: UUID) {
        if let username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(username, forKey: usernameKey(for: id))
        } else {
            defaults.removeObject(forKey: usernameKey(for: id))
        }
    }

    // MARK: - Best available display string

    /// Returns: nickname → customName → "@username" → short UUID fragment.
    static func handle(for id: UUID) -> String {
        if let nick = nickname(for: id) { return nick }
        if let name = customName(for: id) { return name }
        if let user = relayUsername(for: id) { return "@\(user)" }
        return String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Bulk clear (account reset)

    static func clearAllCustomNames() {
        let prefix = ["vdn.nick.", "vdn.name.", "vdn.user."]
        for key in defaults.dictionaryRepresentation().keys {
            if prefix.contains(where: { key.hasPrefix($0) }) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
