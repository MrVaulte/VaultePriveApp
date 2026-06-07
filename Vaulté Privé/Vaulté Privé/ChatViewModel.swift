//
//  ChatViewModel.swift
//  Vaulté Privé
//

import CryptoKit
import Foundation
import Security
import UIKit

private struct VaulteGroupMetaPayload: Codable {
    let title: String
    let members: [String]
    /// Lowercase UUID string; omitted on legacy payloads (treated as meta sender).
    let owner: String?
    /// Lowercase UUID strings; co-owners with elevated privileges (MVP: display + future policy).
    let admins: [String]?
}

private enum VaultePairCryptoError: Error {
    case noSessionWithPeer
}

enum VaulteSystemSignals {
    static let prefix             = "__sys:"
    static let chatDeletePrefix   = "chat_delete:"
    /// Signal sent when one side deletes a single message — peer deletes locally too.
    static let msgDeletePrefix    = "msg_delete:"
    /// Signal sent when one side clears all messages in a conversation.
    static let convClearPrefix    = "conv_clear:"

    static func encodedPayload(for signal: String) -> String {
        Data((prefix + signal).utf8).base64EncodedString()
    }

    static func decodedSignal(from payload: String) -> String? {
        guard let data = Data(base64Encoded: payload),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix(prefix)
        else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    static func deletedConversationId(from payload: String) -> UUID? {
        guard let signal = decodedSignal(from: payload),
              signal.hasPrefix(chatDeletePrefix)
        else { return nil }
        return UUID(uuidString: String(signal.dropFirst(chatDeletePrefix.count)))
    }

    static func deletedMessageId(from payload: String) -> UUID? {
        guard let signal = decodedSignal(from: payload),
              signal.hasPrefix(msgDeletePrefix)
        else { return nil }
        return UUID(uuidString: String(signal.dropFirst(msgDeletePrefix.count)))
    }
}

@Observable
@MainActor
final class ChatViewModel {
    private let store: OTPStore
    private let importPeerPlaceholder = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let conversationId: UUID
    private(set) var currentUserId: UUID

    var peerRecipientId: UUID?
    var draftText: String = ""
    /// JPEG picked in the composer (sent as encrypted JSON image payload on next send).
    var pendingComposerImageJPEG: Data?
    /// When true, the pending image was attached via the 4K (minimal compression) picker.
    var pendingComposerImageUses4K: Bool = false
    var rows: [ChatRow] = []
    var inboundRemaining: Int = 0
    var outboundRemaining: Int = 0
    var nextOutboundPadByteLength: Int = 0
    var verifiedOtpStateSummary: VerifiedOtpBundleSummary?
    var verifiedOtpPendingExportURL: URL?
    var userError: String?
    var secureModeState = SecureConversationModeState()
    var modeToastTitle: String?
    var modeToastDetail: String?

    /// Multi-user thread: ciphertext is encrypted per pairwise `pad_id`, not with the group UUID.
    var isGroupConversation: Bool = false
    private(set) var groupMemberUUIDs: [UUID] = []
    /// Group creator / rename authority; `nil` for DMs or legacy rows without a stored owner.
    private(set) var groupOwnerUserId: UUID?
    private(set) var groupAdminUserIds: [UUID] = []
    /// Non-empty for group threads (`conversations.title`).
    var conversationDisplayTitle: String = ""

    // MARK: - Per-conversation permissions

    /// Peer approved our screenshots (set when we receive screenshot_ok from peer). Persisted; stored so `@Observable` refreshes the chat chrome when it flips.
    var screenshotAllowed = false {
        didSet { UserDefaults.standard.set(screenshotAllowed, forKey: permKey("screenshot.allowed")) }
    }
    /// Peer approved our copying (set when we receive copy_ok from peer).
    var copyAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: permKey("copy.allowed")) }
        set { UserDefaults.standard.set(newValue, forKey: permKey("copy.allowed")) }
    }
    /// We already approved peer's screenshots — auto-approve future requests silently.
    var iApprovedPeerScreenshots: Bool {
        get { UserDefaults.standard.bool(forKey: permKey("peer.screenshot.approved")) }
        set { UserDefaults.standard.set(newValue, forKey: permKey("peer.screenshot.approved")) }
    }
    /// We already approved peer's copying — auto-approve future requests silently.
    var iApprovedPeerCopy: Bool {
        get { UserDefaults.standard.bool(forKey: permKey("peer.copy.approved")) }
        set { UserDefaults.standard.set(newValue, forKey: permKey("peer.copy.approved")) }
    }
    /// Peer wants to take a screenshot — show alert (only if not already approved).
    var peerRequestsScreenshot = false
    /// Peer wants to copy — show alert (only if not already approved).
    var peerRequestsCopy = false

    /// 0 = off; otherwise seconds after `created_at` when the message is removed (local + relay).
    var disappearingMessageSeconds: Int = 0
    private var modeToastDismissTask: Task<Void, Never>?

    private func permKey(_ type: String) -> String {
        "vaulte.perm.\(type).\(conversationId.uuidString.lowercased())"
    }

    private var vanishStorageKey: String {
        "vaulte.vanish.\(conversationId.uuidString.lowercased())"
    }

    init(store: OTPStore, conversationId: UUID, currentUserId: UUID) {
        self.store = store
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        disappearingMessageSeconds = UserDefaults.standard.integer(forKey: "vaulte.vanish.\(conversationId.uuidString.lowercased())")
        screenshotAllowed = UserDefaults.standard.bool(forKey: permKey("screenshot.allowed"))
    }

    var activeSecureMode: SecureConversationMode {
        secureModeState.activeMode
    }

    var hasEliteAccess: Bool {
        VaulteSubscriptionManager.shared.hasEliteAccess
    }

    var hasVerifiedOtpLimitedAccess: Bool {
        VaulteSubscriptionManager.shared.hasVerifiedOtpLimitedAccess
    }

    var hasVerifiedOtpFullAccess: Bool {
        VaulteSubscriptionManager.shared.hasVerifiedOtpFullAccess
    }

    var pendingSecureModeState: SecureConversationPendingState? {
        secureModeState.pendingState
    }

    var pendingSecureModeRequest: ModeSwitchRequest? {
        secureModeState.pendingRequest
    }

    var showsIncomingModeSwitchBanner: Bool {
        secureModeState.pendingState == .pendingIncoming && secureModeState.pendingRequest != nil
    }

    var canToggleSecureMode: Bool {
        !isGroupConversation &&
        peerRecipientId != nil &&
        peerRecipientId != importPeerPlaceholder
    }

    /// Persists locally (SQLite + UserDefaults), notifies peer via `__sys:vanish:…`, and applies only to **new** messages from here on.
    func setDisappearingMessageSeconds(_ seconds: Int) async {
        if seconds > 0, !hasEliteAccess {
            showModeToast(
                title: VaulteL.t("chat.vanish_elite_only"),
                detail: VaulteL.t("chat.vanish_elite_detail")
            )
            return
        }
        let capped = max(0, min(seconds, 86400 * 7))
        disappearingMessageSeconds = capped
        UserDefaults.standard.set(capped, forKey: vanishStorageKey)
        try? await store.setDisappearingMessageSeconds(capped, for: conversationId)
        await sendSystemMessage("vanish:\(capped)")
    }

    /// Loads TTL from the conversation row (survives relaunch); migrates legacy `UserDefaults` into SQLite once.
    func refreshDisappearingFromStore() async {
        let fromDb = (try? await store.disappearingMessageSeconds(for: conversationId)) ?? 0
        let ud = UserDefaults.standard.integer(forKey: vanishStorageKey)
        if fromDb == 0, ud != 0 {
            try? await store.setDisappearingMessageSeconds(ud, for: conversationId)
            disappearingMessageSeconds = ud
            return
        }
        disappearingMessageSeconds = fromDb
        if fromDb != ud {
            UserDefaults.standard.set(fromDb, forKey: vanishStorageKey)
        }
    }

    var canSend: Bool {
        if pendingComposerImageJPEG != nil { return true }
        return !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var draftExceedsNextPad: Bool {
        guard activeSecureMode == .verifiedOtp else { return false }
        let bodyLength = estimatedDraftPayloadLength()
        guard let sendBundle = verifiedOtpStateSummary?.sendBundle else { return false }
        return bodyLength > sendBundle.remainingBytes
    }

    func loadPeer() async {
        peerRecipientId = try? await store.peerRecipient(for: conversationId)
        isGroupConversation = (try? await store.isGroupConversation(conversationId: conversationId)) ?? false
        groupMemberUUIDs = (try? await store.groupMemberUserIds(conversationId: conversationId)) ?? []
        if isGroupConversation {
            conversationDisplayTitle = (try? await store.conversationTitle(conversationId: conversationId)) ?? ""
            groupOwnerUserId = try? await store.groupOwnerUserId(conversationId: conversationId)
            groupAdminUserIds = (try? await store.groupAdminUserIds(conversationId: conversationId)) ?? []
        } else {
            conversationDisplayTitle = ""
            groupOwnerUserId = nil
            groupAdminUserIds = []
        }
        await loadSecureModeState()
        await refreshVerifiedOtpSummary()
    }

    func refreshVerifiedOtpSummary() async {
        verifiedOtpStateSummary = try? await store.verifiedOtpBundleSummary(conversationId: conversationId)
        inboundRemaining = verifiedOtpStateSummary?.receiveBundle?.remainingBytes ?? 0
        outboundRemaining = verifiedOtpStateSummary?.sendBundle?.remainingBytes ?? 0
        nextOutboundPadByteLength = outboundRemaining
    }

    func loadSecureModeState() async {
        var stored = (try? await store.secureConversationModeState(for: conversationId)) ?? SecureConversationModeState()
        if stored.activeMode != .e2e && stored.activeMode != .verifiedOtp {
            stored.activeMode = .e2e
            stored.migrateLegacyModes()
            secureModeState = stored
            await persistSecureModeState()
        } else {
            secureModeState = stored
        }
        await expirePendingModeSwitchIfNeeded(showToastIfOutgoing: false)
    }

    func expirePendingModeSwitchIfNeeded(showToastIfOutgoing: Bool) async {
        guard let request = secureModeState.pendingRequest, request.isExpired else { return }
        let wasOutgoing = secureModeState.pendingState == .pendingOutgoing
        secureModeState.pendingState = nil
        secureModeState.pendingRequest = nil
        secureModeState.markResolved(request.requestId)
        secureModeState.updatedAt = Date()
        try? await store.setSecureConversationModeState(secureModeState, for: conversationId)
        if wasOutgoing, showToastIfOutgoing {
            showModeToast(
                title: VaulteL.t("chat.mode_switch_expired"),
                detail: VaulteL.t("chat.mode_switch_old_client")
            )
        }
    }

    private func persistSecureModeState() async {
        secureModeState.updatedAt = Date()
        try? await store.setSecureConversationModeState(secureModeState, for: conversationId)
    }

    private func showModeToast(title: String, detail: String? = nil) {
        modeToastTitle = title
        modeToastDetail = detail
        modeToastDismissTask?.cancel()
        modeToastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.modeToastTitle = nil
            self.modeToastDetail = nil
        }
    }

    func showEliteLockedToast(title: String, detail: String? = nil) {
        showModeToast(title: title, detail: detail)
    }

    /// After creating a group locally, fan out hidden metadata so other devices learn membership + title.
    /// Pass explicit `ownerUUID` / `adminUUIDs` when renaming so the owner does not change.
    func sendGroupMemberBootstrap(
        title: String,
        memberUUIDs: [UUID],
        ownerUUID: UUID? = nil,
        adminUUIDs: [UUID]? = nil
    ) async {
        userError = nil
        let unique = Array(Set(memberUUIDs)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard unique.count >= 2 else {
            userError = "errvm.group_members"
            return
        }
        let owner = ownerUUID ?? currentUserId
        let admins = adminUUIDs ?? []
        let adminStrings = Array(Set(admins)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }.map { $0.uuidString.lowercased() }
        let meta = VaulteGroupMetaPayload(
            title: title,
            members: unique.map { $0.uuidString.lowercased() },
            owner: owner.uuidString.lowercased(),
            admins: adminStrings
        )
        guard let metaData = try? JSONEncoder().encode(meta),
              let metaJSON = String(data: metaData, encoding: .utf8)
        else {
            userError = "errvm.send_failed"
            return
        }
        let plaintext = "__grpmeta:" + metaJSON
        let plainData = Data(plaintext.utf8)
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let createdAt = Date()
            for member in unique where member != currentUserId {
                let pairId = VaulteDirectConversationId.uuid(between: currentUserId, and: member)
                let payload: String = try encryptPayloadForPair(plainData: plainData, pairConversationId: pairId)
                let messageId = UUID()
                let dto = NetworkMessageDTO(
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: currentUserId,
                    recipientId: member,
                    padId: pairId,
                    ciphertextBase64: payload,
                    createdAt: createdAt
                )
                try await client.send(dto)
                try await store.appendOutgoingPlaceholder(
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: currentUserId,
                    recipientId: member,
                    padId: pairId,
                    plaintext: plaintext,
                    createdAt: createdAt
                )
                try await store.upsertServerMessage(
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: currentUserId,
                    recipientId: member,
                    padId: pairId,
                    ciphertextBase64: payload,
                    createdAt: createdAt
                )
            }
            await syncFromServer()
        } catch RelayAPIError.unauthorized {
            userError = "errvm.relay_auth"
        } catch RelayAPIError.forbidden {
            userError = "errvm.relay_denied"
        } catch RelayAPIError.relayError(let code) {
            userError = "errvm.relay_fmt|\(code)"
        } catch VaultePairCryptoError.noSessionWithPeer {
            userError = "errvm.group_no_dm_keys"
        } catch {
            userError = "errvm.send_failed"
        }
    }

    /// Updates local title and fan-outs `__grpmeta:` so every member stays in sync. Only the **owner** may rename.
    func renameGroupTitle(_ newTitle: String) async {
        userError = nil
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            userError = "newgroup.error_title"
            return
        }
        guard isGroupConversation else { return }
        guard let owner = try? await store.groupOwnerUserId(conversationId: conversationId), owner == currentUserId else {
            userError = "errvm.group_not_owner"
            return
        }
        do {
            try await store.updateGroupConversationTitle(conversationId: conversationId, title: trimmed)
            await loadPeer()
            let admins = (try? await store.groupAdminUserIds(conversationId: conversationId)) ?? []
            await sendGroupMemberBootstrap(
                title: trimmed,
                memberUUIDs: groupMemberUUIDs,
                ownerUUID: owner,
                adminUUIDs: admins
            )
        } catch {
            userError = "errvm.send_failed"
        }
    }

    private func encryptPayloadForPair(plainData: Data, pairConversationId: UUID) throws -> String {
        if var ratchetState = ConversationKeyStore.loadRatchetState(for: pairConversationId),
           ratchetState.sendChainKey != nil {
            let wireData = try VaulteRatchet.encrypt(plaintext: plainData, state: &ratchetState)
            ConversationKeyStore.saveRatchetState(ratchetState, for: pairConversationId)
            return wireData.base64EncodedString()
        } else {
            throw VaultePairCryptoError.noSessionWithPeer
        }
    }

    private func wrapPayloadIfNeeded(
        innerPayload: String,
        messageId: UUID,
        recipientId: UUID,
        conversationWireId: UUID
    ) async throws -> String {
        guard !isGroupConversation else {
            return innerPayload
        }
        if secureModeState.activeMode == .verifiedOtp {
            guard let loaded = try await store.loadVerifiedOtpBundleForDirection(conversationId: conversationId, direction: .send) else {
                throw OTPError.verifiedOtpBundleNotFound
            }
            let reservation = try await store.reserveVerifiedOtpSendSlice(
                conversationId: conversationId,
                plaintextLength: Data(innerPayload.utf8).count
            )
            return try VerifiedOtpCodec.seal(
                innerPayload: innerPayload,
                bundle: loaded.record,
                padBytes: loaded.padBytes,
                reservation: reservation,
                messageId: messageId,
                conversationId: conversationWireId,
                senderId: currentUserId,
                recipientId: recipientId
            )
        }
        return innerPayload
    }

    /// Legacy E2E+ decode only — the mode is no longer available for new messages.
    private func ensureSharedE2EPlusContext() -> ConversationKeyStore.E2EPlusContext? {
        let contextConversationId = e2ePlusContextConversationId()
        if let existing = ConversationKeyStore.loadActiveE2EPlusContext(for: contextConversationId) {
            return existing
        }
        guard let seed = currentE2EPlusSeed() else { return nil }
        return ConversationKeyStore.activateDerivedE2EPlusContext(for: contextConversationId, seed: seed)
    }

    private func currentE2EPlusSeed() -> Data? {
        guard let peer = peerRecipientId, peer != importPeerPlaceholder else { return nil }
        let pairId = VaulteDirectConversationId.uuid(between: currentUserId, and: peer)
        if let state = ConversationKeyStore.loadRatchetState(for: conversationId) {
            return state.rootKey
        }
        if let state = ConversationKeyStore.loadRatchetState(for: pairId) {
            return state.rootKey
        }
        if let aes = ConversationKeyStore.load(for: conversationId) ?? ConversationKeyStore.load(for: pairId) {
            return aes.withUnsafeBytes { Data($0) }
        }
        return nil
    }

    private func directPairConversationId(for peerId: UUID) -> UUID {
        VaulteDirectConversationId.uuid(between: currentUserId, and: peerId)
    }

    private func directWireConversationId(for peerId: UUID) -> UUID {
        directPairConversationId(for: peerId)
    }

    private func directCryptoKeyConversationId(for peerId: UUID) -> UUID {
        if ConversationKeyStore.loadRatchetState(for: conversationId) != nil ||
            ConversationKeyStore.load(for: conversationId) != nil {
            return conversationId
        }
        return directPairConversationId(for: peerId)
    }

    /// Order matters: relay `pad_id` is authoritative for which ratchet/AES slot the sender used; then local heuristics for legacy rows.
    private func directMessageInnerCryptoKeyCandidates(peerId: UUID, padIdFromWire: UUID) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        func push(_ id: UUID) {
            guard seen.insert(id).inserted else { return }
            ordered.append(id)
        }
        push(padIdFromWire)
        push(directCryptoKeyConversationId(for: peerId))
        push(directPairConversationId(for: peerId))
        push(conversationId)
        return ordered
    }

    private func e2ePlusContextConversationId(for peerId: UUID? = nil) -> UUID {
        guard !isGroupConversation else { return conversationId }
        let resolvedPeer = peerId ?? peerRecipientId
        guard let resolvedPeer, resolvedPeer != importPeerPlaceholder else { return conversationId }
        return directPairConversationId(for: resolvedPeer)
    }

    func updatePeer(to uuid: UUID) async throws {
        try await store.updatePeerRecipient(conversationId: conversationId, peerRecipientId: uuid)
        await loadPeer()
    }

    func refreshPads() async {
        inboundRemaining = 0
        outboundRemaining = 0
        nextOutboundPadByteLength = 0
    }

    func reloadMessages() async {
        await refreshPads()
        guard let cached = try? await store.cachedMessages(conversationId: conversationId) else {
            rows = []
            return
        }

        let isGroup = (try? await store.isGroupConversation(conversationId: conversationId)) ?? false
        var seenLineDedupe = Set<String>()
        var built: [ChatRow] = []
        for message in cached {
            if message.state == .invalid {
                continue
            }
            if message.state == .pending, message.plaintext == nil || message.plaintext?.isEmpty == true {
                // No placeholder bubble — avoids flashing "Decrypting…" on every sync/request.
                continue
            }
            guard let rawPlain = message.plaintext else {
                continue
            }
            if rawPlain.isEmpty {
                continue
            }
            if rawPlain == "__sys__" { continue }
            if rawPlain.hasPrefix("__grpmeta:") { continue }
            if isGroup, let dedupeKey = Self.groupLineDedupeKey(rawPlain) {
                if !seenLineDedupe.insert(dedupeKey).inserted { continue }
            }
            let displayPlain = Self.stripGroupLineDedupePrefix(rawPlain)
            let parsed = Self.parseStoredPlaintext(displayPlain)
            if parsed.image == nil, Self.isCorruptedDisplayedPlaintext(parsed.text) {
                continue
            }
            built.append(
                ChatRow(
                    id: message.messageId,
                    isMine: message.senderId == currentUserId,
                    text: parsed.text,
                    imageJPEGData: parsed.image,
                    isInvalid: message.state == .invalid,
                    date: message.createdAt,
                    relayDeliveredAt: message.relayDeliveredAt
                )
            )
        }
        built.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        rows = built
    }

    func syncFromServer() async {
        do {
            await VaulteSendRetryQueue.flushIfPossible(store: store, baseURL: VaulteRelayConfiguration.baseURL)
            await expirePendingModeSwitchIfNeeded(showToastIfOutgoing: true)
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            var handshakeUserError: String?
            let remote: [NetworkMessageDTO]
            if !isGroupConversation, let peerId = peerRecipientId {
                remote = try await client.fetchMessages(
                    conversationId: directWireConversationId(for: peerId),
                    viewerUserId: currentUserId
                )
            } else {
                remote = try await client.fetchMessages(conversationId: conversationId, viewerUserId: currentUserId)
            }

            for message in remote {
                try? await store.mergeRelayDeliveredAt(messageId: message.messageId, deliveredAt: message.deliveredAt)
                let alreadyExists = try await store.hasMessage(messageId: message.messageId)
                if alreadyExists { continue }

                try await store.upsertServerMessage(
                    messageId: message.messageId,
                    conversationId: isGroupConversation ? message.conversationId : conversationId,
                    senderId: message.senderId,
                    recipientId: message.recipientId,
                    padId: message.padId,
                    ciphertextBase64: message.ciphertextBase64,
                    createdAt: message.createdAt,
                    relayDeliveredAt: message.deliveredAt
                )
            }

            let remoteIds = Set(remote.map(\.messageId))
            if isGroupConversation, !remoteIds.isEmpty {
                try await store.pruneMessagesToMatchRelay(conversationId: conversationId, remoteMessageIds: remoteIds)
            }

            // Also fetch initial X3DH messages if this is a direct conversation
            if !isGroupConversation, let peerId = peerRecipientId {
                let inboxMessages = try await client.fetchInboxMessages(recipientId: currentUserId)
                for message in inboxMessages where message.senderId == peerId && message.recipientId == currentUserId {
                    try? await store.mergeRelayDeliveredAt(messageId: message.messageId, deliveredAt: message.deliveredAt)
                    let alreadyExists = try await store.hasMessage(messageId: message.messageId)
                    if alreadyExists { continue }
                    try await store.upsertServerMessage(
                        messageId: message.messageId,
                        conversationId: conversationId,
                        senderId: message.senderId,
                        recipientId: message.recipientId,
                        padId: message.padId,
                        ciphertextBase64: message.ciphertextBase64,
                        createdAt: message.createdAt,
                        relayDeliveredAt: message.deliveredAt
                    )
                }

                let initialMessages = try await client.fetchInitialX3DHMessages(recipientId: currentUserId)
                for message in initialMessages where message.senderId == peerId {
                    let alreadyExists = try await store.hasMessage(messageId: message.messageId)
                    if alreadyExists { continue }

                    // Process X3DH initialization as Bob
                    do {
                        try await processInitialX3DHMessage(message, client: client)
                    } catch {
                        if let key = Self.userErrorKeyForX3DHFailure(error) {
                            handshakeUserError = key
                            continue
                        }
                        throw error
                    }
                }

                // Auto-initiate X3DH as Alice if no session exists yet (e.g. added by username, not QR).
                let pairId = VaulteDirectConversationId.uuid(between: currentUserId, and: peerId)
                let needsHandshake = ConversationKeyStore.loadRatchetState(for: pairId)?.sendChainKey == nil
                if needsHandshake {
                    do {
                        try await startX3DHSessionWithPeer(peerId: peerId)
                    } catch {
                        if let key = Self.userErrorKeyForX3DHFailure(error),
                           !Self.isIgnorableAutoHandshakeFailure(error) {
                            handshakeUserError = key
                        }
                    }
                }
            }

            try await decodePendingMessages(client: client)
            await reloadMessages()
            await purgeExpiredMessages()
            userError = handshakeUserError
        } catch RelayAPIError.unauthorized {
            userError = "errvm.relay_auth"
        } catch RelayAPIError.forbidden {
            userError = "errvm.relay_denied"
        } catch RelayAPIError.relayError(let code) {
            userError = "errvm.relay_fmt|\(code)"
        } catch RelayAPIError.badResponse {
            // HTTP not 2xx/3xx or empty URL — relay access logs may still look “fine” if logging is sparse.
            userError = "errvm.sync_bad_http"
        } catch let _ as DecodingError {
            // Common when relay returns 200 but body is not `[NetworkMessageDTO]` (proxy HTML, API mismatch).
            userError = "errvm.sync_decode"
        } catch {
            #if DEBUG
            print("ChatViewModel.syncFromServer error: \(error)")
            #endif
            userError = Self.userErrorKeyForSyncFailure(error)
        }
    }

    /// Maps sync failures to localized `errvm.*` keys. Network issues get a clearer string than a generic sync error.
    private static func userErrorKeyForSyncFailure(_ error: Error) -> String {
        let networkCodes: Set<URLError.Code> = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .timedOut,
            .dnsLookupFailed,
            .internationalRoamingOff,
            .dataNotAllowed,
            .secureConnectionFailed
        ]
        if let url = error as? URLError, networkCodes.contains(url.code) {
            return "errvm.sync_network"
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: ns.code)
            if networkCodes.contains(code) {
                return "errvm.sync_network"
            }
        }
        return "errvm.sync"
    }

    private static func userErrorKeyForX3DHFailure(_ error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == "X3DH" else { return nil }
        switch ns.code {
        case 1:
            return "errvm.x3dh_not_ready"
        case 9, 10, 11, 12:
            return "errvm.x3dh_security"
        default:
            return "errvm.x3dh_reset_required"
        }
    }

    private static func isIgnorableAutoHandshakeFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "X3DH" && ns.code == 1
    }

    private static func makeModeSignalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeModeSignalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func sendModeSwitchEnvelope(_ envelope: ModeSwitchSignalEnvelope) async {
        guard let data = try? Self.makeModeSignalEncoder().encode(envelope) else { return }
        await sendSystemMessage("mode_switch:\(data.base64EncodedString())")
    }

    func requestVerifiedOtpModeToggle() async {
        await loadPeer()
        guard canToggleSecureMode else { return }
        await expirePendingModeSwitchIfNeeded(showToastIfOutgoing: false)
        guard secureModeState.pendingState == nil else { return }
        guard hasVerifiedOtpFullAccess else {
            showModeToast(
                title: "Verified OTP requires Elite",
                detail: "Premier can prepare bundles, but only Elite can activate the separate OTP mode."
            )
            return
        }
        let summary = (try? await store.verifiedOtpBundleSummary(conversationId: conversationId))
        guard summary?.activeSendBundle != nil, summary?.activeReceiveBundle != nil else {
            showModeToast(
                title: "Verified OTP unavailable",
                detail: "Both directional bundles must be imported before requesting this mode."
            )
            return
        }

        let nextMode: SecureConversationMode = secureModeState.activeMode == .verifiedOtp ? .e2e : .verifiedOtp
        let request = ModeSwitchRequest(
            requestId: UUID(),
            from: secureModeState.activeMode,
            to: nextMode,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(300)
        )
        secureModeState.pendingState = .pendingOutgoing
        secureModeState.pendingRequest = request
        await persistSecureModeState()
        await sendModeSwitchEnvelope(ModeSwitchSignalEnvelope(request: request))

        if request.to == .verifiedOtp {
            showModeToast(
                title: "Verified OTP request sent",
                detail: "Your peer will see an approval message with actions before the stronger mode turns on."
            )
        } else {
            showModeToast(title: "Verified OTP disable request sent")
        }
    }

    func acceptPendingModeSwitch() async {
        guard secureModeState.pendingState == .pendingIncoming,
              let request = secureModeState.pendingRequest
        else { return }
        if request.to == .verifiedOtp {
            if !hasVerifiedOtpFullAccess {
                await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
                secureModeState.pendingState = nil
                secureModeState.pendingRequest = nil
                secureModeState.markResolved(request.requestId)
                await persistSecureModeState()
                showModeToast(
                    title: "Verified OTP requires Elite",
                    detail: "Only Elite can approve and activate Verified OTP Strong Mode."
                )
                return
            }
            let summary = (try? await store.verifiedOtpBundleSummary(conversationId: conversationId))
            guard summary?.activeSendBundle != nil, summary?.activeReceiveBundle != nil else {
                await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
                secureModeState.pendingState = nil
                secureModeState.pendingRequest = nil
                secureModeState.markResolved(request.requestId)
                await persistSecureModeState()
                showModeToast(
                    title: "Verified OTP unavailable",
                    detail: "Import both directional bundles before approving this mode."
                )
                return
            }
        }
        if request.isExpired {
            await expirePendingModeSwitchIfNeeded(showToastIfOutgoing: false)
            return
        }
        await sendModeSwitchEnvelope(.init(kind: .accept, requestId: request.requestId))
        await applyAcceptedModeSwitch(request, additionallyResolved: [])
    }

    func rejectPendingModeSwitch() async {
        guard secureModeState.pendingState == .pendingIncoming,
              let request = secureModeState.pendingRequest
        else { return }
        await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
        secureModeState.pendingState = nil
        secureModeState.pendingRequest = nil
        secureModeState.markResolved(request.requestId)
        await persistSecureModeState()
    }

    private func applyAcceptedModeSwitch(_ request: ModeSwitchRequest, additionallyResolved: [UUID]) async {
        secureModeState.activeMode = request.to
        secureModeState.pendingState = nil
        secureModeState.pendingRequest = nil
        secureModeState.markResolved(request.requestId)
        for extra in additionallyResolved {
            secureModeState.markResolved(extra)
        }
        await persistSecureModeState()
        await refreshVerifiedOtpSummary()
        if request.to == .verifiedOtp {
            showModeToast(title: "Verified OTP enabled")
        } else {
            showModeToast(title: VaulteL.t("chat.mode_switch_enabled_e2e"))
        }
    }

    private func handleIncomingModeSwitchRequest(_ request: ModeSwitchRequest) async {
        await expirePendingModeSwitchIfNeeded(showToastIfOutgoing: false)
        if secureModeState.resolvedRequestIds.contains(request.requestId) || request.isExpired {
            secureModeState.markResolved(request.requestId)
            await persistSecureModeState()
            return
        }

        if request.to == .verifiedOtp {
            if !hasVerifiedOtpFullAccess {
                await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
                secureModeState.markResolved(request.requestId)
                await persistSecureModeState()
                showModeToast(
                    title: "Verified OTP requires Elite",
                    detail: "Only Elite can approve and activate Verified OTP Strong Mode."
                )
                return
            }
            let summary = (try? await store.verifiedOtpBundleSummary(conversationId: conversationId))
            guard summary?.activeSendBundle != nil, summary?.activeReceiveBundle != nil else {
                await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
                secureModeState.markResolved(request.requestId)
                await persistSecureModeState()
                showModeToast(
                    title: "Verified OTP unavailable",
                    detail: "Both directional bundles must be ready before this mode can be approved."
                )
                return
            }
        }

        if request.from != secureModeState.activeMode {
            await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
            secureModeState.markResolved(request.requestId)
            await persistSecureModeState()
            return
        }

        if let localPending = secureModeState.pendingRequest {
            if localPending.requestId == request.requestId { return }
            if secureModeState.pendingState == .pendingOutgoing && localPending.to == request.to {
                await sendModeSwitchEnvelope(.init(kind: .accept, requestId: request.requestId))
                await applyAcceptedModeSwitch(request, additionallyResolved: [localPending.requestId])
                return
            }
            await sendModeSwitchEnvelope(.init(kind: .reject, requestId: request.requestId))
            secureModeState.markResolved(request.requestId)
            await persistSecureModeState()
            return
        }

        secureModeState.pendingState = .pendingIncoming
        secureModeState.pendingRequest = request
        await persistSecureModeState()
    }

    private func handleIncomingModeSwitchAccept(requestId: UUID) async {
        guard secureModeState.pendingState == .pendingOutgoing,
              let request = secureModeState.pendingRequest,
              request.requestId == requestId
        else { return }
        await applyAcceptedModeSwitch(request, additionallyResolved: [])
    }

    private func handleIncomingModeSwitchReject(requestId: UUID) async {
        guard secureModeState.pendingState == .pendingOutgoing,
              let request = secureModeState.pendingRequest,
              request.requestId == requestId
        else { return }
        secureModeState.pendingState = nil
        secureModeState.pendingRequest = nil
        secureModeState.markResolved(requestId)
        await persistSecureModeState()
        showModeToast(title: VaulteL.t("chat.mode_switch_rejected"))
    }

    func send() async {
        userError = nil
        await loadPeer()

        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || pendingComposerImageJPEG != nil else { return }

        let plaintextString: String
        if let jpeg = pendingComposerImageJPEG {
            let caption = trimmed.isEmpty ? nil : trimmed
            let env = VaulteChatImagePayload(
                v: 1,
                m: "image/jpeg",
                d: jpeg.base64EncodedString(),
                c: caption
            )
            let enc = JSONEncoder()
            guard let jsonData = try? enc.encode(env),
                  let json = String(data: jsonData, encoding: .utf8)
            else {
                userError = "errvm.send_failed"
                return
            }
            let attachMode: VaulteChatComposerImageEncoder.Mode = pendingComposerImageUses4K ? .raw4K : .standard
            guard jsonData.count <= VaulteChatComposerImageEncoder.maxPlaintextJSONBytes(for: attachMode) else {
                userError = pendingComposerImageUses4K ? "errvm.photo_4k_too_large" : "errvm.photo_too_large"
                return
            }
            plaintextString = json
            pendingComposerImageJPEG = nil
            pendingComposerImageUses4K = false
        } else {
            plaintextString = trimmed
        }

        draftText = ""

        if isGroupConversation {
            await sendGroupFanout(placeholderPlaintext: plaintextString)
            return
        }

        guard let peer = peerRecipientId else {
            draftText = plaintextString
            userError = "errvm.recipient"
            return
        }
        if peer == importPeerPlaceholder {
            draftText = plaintextString
            userError = "errvm.import_placeholder"
            return
        }

        let plainData = Data(plaintextString.utf8)

        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let messageId = UUID()
            let createdAt = Date()
            let directKeyId = directCryptoKeyConversationId(for: peer)
            let wireConversationId = directWireConversationId(for: peer)

            // Lazily establish X3DH session on first send if not already set up
            if ConversationKeyStore.loadRatchetState(for: directKeyId)?.sendChainKey == nil {
                try await startX3DHSessionWithPeer(peerId: peer)
            }

            let payload: String
            if var ratchetState = ConversationKeyStore.loadRatchetState(for: directKeyId),
               ratchetState.sendChainKey != nil {
                let wireData = try VaulteRatchet.encrypt(plaintext: plainData, state: &ratchetState)
                ConversationKeyStore.saveRatchetState(ratchetState, for: directKeyId)
                payload = try await wrapPayloadIfNeeded(
                    innerPayload: wireData.base64EncodedString(),
                    messageId: messageId,
                    recipientId: peer,
                    conversationWireId: wireConversationId
                )
            } else if let aesKey = ConversationKeyStore.load(for: directKeyId) {
                let nonce = try AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(plainData, using: aesKey, nonce: nonce)
                let combined = nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
                payload = try await wrapPayloadIfNeeded(
                    innerPayload: combined.base64EncodedString(),
                    messageId: messageId,
                    recipientId: peer,
                    conversationWireId: wireConversationId
                )
            } else {
                throw VaultePairCryptoError.noSessionWithPeer
            }

            let dto = NetworkMessageDTO(
                messageId: messageId,
                conversationId: wireConversationId,
                senderId: currentUserId,
                recipientId: peer,
                padId: directKeyId,
                ciphertextBase64: payload,
                createdAt: createdAt
            )

            let retryBundle = VaultePendingRelaySend(
                messageId: messageId,
                conversationIdWire: wireConversationId,
                senderId: currentUserId,
                recipientId: peer,
                padId: directKeyId,
                ciphertextBase64: payload,
                createdAt: createdAt,
                localConversationId: conversationId,
                plaintext: plaintextString,
                disappearingSecondsAtEnqueue: disappearingMessageSeconds,
                verifiedOtpBundleId: verifiedOtpEnvelopeMeta(from: payload)?.bundleId,
                verifiedOtpSequence: verifiedOtpEnvelopeMeta(from: payload)?.sequence,
                verifiedOtpOffset: verifiedOtpEnvelopeMeta(from: payload)?.offset,
                verifiedOtpLength: verifiedOtpEnvelopeMeta(from: payload)?.length
            )

            do {
                try await client.send(dto)
            } catch let relay as RelayAPIError {
                switch relay {
                case .unauthorized, .forbidden:
                    throw relay
                case .relayError, .badResponse:
                    try? VaulteSendRetryQueue.enqueue(retryBundle)
                    throw relay
                case .notFound, .usernameTaken, .invalidUsername:
                    throw relay
                }
            } catch {
                try? VaulteSendRetryQueue.enqueue(retryBundle)
                throw error
            }

            try await store.appendOutgoingPlaceholder(
                messageId: messageId,
                conversationId: conversationId,
                senderId: currentUserId,
                recipientId: peer,
                padId: conversationId,
                plaintext: plaintextString,
                createdAt: createdAt
            )
            try await store.upsertServerMessage(
                messageId: messageId,
                conversationId: conversationId,
                senderId: currentUserId,
                recipientId: peer,
                padId: conversationId,
                ciphertextBase64: payload,
                createdAt: createdAt,
                relayDeliveredAt: nil
            )
            if disappearingMessageSeconds > 0 {
                let exp = createdAt.addingTimeInterval(TimeInterval(disappearingMessageSeconds))
                try await store.setMessageExpiresAt(messageId: messageId, expiresAt: exp)
            }
            await refreshVerifiedOtpSummary()
            await reloadMessages()
        } catch RelayAPIError.unauthorized {
            draftText = plaintextString
            userError = "errvm.relay_auth"
        } catch RelayAPIError.forbidden {
            draftText = plaintextString
            userError = "errvm.relay_denied"
        } catch RelayAPIError.relayError(let code) {
            draftText = plaintextString
            userError = "errvm.relay_fmt|\(code)"
        } catch VaultePairCryptoError.noSessionWithPeer {
            draftText = plaintextString
            userError = "errvm.group_no_dm_keys"
        } catch OTPError.verifiedOtpBundleNotFound,
                OTPError.verifiedOtpBundleExhausted,
                OTPError.verifiedOtpBundleRevoked {
            draftText = plaintextString
            userError = "chat.verified_otp_exhausted"
        } catch {
            draftText = plaintextString
            userError = Self.userErrorKeyForX3DHFailure(error) ?? "errvm.send_failed"
        }
    }

    static func publishX3DHKeysIfNeeded(for userId: UUID) async throws {
        let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
        try await ensureX3DHKeys(client: client, currentUserId: userId)
    }

    /// Initialize X3DH session with peer by fetching their prekey bundle and performing handshake.
    func startX3DHSessionWithPeer(peerId: UUID) async throws {
        let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
        try await Self.ensureX3DHKeys(client: client, currentUserId: currentUserId)
        guard let bundleDTO = try await client.fetchPrekeyBundle(userId: peerId) else {
            throw NSError(domain: "X3DH", code: 1, userInfo: [NSLocalizedDescriptionKey: "No prekey bundle available"])
        }
        guard let identityKeyData = Data(base64Encoded: bundleDTO.identityKey),
              let identityKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: identityKeyData),
              let spkDTO = bundleDTO.signedPrekey,
              let signedPrekeyData = Data(base64Encoded: spkDTO.publicKeyBase64),
              let signedPrekey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: signedPrekeyData),
              let signature = Data(base64Encoded: spkDTO.signatureBase64)
        else {
            throw NSError(domain: "X3DH", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid prekey bundle"])
        }

        guard let signingKeyB64 = bundleDTO.signingPublicKey,
              let signingKeyData = Data(base64Encoded: signingKeyB64),
              let signingPubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKeyData)
        else {
            throw NSError(domain: "X3DH", code: 9, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid signing public key in prekey bundle"])
        }

        // Verify SPK signature with peer's Ed25519 signing key.
        guard signingPubKey.isValidSignature(signature, for: signedPrekeyData) else {
            throw NSError(domain: "X3DH", code: 10, userInfo: [NSLocalizedDescriptionKey: "SPK signature verification failed — possible key substitution attack"])
        }

        // TOFU: pin or detect identity key change
        let peerKeyChanged = LocalIdentityStore.checkAndUpdateTOFU(
            userId: peerId,
            publicKeyBase64: bundleDTO.identityKey
        )
        if peerKeyChanged {
            throw NSError(domain: "X3DH", code: 11, userInfo: [NSLocalizedDescriptionKey: "Peer identity key changed since last session"])
        }
        let oneTimePrekeyPub: Curve25519.KeyAgreement.PublicKey? = {
            guard let otp = bundleDTO.oneTimePrekey,
                  let d = Data(base64Encoded: otp.publicKeyBase64),
                  let k = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: d)
            else { return nil }
            return k
        }()
        let bundle = PreKeyBundle(
            identityKey: identityKey,
            signedPreKeyId: spkDTO.keyId,
            signedPreKey: signedPrekey,
            signedPreKeySignature: signature,
            oneTimePreKeyId: bundleDTO.oneTimePrekey?.keyId,
            oneTimePreKey: oneTimePrekeyPub
        )
        guard let aliceIdentityKey = LocalIdentityStore.loadIdentityKey() else {
            throw NSError(domain: "X3DH", code: 6, userInfo: [NSLocalizedDescriptionKey: "No identity key available"])
        }
        let aliceEphemeralKey = Curve25519.KeyAgreement.PrivateKey()
        var ratchetState = try VaulteRatchet.initAliceX3DH(
            aliceIdentityKey: aliceIdentityKey,
            aliceEphemeralKey: aliceEphemeralKey,
            bobPreKeyBundle: bundle
        ).0
        let directConversationId = VaulteDirectConversationId.uuid(between: currentUserId, and: peerId)
        ConversationKeyStore.saveRatchetState(ratchetState, for: directConversationId)
        let initialMessage = "Hello from X3DH!"
        let initialData = Data(initialMessage.utf8)
        let wireData = try VaulteRatchet.encrypt(plaintext: initialData, state: &ratchetState)
        ConversationKeyStore.saveRatchetState(ratchetState, for: directConversationId)
        let dto = InitialX3DHMessageDTO(
            messageId: UUID(),
            conversationId: directConversationId,
            senderId: currentUserId,
            recipientId: peerId,
            identityKey: aliceIdentityKey.publicKey.rawRepresentation.base64EncodedString(),
            ephemeralKey: aliceEphemeralKey.publicKey.rawRepresentation.base64EncodedString(),
            signedPrekeyId: spkDTO.keyId,
            oneTimePrekeyId: bundleDTO.oneTimePrekey?.keyId,
            ciphertextBase64: "e2:" + wireData.base64EncodedString(),
            createdAt: Date()
        )
        try await client.sendInitialX3DHMessage(dto)
        // "Hello from X3DH!" is a silent protocol handshake — not stored in chat history.
    }

    private static func ensureX3DHKeys(client: ChatAPIClient, currentUserId: UUID) async throws {
        // Ed25519 signing key (used to sign the SPK)
        let signingKey: Curve25519.Signing.PrivateKey
        if let existing = LocalIdentityStore.loadSigningKey() {
            signingKey = existing
        } else {
            let fresh = Curve25519.Signing.PrivateKey()
            try LocalIdentityStore.saveSigningKey(fresh)
            signingKey = fresh
        }

        // Identity key: ensure it exists locally, then always publish it to the relay.
        let identityPair: IdentityKeyPair
        if let existing = LocalIdentityStore.loadIdentityKey() {
            identityPair = existing
        } else {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let pair = IdentityKeyPair(
                privateKey: privateKey,
                publicKey: privateKey.publicKey
            )
            try LocalIdentityStore.saveIdentityKey(pair)
            identityPair = pair
        }
        try await client.upsertIdentityKey(
            userId: currentUserId,
            publicKeyBase64: identityPair.publicKey.rawRepresentation.base64EncodedString(),
            signingPublicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        // Signed prekey: ensure it exists locally, then always publish the current SPK.
        let signedPrekey: SignedPreKeyPair
        if let existing = LocalIdentityStore.loadSignedPrekey() {
            signedPrekey = existing
        } else {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let spkPublicData = privateKey.publicKey.rawRepresentation
            let signature = try signingKey.signature(for: spkPublicData)
            let pair = SignedPreKeyPair(
                keyId: Int(Date().timeIntervalSince1970),
                privateKey: privateKey,
                publicKey: privateKey.publicKey,
                signature: signature
            )
            try LocalIdentityStore.saveSignedPrekey(pair)
            signedPrekey = pair
        }
        try await client.uploadSignedPrekey(
            userId: currentUserId,
            keyId: signedPrekey.keyId,
            publicKeyBase64: signedPrekey.publicKey.rawRepresentation.base64EncodedString(),
            signatureBase64: signedPrekey.signature.base64EncodedString()
        )

        // One-time prekeys: only upload freshly generated keys.
        // Re-uploading every local key can resurrect server-consumed OTPs and break X3DH's one-time property.
        var oneTime = LocalIdentityStore.loadOneTimePrekeys()
        let serverOneTimeCount: Int
        do {
            serverOneTimeCount = try await client.fetchOneTimePrekeyCount(userId: currentUserId)
        } catch let relay as RelayAPIError {
            switch relay {
            case .unauthorized, .forbidden:
                throw relay
            default:
                serverOneTimeCount = 0
            }
        } catch {
            serverOneTimeCount = 0
        }
        if oneTime.count < serverOneTimeCount {
            let replacementCount = 20
            let startId = max((oneTime.map(\.keyId).max() ?? 0) + 1, Int(Date().timeIntervalSince1970))
            let replacementKeys: [OneTimePreKeyPair] = (0..<replacementCount).map { offset in
                let priv = Curve25519.KeyAgreement.PrivateKey()
                return OneTimePreKeyPair(
                    keyId: startId + offset,
                    privateKey: priv,
                    publicKey: priv.publicKey
                )
            }
            try LocalIdentityStore.saveOneTimePrekeys(replacementKeys)
            try await client.uploadOneTimePrekeys(
                userId: currentUserId,
                keys: replacementKeys.map {
                    ($0.keyId, $0.publicKey.rawRepresentation.base64EncodedString())
                },
                replaceExisting: true
            )
            return
        }

        let desiredServerOneTimeCount = 20
        let missingServerKeys = max(0, desiredServerOneTimeCount - serverOneTimeCount)
        if missingServerKeys > 0 {
            let startId = (oneTime.map(\.keyId).max() ?? 0) + 1
            let newKeys: [OneTimePreKeyPair] = (0..<missingServerKeys).map { offset in
                let priv = Curve25519.KeyAgreement.PrivateKey()
                return OneTimePreKeyPair(
                    keyId: startId + offset,
                    privateKey: priv,
                    publicKey: priv.publicKey
                )
            }
            oneTime.append(contentsOf: newKeys)
            try LocalIdentityStore.saveOneTimePrekeys(oneTime)
            try await client.uploadOneTimePrekeys(
                userId: currentUserId,
                keys: newKeys.map {
                    ($0.keyId, $0.publicKey.rawRepresentation.base64EncodedString())
                }
            )
        }
    }

    private func processInitialX3DHMessage(_ message: InitialX3DHMessageDTO, client: ChatAPIClient) async throws {
        guard let aliceIdentityData = Data(base64Encoded: message.identityKey),
              let aliceIdentityKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceIdentityData),
              let aliceEphemeralData = Data(base64Encoded: message.ephemeralKey),
              let aliceEphemeralKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: aliceEphemeralData)
        else {
            throw NSError(domain: "X3DH", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid X3DH message keys"])
        }

        // TOFU: pin or detect sender identity key change
        let senderKeyChanged = LocalIdentityStore.checkAndUpdateTOFU(
            userId: message.senderId,
            publicKeyBase64: message.identityKey
        )
        if senderKeyChanged {
            throw NSError(domain: "X3DH", code: 12, userInfo: [NSLocalizedDescriptionKey: "Sender identity key changed"])
        }
        guard let bobIdentityKey = LocalIdentityStore.loadIdentityKey() else {
            throw NSError(domain: "X3DH", code: 4, userInfo: [NSLocalizedDescriptionKey: "No identity key available"])
        }
        guard let bobSignedPreKey = LocalIdentityStore.loadSignedPrekey(),
              bobSignedPreKey.keyId == message.signedPrekeyId
        else {
            throw NSError(domain: "X3DH", code: 5, userInfo: [NSLocalizedDescriptionKey: "No matching signed prekey available"])
        }
        let bobOneTimePreKey: OneTimePreKeyPair? = {
            guard let id = message.oneTimePrekeyId else { return nil }
            return try? LocalIdentityStore.consumeOneTimePrekey(id: id)
        }()
        var ratchetState = try VaulteRatchet.initBobX3DH(
            bobIdentityKey: bobIdentityKey,
            bobSignedPreKey: bobSignedPreKey,
            bobOneTimePreKey: bobOneTimePreKey,
            aliceIdentityKey: aliceIdentityKey,
            aliceEphemeralKey: aliceEphemeralKey
        )
        ConversationKeyStore.saveRatchetState(ratchetState, for: message.conversationId)
        guard message.ciphertextBase64.hasPrefix("e2:"),
              let wireData = Data(base64Encoded: String(message.ciphertextBase64.dropFirst(3)))
        else {
            throw NSError(domain: "X3DH", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid ciphertext"])
        }
        let plainData = try VaulteRatchet.decrypt(wireData: wireData, state: &ratchetState)
        ConversationKeyStore.saveRatchetState(ratchetState, for: message.conversationId)
        guard let plaintext = String(data: plainData, encoding: .utf8) else {
            throw NSError(domain: "X3DH", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not decode plaintext"])
        }
        try await store.upsertServerMessage(
            messageId: message.messageId,
            conversationId: message.conversationId,
            senderId: message.senderId,
            recipientId: message.recipientId,
            padId: message.conversationId,
            ciphertextBase64: message.ciphertextBase64,
            createdAt: message.createdAt
        )
        try await store.setMessagePlaintext(
            messageId: message.messageId,
            plaintext: "__sys__",
            state: .ok
        )
        try await client.consumeInitialX3DHMessage(messageId: message.messageId, userId: currentUserId)
    }

    private func sendGroupFanout(placeholderPlaintext: String) async {
        let members = groupMemberUUIDs
        guard Set(members).count >= 2 else {
            userError = "errvm.group_members"
            return
        }
        let lineTag = UUID()
        let wrappedPlain = "__gl:\(lineTag.uuidString)\n" + placeholderPlaintext
        let plainData = Data(wrappedPlain.utf8)
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let createdAt = Date()
            for member in members where member != currentUserId {
                let pairId = VaulteDirectConversationId.uuid(between: currentUserId, and: member)
                let payload = try encryptPayloadForPair(plainData: plainData, pairConversationId: pairId)
                let messageId = UUID()
                let dto = NetworkMessageDTO(
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: currentUserId,
                    recipientId: member,
                    padId: pairId,
                    ciphertextBase64: payload,
                    createdAt: createdAt
                )
                try await client.send(dto)
                try await store.appendOutgoingPlaceholder(
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: currentUserId,
                    recipientId: member,
                    padId: pairId,
                    plaintext: wrappedPlain,
                    createdAt: createdAt
                )
                try await store.upsertServerMessage(
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: currentUserId,
                    recipientId: member,
                    padId: pairId,
                    ciphertextBase64: payload,
                    createdAt: createdAt
                )
                if disappearingMessageSeconds > 0 {
                    let exp = createdAt.addingTimeInterval(TimeInterval(disappearingMessageSeconds))
                    try await store.setMessageExpiresAt(messageId: messageId, expiresAt: exp)
                }
            }
            await reloadMessages()
        } catch RelayAPIError.unauthorized {
            userError = "errvm.relay_auth"
        } catch RelayAPIError.forbidden {
            userError = "errvm.relay_denied"
        } catch RelayAPIError.relayError(let code) {
            userError = "errvm.relay_fmt|\(code)"
        } catch VaultePairCryptoError.noSessionWithPeer {
            userError = "errvm.group_no_dm_keys"
        } catch {
            userError = "errvm.send_failed"
        }
    }

    // MARK: - Message actions

    func deleteMessage(_ messageId: UUID) async {
        userError = nil
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let cached = try await store.cachedMessages(conversationId: conversationId)
            let isGroup = (try? await store.isGroupConversation(conversationId: conversationId)) ?? false
            let target = cached.first { $0.messageId == messageId }
            let idsToDelete: [UUID]
            if isGroup, let plain = target?.plaintext, let glKey = Self.groupLineDedupeKey(plain) {
                idsToDelete = cached
                    .filter { Self.groupLineDedupeKey($0.plaintext ?? "") == glKey }
                    .map(\.messageId)
            } else {
                idsToDelete = [messageId]
            }
            for id in idsToDelete {
                try? await client.deleteMessage(messageId: id, requesterId: currentUserId)
                try? await store.deleteMessage(messageId: id)
                // Notify peer so they delete the same message locally.
                await sendSystemMessage("\(VaulteSystemSignals.msgDeletePrefix)\(id.uuidString.lowercased())")
            }
            await reloadMessages()
            Task { await syncFromServer() }
        } catch RelayAPIError.unauthorized {
            userError = "errvm.relay_auth"
        } catch RelayAPIError.forbidden {
            userError = "errvm.relay_denied"
        } catch {
            userError = "errvm.delete_failed"
        }
    }

    // MARK: - System messages

    /// Sends a system signal to the peer (not shown as a chat bubble).
    func sendSystemMessage(_ signal: String) async {
        await loadPeer()
        let raw = "__sys:\(signal)"
        let plainData = Data(raw.utf8)
        if isGroupConversation {
            let members = groupMemberUUIDs
            guard Set(members).count >= 2 else { return }
            do {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                let createdAt = Date()
                for member in members where member != currentUserId {
                    let pairId = VaulteDirectConversationId.uuid(between: currentUserId, and: member)
                    guard let payload = try? encryptPayloadForPair(plainData: plainData, pairConversationId: pairId)
                    else { continue }
                    let dto = NetworkMessageDTO(
                        messageId: UUID(),
                        conversationId: conversationId,
                        senderId: currentUserId,
                        recipientId: member,
                        padId: pairId,
                        ciphertextBase64: payload,
                        createdAt: createdAt
                    )
                    try await client.send(dto)
                }
            } catch {}
            return
        }
        guard let peer = peerRecipientId, peer != importPeerPlaceholder else { return }
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let pairId = directPairConversationId(for: peer)
            let wireConversationId = directWireConversationId(for: peer)
            let messageId = UUID()
            let createdAt = Date()
            let dmRatchetKey = directCryptoKeyConversationId(for: peer)
            let payload: String
            if var ratchetState = ConversationKeyStore.loadRatchetState(for: dmRatchetKey),
               ratchetState.sendChainKey != nil {
                let wireData = try VaulteRatchet.encrypt(plaintext: plainData, state: &ratchetState)
                ConversationKeyStore.saveRatchetState(ratchetState, for: dmRatchetKey)
                payload = try await wrapPayloadIfNeeded(
                    innerPayload: wireData.base64EncodedString(),
                    messageId: messageId,
                    recipientId: peer,
                    conversationWireId: wireConversationId
                )
            } else if let aesKey = ConversationKeyStore.load(for: dmRatchetKey) ?? ConversationKeyStore.load(for: pairId) {
                let nonce = try AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(plainData, using: aesKey, nonce: nonce)
                let combined = nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
                payload = try await wrapPayloadIfNeeded(
                    innerPayload: combined.base64EncodedString(),
                    messageId: messageId,
                    recipientId: peer,
                    conversationWireId: wireConversationId
                )
            } else {
                payload = try await wrapPayloadIfNeeded(
                    innerPayload: plainData.base64EncodedString(),
                    messageId: messageId,
                    recipientId: peer,
                    conversationWireId: wireConversationId
                )
            }
            let dto = NetworkMessageDTO(
                messageId: messageId,
                conversationId: wireConversationId,
                senderId: currentUserId,
                recipientId: peer,
                padId: dmRatchetKey,
                ciphertextBase64: payload,
                createdAt: createdAt
            )
            try await client.send(dto)
        } catch {}
    }

    /// Called when we approve the peer's screenshot request.
    func approveScreenshotForPeer() async {
        iApprovedPeerScreenshots = true
        await sendSystemMessage("screenshot_ok")
    }

    /// Called when we approve the peer's copy request.
    func approveCopyForPeer() async {
        iApprovedPeerCopy = true
        await sendSystemMessage("copy_ok")
    }

    func requestCopyPermission() async {
        guard hasEliteAccess else {
            showModeToast(
                title: VaulteL.t("chat.copy_elite_only"),
                detail: VaulteL.t("chat.copy_elite_detail")
            )
            return
        }
        await sendSystemMessage("copy")
        showModeToast(title: VaulteL.t("chat.copy_request_sent"))
    }

    /// Removes messages past `expires_at` locally and on the relay.
    func purgeExpiredMessages() async {
        do {
            let ids = try await store.fetchExpiredMessageIds(conversationId: conversationId, before: Date())
            guard !ids.isEmpty else { return }
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            for id in ids {
                try? await client.deleteMessage(messageId: id, requesterId: currentUserId)
                try? await store.deleteMessage(messageId: id)
            }
            await reloadMessages()
        } catch {}
    }

    private func applyVanishExpiryIfNeeded(messageId: UUID, createdAt: Date) async throws {
        let secs = disappearingMessageSeconds
        guard secs > 0 else { return }
        let exp = createdAt.addingTimeInterval(TimeInterval(secs))
        try await store.setMessageExpiresAt(messageId: messageId, expiresAt: exp)
    }

    private func decodePendingMessages(client: ChatAPIClient? = nil) async throws {
        let cached = try await store.cachedMessages(conversationId: conversationId)
        let isGroupConv = (try? await store.isGroupConversation(conversationId: conversationId)) ?? false

        for message in cached where message.state != .ok {
            let keyCandidates: [UUID] = {
                if isGroupConv {
                    if message.padId != message.conversationId { return [message.padId] }
                    return [conversationId]
                }
                let peerId = message.senderId == currentUserId ? message.recipientId : message.senderId
                return directMessageInnerCryptoKeyCandidates(peerId: peerId, padIdFromWire: message.padId)
            }()

            if message.senderId == currentUserId {
                if let existing = message.plaintext, !existing.isEmpty {
                    try await store.setMessagePlaintext(messageId: message.messageId, plaintext: existing, state: .ok)
                    try await applyVanishExpiryIfNeeded(messageId: message.messageId, createdAt: message.createdAt)
                }
                continue
            }

            var decoded: String?
            for keyConv in keyCandidates {
                if let t = await decodeMessageBody(
                    message.ciphertextBase64,
                    keyConversationId: keyConv,
                    messageId: message.messageId,
                    senderId: message.senderId,
                    recipientId: message.recipientId
                ) {
                    decoded = t
                    break
                }
            }
            if let text = decoded {
                if text.hasPrefix("__sys:") {
                    let signal = String(text.dropFirst(6))
                    await handleIncomingSystemSignal(signal)
                    try await store.setMessagePlaintext(messageId: message.messageId, plaintext: "__sys__", state: .ok)
                } else if text.hasPrefix("__grpmeta:") {
                    try await applyGroupMetaIfNeeded(from: text, listPeerId: message.senderId)
                    try await store.setMessagePlaintext(messageId: message.messageId, plaintext: "__sys__", state: .ok)
                } else {
                    try await store.setMessagePlaintext(messageId: message.messageId, plaintext: text, state: .ok)
                    try await applyVanishExpiryIfNeeded(messageId: message.messageId, createdAt: message.createdAt)
                }
                // Delivery ACK — fire-and-forget, non-fatal
                if let ackClient = client {
                    let msgId = message.messageId
                    let me = currentUserId
                    Task {
                        try? await ackClient.ackMessageDelivered(messageId: msgId, recipientId: me)
                        try? await ackClient.deleteMessage(messageId: msgId, requesterId: me)
                    }
                }
            } else {
                try await store.setMessagePlaintext(messageId: message.messageId, plaintext: "", state: .invalid)
            }
        }
    }

    func sendConversationDeleteSignal() async {
        await loadPeer()
        guard !isGroupConversation,
              let peer = peerRecipientId,
              peer != importPeerPlaceholder
        else { return }
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let pairId = directPairConversationId(for: peer)
            let dto = NetworkMessageDTO(
                messageId: UUID(),
                conversationId: pairId,
                senderId: currentUserId,
                recipientId: peer,
                padId: pairId,
                ciphertextBase64: VaulteSystemSignals.encodedPayload(
                    for: "\(VaulteSystemSignals.chatDeletePrefix)\(conversationId.uuidString.lowercased())"
                ),
                createdAt: Date()
            )
            try await client.send(dto)
        } catch {}
    }

    private func applyGroupMetaIfNeeded(from text: String, listPeerId: UUID) async throws {
        let json = String(text.dropFirst("__grpmeta:".count))
        guard let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(VaulteGroupMetaPayload.self, from: data)
        else { return }
        let uuids = meta.members.compactMap { UUID(uuidString: $0) }
        guard uuids.count >= 2 else { return }
        let ownerUUID: UUID = {
            if let raw = meta.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
               let u = UUID(uuidString: raw) {
                return u
            }
            return listPeerId
        }()
        let adminUUIDs = (meta.admins ?? []).compactMap { UUID(uuidString: $0) }
        let adminsClean = Array(Set(adminUUIDs)).filter { $0 != ownerUUID }
        try await store.applyGroupBootstrapFromMeta(
            conversationId: conversationId,
            title: meta.title,
            memberUserIds: uuids,
            listPeerId: listPeerId,
            ownerUserId: ownerUUID,
            adminUserIds: adminsClean
        )
        await loadPeer()
    }

    private func handleIncomingSystemSignal(_ signal: String) async {
        switch signal {
        case "screenshot":
            if iApprovedPeerScreenshots {
                // Already approved — silently send approval again, no alert
                Task { await sendSystemMessage("screenshot_ok") }
            } else {
                peerRequestsScreenshot = true
            }
        case "screenshot_ok":
            screenshotAllowed = true
        case "copy":
            if iApprovedPeerCopy {
                Task { await sendSystemMessage("copy_ok") }
            } else {
                peerRequestsCopy = true
            }
        case "copy_ok":
            copyAllowed = true
        default:
            if signal.hasPrefix("otp_pair_") {
                await VaulteOtpPadPairingCenter.shared.handleSignal(signal, conversationId: conversationId)
                return
            }
            if signal.hasPrefix(VaulteSystemSignals.chatDeletePrefix) {
                let raw = String(signal.dropFirst(VaulteSystemSignals.chatDeletePrefix.count))
                guard let targetConversationId = UUID(uuidString: raw),
                      targetConversationId == conversationId
                else { return }
                try? await store.deleteConversation(targetConversationId)
                rows = []
                userError = "Chat deleted by peer"
                return
            }

            // Peer deleted a single message — remove it from our local store too.
            if signal.hasPrefix(VaulteSystemSignals.msgDeletePrefix) {
                let raw = String(signal.dropFirst(VaulteSystemSignals.msgDeletePrefix.count))
                guard let deletedId = UUID(uuidString: raw) else { return }
                try? await store.deleteMessage(messageId: deletedId)
                rows.removeAll { $0.id == deletedId }
                return
            }

            // Peer cleared the entire conversation — wipe our local copy too.
            if signal.hasPrefix(VaulteSystemSignals.convClearPrefix) {
                let raw = String(signal.dropFirst(VaulteSystemSignals.convClearPrefix.count))
                guard let targetId = UUID(uuidString: raw),
                      targetId == conversationId else { return }
                try? await store.deleteConversationMessages(conversationId: conversationId)
                rows = []
                return
            }
            if signal.hasPrefix("mode_switch:") {
                let raw = String(signal.dropFirst("mode_switch:".count))
                guard let data = Data(base64Encoded: raw),
                      let envelope = try? Self.makeModeSignalDecoder().decode(ModeSwitchSignalEnvelope.self, from: data)
                else { return }
                switch envelope.kind {
                case .request:
                    if let request = envelope.request {
                        await handleIncomingModeSwitchRequest(request)
                    }
                case .accept:
                    await handleIncomingModeSwitchAccept(requestId: envelope.requestId)
                case .reject:
                    await handleIncomingModeSwitchReject(requestId: envelope.requestId)
                }
                return
            }
            if signal.hasPrefix("vanish:") {
                let rest = signal.dropFirst(7)
                if let v = Int(rest), v >= 0 {
                    let capped = min(v, 86400 * 7)
                    disappearingMessageSeconds = capped
                    UserDefaults.standard.set(capped, forKey: vanishStorageKey)
                    try? await store.setDisappearingMessageSeconds(capped, for: conversationId)
                }
            }
        }
    }

    private func decodeMessageBody(
        _ payload: String,
        keyConversationId: UUID,
        messageId: UUID,
        senderId: UUID,
        recipientId: UUID
    ) async -> String? {
        if VerifiedOtpCodec.looksLikeEnvelope(payload) {
            do {
                guard let loaded = try await store.loadVerifiedOtpBundleForDirection(conversationId: conversationId, direction: .receive) else {
                    return nil
                }
                let opened = try VerifiedOtpCodec.open(
                    payloadB64: payload,
                    bundle: loaded.record,
                    padBytes: loaded.padBytes,
                    messageId: messageId,
                    conversationId: conversationId,
                    senderId: senderId,
                    recipientId: recipientId
                )
                let length = Data(base64Encoded: opened.envelope.ciphertextB64)?.count ?? 0
                try? await store.commitVerifiedOtpReceivedSlice(
                    conversationId: conversationId,
                    bundleId: loaded.record.bundleId,
                    offset: opened.envelope.offset,
                    length: length
                )
                Task { await refreshVerifiedOtpSummary() }
                return await decodeMessageBody(
                    opened.innerPayload,
                    keyConversationId: keyConversationId,
                    messageId: messageId,
                    senderId: senderId,
                    recipientId: recipientId
                )
            } catch {
                return nil
            }
        }
        if RoutedE2EPlusCodec.looksLikeEnvelope(payload) {
            let peerId = senderId == currentUserId ? recipientId : senderId
            let outerConv = e2ePlusContextConversationId(for: peerId)
            let contextLoader: (UUID) -> ConversationKeyStore.E2EPlusContext? = { ConversationKeyStore.loadE2EPlusContext(id: $0) }
            var innerPayload = try? RoutedE2EPlusCodec.open(
                payloadB64: payload,
                contextLoader: contextLoader,
                messageId: messageId,
                conversationId: outerConv,
                senderId: senderId,
                recipientId: recipientId
            )
            if innerPayload == nil {
                _ = ensureSharedE2EPlusContext()
                innerPayload = try? RoutedE2EPlusCodec.open(
                    payloadB64: payload,
                    contextLoader: contextLoader,
                    messageId: messageId,
                    conversationId: outerConv,
                    senderId: senderId,
                    recipientId: recipientId
                )
            }
            guard let inner = innerPayload else { return nil }
            return await decodeMessageBody(
                inner,
                keyConversationId: keyConversationId,
                messageId: messageId,
                senderId: senderId,
                recipientId: recipientId
            )
        }
        if payload.hasPrefix("e2:") {
            return decryptRatchet(String(payload.dropFirst(3)), keyConversationId: keyConversationId)
        }
        if payload.hasPrefix("e1:") {
            return decryptAESGCM(String(payload.dropFirst(3)), keyConversationId: keyConversationId)
        }
        if let text = decryptRatchet(payload, keyConversationId: keyConversationId) {
            return text
        }
        if let text = decryptAESGCM(payload, keyConversationId: keyConversationId) {
            return text
        }
        guard let data = Data(base64Encoded: payload),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Decrypt a Double Ratchet (e2:) message.
    private func decryptRatchet(_ b64: String, keyConversationId: UUID) -> String? {
        guard let wireData = Data(base64Encoded: b64),
              var state = ConversationKeyStore.loadRatchetState(for: keyConversationId)
        else { return nil }
        do {
            let plainData = try VaulteRatchet.decrypt(wireData: wireData, state: &state)
            ConversationKeyStore.saveRatchetState(state, for: keyConversationId)
            return String(data: plainData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Decrypt an AES-GCM (e1:) message.
    private func decryptAESGCM(_ b64: String, keyConversationId: UUID) -> String? {
        guard let combined = Data(base64Encoded: b64),
              combined.count > 28,
              let aesKey = ConversationKeyStore.load(for: keyConversationId)
        else { return nil }
        let nonceData  = combined.prefix(12)
        let tag        = combined.suffix(16)
        let ciphertext = combined.dropFirst(12).dropLast(16)
        guard let nonce     = try? AES.GCM.Nonce(data: nonceData),
              let sealed    = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plainData = try? AES.GCM.open(sealed, using: aesKey),
              let text      = String(data: plainData, encoding: .utf8)
        else { return nil }
        return text
    }

    func createVerifiedOtpBundles(byteCount: Int) async throws -> URL {
        guard let peerId = peerRecipientId, peerId != importPeerPlaceholder else {
            throw OTPError.verifiedOtpPeerIdentityUnavailable
        }
        let outbound = try VerifiedOtpBundleCrypto.generateDirectionalBundle(
            conversationId: conversationId,
            ownerUserId: currentUserId,
            peerId: peerId,
            direction: .send,
            byteCount: byteCount
        )
        let inbound = try VerifiedOtpBundleCrypto.generateDirectionalBundle(
            conversationId: conversationId,
            ownerUserId: currentUserId,
            peerId: peerId,
            direction: .receive,
            byteCount: byteCount
        )
        _ = try await store.createVerifiedOtpBundle(descriptor: outbound.descriptor, padBytes: outbound.padBytes)
        _ = try await store.createVerifiedOtpBundle(descriptor: inbound.descriptor, padBytes: inbound.padBytes)

        // Wipe any previously-generated export bundle before writing the new one.
        if let old = verifiedOtpPendingExportURL {
            Self.secureWipeFile(at: old)
            verifiedOtpPendingExportURL = nil
        }

        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: try OTPStore.defaultStoreSQLiteURL(),
            create: true
        )
        let url = tempDir.appendingPathComponent("verified-otp-\(conversationId.uuidString.lowercased()).vaultepad", isDirectory: false)
        let payload = [
            "send": outbound.fileData.base64EncodedString(),
            "receive": inbound.fileData.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
        verifiedOtpPendingExportURL = url
        await refreshVerifiedOtpSummary()
        return url
    }

    func importVerifiedOtpBundleFile(url: URL) async throws {
        // Access a security-scoped resource if the URL is from Files / share sheet.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let fileData = try Data(contentsOf: url)
        if let bundleMap = try? JSONSerialization.jsonObject(with: fileData) as? [String: String] {
            for (declaredDirection, raw) in bundleMap {
                guard let data = Data(base64Encoded: raw) else { continue }
                let imported = try VerifiedOtpBundleCrypto.importBundleFile(data)
                guard imported.descriptor.direction.rawValue == declaredDirection else {
                    throw OTPError.verifiedOtpBundleMismatch
                }
                try verifyBundlePeerBinding(imported)
                _ = try await store.importVerifiedOtpBundle(descriptor: imported.descriptor, padBytes: imported.padBytes)
            }
        } else {
            let imported = try VerifiedOtpBundleCrypto.importBundleFile(fileData)
            try verifyBundlePeerBinding(imported)
            _ = try await store.importVerifiedOtpBundle(descriptor: imported.descriptor, padBytes: imported.padBytes)
        }
        await refreshVerifiedOtpSummary()

        // SECURITY: Securely erase the source file so the pad cannot be imported
        // a second time on this or any other device. We overwrite with random bytes
        // (same length as the file) before unlinking — belt-and-suspenders on top of
        // APFS encryption, which does not guarantee immediate key rotation on delete.
        Self.secureWipeFile(at: url)
    }

    // MARK: - Secure file wipe

    /// Overwrites `url` with cryptographically random bytes matching the file size,
    /// then deletes it. Call this after consuming any OTP pad file.
    ///
    /// On APFS the on-disk data is encrypted; overwriting provides defence-in-depth
    /// against scenarios where the volume key is somehow compromised before the
    /// file's encryption key is rotated (which happens on deletion in Data Protection Class A/B).
    static func secureWipeFile(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > 0
        else {
            try? fm.removeItem(at: url)
            return
        }
        // Generate random overwrite data (fail silently — still delete).
        let wipe: Data
        if let random = try? SecureRandom.bytes(count: size) {
            wipe = random
        } else {
            wipe = Data(repeating: 0x00, count: size)
        }
        // Overwrite then delete.
        try? wipe.write(to: url, options: [.atomic])
        try? fm.removeItem(at: url)
    }

    /// Wipe the pending export bundle from disk (call after the share sheet dismisses).
    func wipeExportedBundleIfNeeded() {
        if let url = verifiedOtpPendingExportURL {
            Self.secureWipeFile(at: url)
            verifiedOtpPendingExportURL = nil
        }
    }

    /// Verifies that the bundle's embedded sender identity key matches the TOFU-pinned
    /// peer identity for this conversation. Without this check, the Ed25519 signature is
    /// verified against a key carried inside the same file — i.e., anyone can self-sign
    /// a bundle and claim to be the peer.
    private func verifyBundlePeerBinding(_ imported: VerifiedOtpBundleImportResult) throws {
        guard let peerId = peerRecipientId else {
            // No peer pinned yet — accept and the TOFU pin will be set on first message.
            return
        }
        let bundleSenderIdentityB64 = imported.descriptor.senderIdentityPublicKeyB64
        if let pinnedKey = LocalIdentityStore.pinnedPeerIdentityKey(for: peerId) {
            // Peer already pinned: bundle sender key must match exactly.
            guard pinnedKey == bundleSenderIdentityB64 else {
                throw OTPError.verifiedOtpBundleMismatch
            }
        } else {
            // First contact: pin the key from the bundle so future bundles are bound to it.
            LocalIdentityStore.pinPeerIdentityKey(bundleSenderIdentityB64, for: peerId)
        }
    }

    func enableVerifiedOtpModeIfReady() async throws {
        guard hasVerifiedOtpFullAccess else {
            throw OTPError.verifiedOtpEliteRequired
        }
        let summary = try await store.verifiedOtpBundleSummary(conversationId: conversationId)
        guard summary.activeSendBundle != nil, summary.activeReceiveBundle != nil else {
            throw OTPError.verifiedOtpUnavailable
        }
        secureModeState.activeMode = .verifiedOtp
        secureModeState.pendingState = nil
        secureModeState.pendingRequest = nil
        await persistSecureModeState()
        await refreshVerifiedOtpSummary()
    }

    func disableVerifiedOtpMode() async {
        secureModeState.activeMode = .e2e
        secureModeState.pendingState = nil
        secureModeState.pendingRequest = nil
        await persistSecureModeState()
        await refreshVerifiedOtpSummary()
    }

    func revokeVerifiedOtpBundles() async {
        wipeExportedBundleIfNeeded()
        try? await store.revokeVerifiedOtpBundles(conversationId: conversationId)
        if secureModeState.activeMode == .verifiedOtp {
            secureModeState.activeMode = .e2e
            secureModeState.pendingState = nil
            secureModeState.pendingRequest = nil
            await persistSecureModeState()
        }
        await refreshVerifiedOtpSummary()
    }

    func deleteVerifiedOtpBundles() async {
        try? await store.deleteVerifiedOtpBundles(conversationId: conversationId)
        wipeExportedBundleIfNeeded()
        if secureModeState.activeMode == .verifiedOtp {
            secureModeState.activeMode = .e2e
            secureModeState.pendingState = nil
            secureModeState.pendingRequest = nil
            await persistSecureModeState()
        }
        await refreshVerifiedOtpSummary()
    }

    private func verifiedOtpEnvelopeMeta(from payload: String) -> (bundleId: UUID, sequence: Int, offset: Int, length: Int)? {
        guard let data = Data(base64Encoded: payload),
              let env = try? JSONDecoder().decode(VerifiedOtpEnvelope.self, from: data),
              env.mode == "verified_otp",
              let bundleId = UUID(uuidString: env.bundleId),
              let ciphertext = Data(base64Encoded: env.ciphertextB64)
        else { return nil }
        return (bundleId, env.sequence, env.offset, ciphertext.count)
    }

    private func estimatedDraftPayloadLength() -> Int {
        if let jpeg = pendingComposerImageJPEG {
            return max(1, jpeg.count * 2)
        }
        return max(1, draftText.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count)
    }
}

struct ChatRow: Identifiable, Equatable {
    let id: UUID
    var isMine: Bool
    var text: String?
    /// Decrypted JPEG; same E2E path as text (JSON envelope in plaintext).
    var imageJPEGData: Data?
    var isInvalid: Bool
    var date: Date
    /// When relay recorded delivery to recipient (DM/group); UI hint for outgoing bubbles.
    var relayDeliveredAt: Date?
}

/// HEIC/JPEG from the photo picker — standard (compressed) or raw 4K (minimal re-encode).
enum VaulteChatComposerImageEncoder {
    enum Mode {
        case standard
        case raw4K
    }

    static func maxPlaintextJSONBytes(for mode: Mode) -> Int {
        switch mode {
        case .standard: return 900_000
        case .raw4K: return 11_000_000
        }
    }

    private static func maxImageBase64Chars(for mode: Mode) -> Int {
        switch mode {
        case .standard: return 650_000
        case .raw4K: return 10_000_000
        }
    }

    static func jpegForComposer(from imageData: Data, mode: Mode) -> Data? {
        switch mode {
        case .standard: return jpegStandard(from: imageData)
        case .raw4K: return jpegRaw4K(from: imageData)
        }
    }

    /// Fast chat photos (~1080p-class), smaller wire size.
    private static func jpegStandard(from imageData: Data) -> Data? {
        let cap = maxImageBase64Chars(for: .standard)
        let pixelCaps = [1920, 1280, 1024, 768, 640]
        let qualities: [CGFloat] = [0.82, 0.74, 0.66, 0.58, 0.5, 0.42]
        if isJPEG(imageData), fitsWire(imageData, cap: cap) { return imageData }
        for maxPx in pixelCaps {
            for q in qualities {
                guard let data = imageJPEG(from: imageData, maxPixel: maxPx, quality: q) else { continue }
                if fitsWire(data, cap: cap) { return data }
            }
        }
        return nil
    }

    /// Full-resolution 4K path: pass-through JPEG when possible; HEIC → JPEG at quality 1.0 without downscale.
    private static func jpegRaw4K(from imageData: Data) -> Data? {
        let cap = maxImageBase64Chars(for: .raw4K)
        if isJPEG(imageData), fitsWire(imageData, cap: cap) { return imageData }
        for q in [CGFloat(1.0), 0.98, 0.95, 0.92] {
            if let data = jpegAtFullResolution(from: imageData, quality: q), fitsWire(data, cap: cap) { return data }
        }
        for q in [CGFloat(0.95), 0.9, 0.85] {
            if let data = imageJPEG(from: imageData, maxPixel: 4096, quality: q), fitsWire(data, cap: cap) { return data }
        }
        return nil
    }

    private static func fitsWire(_ jpeg: Data, cap: Int) -> Bool {
        jpeg.base64EncodedString().count <= cap
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    private static func jpegAtFullResolution(from imageData: Data, quality: CGFloat) -> Data? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(imageData as CFData, srcOpts as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            return fallbackJPEG(from: imageData, maxPixel: 8192, quality: quality)
        }
        let ui = UIImage(cgImage: cg, scale: 1, orientation: .up)
        return ui.jpegData(compressionQuality: quality)
    }

    private static func imageJPEG(from imageData: Data, maxPixel: Int, quality: CGFloat) -> Data? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(imageData as CFData, srcOpts as CFDictionary),
              CGImageSourceGetCount(src) > 0
        else {
            return fallbackJPEG(from: imageData, maxPixel: maxPixel, quality: quality)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            let ui = UIImage(cgImage: cg, scale: 1, orientation: .up)
            return ui.jpegData(compressionQuality: quality)
        }
        return fallbackJPEG(from: imageData, maxPixel: maxPixel, quality: quality)
    }

    private static func fallbackJPEG(from imageData: Data, maxPixel: Int, quality: CGFloat) -> Data? {
        guard let img = UIImage(data: imageData) else { return nil }
        let w = img.size.width * img.scale
        let h = img.size.height * img.scale
        let maxSide = max(w, h)
        let ratio = min(1, CGFloat(maxPixel) / max(maxSide, 1))
        let newSize = CGSize(width: floor(img.size.width * ratio), height: floor(img.size.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: quality)
    }
}

/// Wire plaintext JSON for image messages (encrypted like any other UTF-8 body).
private struct VaulteChatImagePayload: Codable {
    let v: Int
    let m: String
    let d: String
    let c: String?
}


extension ChatViewModel {
    /// Same logical line across N relay rows (group fan-out).
    static func groupLineDedupeKey(_ plaintext: String) -> String? {
        guard plaintext.hasPrefix("__gl:") else { return nil }
        guard let nl = plaintext.firstIndex(of: "\n") else { return nil }
        return String(plaintext[..<nl])
    }

    static func stripGroupLineDedupePrefix(_ plaintext: String) -> String {
        guard plaintext.hasPrefix("__gl:"), let nl = plaintext.firstIndex(of: "\n") else { return plaintext }
        let after = plaintext.index(after: nl)
        return String(plaintext[after...])
    }

    /// Shared by chat bubbles and conversation list previews.
    static func parseStoredPlaintext(_ plaintext: String?) -> (text: String?, image: Data?) {
        guard let p = plaintext, !p.isEmpty else { return (nil, nil) }
        guard p.first == "{", let pdata = p.data(using: .utf8) else {
            return (p, nil, nil)
        }
        // Try image payload
        if let obj = try? JSONDecoder().decode(VaulteChatImagePayload.self, from: pdata),
           obj.v == 1,
           obj.m.hasPrefix("image/"),
           let img = Data(base64Encoded: obj.d),
           !img.isEmpty {
            let cap = obj.c?.trimmingCharacters(in: .whitespacesAndNewlines)
            let textPart = (cap?.isEmpty == false) ? cap : nil
            return (textPart, img, nil)
        }
        return (p, nil)
    }

    static func isCorruptedDisplayedPlaintext(_ plaintext: String?) -> Bool {
        guard let p = plaintext?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return false }
        if p == "(sent by you)" { return true }
        return RoutedE2EPlusCodec.looksLikeDecodedEnvelopeJSONString(p)
    }
}

enum SafetyNumber {
    /// Same 12×5-digit fingerprint for both users: derived from the two X25519 identity public keys (Base64),
    /// in **sorted** order so `Alice|Bob` and `Bob|Alice` are not two different strings.
    static func compute(localIdentityPubB64: String, remoteIdentityPubB64: String) -> String {
        let a = localIdentityPubB64.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = remoteIdentityPubB64.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = a <= b ? a : b
        let high = a <= b ? b : a
        let bytes = Array((low + "|" + high).utf8)
        guard !bytes.isEmpty else {
            return Array(repeating: "00000", count: 12).joined(separator: " ")
        }

        var groups: [String] = []
        for index in 0..<12 {
            var value = 0
            for offset in 0..<5 {
                value = (value * 31 + Int(bytes[(index * 5 + offset) % bytes.count])) % 100_000
            }
            groups.append(String(format: "%05d", value))
        }
        return groups.joined(separator: " ")
    }
}

actor IdentityKeyExchange {
    static let shared = IdentityKeyExchange()

    // ── Identity key (X25519) ─────────────────────────────────
    private let identityService = "com.vaulteprive.identity.x25519"
    private let identityAccount = "local_private_key"
    // ── Ratchet key (X25519, separate from identity) ──────────
    private let ratchetService  = "com.vaulteprive.identity.ratchet"
    private let ratchetAccount  = "local_ratchet_key"
    // ── Local PSK key in QR (stored in UserDefaults) ──────────
    private let pskDefaultsKey  = "vaulte.qr.psk"

    // MARK: - Identity key

    func localPublicKeyBase64() throws -> String {
        try loadOrCreateIdentityKey().publicKey.rawRepresentation.base64EncodedString()
    }

    // MARK: - Ratchet key

    func localRatchetPublicKeyBase64() throws -> String {
        try loadOrCreateRatchetKey().publicKey.rawRepresentation.base64EncodedString()
    }

    // MARK: - PSK for QR

    /// Returns (or creates) the stable 32-byte PSK that is embedded in this device's QR code.
    func localQRPsk() -> String {
        if let existing = UserDefaults.standard.string(forKey: pskDefaultsKey), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let b64 = Data(bytes).base64EncodedString()
        UserDefaults.standard.set(b64, forKey: pskDefaultsKey)
        return b64
    }

    // MARK: - v1 ECDH (AES-GCM fallback, QR v1)

    func deriveAndStoreKey(peerPublicKeyBase64: String, conversationId: UUID) throws {
        guard let peerPubData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw IdentityKeyError.invalidPublicKey
        }
        let peerPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubData)
        let myPrivate  = try loadOrCreateIdentityKey()

        let sharedSecret = try myPrivate.sharedSecretFromKeyAgreement(with: peerPublic)
        let aesKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(conversationId.uuidString.lowercased().utf8),
            sharedInfo: Data("vaulte-e2e-v1".utf8),
            outputByteCount: 32
        )
        ConversationKeyStore.save(key: aesKey, for: conversationId)
    }

    // MARK: - v2 PQXDH + Double Ratchet init (QR v2)

    /// Full initialisation from a v2 QR scan:
    ///   master = HKDF( X25519(local.id, peer.id) [ECDH extract]
    ///                  mixed with PSK_sorted [post-quantum layer] )
    /// Then initialises the Double Ratchet:
    ///   • local UUID < peer UUID  → Alice (initiator, gets send-chain immediately)
    ///   • local UUID > peer UUID  → Bob  (responder, waits for first e2: to start)
    func initializeRatchetSession(
        localUserId:      UUID,
        peerUserId:       UUID,
        peerIdentityB64:  String,
        peerRatchetB64:   String,
        peerPskB64:       String,
        conversationId:   UUID
    ) throws {
        guard let peerIdData  = Data(base64Encoded: peerIdentityB64),
              let peerRatData = Data(base64Encoded: peerRatchetB64),
              let peerPskData = Data(base64Encoded: peerPskB64)
        else { throw IdentityKeyError.invalidPublicKey }

        let peerIdentityPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerIdData)
        let peerRatchetPub  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerRatData)
        let myIdentityPriv  = try loadOrCreateIdentityKey()

        // ── Stage 1: ECDH on identity keys ───────────────────
        let x25519 = try myIdentityPriv.sharedSecretFromKeyAgreement(with: peerIdentityPub)

        // Extract 32 bytes from the ECDH shared secret
        let x25519Bytes = x25519.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("VaultePQXDH-Extract".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        // ── Stage 2: Mix in both PSKs (post-quantum layer) ───
        let myPskData = Data(base64Encoded: localQRPsk()) ?? Data(repeating: 0, count: 32)
        // Deterministic ordering by UUID string so both parties get the same result
        let (psk1, psk2) = localUserId.uuidString < peerUserId.uuidString
            ? (myPskData, peerPskData)
            : (peerPskData, myPskData)

        let masterSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: x25519Bytes + psk1 + psk2),
            salt: Data("VaultePQXDH-v2".utf8),
            info: Data("master".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }

        // Also save as AES key so e1: fallback still works
        ConversationKeyStore.save(key: SymmetricKey(data: masterSecret), for: conversationId)

        // ── Stage 3: Double Ratchet initialisation ────────────
        let myRatchetPriv = try loadOrCreateRatchetKey()
        let state: VaulteRatchetState
        if localUserId.uuidString < peerUserId.uuidString {
            // Alice — initiator; does first DH-ratchet step immediately
            state = try VaulteRatchet.initAlice(
                masterSecret: masterSecret,
                aliceRatchetPriv: myRatchetPriv,
                bobInitialRatchetPub: peerRatchetPub
            )
        } else {
            // Bob — responder; sends e1: until Alice's first e2: arrives
            state = VaulteRatchet.initBob(
                masterSecret: masterSecret,
                bobRatchetPriv: myRatchetPriv
            )
        }
        ConversationKeyStore.saveRatchetState(state, for: conversationId)
    }

    func evictKeyFromMemory() {}

    func clearLocalIdentityKey() {
        keychainDelete(service: identityService, account: identityAccount)
        keychainDelete(service: ratchetService,  account: ratchetAccount)
    }

    // MARK: - Private helpers

    private func loadOrCreateIdentityKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let k = keychainLoadKey(service: identityService, account: identityAccount) { return k }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        try keychainSaveKey(fresh, service: identityService, account: identityAccount)
        return fresh
    }

    private func loadOrCreateRatchetKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let k = keychainLoadKey(service: ratchetService, account: ratchetAccount) { return k }
        let fresh = Curve25519.KeyAgreement.PrivateKey()
        try keychainSaveKey(fresh, service: ratchetService, account: ratchetAccount)
        return fresh
    }

    private func keychainLoadKey(service: String, account: String) -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key  = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { return nil }
        return key
    }

    private func keychainSaveKey(
        _ key: Curve25519.KeyAgreement.PrivateKey,
        service: String,
        account: String
    ) throws {
        keychainDelete(service: service, account: account)
        var insert: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(macCatalyst)
        insert[kSecUseDataProtectionKeychain as String] = true
        #endif
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityKeyError.keychainFailure(status: status)
        }
    }

    private func keychainDelete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

