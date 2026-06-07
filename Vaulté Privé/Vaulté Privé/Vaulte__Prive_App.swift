//
//  Vaulte__Prive_App.swift
//  Vaulté Privé
//

import SwiftUI
import UserNotifications
import BackgroundTasks

private final class VaulteNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

struct VaulteConnectChallenge: Identifiable, Equatable {
    let id: String
    let origin: String
    let icons: [String]
    let correctIcon: String
    let callbackURLString: String?
    let hasEmbeddedApprovalPayload: Bool
}

@Observable
final class VaulteConnectChallengeCenter {
    static let shared = VaulteConnectChallengeCenter()

    private(set) var pendingChallenge: VaulteConnectChallenge?

    private let defaultSymbols = [
        "star.fill",
        "moon.fill",
        "bolt.fill",
        "heart.fill",
        "flame.fill",
        "leaf.fill",
        "drop.fill",
        "crown.fill",
        "diamond.fill",
    ]

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "vaulte" else { return }

        let host = (url.host ?? "").lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard host == "connect" || path == "connect" else { return }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        let challengeId = items["challenge_id"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? items["challenge_id"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : UUID().uuidString

        let origin = items["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? items["origin"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Connected service"

        let parsedIcons = (items["icons"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let requestedCorrect = (items["correct"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? items["correct"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            : items["match"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? items["match"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil) ?? defaultSymbols[0]
        let callbackURLString = items["callback"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? items["callback"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let hasEmbeddedApprovalPayload = callbackURLString != nil && !parsedIcons.isEmpty && !requestedCorrect.isEmpty

        var icons = uniquePreservingOrder(parsedIcons)
        if !icons.contains(requestedCorrect) {
            icons.append(requestedCorrect)
        }
        for fallback in defaultSymbols where icons.count < 3 {
            if !icons.contains(fallback) {
                icons.append(fallback)
            }
        }
        icons = Array(icons.prefix(3))
        if !icons.contains(requestedCorrect), !icons.isEmpty {
            icons[icons.count - 1] = requestedCorrect
        }

        pendingChallenge = VaulteConnectChallenge(
            id: challengeId,
            origin: origin,
            icons: icons,
            correctIcon: requestedCorrect,
            callbackURLString: callbackURLString,
            hasEmbeddedApprovalPayload: hasEmbeddedApprovalPayload
        )
    }

    func clear() {
        pendingChallenge = nil
    }

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

@main
@MainActor
struct Vaulte__Prive_App: App {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appLanguage = VaulteAppLanguage.shared
    @UIApplicationDelegateAdaptor(VaulteAppDelegate.self) private var appDelegate
    @State private var store: OTPStore?
    @State private var userId: UUID?
    @State private var callManager: CallManager?
    @State private var relayUnlocked = false
    @State private var inboxPollingTask: Task<Void, Never>?
    @State private var verifiedOtpImportCenter = VerifiedOtpImportCenter.shared
    private let notificationDelegate = VaulteNotificationDelegate()

    init() {
        VaulteTypography.applyUIKitAppearances()
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store, let userId, let callManager {
                    if relayUnlocked {
                        RootTabs(store: store, userId: userId, callManager: callManager)
                    } else {
                        RelayConnectLoginView(store: store) {
                            relayUnlocked = true
                        }
                    }
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(VaulteL.t("app.preparing_storage"))
                            .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .environment(\.locale, Locale(identifier: appLanguage.code))
            .task {
                if store == nil {
                    store = try? await OTPStore()
                }
                if userId == nil {
                    userId = try? LocalIdentityStore.readOrCreateUserID()
                    VaultePushCoordinator.shared.updateCurrentUser(relayUnlocked ? userId : nil)
                }
                if let userId, callManager == nil {
                    callManager = CallManager(userId: userId)
                }
            }
            .onOpenURL { url in
                if VaulteVaultepadDocumentType.isVaultepadURL(url) {
                    VerifiedOtpImportCenter.shared.handleIncomingURL(url)
                } else {
                    VaulteConnectChallengeCenter.shared.handleIncomingURL(url)
                }
            }
            .onChange(of: relayUnlocked) { _, unlocked in
                if unlocked {
                    VaultePushCoordinator.shared.updateCurrentUser(userId)
                    startInboxPollingIfNeeded()
                    requestNotificationPermissionIfNeeded()
                    callManager?.connect()
                } else {
                    VaultePushCoordinator.shared.updateCurrentUser(nil)
                    stopInboxPolling()
                    callManager?.disconnect()
                }
            }
            .onChange(of: userId) { _, newUserId in
                VaultePushCoordinator.shared.updateCurrentUser(relayUnlocked ? newUserId : nil)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    if relayUnlocked {
                        VaultePushCoordinator.shared.updateCurrentUser(userId)
                        startInboxPollingIfNeeded()
                        VaultePushCoordinator.shared.requestSystemRegistration()
                        callManager?.connect()
                    }
                case .background:
                    scheduleBackgroundWebSocketKeepAlive()
                default:
                    break
                }
            }
            .onDisappear {
                stopInboxPolling()
                callManager?.disconnect()
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                VaultePushCoordinator.shared.requestSystemRegistration()
            }
        }
    }

    // MARK: - Inbox polling

    private func startInboxPollingIfNeeded() {
        guard inboxPollingTask == nil else { return }
        guard relayUnlocked, store != nil, userId != nil else { return }

        inboxPollingTask = Task {
            while !Task.isCancelled {
                await syncInboxAndNotify()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    private func stopInboxPolling() {
        inboxPollingTask?.cancel()
        inboxPollingTask = nil
    }

    private func syncInboxAndNotify() async {
        guard relayUnlocked, let store, let userId else { return }
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let inbox = try await client.fetchInboxMessages(recipientId: userId)
            var newIncomingCount = 0

            for m in inbox where m.recipientId == userId {
                if let deletedConversationId = VaulteSystemSignals.deletedConversationId(from: m.ciphertextBase64) {
                    try? await store.deleteConversation(deletedConversationId)
                    try? await client.deleteMessage(messageId: m.messageId, requesterId: userId)
                    continue
                }
                let localConversationId: UUID
                if m.padId != m.conversationId {
                    localConversationId = m.conversationId
                } else if let existing = try? await store.directConversationId(for: m.senderId) {
                    localConversationId = existing
                } else {
                    localConversationId = VaulteDirectConversationId.uuid(between: userId, and: m.senderId)
                }
                let alreadyStored = (try? await store.hasMessage(messageId: m.messageId)) ?? false
                if let deletedCutoff = try await store.deletedConversationCutoff(conversationId: localConversationId),
                   m.createdAt <= deletedCutoff
                {
                    continue
                }
                try await store.clearDeletedConversationMarker(conversationId: localConversationId)
                try await store.upsertConversation(id: localConversationId, peerRecipientId: m.senderId)
                if !alreadyStored {
                    try await store.upsertServerMessage(
                        messageId: m.messageId,
                        conversationId: localConversationId,
                        senderId: m.senderId,
                        recipientId: m.recipientId,
                        padId: m.padId,
                        ciphertextBase64: m.ciphertextBase64,
                        createdAt: m.createdAt
                    )
                    if m.senderId != userId {
                        newIncomingCount += 1
                    }
                }
            }

            if newIncomingCount > 0, scenePhase != .active {
                await pushLocalNotification()
            }
        } catch {}
    }

    private func pushLocalNotification() async {
        let content = UNMutableNotificationContent()
        content.title = VaulteL.t("app.notification_title")
        content.body = VaulteL.t("app.notification_body")
        content.sound = .default
        content.badge = NSNumber(value: 1)

        let request = UNNotificationRequest(
            identifier: "vaulte.inbox.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Background WebSocket keep-alive

    private func scheduleBackgroundWebSocketKeepAlive() {
        guard relayUnlocked else { return }
        let app = UIApplication.shared
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = app.beginBackgroundTask(withName: "vaulte.ws.keepalive") {
            self.callManager?.disconnect()
            app.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
        callManager?.connect()
    }
}
