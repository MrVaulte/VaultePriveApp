//
//  OTPStore.swift
//  Vaulté Privé
//

import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ConversationSecurityProfile: String, CaseIterable, Sendable {
    case e2ePlus = "e2e_plus"
    case otpStrict = "otp_strict"
}

enum ConversationKind: String, CaseIterable, Sendable {
    case direct = "direct"
    case group = "group"
    case channel = "channel"

    var isMultiMember: Bool {
        self != .direct
    }
}

/// One row in the conversations list (DM or group).
struct OTPConversationListRow: Sendable, Equatable {
    let id: UUID
    let peerRecipientId: UUID
    let title: String?
    let conversationKind: ConversationKind
    /// Group owner UUID when `isGroup`; used to avoid showing the owner’s personal name as the group title.
    let groupOwnerUserId: UUID?

    var isGroup: Bool {
        conversationKind.isMultiMember
    }

    var isChannel: Bool {
        conversationKind == .channel
    }
}

actor OTPStore {
    private let keychain: OTPKeychainStorage
    private var db: OpaquePointer?
    private static let verifiedOtpKeychainAccountPrefix = "verifiedotp.filekey."
    private static let verifiedOtpPadDirectory = "VerifiedOtpPads"

    /// Placeholder peer until the user sets the real recipient UUID for an imported conversation.
    private let importPeerPlaceholder = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(keychain: OTPKeychainStorage = OTPKeychainStorage()) async throws {
        self.keychain = keychain
        try openDatabase()
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Conversations

    func createConversation(
        peerRecipientId: UUID,
        title: String? = nil,
        securityProfile: ConversationSecurityProfile = .e2ePlus,
        kind: ConversationKind = .direct,
        conversationId: UUID? = nil
    ) throws -> UUID {
        try ensureDeletedConversationsTable()
        let id = conversationId ?? UUID()
        let now = Date.timeIntervalSinceReferenceDate
        let sql: String
        if let title {
            sql = """
            INSERT OR IGNORE INTO conversations (id, peer_recipient_id, title, security_profile, conversation_kind, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            try run(sql, [id.uuidString, peerRecipientId.uuidString, title, securityProfile.rawValue, kind.rawValue, now])
            try run(
                "UPDATE conversations SET peer_recipient_id = ?, title = ?, security_profile = ?, conversation_kind = ? WHERE id = ?;",
                [peerRecipientId.uuidString, title, securityProfile.rawValue, kind.rawValue, id.uuidString]
            )
        } else {
            sql = """
            INSERT OR IGNORE INTO conversations (id, peer_recipient_id, title, security_profile, conversation_kind, created_at)
            VALUES (?, ?, NULL, ?, ?, ?);
            """
            try run(sql, [id.uuidString, peerRecipientId.uuidString, securityProfile.rawValue, kind.rawValue, now])
            try run(
                "UPDATE conversations SET peer_recipient_id = ?, security_profile = ?, conversation_kind = ? WHERE id = ?;",
                [peerRecipientId.uuidString, securityProfile.rawValue, kind.rawValue, id.uuidString]
            )
        }
        try clearDeletedConversationMarker(conversationId: id)
        return id
    }

    func securityProfile(for conversationId: UUID) throws -> ConversationSecurityProfile {
        let sql = "SELECT security_profile FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return .e2ePlus }
        let raw = String(cString: sqlite3_column_text(stmt, 0))
        return ConversationSecurityProfile(rawValue: raw) ?? .e2ePlus
    }

    func conversationKind(for conversationId: UUID) throws -> ConversationKind {
        let sql = "SELECT conversation_kind, is_group FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .direct }
        if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            let raw = String(cString: sqlite3_column_text(stmt, 0))
            if let kind = ConversationKind(rawValue: raw) {
                return kind
            }
        }
        return sqlite3_column_int(stmt, 1) != 0 ? .group : .direct
    }

    func setSecurityProfile(_ profile: ConversationSecurityProfile, for conversationId: UUID) throws {
        try run(
            "UPDATE conversations SET security_profile = ? WHERE id = ?;",
            [profile.rawValue, conversationId.uuidString]
        )
    }

    func verifiedOtpBundleSummary(conversationId: UUID) throws -> VerifiedOtpBundleSummary {
        let records = try verifiedOtpBundles(conversationId: conversationId)
        return VerifiedOtpBundleSummary(
            sendBundle: records.first(where: { $0.direction == .send }),
            receiveBundle: records.first(where: { $0.direction == .receive })
        )
    }

    func verifiedOtpBundles(conversationId: UUID) throws -> [VerifiedOtpBundleRecord] {
        let sql = """
        SELECT bundle_id, conversation_id, peer_id, owner_user_id, direction, status, fingerprint_short, fingerprint_full,
               total_bytes, remaining_bytes, next_sequence, next_offset, imported_at, created_at, file_key_ref, pad_file_url,
               consumed_ranges_json
        FROM verified_otp_bundles
        WHERE conversation_id = ?
        ORDER BY created_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        var records: [VerifiedOtpBundleRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = readVerifiedOtpBundleRecord(stmt) {
                records.append(record)
            }
        }
        return records
    }

    func verifiedOtpBundle(conversationId: UUID, direction: VerifiedOtpDirection) throws -> VerifiedOtpBundleRecord? {
        let sql = """
        SELECT bundle_id, conversation_id, peer_id, owner_user_id, direction, status, fingerprint_short, fingerprint_full,
               total_bytes, remaining_bytes, next_sequence, next_offset, imported_at, created_at, file_key_ref, pad_file_url,
               consumed_ranges_json
        FROM verified_otp_bundles
        WHERE conversation_id = ? AND direction = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        bindText(stmt, index: 2, direction.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readVerifiedOtpBundleRecord(stmt)
    }

    func createVerifiedOtpBundle(
        descriptor: VerifiedOtpBundleDescriptor,
        padBytes: Data
    ) throws -> VerifiedOtpBundleRecord {
        try ensureConversationExists(id: descriptor.conversationId, ts: descriptor.createdAt.timeIntervalSinceReferenceDate)
        let fileKey = try SecureRandom.bytes(count: 32)
        let fileKeyRef = Self.verifiedOtpKeychainAccountPrefix + descriptor.bundleId.uuidString.lowercased()
        try keychain.saveData(account: fileKeyRef, data: fileKey)
        let padURL = try writeProtectedVerifiedOtpPad(
            bundleId: descriptor.bundleId,
            encryptedPadBytes: try encryptVerifiedOtpPad(padBytes, key: fileKey)
        )
        let importedAt = descriptor.createdAt
        let status = VerifiedOtpStateMachine.statusForRemainingBytes(
            remainingBytes: descriptor.totalBytes,
            totalBytes: descriptor.totalBytes
        )
        try run(
            """
            INSERT OR REPLACE INTO verified_otp_bundles (
                bundle_id, conversation_id, peer_id, owner_user_id, direction, status, fingerprint_short, fingerprint_full,
                total_bytes, remaining_bytes, next_sequence, next_offset, imported_at, created_at, file_key_ref, pad_file_url,
                consumed_ranges_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, '[]');
            """,
            [
                descriptor.bundleId.uuidString,
                descriptor.conversationId.uuidString,
                descriptor.peerId.uuidString,
                descriptor.ownerUserId.uuidString,
                descriptor.direction.rawValue,
                status.rawValue,
                descriptor.fingerprint.shortCode,
                descriptor.fingerprint.fullHex,
                Int64(descriptor.totalBytes),
                Int64(descriptor.totalBytes),
                importedAt.timeIntervalSinceReferenceDate,
                descriptor.createdAt.timeIntervalSinceReferenceDate,
                fileKeyRef,
                padURL.path,
            ]
        )
        guard let stored = try verifiedOtpBundle(conversationId: descriptor.conversationId, direction: descriptor.direction) else {
            throw OTPError.verifiedOtpStorageFailure
        }
        return stored
    }

    func importVerifiedOtpBundle(
        descriptor: VerifiedOtpBundleDescriptor,
        padBytes: Data
    ) throws -> VerifiedOtpBundleRecord {
        let localDescriptor = VerifiedOtpBundleDescriptor(
            bundleId: descriptor.bundleId,
            conversationId: descriptor.conversationId,
            peerId: descriptor.peerId,
            ownerUserId: descriptor.ownerUserId,
            direction: descriptor.direction.opposite,
            createdAt: descriptor.createdAt,
            totalBytes: descriptor.totalBytes,
            fingerprint: descriptor.fingerprint
        )
        return try createVerifiedOtpBundle(descriptor: localDescriptor, padBytes: padBytes)
    }

    func exportVerifiedOtpPadFile(conversationId: UUID, direction: VerifiedOtpDirection) throws -> URL? {
        guard let bundle = try verifiedOtpBundle(conversationId: conversationId, direction: direction) else { return nil }
        let padBytes = try loadVerifiedOtpPadBytes(bundle: bundle)
        let fileData = try VerifiedOtpBundleCrypto.bundleFileData(
            descriptor: bundle.descriptor,
            padBytes: padBytes
        )
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: try Self.defaultStoreSQLiteURL(),
            create: true
        )
        let url = tempDir.appendingPathComponent(VerifiedOtpBundleCrypto.fileName(for: bundle.descriptor), isDirectory: false)
        try fileData.write(to: url, options: [.atomic])
        return url
    }

    func reserveVerifiedOtpSendSlice(
        conversationId: UUID,
        plaintextLength: Int
    ) throws -> VerifiedOtpSendReservation {
        guard let bundle = try verifiedOtpBundle(conversationId: conversationId, direction: .send) else {
            throw OTPError.verifiedOtpBundleNotFound
        }
        guard bundle.status != .revoked else { throw OTPError.verifiedOtpBundleRevoked }
        guard bundle.remainingBytes >= plaintextLength else { throw OTPError.verifiedOtpBundleExhausted }
        let reservation = VerifiedOtpSendReservation(
            bundleId: bundle.bundleId,
            sequence: bundle.nextSequence,
            offset: bundle.nextOffset,
            length: plaintextLength,
            remainingAfterReservation: bundle.remainingBytes - plaintextLength,
            statusAfterReservation: VerifiedOtpStateMachine.statusForRemainingBytes(
                remainingBytes: bundle.remainingBytes - plaintextLength,
                totalBytes: bundle.totalBytes
            )
        )
        try run(
            """
            UPDATE verified_otp_bundles
            SET next_sequence = ?, next_offset = ?, remaining_bytes = ?, status = ?
            WHERE bundle_id = ?;
            """,
            [
                Int64(bundle.nextSequence + 1),
                Int64(bundle.nextOffset + plaintextLength),
                Int64(bundle.remainingBytes - plaintextLength),
                reservation.statusAfterReservation.rawValue,
                bundle.bundleId.uuidString,
            ]
        )
        return reservation
    }

    func commitVerifiedOtpReceivedSlice(
        conversationId: UUID,
        bundleId: UUID,
        offset: Int,
        length: Int
    ) throws {
        guard var bundle = try verifiedOtpBundle(conversationId: conversationId, direction: .receive),
              bundle.bundleId == bundleId
        else {
            throw OTPError.verifiedOtpBundleNotFound
        }
        if VerifiedOtpRangeTracker.containsReplay(rangesJSON: bundle.consumedRangesJSON, start: offset, length: length) {
            throw OTPError.verifiedOtpReplayDetected
        }
        let nextRanges = VerifiedOtpRangeTracker.appending(
            rangesJSON: bundle.consumedRangesJSON,
            start: offset,
            length: length
        )
        let maxCoveredEnd = VerifiedOtpRangeTracker.decode(nextRanges).map(\.endExclusive).max() ?? 0
        let remaining = max(0, bundle.totalBytes - maxCoveredEnd)
        let nextStatus = VerifiedOtpStateMachine.statusForRemainingBytes(
            remainingBytes: remaining,
            totalBytes: bundle.totalBytes
        )
        try run(
            """
            UPDATE verified_otp_bundles
            SET consumed_ranges_json = ?, remaining_bytes = ?, status = ?
            WHERE bundle_id = ?;
            """,
            [
                nextRanges,
                Int64(remaining),
                nextStatus.rawValue,
                bundle.bundleId.uuidString,
            ]
        )
        bundle = try verifiedOtpBundle(conversationId: conversationId, direction: .receive) ?? bundle
    }

    func revokeVerifiedOtpBundles(conversationId: UUID) throws {
        try run(
            "UPDATE verified_otp_bundles SET status = ? WHERE conversation_id = ?;",
            [VerifiedOtpBundleStatus.revoked.rawValue, conversationId.uuidString]
        )
    }

    func deleteVerifiedOtpBundles(conversationId: UUID) throws {
        let bundles = try verifiedOtpBundles(conversationId: conversationId)
        for bundle in bundles {
            try? FileManager.default.removeItem(at: bundle.padFileURL)
            try? keychain.deleteData(account: bundle.fileKeyRef)
        }
        try run("DELETE FROM verified_otp_bundles WHERE conversation_id = ?;", [conversationId.uuidString])
    }

    func loadVerifiedOtpPadBytes(bundle: VerifiedOtpBundleRecord) throws -> Data {
        let encrypted = try Data(contentsOf: bundle.padFileURL)
        let fileKey = try keychain.loadData(account: bundle.fileKeyRef)
        return try decryptVerifiedOtpPad(encrypted, key: fileKey)
    }

    func secureConversationModeState(for conversationId: UUID) throws -> SecureConversationModeState {
        let sql = """
        SELECT secure_mode, mode_pending_state, mode_pending_request_json, mode_resolved_request_ids_json, mode_updated_at
        FROM conversations WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return SecureConversationModeState() }

        let activeRaw = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? "e2e" : String(cString: sqlite3_column_text(stmt, 0))
        let pendingRaw = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 1))
        let requestJSON = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 2))
        let resolvedJSON = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "[]" : String(cString: sqlite3_column_text(stmt, 3))
        let updatedAtValue = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 4)

        let activeMode = SecureConversationMode.resolved(from: activeRaw)

        let pendingRequest: ModeSwitchRequest? = {
            guard !requestJSON.isEmpty, let data = requestJSON.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ModeSwitchRequest.self, from: data)
        }()
        let resolvedIds: [UUID] = {
            guard let data = resolvedJSON.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return raw.compactMap(UUID.init(uuidString:))
        }()

        var state = SecureConversationModeState(
            activeMode: activeMode,
            pendingState: SecureConversationPendingState(rawValue: pendingRaw),
            pendingRequest: pendingRequest,
            resolvedRequestIds: resolvedIds,
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAtValue)
        )
        if activeRaw == "e2e_plus" || requestJSON.contains("e2e_plus") {
            state.migrateLegacyModes()
        }
        return state
    }

    func setSecureConversationModeState(_ state: SecureConversationModeState, for conversationId: UUID) throws {
        let requestJSON: String = {
            guard let pending = state.pendingRequest,
                  let data = try? JSONEncoder().encode(pending),
                  let json = String(data: data, encoding: .utf8)
            else { return "" }
            return json
        }()
        let resolvedJSON: String = {
            let raw = state.resolvedRequestIds.map { $0.uuidString.lowercased() }
            guard let data = try? JSONEncoder().encode(raw),
                  let json = String(data: data, encoding: .utf8)
            else { return "[]" }
            return json
        }()
        try run(
            """
            UPDATE conversations
            SET secure_mode = ?, mode_pending_state = ?, mode_pending_request_json = ?, mode_resolved_request_ids_json = ?, mode_updated_at = ?
            WHERE id = ?;
            """,
            [
                state.activeMode.rawValue,
                state.pendingState?.rawValue ?? "",
                requestJSON,
                resolvedJSON,
                state.updatedAt.timeIntervalSinceReferenceDate,
                conversationId.uuidString,
            ]
        )
    }

    func updatePeerRecipient(conversationId: UUID, peerRecipientId: UUID) throws {
        try run(
            "UPDATE conversations SET peer_recipient_id = ? WHERE id = ?;",
            [peerRecipientId.uuidString, conversationId.uuidString]
        )
    }

    func allConversations() throws -> [OTPConversationListRow] {
        let sql = """
        SELECT id, peer_recipient_id, title, conversation_kind, is_group, group_member_ids, group_owner_id
        FROM conversations ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [OTPConversationListRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = String(cString: sqlite3_column_text(stmt, 0))
            let peer = String(cString: sqlite3_column_text(stmt, 1))
            let titlePtr = sqlite3_column_text(stmt, 2)
            let title = titlePtr == nil ? nil : String(cString: titlePtr!)
            let kind: ConversationKind = {
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    let raw = String(cString: sqlite3_column_text(stmt, 3))
                    if let parsed = ConversationKind(rawValue: raw) {
                        return parsed
                    }
                }
                let legacyIsGroup = sqlite3_column_type(stmt, 4) != SQLITE_NULL && sqlite3_column_int(stmt, 4) != 0
                return legacyIsGroup ? .group : .direct
            }()
            let ownerPtr = sqlite3_column_text(stmt, 6)
            let ownerId: UUID? = {
                guard kind.isMultiMember, ownerPtr != nil else { return nil }
                return UUID(uuidString: String(cString: ownerPtr!))
            }()
            guard let cid = UUID(uuidString: sid), let pid = UUID(uuidString: peer) else { continue }
            rows.append(OTPConversationListRow(id: cid, peerRecipientId: pid, title: title, conversationKind: kind, groupOwnerUserId: ownerId))
        }
        return rows
    }

    /// Whether this conversation is a multi-member group (E2E fan-out over pairwise sessions).
    func isGroupConversation(conversationId: UUID) throws -> Bool {
        let sql = "SELECT conversation_kind, is_group FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            let raw = String(cString: sqlite3_column_text(stmt, 0))
            if let kind = ConversationKind(rawValue: raw) {
                return kind.isMultiMember
            }
        }
        return sqlite3_column_int(stmt, 1) != 0
    }

    /// Sorted member UUIDs for a group; empty for DMs or unknown.
    func groupMemberUserIds(conversationId: UUID) throws -> [UUID] {
        let sql = "SELECT group_member_ids FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return [] }
        let json = String(cString: sqlite3_column_text(stmt, 0))
        return Self.decodeMemberUUIDList(json: json)
    }

    /// Creates a **group** thread (new random `conversation_id`). `memberUserIds` must include every participant (including the creator). `listPeerId` seeds list UI (e.g. first non-self member). `ownerUserId` is persisted as the group owner (typically the creator).
    func createGroupConversation(
        title: String,
        memberUserIds: [UUID],
        listPeerId: UUID,
        ownerUserId: UUID,
        kind: ConversationKind = .group,
        groupId: UUID = UUID()
    ) throws -> UUID {
        try ensureDeletedConversationsTable()
        let unique = Array(Set(memberUserIds))
        guard unique.count >= 2 else {
            throw OTPError.databaseError("group requires at least two distinct members")
        }
        let sorted = unique.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let jsonStrings = sorted.map(\.uuidString)
        let jsonData = try JSONSerialization.data(withJSONObject: jsonStrings)
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw OTPError.databaseError("group member json")
        }
        let adminJson = try Self.encodeUUIDStringList([])
        let now = Date.timeIntervalSinceReferenceDate
        try run(
            """
            INSERT OR IGNORE INTO conversations (id, peer_recipient_id, title, security_profile, conversation_kind, created_at, is_group, group_member_ids, group_owner_id, group_admin_ids)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?);
            """,
            [
                groupId.uuidString,
                listPeerId.uuidString,
                title,
                ConversationSecurityProfile.e2ePlus.rawValue,
                kind.rawValue,
                now,
                json,
                ownerUserId.uuidString,
                adminJson,
            ]
        )
        try run(
            """
            UPDATE conversations SET peer_recipient_id = ?, title = ?, security_profile = ?, conversation_kind = ?, is_group = 1, group_member_ids = ?, group_owner_id = ?, group_admin_ids = ?
            WHERE id = ?;
            """,
            [
                listPeerId.uuidString,
                title,
                ConversationSecurityProfile.e2ePlus.rawValue,
                kind.rawValue,
                json,
                ownerUserId.uuidString,
                adminJson,
                groupId.uuidString,
            ]
        )
        try clearDeletedConversationMarker(conversationId: groupId)
        return groupId
    }

    /// Called when decrypting hidden `__grpmeta:` bootstrap from a peer (or self-echo).
    func applyGroupBootstrapFromMeta(
        conversationId: UUID,
        title: String,
        memberUserIds: [UUID],
        listPeerId: UUID,
        ownerUserId: UUID,
        adminUserIds: [UUID],
        kind: ConversationKind = .group
    ) throws {
        let unique = Array(Set(memberUserIds))
        guard unique.count >= 2 else { return }
        let sorted = unique.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let jsonData = try JSONSerialization.data(withJSONObject: sorted.map(\.uuidString))
        guard let json = String(data: jsonData, encoding: .utf8) else { return }
        let adminJson = try Self.encodeUUIDStringList(adminUserIds)
        let now = Date.timeIntervalSinceReferenceDate
        try run(
            """
            INSERT OR IGNORE INTO conversations (id, peer_recipient_id, title, security_profile, conversation_kind, created_at, is_group, group_member_ids, group_owner_id, group_admin_ids)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?);
            """,
            [
                conversationId.uuidString,
                listPeerId.uuidString,
                title,
                ConversationSecurityProfile.e2ePlus.rawValue,
                kind.rawValue,
                now,
                json,
                ownerUserId.uuidString,
                adminJson,
            ]
        )
        try run(
            """
            UPDATE conversations SET peer_recipient_id = ?, title = ?, conversation_kind = ?, is_group = 1, group_member_ids = ?, group_owner_id = ?, group_admin_ids = ? WHERE id = ?;
            """,
            [listPeerId.uuidString, title, kind.rawValue, json, ownerUserId.uuidString, adminJson, conversationId.uuidString]
        )
        try clearDeletedConversationMarker(conversationId: conversationId)
    }

    func groupOwnerUserId(conversationId: UUID) throws -> UUID? {
        let sql = "SELECT group_owner_id FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        let s = String(cString: sqlite3_column_text(stmt, 0))
        return UUID(uuidString: s)
    }

    func groupAdminUserIds(conversationId: UUID) throws -> [UUID] {
        let sql = "SELECT group_admin_ids FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return [] }
        let json = String(cString: sqlite3_column_text(stmt, 0))
        return Self.decodeMemberUUIDList(json: json)
    }

    func updateGroupConversationTitle(conversationId: UUID, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try run(
            "UPDATE conversations SET title = ? WHERE id = ? AND is_group = 1;",
            [trimmed, conversationId.uuidString]
        )
    }

    private static func decodeMemberUUIDList(json: String) -> [UUID] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr.compactMap { UUID(uuidString: $0) }
    }

    private static func encodeUUIDStringList(_ uuids: [UUID]) throws -> String {
        let arr = uuids.map(\.uuidString)
        let data = try JSONSerialization.data(withJSONObject: arr)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OTPError.databaseError("encode uuid list")
        }
        return json
    }

    func upsertConversation(id: UUID, peerRecipientId: UUID) throws {
        try ensureDeletedConversationsTable()
        let now = Date.timeIntervalSinceReferenceDate
        try run(
            """
            INSERT OR IGNORE INTO conversations (id, peer_recipient_id, title, security_profile, conversation_kind, created_at)
            VALUES (?, ?, NULL, ?, ?, ?);
            """,
            [id.uuidString, peerRecipientId.uuidString, ConversationSecurityProfile.e2ePlus.rawValue, ConversationKind.direct.rawValue, now]
        )
        try run(
            "UPDATE conversations SET peer_recipient_id = ?, conversation_kind = ? WHERE id = ?;",
            [peerRecipientId.uuidString, ConversationKind.direct.rawValue, id.uuidString]
        )
        try clearDeletedConversationMarker(conversationId: id)
    }

    /// Delete only messages in a conversation, keeping the conversation entry and keys intact.
    func deleteConversationMessages(conversationId: UUID) throws {
        try run("DELETE FROM messages WHERE conversation_id = ?;", [conversationId.uuidString])
    }

    func deleteConversation(_ conversationId: UUID) throws {
        try ensureDeletedConversationsTable()
        try markConversationDeleted(conversationId, at: Date())
        let padIds = try padIds(for: conversationId)
        if !padIds.isEmpty {
            keychain.deleteAllKnown(padIds: padIds)
        }
        try? keychain.delete(padId: conversationId)
        try run("DELETE FROM messages WHERE conversation_id = ?;", [conversationId.uuidString])
        try run("DELETE FROM pads WHERE conversation_id = ?;", [conversationId.uuidString])
        try run("DELETE FROM conversations WHERE id = ?;", [conversationId.uuidString])
    }

    func deletedConversationCutoff(conversationId: UUID) throws -> Date? {
        try ensureDeletedConversationsTable()
        let sql = "SELECT deleted_at FROM deleted_conversations WHERE conversation_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
    }

    func clearDeletedConversationMarker(conversationId: UUID) throws {
        try ensureDeletedConversationsTable()
        try run("DELETE FROM deleted_conversations WHERE conversation_id = ?;", [conversationId.uuidString])
    }

    /// Returns a stable per-conversation E2E key material.
    /// Stored in Keychain under the conversation UUID and reused for every message in that chat.
    func persistentE2EKey(conversationId: UUID, byteLength: Int = 32) throws -> (keyId: UUID, key: Data) {
        do {
            let existing = try keychain.load(padId: conversationId)
            return (conversationId, existing)
        } catch {
            let created = try SecureRandom.bytes(count: max(16, byteLength))
            try keychain.save(padId: conversationId, data: created)
            return (conversationId, created)
        }
    }

    func peerRecipient(for conversationId: UUID) throws -> UUID? {
        let sql = "SELECT peer_recipient_id FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let s = String(cString: sqlite3_column_text(stmt, 0))
        return UUID(uuidString: s)
    }

    func directConversationId(for peerRecipientId: UUID) throws -> UUID? {
        let sql = """
        SELECT id
        FROM conversations
        WHERE peer_recipient_id = ?
          AND is_group = 0
        ORDER BY created_at DESC, id DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, peerRecipientId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let raw = String(cString: sqlite3_column_text(stmt, 0))
        return UUID(uuidString: raw)
    }

    func conversationTitle(conversationId: UUID) throws -> String? {
        let sql = "SELECT title FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        let t = String(cString: sqlite3_column_text(stmt, 0))
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Pads

    /// Generates cryptographically strong pads locally. Bytes live in Keychain; metadata in SQLite.
    func generatePads(
        conversationId: UUID,
        direction: OTPDirection,
        count: Int,
        byteLength: Int = 256
    ) throws {
        guard count > 0, byteLength > 0 else { return }
        let now = Date()
        let ts = now.timeIntervalSinceReferenceDate

        for _ in 0 ..< count {
            let id = UUID()
            let bytes = try SecureRandom.bytes(count: byteLength)
            try keychain.save(padId: id, data: bytes)
            try run(
                """
                INSERT INTO pads (id, conversation_id, direction, byte_length, is_used, created_at)
                VALUES (?, ?, ?, ?, 0, ?);
                """,
                [id.uuidString, conversationId.uuidString, direction.rawValue, Int32(byteLength), ts]
            )
        }
    }

    func remainingCounts(conversationId: UUID) throws -> (inbound: Int, outbound: Int) {
        let inbound = try countPads(conversationId: conversationId, direction: .inbound, unusedOnly: true)
        let outbound = try countPads(conversationId: conversationId, direction: .outbound, unusedOnly: true)
        return (inbound, outbound)
    }

    func nextUnusedOutboundRecord(conversationId: UUID) throws -> OTPPadRecord? {
        let sql = """
        SELECT id, conversation_id, direction, byte_length, is_used, created_at
        FROM pads
        WHERE conversation_id = ? AND direction = ? AND is_used = 0
        ORDER BY created_at ASC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, conversationId.uuidString)
        bindText(stmt, index: 2, OTPDirection.outbound.rawValue)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readPadRecord(stmt)
    }

    func padRecord(padId: UUID) throws -> OTPPadRecord? {
        let sql = """
        SELECT id, conversation_id, direction, byte_length, is_used, created_at
        FROM pads WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, padId.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readPadRecord(stmt)
    }

    func loadPadBytes(padId: UUID) throws -> Data {
        try keychain.load(padId: padId)
    }

    func fullPad(from record: OTPPadRecord) throws -> OTPPad {
        let bytes = try keychain.load(padId: record.id)
        return OTPPad(
            id: record.id,
            direction: record.direction,
            bytes: bytes,
            isUsed: record.isUsed,
            createdAt: record.createdAt
        )
    }

    func markPadUsed(padId: UUID) throws {
        try run(
            "UPDATE pads SET is_used = 1 WHERE id = ?;",
            [padId.uuidString]
        )
    }

    /// Imports pads from an offline QR payload. Does not write QR data to the photo library.
    func importQRPayload(_ payload: OTPQRPayload) throws {
        let tsBase = Date().timeIntervalSinceReferenceDate
        for (idx, entry) in payload.pads.enumerated() {
            guard let data = Data(base64Encoded: entry.bytesB64) else {
                throw OTPError.importPayloadInvalid
            }
            try keychain.save(padId: entry.id, data: data)
            let created = entry.createdAt.timeIntervalSinceReferenceDate
            try run(
                """
                INSERT OR REPLACE INTO pads (id, conversation_id, direction, byte_length, is_used, created_at)
                VALUES (?, ?, ?, ?, 0, ?);
                """,
                [
                    entry.id.uuidString,
                    payload.conversationId.uuidString,
                    payload.direction.rawValue,
                    Int32(data.count),
                    created + Double(idx) * 1e-9,
                ]
            )
        }
        try ensureConversationExists(id: payload.conversationId, ts: tsBase)
    }

    /// Builds a peer-facing package: same key material as your unused outbound pads, labeled inbound for the peer.
    func makePeerInboundPayload(conversationId: UUID, maxPads: Int = 8) throws -> OTPQRPayload {
        let sql = """
        SELECT id, byte_length, is_used, created_at FROM pads
        WHERE conversation_id = ? AND direction = ? AND is_used = 0
        ORDER BY created_at ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, conversationId.uuidString)
        bindText(stmt, index: 2, OTPDirection.outbound.rawValue)
        sqlite3_bind_int(stmt, 3, Int32(maxPads))

        var entries: [OTPQRPadEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            guard let uuid = UUID(uuidString: id) else { continue }
            let created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            let material = try keychain.load(padId: uuid)
            entries.append(OTPQRPadEntry(id: uuid, bytesB64: material.base64EncodedString(), createdAt: created))
        }

        return OTPQRPayload(
            schemaVersion: 1,
            conversationId: conversationId,
            direction: .inbound,
            pads: entries
        )
    }

    func loadVerifiedOtpBundleForDirection(
        conversationId: UUID,
        direction: VerifiedOtpDirection
    ) throws -> (record: VerifiedOtpBundleRecord, padBytes: Data)? {
        guard let record = try verifiedOtpBundle(conversationId: conversationId, direction: direction) else { return nil }
        return (record, try loadVerifiedOtpPadBytes(bundle: record))
    }

    // MARK: - Messages (local ciphertext + optional decrypted cache)

    func upsertServerMessage(
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID,
        padId: UUID,
        ciphertextBase64: String,
        createdAt: Date,
        relayDeliveredAt: Date? = nil
    ) throws {
        let relayBind: Any = relayDeliveredAt.map { $0.timeIntervalSinceReferenceDate } ?? NSNull()
        let sql = """
        INSERT INTO messages (message_id, conversation_id, sender_id, recipient_id, pad_id, ciphertext_b64, created_at, plaintext, state, relay_delivered_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, ?)
        ON CONFLICT(message_id) DO UPDATE SET
          ciphertext_b64 = excluded.ciphertext_b64,
          created_at = excluded.created_at,
          relay_delivered_at = COALESCE(excluded.relay_delivered_at, messages.relay_delivered_at);
        """
        try run(
            sql,
            [
                messageId.uuidString,
                conversationId.uuidString,
                senderId.uuidString,
                recipientId.uuidString,
                padId.uuidString,
                ciphertextBase64,
                createdAt.timeIntervalSinceReferenceDate,
                relayBind,
            ]
        )
    }

    /// Merges relay delivery timestamp when syncing (sender sees peer ack).
    func mergeRelayDeliveredAt(messageId: UUID, deliveredAt: Date?) throws {
        guard let deliveredAt else { return }
        let ts = deliveredAt.timeIntervalSinceReferenceDate
        try run(
            """
            UPDATE messages
            SET relay_delivered_at = ?
            WHERE message_id = ?
              AND (relay_delivered_at IS NULL OR relay_delivered_at < ?);
            """,
            [ts, messageId.uuidString, ts]
        )
    }

    func hasMessage(messageId: UUID) throws -> Bool {
        let sql = "SELECT 1 FROM messages WHERE message_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, messageId)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Latest row for conversation list previews (excludes handled system rows).
    func lastMessageForListPreview(conversationId: UUID) throws -> (plaintext: String?, senderId: UUID)? {
        let sql = """
        SELECT plaintext, sender_id FROM messages
        WHERE conversation_id = ?
        ORDER BY created_at DESC, message_id DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let plainPtr = sqlite3_column_text(stmt, 0)
        let plain = plainPtr == nil ? nil : String(cString: plainPtr!)
        if plain == "__sys__" { return nil }
        if plain?.hasPrefix("__grpmeta:") == true { return nil }
        let sid = String(cString: sqlite3_column_text(stmt, 1))
        guard let senderId = UUID(uuidString: sid) else { return nil }
        return (plain, senderId)
    }

    func cachedMessages(conversationId: UUID) throws -> [CachedMessage] {
        let sql = """
        SELECT message_id, conversation_id, sender_id, recipient_id, pad_id, ciphertext_b64, created_at, plaintext, state, expires_at, relay_delivered_at
        FROM messages WHERE conversation_id = ? ORDER BY created_at ASC, message_id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, conversationId.uuidString)

        var rows: [CachedMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mid = String(cString: sqlite3_column_text(stmt, 0))
            let cid = String(cString: sqlite3_column_text(stmt, 1))
            let sid = String(cString: sqlite3_column_text(stmt, 2))
            let rid = String(cString: sqlite3_column_text(stmt, 3))
            let pid = String(cString: sqlite3_column_text(stmt, 4))
            let b64 = String(cString: sqlite3_column_text(stmt, 5))
            let created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
            let plainPtr = sqlite3_column_text(stmt, 7)
            let plaintext = plainPtr == nil ? nil : String(cString: plainPtr!)
            let state = sqlite3_column_int(stmt, 8)
            let expiresAt: Date? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 9))
            let relayDeliveredAt: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10))
            guard let uMid = UUID(uuidString: mid),
                  let uCid = UUID(uuidString: cid),
                  let uSid = UUID(uuidString: sid),
                  let uRid = UUID(uuidString: rid),
                  let uPid = UUID(uuidString: pid)
            else { continue }
            rows.append(
                CachedMessage(
                    messageId: uMid,
                    conversationId: uCid,
                    senderId: uSid,
                    recipientId: uRid,
                    padId: uPid,
                    ciphertextBase64: b64,
                    createdAt: created,
                    plaintext: plaintext,
                    state: CachedMessage.State(rawValue: Int(state)) ?? .pending,
                    expiresAt: expiresAt,
                    relayDeliveredAt: relayDeliveredAt
                )
            )
        }
        return rows
    }

    /// Local plaintext search (Premium). Only rows with decrypted `plaintext` are returned.
    func searchDecryptedMessages(normalizedNeedle: String, limit: Int = 60) throws -> [OTPMessageSearchHit] {
        let trimmed = normalizedNeedle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let cap = max(1, min(limit, 200))
        let sql = """
        SELECT message_id, conversation_id, plaintext, created_at
        FROM messages
        WHERE plaintext IS NOT NULL
          AND plaintext != ''
          AND plaintext != '__sys__'
          AND LOWER(plaintext) LIKE ? ESCAPE '\\'
        ORDER BY created_at DESC, message_id DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, pattern)
        sqlite3_bind_int(stmt, 2, Int32(cap))

        var out: [OTPMessageSearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mid = String(cString: sqlite3_column_text(stmt, 0))
            let cid = String(cString: sqlite3_column_text(stmt, 1))
            let plainPtr = sqlite3_column_text(stmt, 2)
            let plain = plainPtr == nil ? "" : String(cString: plainPtr!)
            let created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            guard let uMid = UUID(uuidString: mid), let uCid = UUID(uuidString: cid) else { continue }
            let preview = String(plain.prefix(160))
            out.append(OTPMessageSearchHit(messageId: uMid, conversationId: uCid, preview: preview, createdAt: created))
        }
        return out
    }

    func setMessageExpiresAt(messageId: UUID, expiresAt: Date?) throws {
        if let expiresAt {
            try run(
                "UPDATE messages SET expires_at = ? WHERE message_id = ?;",
                [expiresAt.timeIntervalSinceReferenceDate, messageId.uuidString]
            )
        } else {
            try run(
                "UPDATE messages SET expires_at = NULL WHERE message_id = ?;",
                [messageId.uuidString]
            )
        }
    }

    /// Messages whose `expires_at` has passed (caller should delete on relay, then `deleteMessage`).
    func fetchExpiredMessageIds(conversationId: UUID, before cutoff: Date) throws -> [UUID] {
        let cutoffRef = cutoff.timeIntervalSinceReferenceDate
        let selectSQL = """
        SELECT message_id FROM messages
        WHERE conversation_id = ?
          AND expires_at IS NOT NULL
          AND expires_at <= ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        sqlite3_bind_double(stmt, 2, cutoffRef)

        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = String(cString: sqlite3_column_text(stmt, 0))
            if let u = UUID(uuidString: s) { ids.append(u) }
        }
        return ids
    }

    func setMessagePlaintext(messageId: UUID, plaintext: String, state: CachedMessage.State) throws {
        try run(
            "UPDATE messages SET plaintext = ?, state = ? WHERE message_id = ?;",
            [plaintext, Int64(state.rawValue), messageId.uuidString]
        )
    }

    func deleteMessage(messageId: UUID) throws {
        try run("DELETE FROM messages WHERE message_id = ?;", [messageId.uuidString])
    }

    /// Drops local rows for this conversation that are no longer returned by the relay (e.g. deleted by either participant).
    func pruneMessagesToMatchRelay(conversationId: UUID, remoteMessageIds: Set<UUID>) throws {
        if remoteMessageIds.isEmpty {
            try run("DELETE FROM messages WHERE conversation_id = ?;", [conversationId.uuidString])
            return
        }
        let ids = remoteMessageIds.map(\.uuidString)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        DELETE FROM messages
        WHERE conversation_id = ?
          AND message_id NOT IN (\(placeholders));
        """
        var args: [Any] = [conversationId.uuidString]
        args.append(contentsOf: ids)
        try run(sql, args)
    }

    func appendOutgoingPlaceholder(
        messageId: UUID,
        conversationId: UUID,
        senderId: UUID,
        recipientId: UUID,
        padId: UUID,
        plaintext: String,
        createdAt: Date
    ) throws {
        try run(
            """
            INSERT INTO messages (message_id, conversation_id, sender_id, recipient_id, pad_id, ciphertext_b64, created_at, plaintext, state)
            VALUES (?, ?, ?, ?, ?, '', ?, ?, 1)
            ON CONFLICT(message_id) DO UPDATE SET
              plaintext = excluded.plaintext,
              state = 1;
            """,
            [
                messageId.uuidString,
                conversationId.uuidString,
                senderId.uuidString,
                recipientId.uuidString,
                padId.uuidString,
                createdAt.timeIntervalSinceReferenceDate,
                plaintext,
            ]
        )
    }

    // MARK: - Panic

    func panicWipe() throws {
        let ids = try allPadIds()
        keychain.deleteAllKnown(padIds: ids)
        try run("DELETE FROM messages;")
        try run("DELETE FROM pads;")
    }

    func wipeAllLocalData() throws {
        let padIds = try allPadIds()
        let conversationIds = try allConversationIds()
        keychain.deleteAllKnown(padIds: padIds)
        keychain.deleteAllKnown(padIds: conversationIds)
        try run("DELETE FROM messages;")
        try run("DELETE FROM pads;")
        try run("DELETE FROM conversations;")
    }

    // MARK: - Private

    private func allPadIds() throws -> [UUID] {
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM pads;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = String(cString: sqlite3_column_text(stmt, 0))
            if let u = UUID(uuidString: s) { out.append(u) }
        }
        return out
    }

    private func allConversationIds() throws -> [UUID] {
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM conversations;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = String(cString: sqlite3_column_text(stmt, 0))
            if let u = UUID(uuidString: s) { out.append(u) }
        }
        return out
    }

    private func padIds(for conversationId: UUID) throws -> [UUID] {
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM pads WHERE conversation_id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, conversationId.uuidString)

        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = String(cString: sqlite3_column_text(stmt, 0))
            if let u = UUID(uuidString: s) { out.append(u) }
        }
        return out
    }

    private func countPads(conversationId: UUID, direction: OTPDirection, unusedOnly: Bool) throws -> Int {
        let sql: String
        if unusedOnly {
            sql = """
            SELECT COUNT(*) FROM pads
            WHERE conversation_id = ? AND direction = ? AND is_used = 0;
            """
        } else {
            sql = """
            SELECT COUNT(*) FROM pads
            WHERE conversation_id = ? AND direction = ?;
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, conversationId.uuidString)
        bindText(stmt, index: 2, direction.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func markConversationDeleted(_ conversationId: UUID, at date: Date) throws {
        try run(
            """
            INSERT INTO deleted_conversations (conversation_id, deleted_at)
            VALUES (?, ?)
            ON CONFLICT(conversation_id) DO UPDATE SET deleted_at = excluded.deleted_at;
            """,
            [conversationId.uuidString, date.timeIntervalSinceReferenceDate]
        )
    }

    private func ensureConversationExists(id: UUID, ts: Double) throws {
        try run(
            """
            INSERT OR IGNORE INTO conversations (id, peer_recipient_id, title, security_profile, created_at)
            VALUES (?, ?, NULL, ?, ?);
            """,
            [id.uuidString, importPeerPlaceholder.uuidString, ConversationSecurityProfile.e2ePlus.rawValue, ts]
        )
    }

    private func readVerifiedOtpBundleRecord(_ stmt: OpaquePointer?) -> VerifiedOtpBundleRecord? {
        guard let stmt else { return nil }
        let bundleIdRaw = String(cString: sqlite3_column_text(stmt, 0))
        let conversationIdRaw = String(cString: sqlite3_column_text(stmt, 1))
        let peerIdRaw = String(cString: sqlite3_column_text(stmt, 2))
        let ownerUserIdRaw = String(cString: sqlite3_column_text(stmt, 3))
        let directionRaw = String(cString: sqlite3_column_text(stmt, 4))
        let statusRaw = String(cString: sqlite3_column_text(stmt, 5))
        let fingerprintShort = String(cString: sqlite3_column_text(stmt, 6))
        let fingerprintFull = String(cString: sqlite3_column_text(stmt, 7))
        let totalBytes = Int(sqlite3_column_int(stmt, 8))
        let remainingBytes = Int(sqlite3_column_int(stmt, 9))
        let nextSequence = Int(sqlite3_column_int(stmt, 10))
        let nextOffset = Int(sqlite3_column_int(stmt, 11))
        let importedAt: Date? = sqlite3_column_type(stmt, 12) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 12))
        let createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 13))
        let fileKeyRef = String(cString: sqlite3_column_text(stmt, 14))
        let padFileURLRaw = String(cString: sqlite3_column_text(stmt, 15))
        let consumedRangesJSON = String(cString: sqlite3_column_text(stmt, 16))
        guard let bundleId = UUID(uuidString: bundleIdRaw),
              let conversationId = UUID(uuidString: conversationIdRaw),
              let peerId = UUID(uuidString: peerIdRaw),
              let ownerUserId = UUID(uuidString: ownerUserIdRaw),
              let direction = VerifiedOtpDirection(rawValue: directionRaw),
              let status = VerifiedOtpBundleStatus(rawValue: statusRaw)
        else { return nil }
        return VerifiedOtpBundleRecord(
            bundleId: bundleId,
            conversationId: conversationId,
            peerId: peerId,
            ownerUserId: ownerUserId,
            direction: direction,
            status: status,
            fingerprintShortCode: fingerprintShort,
            fingerprintFullHex: fingerprintFull,
            totalBytes: totalBytes,
            remainingBytes: remainingBytes,
            nextSequence: nextSequence,
            nextOffset: nextOffset,
            importedAt: importedAt,
            createdAt: createdAt,
            fileKeyRef: fileKeyRef,
            padFileURL: URL(fileURLWithPath: padFileURLRaw),
            consumedRangesJSON: consumedRangesJSON
        )
    }

    private func readPadRecord(_ stmt: OpaquePointer?) -> OTPPadRecord? {
        guard let stmt else { return nil }
        let sid = String(cString: sqlite3_column_text(stmt, 0))
        let cid = String(cString: sqlite3_column_text(stmt, 1))
        let dir = String(cString: sqlite3_column_text(stmt, 2))
        let bl = Int(sqlite3_column_int(stmt, 3))
        let used = sqlite3_column_int(stmt, 4) != 0
        let created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
        guard let id = UUID(uuidString: sid),
              let conversationId = UUID(uuidString: cid),
              let direction = OTPDirection(rawValue: dir)
        else { return nil }
        return OTPPadRecord(
            id: id,
            conversationId: conversationId,
            direction: direction,
            byteLength: bl,
            isUsed: used,
            createdAt: created
        )
    }

    private func openDatabase() throws {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VaultePrive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("store.sqlite3", isDirectory: false)
        let path = url.path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw OTPError.databaseError("open failed")
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=FULL;", nil, nil, nil)
        sqlite3_busy_timeout(db, 5_000)
    }

    private func verifiedOtpPadDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VaultePrive", isDirectory: true)
        let dir = base.appendingPathComponent(Self.verifiedOtpPadDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
        return dir
    }

    private func writeProtectedVerifiedOtpPad(bundleId: UUID, encryptedPadBytes: Data) throws -> URL {
        let dir = try verifiedOtpPadDirectoryURL()
        let url = dir.appendingPathComponent(bundleId.uuidString.lowercased() + ".bin", isDirectory: false)
        try encryptedPadBytes.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        return url
    }

    private func encryptVerifiedOtpPad(_ plaintext: Data, key: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        return nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
    }

    private func decryptVerifiedOtpPad(_ combined: Data, key: Data) throws -> Data {
        guard combined.count >= 28 else {
            throw OTPError.verifiedOtpStorageFailure
        }
        let nonceData = combined.prefix(12)
        let ciphertext = combined.dropFirst(12).dropLast(16)
        let tag = combined.suffix(16)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealed, using: SymmetricKey(data: key))
    }

    private func migrate() throws {
        try execDDL(
            """
            CREATE TABLE IF NOT EXISTS conversations (
              id TEXT PRIMARY KEY,
              peer_recipient_id TEXT NOT NULL,
              title TEXT,
              security_profile TEXT NOT NULL DEFAULT 'e2e_plus',
              conversation_kind TEXT NOT NULL DEFAULT 'direct',
              created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS pads (
              id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              direction TEXT NOT NULL,
              byte_length INTEGER NOT NULL,
              is_used INTEGER NOT NULL,
              created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_pads_lookup ON pads (conversation_id, direction, is_used);

            CREATE TABLE IF NOT EXISTS messages (
              message_id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              sender_id TEXT NOT NULL,
              recipient_id TEXT NOT NULL,
              pad_id TEXT NOT NULL,
              ciphertext_b64 TEXT NOT NULL,
              created_at REAL NOT NULL,
              plaintext TEXT,
              state INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages (conversation_id, created_at);

            CREATE TABLE IF NOT EXISTS deleted_conversations (
              conversation_id TEXT PRIMARY KEY,
              deleted_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS verified_otp_bundles (
              bundle_id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              peer_id TEXT NOT NULL,
              owner_user_id TEXT NOT NULL,
              direction TEXT NOT NULL,
              status TEXT NOT NULL,
              fingerprint_short TEXT NOT NULL,
              fingerprint_full TEXT NOT NULL,
              total_bytes INTEGER NOT NULL,
              remaining_bytes INTEGER NOT NULL,
              next_sequence INTEGER NOT NULL DEFAULT 0,
              next_offset INTEGER NOT NULL DEFAULT 0,
              imported_at REAL NULL,
              created_at REAL NOT NULL,
              file_key_ref TEXT NOT NULL,
              pad_file_url TEXT NOT NULL,
              consumed_ranges_json TEXT NOT NULL DEFAULT '[]'
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_verified_otp_bundle_direction
              ON verified_otp_bundles (conversation_id, direction);
            """
        )
        try ensureConversationSecurityProfileColumn()
        try ensureMessagesExpiresAtColumn()
        try ensureMessagesRelayDeliveredAtColumn()
        try ensureConversationGroupColumns()
        try ensureConversationKindColumn()
        try ensureConversationSecureModeColumns()
        try ensureConversationDisappearingSecondsColumn()
        try ensureVerifiedOtpBundleColumns()
    }

    /// Per-conversation disappearing-message TTL (seconds). Synced with `UserDefaults` + peer `__sys:vanish:` in `ChatViewModel`.
    private func ensureConversationDisappearingSecondsColumn() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(conversations);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var has = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == "disappearing_seconds" { has = true; break }
        }
        guard !has else { return }
        try run("ALTER TABLE conversations ADD COLUMN disappearing_seconds INTEGER NOT NULL DEFAULT 0;")
    }

    private func ensureVerifiedOtpBundleColumns() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(verified_otp_bundles);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var hasConsumedRanges = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == "consumed_ranges_json" {
                hasConsumedRanges = true
            }
        }
        if !hasConsumedRanges {
            try run("ALTER TABLE verified_otp_bundles ADD COLUMN consumed_ranges_json TEXT NOT NULL DEFAULT '[]';")
        }
    }

    func disappearingMessageSeconds(for conversationId: UUID) throws -> Int {
        let sql = "SELECT disappearing_seconds FROM conversations WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bindUUID(stmt, index: 1, conversationId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func setDisappearingMessageSeconds(_ seconds: Int, for conversationId: UUID) throws {
        let capped = max(0, min(seconds, 86400 * 7))
        try run(
            "UPDATE conversations SET disappearing_seconds = ? WHERE id = ?;",
            [Int64(capped), conversationId.uuidString]
        )
    }

    private func ensureConversationGroupColumns() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(conversations);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var hasGroup = false
        var hasMembers = false
        var hasOwner = false
        var hasAdminList = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            switch name {
            case "is_group": hasGroup = true
            case "group_member_ids": hasMembers = true
            case "group_owner_id": hasOwner = true
            case "group_admin_ids": hasAdminList = true
            default: break
            }
        }
        if !hasGroup {
            try run("ALTER TABLE conversations ADD COLUMN is_group INTEGER NOT NULL DEFAULT 0;")
        }
        if !hasMembers {
            try run("ALTER TABLE conversations ADD COLUMN group_member_ids TEXT NULL;")
        }
        if !hasOwner {
            try run("ALTER TABLE conversations ADD COLUMN group_owner_id TEXT NULL;")
        }
        if !hasAdminList {
            try run("ALTER TABLE conversations ADD COLUMN group_admin_ids TEXT NULL;")
        }
    }

    private func ensureConversationKindColumn() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(conversations);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var hasKind = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == "conversation_kind" {
                hasKind = true
                break
            }
        }
        if !hasKind {
            try run("ALTER TABLE conversations ADD COLUMN conversation_kind TEXT NOT NULL DEFAULT 'direct';")
        }
        try run("UPDATE conversations SET conversation_kind = 'group' WHERE is_group = 1 AND (conversation_kind IS NULL OR conversation_kind = '' OR conversation_kind = 'direct');")
        try run("UPDATE conversations SET conversation_kind = 'direct' WHERE is_group = 0 AND (conversation_kind IS NULL OR conversation_kind = '');")
    }

    private func ensureMessagesExpiresAtColumn() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(messages);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var has = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == "expires_at" { has = true; break }
        }
        guard !has else { return }
        try run("ALTER TABLE messages ADD COLUMN expires_at REAL NULL;")
    }

    private func ensureMessagesRelayDeliveredAtColumn() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(messages);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var has = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == "relay_delivered_at" { has = true; break }
        }
        guard !has else { return }
        try run("ALTER TABLE messages ADD COLUMN relay_delivered_at REAL NULL;")
    }

    /// Same on-disk path as `openDatabase()` (for encrypted backup export).
    nonisolated static func defaultStoreSQLiteURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("VaultePrive", isDirectory: true)
        return dir.appendingPathComponent("store.sqlite3", isDirectory: false)
    }

    private func ensureConversationSecureModeColumns() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(conversations);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var hasMode = false
        var hasPendingState = false
        var hasPendingRequestJSON = false
        var hasResolvedIdsJSON = false
        var hasUpdatedAt = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            switch name {
            case "secure_mode": hasMode = true
            case "mode_pending_state": hasPendingState = true
            case "mode_pending_request_json": hasPendingRequestJSON = true
            case "mode_resolved_request_ids_json": hasResolvedIdsJSON = true
            case "mode_updated_at": hasUpdatedAt = true
            default: break
            }
        }
        if !hasMode {
            try run("ALTER TABLE conversations ADD COLUMN secure_mode TEXT NOT NULL DEFAULT 'e2e';")
        }
        if !hasPendingState {
            try run("ALTER TABLE conversations ADD COLUMN mode_pending_state TEXT NOT NULL DEFAULT '';")
        }
        if !hasPendingRequestJSON {
            try run("ALTER TABLE conversations ADD COLUMN mode_pending_request_json TEXT NOT NULL DEFAULT '';")
        }
        if !hasResolvedIdsJSON {
            try run("ALTER TABLE conversations ADD COLUMN mode_resolved_request_ids_json TEXT NOT NULL DEFAULT '[]';")
        }
        if !hasUpdatedAt {
            try run("ALTER TABLE conversations ADD COLUMN mode_updated_at REAL NOT NULL DEFAULT 0;")
        }
    }

    private func ensureConversationSecurityProfileColumn() throws {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(conversations);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var hasColumn = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            if name == "security_profile" {
                hasColumn = true
                break
            }
        }
        guard !hasColumn else { return }
        try run("ALTER TABLE conversations ADD COLUMN security_profile TEXT NOT NULL DEFAULT 'e2e_plus';")
    }

    private func ensureDeletedConversationsTable() throws {
        try run(
            """
            CREATE TABLE IF NOT EXISTS deleted_conversations (
              conversation_id TEXT PRIMARY KEY,
              deleted_at REAL NOT NULL
            );
            """
        )
    }

    private func execDDL(_ ddl: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, ddl, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(err)
            throw OTPError.databaseError(msg)
        }
    }

    private func run(_ sql: String, _ bindings: [Any] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try bindAll(stmt, bindings)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw OTPError.databaseError(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindAll(_ stmt: OpaquePointer?, _ bindings: [Any]) throws {
        for (i, arg) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String:
                bindText(stmt, index: idx, s)
            case let d as Double:
                sqlite3_bind_double(stmt, idx, d)
            case let i64 as Int64:
                sqlite3_bind_int64(stmt, idx, i64)
            case let i32 as Int32:
                sqlite3_bind_int(stmt, idx, i32)
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            default:
                throw OTPError.databaseError("unsupported bind \(type(of: arg))")
            }
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, _ value: String) {
        _ = value.withCString { cstr in
            sqlite3_bind_text(stmt, index, cstr, -1, SQLITE_TRANSIENT)
        }
    }

    private func bindUUID(_ stmt: OpaquePointer?, index: Int32, _ id: UUID) {
        bindText(stmt, index: index, id.uuidString)
    }
}

struct OTPMessageSearchHit: Sendable, Equatable {
    let messageId: UUID
    let conversationId: UUID
    let preview: String
    let createdAt: Date
}

struct CachedMessage: Identifiable, Sendable {
    enum State: Int, Sendable {
        case pending = 0
        case ok = 1
        case invalid = 2
    }

    var id: UUID { messageId }
    var messageId: UUID
    var conversationId: UUID
    var senderId: UUID
    var recipientId: UUID
    var padId: UUID
    var ciphertextBase64: String
    var createdAt: Date
    var plaintext: String?
    var state: State
    /// When set, the message is removed locally (and on relay) after this time.
    var expiresAt: Date?
    /// When the relay recorded delivery to the recipient (`delivered_at`); local UI only.
    var relayDeliveredAt: Date?
}
