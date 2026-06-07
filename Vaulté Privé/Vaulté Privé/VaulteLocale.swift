//
//  VaulteLocale.swift
//  Vaulté Privé
//
//  In-app language: English (default), German, or French.
//  `VaulteAppLanguage` drives SwiftUI refresh; `VaulteL` resolves strings for the active code.
//

import Foundation
internal import Combine

// MARK: - Live language selection (SwiftUI observes this)

final class VaulteAppLanguage: ObservableObject {
    static let shared = VaulteAppLanguage()

    static let storageKey = "vaulteprive.app.language"

    @Published private(set) var code: String

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? "en"
        code = Self.normalize(raw)
    }

    static func normalize(_ raw: String) -> String {
        switch raw {
        case "de", "fr": return raw
        default: return "en"
        }
    }

    /// Updates language, persists to UserDefaults, and notifies SwiftUI.
    func setCode(_ raw: String) {
        let next = Self.normalize(raw)
        guard next != code else { return }
        code = next
        UserDefaults.standard.set(next, forKey: Self.storageKey)
    }
}

// MARK: - Locale helpers

enum VaulteLocale {
    static var languageCode: String {
        VaulteAppLanguage.shared.code
    }

    static var preferredLocale: Locale {
        Locale(identifier: languageCode)
    }
}

// MARK: - String lookup

enum VaulteL {
    /// `String(localized:bundle:locale:)` with `bundle: .main` follows the **system** language list;
    /// in-app switching requires the explicit `en` / `de` / `fr` `.lproj` bundle.
    private static func stringsBundle(for languageCode: String) -> Bundle {
        let lang = VaulteAppLanguage.normalize(languageCode)
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    private static var activeStringsBundle: Bundle {
        stringsBundle(for: VaulteAppLanguage.shared.code)
    }

    static func t(_ key: String) -> String {
        activeStringsBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func tf1(_ key: String, _ a: String) -> String {
        String(format: t(key), locale: VaulteLocale.preferredLocale, a)
    }

    static func tf1(_ key: String, _ a: Int) -> String {
        String(format: t(key), locale: VaulteLocale.preferredLocale, a)
    }

    static func tf2(_ key: String, _ a: String, _ b: String) -> String {
        String(format: t(key), locale: VaulteLocale.preferredLocale, a, b)
    }

    /// Resolves `ChatViewModel.userError` values (including dynamic relay codes).
    static func resolveChatUserError(_ stored: String) -> String {
        let prefix = "errvm.relay_fmt|"
        if stored.hasPrefix(prefix) {
            let code = String(stored.dropFirst(prefix.count))
            return tf1("errvm.relay_fmt", code)
        }
        if stored == "chat.verified_otp_exhausted" {
            return t("chat.verified_otp_exhausted")
        }
        return t(stored)
    }

    /// Login / username setup when publishing X3DH keys or encrypted profile fails.
    static func relaySetupErrorMessage(_ error: Error) -> String {
        if let relay = error as? RelayAPIError {
            switch relay {
            case .unauthorized:
                return t("relay.api.unauthorized")
            case .forbidden:
                return t("relay.api.forbidden")
            case .usernameTaken:
                return t("relay.api.username_taken")
            case .invalidUsername:
                return t("relay.api.invalid_username")
            case .relayError(let code):
                return tf1("relay.api.server_fmt", code)
            case .badResponse:
                return t("relay.api.bad_response")
            case .notFound:
                return t("relay.api.not_found")
            }
        }
        if let profile = error as? VaulteRelayEncryptedProfileError {
            return profile.errorDescription ?? t("relay.error.secure_chat_prepare_failed")
        }
        return t("relay.error.secure_chat_prepare_failed")
    }
}
