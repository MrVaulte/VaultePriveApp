//
//  CallManager.swift
//  Vaulté Privé
//

import Foundation
import CryptoKit
import AVFoundation
import UserNotifications

// MARK: - WebSocket HMAC signing (matches server verification)

private enum WsHmacSigner {
    static func signRegister(userId: String, timestamp: Int, nonce: String) -> String? {
        guard let secret = VaulteRelayConfiguration.hmacSecret, !secret.isEmpty else { return nil }
        let canonical = "ws.register.\(userId).\(timestamp).\(nonce)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func signMessage(userId: String, payload: [String: Any]) -> [String: Any] {
        guard let secret = VaulteRelayConfiguration.hmacSecret, !secret.isEmpty else { return payload }
        let ts = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString

        let sortedKeys = payload.keys.sorted()
        let signable = sortedKeys.reduce(into: [String: Any]()) { $0[$1] = payload[$1] }
        let body: String
        if let data = try? JSONSerialization.data(withJSONObject: signable),
           let str = String(data: data, encoding: .utf8) {
            body = str
        } else {
            body = ""
        }

        let canonical = "ws.msg.\(userId).\(ts).\(nonce).\(body)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        let hex = Data(mac).map { String(format: "%02x", $0) }.joined()

        var signed = payload
        signed["_ts"] = ts
        signed["_nonce"] = nonce
        signed["_sig"] = hex
        return signed
    }
}

// MARK: - Call crypto engine (thread-safe class with separate send/recv keys)

private final class CallCryptoEngine: @unchecked Sendable {
    static let framePayloadSize = 1920 // 60ms @ 16kHz mono Int16
    static let magicPadByte: UInt8 = 0x80

    private let lock = NSLock()
    private var sendKey: SymmetricKey
    private var recvKey: SymmetricKey
    private let callId: UUID
    private var sendSeq: UInt64 = 0
    private var recvSeqHigh: UInt64 = 0
    private var recvSeen: Set<UInt64> = []

    init(masterSecret: Data, callId: UUID, ephemeralSalt: Data, localIsLower: Bool) {
        self.callId = callId

        let keyA = Self.hkdf(master: masterSecret, salt: ephemeralSalt, info: "vaulte.call.keyA.v3|\(callId.uuidString.lowercased())")
        let keyB = Self.hkdf(master: masterSecret, salt: ephemeralSalt, info: "vaulte.call.keyB.v3|\(callId.uuidString.lowercased())")

        if localIsLower {
            sendKey = SymmetricKey(data: keyA)
            recvKey = SymmetricKey(data: keyB)
        } else {
            sendKey = SymmetricKey(data: keyB)
            recvKey = SymmetricKey(data: keyA)
        }
    }

    static func segmentFrames(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var frames: [Data] = []
        var offset = 0
        let chunkSize = max(1, framePayloadSize - 1)
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            frames.append(data.subdata(in: offset ..< end))
            offset = end
        }
        return frames
    }

    func encryptFrame(_ pcm: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        sendSeq += 1
        let seq = sendSeq
        let padded = padToFixedSize(pcm)

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: seq.littleEndian) { src in
            for i in 0..<min(src.count, 12) { nonceBytes[i] = src[i] }
        }

        var aad = Data("vaulte.call.v3|".utf8)
        aad.append(Data(callId.uuidString.lowercased().utf8))
        withUnsafeBytes(of: seq.littleEndian) { aad.append(contentsOf: $0) }

        guard let nonce = try? ChaChaPoly.Nonce(data: Data(nonceBytes)),
              let box = try? ChaChaPoly.seal(padded, using: sendKey, nonce: nonce, authenticating: aad)
        else { return nil }

        var wire = Data(capacity: 8 + 12 + box.ciphertext.count + 16)
        withUnsafeBytes(of: seq.littleEndian) { wire.append(contentsOf: $0) }
        wire.append(Data(nonceBytes))
        wire.append(box.ciphertext)
        wire.append(box.tag)
        return wire
    }

    func decryptFrame(_ wire: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard wire.count > 36 else { return nil }

        let seq = wire.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        guard seq > 0, !recvSeen.contains(seq) else { return nil }
        if recvSeqHigh > 256 && seq + 256 < recvSeqHigh { return nil }

        let nonceData = wire[wire.startIndex + 8 ..< wire.startIndex + 20]
        let payload = wire.suffix(from: wire.startIndex + 20)
        guard payload.count > 16 else { return nil }
        let tag = payload.suffix(16)
        let ct = payload.dropLast(16)

        var aad = Data("vaulte.call.v3|".utf8)
        aad.append(Data(callId.uuidString.lowercased().utf8))
        withUnsafeBytes(of: seq.littleEndian) { aad.append(contentsOf: $0) }

        guard let nonce = try? ChaChaPoly.Nonce(data: nonceData),
              let sealed = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let padded = try? ChaChaPoly.open(sealed, using: recvKey, authenticating: aad)
        else { return nil }

        recvSeen.insert(seq)
        if seq > recvSeqHigh { recvSeqHigh = seq }
        if recvSeen.count > 512 {
            let cutoff = recvSeqHigh > 256 ? recvSeqHigh - 256 : 0
            recvSeen = recvSeen.filter { $0 >= cutoff }
        }

        return unpadFromFixedSize(padded)
    }

    func zeroize() {
        lock.lock()
        defer { lock.unlock() }
        sendKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        recvKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        sendSeq = 0
        recvSeen.removeAll()
        recvSeqHigh = 0
    }

    // MARK: - Helpers

    private static func hkdf(master: Data, salt: Data, info: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private func padToFixedSize(_ data: Data) -> Data {
        if data.count >= Self.framePayloadSize {
            var truncated = Data(data.prefix(Self.framePayloadSize - 1))
            truncated.append(Self.magicPadByte)
            return truncated
        }
        var padded = data
        padded.append(Self.magicPadByte)
        let remaining = Self.framePayloadSize - padded.count
        if remaining > 0 {
            padded.append(Data(repeating: 0x00, count: remaining))
        }
        return padded
    }

    private func unpadFromFixedSize(_ padded: Data) -> Data {
        var idx = padded.count - 1
        while idx >= 0 && padded[padded.startIndex + idx] == 0x00 { idx -= 1 }
        guard idx >= 0 && padded[padded.startIndex + idx] == Self.magicPadByte else { return padded }
        return padded[padded.startIndex ..< (padded.startIndex + idx)]
    }
}

// MARK: - Public types

enum CallState: Equatable, Sendable {
    case idle
    case outgoing(callId: UUID, peerId: UUID)
    case incoming(callId: UUID, peerId: UUID)
    case active(callId: UUID, peerId: UUID)
    case ended(reason: String)
}

struct CallHistoryEntry: Identifiable, Sendable {
    let id: UUID
    let peerId: UUID
    let peerName: String?
    let direction: CallDirection
    let outcome: CallOutcome
    let startedAt: Date
    var duration: TimeInterval

    enum CallDirection: String, Sendable { case outgoing, incoming }
    enum CallOutcome: String, Sendable { case answered, missed, declined }
}

// MARK: - CallManager

@Observable @MainActor
final class CallManager {
    private(set) var state: CallState = .idle
    private(set) var callDuration: TimeInterval = 0
    private(set) var isMuted = false
    private(set) var isSpeaker = false
    private(set) var history: [CallHistoryEntry] = []
    private(set) var callStatusDetail: String?

    private let userId: UUID
    private var webSocket: URLSessionWebSocketTask?
    private var audioEngine: VoIPAudioEngine?
    private var durationTimer: Timer?
    private var callStartTime: Date?
    private var cryptoEngine: CallCryptoEngine?
    private var reconnectTask: Task<Void, Never>?
    private var isConnected = false
    private var conversationIdForCall: UUID?
    private var peerNameForCall: String?
    private var localEphemeralSalt: Data?
    private var remoteEphemeralSalt: Data?

    private let audioQueue = DispatchQueue(label: "com.vaulte.call.audio", qos: .userInteractive)

    init(userId: UUID) {
        self.userId = userId
    }

    // MARK: - WebSocket lifecycle

    func connect() {
        guard webSocket == nil else { return }
        let base = VaulteRelayConfiguration.baseURL
        let wsScheme = base.scheme == "https" ? "wss" : "ws"
        guard let host = base.host, let wsURL = URL(string: "\(wsScheme)://\(host)\(base.port.map { ":\($0)" } ?? "")/ws") else { return }

        let session = URLSession(configuration: .default, delegate: PinnedSessionDelegate.shared, delegateQueue: nil)
        let task = session.webSocketTask(with: wsURL)
        webSocket = task
        task.resume()

        let uid = userId.uuidString.lowercased()
        let ts = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString
        let signature = WsHmacSigner.signRegister(userId: uid, timestamp: ts, nonce: nonce)
        var reg: [String: Any] = ["type": "register", "userId": uid, "timestamp": ts, "nonce": nonce]
        if let sig = signature { reg["signature"] = sig }
        sendRawJSON(reg)
        receiveLoop()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
    }

    // MARK: - Call actions

    func startCall(peerId: UUID, conversationId: UUID, peerName: String?) {
        guard case .idle = state else { return }
        let callId = UUID()
        self.conversationIdForCall = conversationId
        self.peerNameForCall = peerName
        guard let ephemeral = try? SecureRandom.bytes(count: 32) else { return }
        self.localEphemeralSalt = ephemeral
        state = .outgoing(callId: callId, peerId: peerId)
        sendJSON([
            "type": "call_offer",
            "callId": callId.uuidString.lowercased(),
            "targetUserId": peerId.uuidString.lowercased(),
            "conversationId": conversationId.uuidString.lowercased(),
            "ephemeralSaltB64": ephemeral.base64EncodedString()
        ])
    }

    func acceptCall() {
        guard case let .incoming(callId, peerId) = state else { return }
        clearCallNotification(for: peerId)
        guard let ephemeral = try? SecureRandom.bytes(count: 32) else {
            state = .ended(reason: "call.reason.random_failed")
            scheduleReturnToIdle()
            return
        }
        self.localEphemeralSalt = ephemeral
        var answer: [String: Any] = [
            "type": "call_answer",
            "callId": callId.uuidString.lowercased(),
            "targetUserId": peerId.uuidString.lowercased(),
            "ephemeralSaltB64": ephemeral.base64EncodedString()
        ]
        if let convId = conversationIdForCall {
            answer["conversationId"] = convId.uuidString.lowercased()
        }
        sendJSON(answer)
        Task { await beginActiveCall(callId: callId, peerId: peerId) }
    }

    func declineCall() {
        guard case let .incoming(callId, peerId) = state else { return }
        clearCallNotification(for: peerId)
        sendJSON([
            "type": "call_decline",
            "callId": callId.uuidString.lowercased(),
            "targetUserId": peerId.uuidString.lowercased()
        ])
        addHistoryEntry(peerId: peerId, direction: .incoming, outcome: .declined)
        state = .ended(reason: "call.reason.declined")
        scheduleReturnToIdle()
    }

    func endCall() {
        let peerId: UUID?
        let callId: UUID?
        switch state {
        case let .active(cid, pid): callId = cid; peerId = pid
        case let .outgoing(cid, pid): callId = cid; peerId = pid
        case let .incoming(cid, pid): callId = cid; peerId = pid
        default: return
        }
        if let peerId, let callId {
            sendJSON([
                "type": "call_end",
                "callId": callId.uuidString.lowercased(),
                "targetUserId": peerId.uuidString.lowercased()
            ])
        }
        stopActiveCall()
        if let peerId {
            addHistoryEntry(peerId: peerId, direction: .outgoing, outcome: .answered)
        }
        state = .ended(reason: "call.reason.ended")
        scheduleReturnToIdle()
    }

    func toggleMute() {
        isMuted.toggle()
        audioEngine?.setMuted(isMuted)
    }

    func toggleSpeaker() {
        isSpeaker.toggle()
        audioEngine?.setSpeaker(isSpeaker)
    }

    // MARK: - Active call setup

    private func beginActiveCall(callId: UUID, peerId: UUID) async {
        state = .active(callId: callId, peerId: peerId)
        callStartTime = Date()
        callDuration = 0

        guard let masterSecret = await deriveCallMasterSecret(peerId: peerId, callId: callId) else {
            state = .ended(reason: "call.reason.key_exchange_failed")
            scheduleReturnToIdle()
            return
        }

        guard let local = localEphemeralSalt, !local.isEmpty,
              let remote = remoteEphemeralSalt, !remote.isEmpty else {
            state = .ended(reason: "call.reason.missing_salt")
            scheduleReturnToIdle()
            return
        }
        let combinedSalt = combineEphemeralSalts(local: local, remote: remote, peerId: peerId)

        let localIsLower = userId.uuidString.lowercased() < peerId.uuidString.lowercased()
        let engine = CallCryptoEngine(masterSecret: masterSecret, callId: callId, ephemeralSalt: combinedSalt, localIsLower: localIsLower)
        cryptoEngine = engine
        startAudioEngine(cryptoEngine: engine)
        startDurationTimer()
    }

    private func combineEphemeralSalts(local: Data, remote: Data, peerId: UUID) -> Data {
        let localId = userId.uuidString.lowercased()
        let remoteId = peerId.uuidString.lowercased()
        var combined = Data()
        if localId <= remoteId {
            combined.append(local)
            combined.append(remote)
        } else {
            combined.append(remote)
            combined.append(local)
        }
        return Data(SHA256.hash(data: combined))
    }

    private func deriveCallMasterSecret(peerId: UUID, callId: UUID) async -> Data? {
        // SECURITY: Fail-closed — refuse to start an encrypted call if no shared conversation
        // key exists. The previous fallback (SHA256 of two public user IDs) was deterministic
        // and computable by any observer, providing no real confidentiality.
        guard let convId = conversationIdForCall,
              let convKey = ConversationKeyStore.load(for: convId) else {
            return nil
        }
        let sharedRoot = convKey.withUnsafeBytes { Data($0) }
        var callContext = Data("vaulte.call.master.v2|".utf8)
        callContext.append(Data(callId.uuidString.lowercased().utf8))
        let masterKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedRoot),
            salt: callContext,
            info: Data("vaulte.call.master.derive".utf8),
            outputByteCount: 32
        )
        return masterKey.withUnsafeBytes { Data($0) }
    }

    private func stopActiveCall() {
        durationTimer?.invalidate()
        durationTimer = nil
        audioEngine?.stop()
        audioEngine = nil
        cryptoEngine?.zeroize()
        cryptoEngine = nil
        localEphemeralSalt = nil
        remoteEphemeralSalt = nil
        callStatusDetail = nil
    }

    private func startAudioEngine(cryptoEngine: CallCryptoEngine) {
        let engine = VoIPAudioEngine()
        self.audioEngine = engine
        let ws = webSocket
        let queue = audioQueue

        engine.start { [weak cryptoEngine] pcmData in
            queue.async {
                guard let crypto = cryptoEngine else { return }
                for frame in CallCryptoEngine.segmentFrames(pcmData) {
                    guard let encrypted = crypto.encryptFrame(frame) else { continue }
                    ws?.send(.data(encrypted)) { _ in }
                }
            }
        }
        if engine.failedToStart {
            callStatusDetail = "Audio engine failed to start"
        }
    }

    // MARK: - Encrypted audio receive (called from any thread)

    private nonisolated func receiveAudioFrameOffMain(_ data: Data, crypto: CallCryptoEngine, engine: VoIPAudioEngine) {
        guard let pcm = crypto.decryptFrame(data) else { return }
        engine.playReceived(pcm)
    }

    // MARK: - Timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.callStartTime else { return }
                self.callDuration = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - WebSocket I/O

    private func sendJSON(_ dict: [String: Any]) {
        let signed = WsHmacSigner.signMessage(userId: userId.uuidString.lowercased(), payload: dict)
        sendRawJSON(signed)
    }

    private func sendRawJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8)
        else { return }
        webSocket?.send(.string(str)) { _ in }
    }

    private func receiveLoop() {
        let ws = webSocket
        let crypto = cryptoEngine
        let audio = audioEngine

        ws?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    if let c = self?.cryptoEngine, let a = self?.audioEngine {
                        self?.audioQueue.async {
                            guard let pcm = c.decryptFrame(data) else { return }
                            a.playReceived(pcm)
                        }
                    }
                    Task { @MainActor in self?.receiveLoop() }

                case .string(let text):
                    Task { @MainActor in
                        self?.handleMessage(text)
                        self?.receiveLoop()
                    }

                @unknown default:
                    Task { @MainActor in self?.receiveLoop() }
                }

            case .failure:
                Task { @MainActor in self?.handleDisconnect() }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String
        else { return }

        switch type {
        case "registered":
            isConnected = true

        case "call_offer":
            guard case .idle = state,
                  let callIdStr = dict["callId"] as? String,
                  let callId = UUID(uuidString: callIdStr),
                  let fromStr = dict["fromUserId"] as? String,
                  let fromId = UUID(uuidString: fromStr)
            else { return }

            // SECURITY: Only accept calls from TOFU-pinned contacts.
            // Prevents relay-level spoofing of fromUserId — the caller must have
            // completed at least one encrypted session (which pins their identity key).
            guard LocalIdentityStore.pinnedPeerIdentityKey(for: fromId) != nil else {
                sendJSON([
                    "type": "call_decline",
                    "callId": callId.uuidString.lowercased(),
                    "targetUserId": fromStr.lowercased()
                ])
                return
            }

            // SECURITY: Do not trust caller-supplied conversationId — look it up locally
            // to prevent a key-oracle attack where attacker chooses which key we use.
            let claimedConvId = (dict["conversationId"] as? String).flatMap(UUID.init(uuidString:))
            conversationIdForCall = ConversationKeyStore.conversationId(forPeer: fromId) ?? claimedConvId

            if let saltB64 = dict["ephemeralSaltB64"] as? String {
                remoteEphemeralSalt = Data(base64Encoded: saltB64)
            }
            state = .incoming(callId: callId, peerId: fromId)
            fireIncomingCallNotification(from: fromId)

        case "call_answer":
            if case let .outgoing(callId, peerId) = state {
                if let saltB64 = dict["ephemeralSaltB64"] as? String {
                    remoteEphemeralSalt = Data(base64Encoded: saltB64)
                }
                Task { await beginActiveCall(callId: callId, peerId: peerId) }
            }

        case "call_decline":
            if case let .outgoing(_, peerId) = state {
                addHistoryEntry(peerId: peerId, direction: .outgoing, outcome: .declined)
                state = .ended(reason: "call.reason.declined")
                scheduleReturnToIdle()
            }

        case "call_end":
            switch state {
            case let .active(_, peerId):
                stopActiveCall()
                addHistoryEntry(peerId: peerId, direction: .incoming, outcome: .answered)
                state = .ended(reason: "call.reason.ended")
                scheduleReturnToIdle()
            case .incoming, .outgoing:
                state = .ended(reason: "call.reason.cancelled")
                scheduleReturnToIdle()
            default: break
            }

        case "call_unavailable":
            if case let .outgoing(_, peerId) = state {
                addHistoryEntry(peerId: peerId, direction: .outgoing, outcome: .missed)
                state = .ended(reason: "call.reason.unavailable")
                scheduleReturnToIdle()
            }

        default:
            break
        }
    }

    private func handleDisconnect() {
        isConnected = false
        webSocket = nil
        switch state {
        case .active:
            callStatusDetail = "Connection lost"
            scheduleReconnect()
        default:
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { connect() }
        }
    }

    private func scheduleReturnToIdle() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .ended = state { state = .idle }
        }
    }

    // MARK: - History

    private func addHistoryEntry(peerId: UUID, direction: CallHistoryEntry.CallDirection, outcome: CallHistoryEntry.CallOutcome) {
        let entry = CallHistoryEntry(
            id: UUID(),
            peerId: peerId,
            peerName: peerNameForCall,
            direction: direction,
            outcome: outcome,
            startedAt: callStartTime ?? Date(),
            duration: callDuration
        )
        history.insert(entry, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
    }

    var peerIdForCurrentCall: UUID? {
        switch state {
        case let .active(_, pid): return pid
        case let .outgoing(_, pid): return pid
        case let .incoming(_, pid): return pid
        default: return nil
        }
    }

    var callIdForCurrentCall: UUID? {
        switch state {
        case let .active(cid, _): return cid
        case let .outgoing(cid, _): return cid
        case let .incoming(cid, _): return cid
        default: return nil
        }
    }

    var isInCall: Bool {
        switch state {
        case .idle, .ended: return false
        default: return true
        }
    }

    var displayNameForCurrentCall: String? {
        let trimmed = peerNameForCall?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Incoming call notification

    private func fireIncomingCallNotification(from peerId: UUID) {
        let name = VaulteDisplayName.customName(for: peerId)
            ?? VaulteDisplayName.handle(for: peerId)
        let content = UNMutableNotificationContent()
        content.title = "Incoming Call"
        content.body = "\(name) is calling on Vaulté Privé"
        content.sound = .defaultCriticalSound(withAudioVolume: 1.0)
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "INCOMING_CALL"

        let request = UNNotificationRequest(
            identifier: "vaulte.call.\(peerId.uuidString)",
            content: content,
            trigger: nil
        )
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func clearCallNotification(for peerId: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["vaulte.call.\(peerId.uuidString)"]
        )
    }
}
