import Foundation
import UIKit

@MainActor
final class VaultePushCoordinator {
    static let shared = VaultePushCoordinator()

    private let tokenKey = "vaulte.push.apns.deviceTokenHex"
    private var currentUserId: UUID?
    private var registrationTask: Task<Void, Never>?

    private init() {}

    private var isPushAvailable: Bool {
        VaulteRelayConfiguration.pushNotificationsEnabled
    }

    func updateCurrentUser(_ userId: UUID?) {
        currentUserId = userId
        guard isPushAvailable else { return }
        scheduleRegistrationSync()
    }

    func requestSystemRegistration() {
        guard isPushAvailable else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        guard isPushAvailable else { return }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: tokenKey)
        scheduleRegistrationSync()
    }

    func didFailRegistration(error: Error) {
        #if DEBUG
        print("APNs registration failed:", error.localizedDescription)
        #endif
    }

    func cachedDeviceTokenHex() -> String? {
        let token = (UserDefaults.standard.string(forKey: tokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token.isEmpty ? nil : token
    }

    func unregisterCurrentToken() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    private func scheduleRegistrationSync() {
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            guard let self else { return }
            await self.syncRegistrationIfPossible()
        }
    }

    private func syncRegistrationIfPossible() async {
        guard let userId = currentUserId,
              let token = cachedDeviceTokenHex()
        else { return }
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            try await client.registerAPNsDeviceToken(
                userId: userId,
                deviceTokenHex: token,
                bundleId: Bundle.main.bundleIdentifier
            )
        } catch {
            #if DEBUG
            print("APNs token relay registration failed:", error.localizedDescription)
            #endif
        }
    }
}

final class VaulteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            VaultePushCoordinator.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            VaultePushCoordinator.shared.didFailRegistration(error: error)
        }
    }
}
