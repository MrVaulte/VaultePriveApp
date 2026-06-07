import Foundation

extension Notification.Name {
    static let vaulteOtpPairingDidStart = Notification.Name("vaulteOtpPairingDidStart")
    static let vaulteOtpPairingDidComplete = Notification.Name("vaulteOtpPairingDidComplete")
}

enum VaulteOtpPadPairingSlotState: Equatable {
    case idle
    case checking
    case correct
    case wrong
}

struct VaulteOtpPadPairingSession: Identifiable, Equatable {
    enum Role: Equatable {
        case sender
        case receiver
    }

    let id: UUID
    let conversationId: UUID
    let role: Role
    let code: String?
    var expectedCode: String?
    var senderSlots: [VaulteOtpPadPairingSlotState]
    var receiverDigits: [String]
    var receiverSlots: [VaulteOtpPadPairingSlotState]
    let importURL: URL?
    var isComplete: Bool
    var isLinked: Bool
    var isImporting: Bool
    var errorMessage: String?

    static func sender(
        sessionId: UUID,
        conversationId: UUID,
        code: String
    ) -> VaulteOtpPadPairingSession {
        VaulteOtpPadPairingSession(
            id: sessionId,
            conversationId: conversationId,
            role: .sender,
            code: code,
            expectedCode: nil,
            senderSlots: Array(repeating: .idle, count: 6),
            receiverDigits: Array(repeating: "", count: 6),
            receiverSlots: Array(repeating: .idle, count: 6),
            importURL: nil,
            isComplete: false,
            isLinked: true,
            isImporting: false,
            errorMessage: nil
        )
    }

    static func receiver(
        sessionId: UUID,
        conversationId: UUID,
        importURL: URL,
        isLinked: Bool = false
    ) -> VaulteOtpPadPairingSession {
        VaulteOtpPadPairingSession(
            id: sessionId,
            conversationId: conversationId,
            role: .receiver,
            code: nil,
            expectedCode: nil,
            senderSlots: Array(repeating: .idle, count: 6),
            receiverDigits: Array(repeating: "", count: 6),
            receiverSlots: Array(repeating: .idle, count: 6),
            importURL: importURL,
            isComplete: false,
            isLinked: isLinked,
            isImporting: false,
            errorMessage: nil
        )
    }
}

@MainActor
@Observable
final class VaulteOtpPadPairingCenter {
    static let shared = VaulteOtpPadPairingCenter()

    private(set) var activeSession: VaulteOtpPadPairingSession?

    private var userId: UUID?
    private var boundStore: OTPStore?
    private var fastSyncTask: Task<Void, Never>?

    func bind(userId: UUID, store: OTPStore) {
        self.userId = userId
        self.boundStore = store
        if let session = activeSession,
           session.role == .receiver,
           !session.isLinked,
           !session.isComplete {
            Task {
                await syncConversation(for: session.conversationId)
                await sendPairingRequest(sessionId: session.id, conversationId: session.conversationId)
            }
        }
    }

    @discardableResult
    func startSenderPairing(sessionId: UUID, conversationId: UUID, code: String) -> UUID {
        setActiveSession(.sender(sessionId: sessionId, conversationId: conversationId, code: code))
        return sessionId
    }

    func openReceiverImport(url: URL, conversationId: UUID) {
        let sessionId = UUID()
        setActiveSession(.receiver(sessionId: sessionId, conversationId: conversationId, importURL: url))
        Task {
            await syncConversation(for: conversationId)
            await sendPairingRequest(sessionId: sessionId, conversationId: conversationId)
        }
    }

    func attachReceiverImport(url: URL, conversationId: UUID) {
        if var session = activeSession,
           session.role == .receiver,
           session.conversationId == conversationId {
            session = VaulteOtpPadPairingSession(
                id: session.id,
                conversationId: conversationId,
                role: .receiver,
                code: nil,
                expectedCode: session.expectedCode,
                senderSlots: session.senderSlots,
                receiverDigits: session.receiverDigits,
                receiverSlots: session.receiverSlots,
                importURL: url,
                isComplete: session.isComplete,
                isLinked: session.isLinked,
                isImporting: session.isImporting,
                errorMessage: session.errorMessage
            )
            let sessionId = session.id
            let wasLinked = session.isLinked
            let wasComplete = session.isComplete
            setActiveSession(session)
            Task {
                await syncConversation(for: conversationId)
                if !wasLinked, !wasComplete {
                    await sendPairingRequest(sessionId: sessionId, conversationId: conversationId)
                }
            }
            return
        }
        openReceiverImport(url: url, conversationId: conversationId)
    }

    func clear() {
        fastSyncTask?.cancel()
        fastSyncTask = nil
        activeSession = nil
    }

    func handleSignal(_ signal: String, conversationId: UUID) async {
        if signal.hasPrefix("otp_pair_request:") {
            let parts = signal.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3,
                  let sessionId = UUID(uuidString: parts[1]),
                  let convId = UUID(uuidString: parts[2]),
                  convId == conversationId
            else { return }

            if let session = activeSession, session.role == .receiver {
                return
            }

            let code = VaulteOtpPadPairingCode.generate()
            _ = startSenderPairing(sessionId: sessionId, conversationId: convId, code: code)
            await sendSignal(
                conversationId: convId,
                body: "otp_pair_begin:\(sessionId.uuidString.lowercased()):\(convId.uuidString.lowercased()):\(code)"
            )
            return
        }

        if signal.hasPrefix("otp_pair_begin:") {
            let parts = signal.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3,
                  let sessionId = UUID(uuidString: parts[1]),
                  let convId = UUID(uuidString: parts[2]),
                  convId == conversationId
            else { return }

            let pairingCode = parts.count >= 4 ? parts[3] : nil

            if var session = activeSession,
               session.role == .receiver,
               session.conversationId == convId,
               let importURL = session.importURL {
                session = VaulteOtpPadPairingSession(
                    id: sessionId,
                    conversationId: convId,
                    role: .receiver,
                    code: nil,
                    expectedCode: pairingCode?.count == 6 && pairingCode?.allSatisfy(\.isNumber) == true ? pairingCode : session.expectedCode,
                    senderSlots: session.senderSlots,
                    receiverDigits: session.receiverDigits,
                    receiverSlots: session.receiverSlots,
                    importURL: importURL,
                    isComplete: session.isComplete,
                    isLinked: true,
                    isImporting: session.isImporting,
                    errorMessage: nil
                )
                setActiveSession(session)
            }
            return
        }

        if signal.hasPrefix("otp_pair_activate:") {
            await activateVerifiedOtpModeAfterPairing(conversationId: conversationId)
            return
        }

        guard var session = activeSession, session.conversationId == conversationId else { return }

        if signal.hasPrefix("otp_pair_digit:") {
            let parts = signal.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4,
                  UUID(uuidString: parts[1]) == session.id,
                  let index = Int(parts[2]),
                  (0..<6).contains(index),
                  let digit = parts[3].last
            else { return }

            guard session.role == .sender, let code = session.code else { return }
            let expected = code[code.index(code.startIndex, offsetBy: index)]
            let isCorrect = digit == expected

            session.receiverDigits[index] = String(digit)
            session.senderSlots[index] = isCorrect ? .correct : .wrong
            setActiveSession(session)

            let sessionId = session.id
            Task {
                await sendSignal(
                    conversationId: conversationId,
                    body: "otp_pair_ack:\(sessionId.uuidString.lowercased()):\(index):\(isCorrect ? "1" : "0")"
                )
            }
            return
        }

        if signal.hasPrefix("otp_pair_ack:") {
            let parts = signal.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4,
                  UUID(uuidString: parts[1]) == session.id,
                  let index = Int(parts[2]),
                  (0..<6).contains(index)
            else { return }

            guard session.role == .receiver, session.expectedCode == nil else { return }
            let ok = parts[3] == "1"
            session.receiverSlots[index] = ok ? .correct : .wrong
            if !ok {
                session.errorMessage = "Wrong digit."
                clearReceiverDigits(from: index, in: &session)
            }
            setActiveSession(session)
            if ok {
                await receiverCompleteIfReady()
            }
            return
        }

        if signal.hasPrefix("otp_pair_done:") {
            let parts = signal.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2,
                  let doneSessionId = UUID(uuidString: parts[1]),
                  doneSessionId == session.id
            else { return }
            await activateVerifiedOtpModeAfterPairing(conversationId: conversationId)
            if session.role == .sender {
                session.isComplete = true
                setActiveSession(session)
                stopFastSyncIfComplete()
            }
            return
        }

        if signal.hasPrefix("otp_pair_cancel:") {
            let parts = signal.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, UUID(uuidString: parts[1]) == session.id else { return }
            clear()
        }
    }

    func receiverSubmitDigit(at index: Int, digit: Character) async {
        guard var session = activeSession,
              session.role == .receiver,
              session.isLinked,
              (0..<6).contains(index)
        else { return }

        session.receiverDigits[index] = String(digit)
        session.errorMessage = nil

        if let expected = session.expectedCode, expected.count == 6 {
            let expectedChar = expected[expected.index(expected.startIndex, offsetBy: index)]
            let ok = digit == expectedChar
            session.receiverSlots[index] = ok ? .correct : .wrong
            if !ok {
                session.errorMessage = "Wrong digit."
                clearReceiverDigits(from: index, in: &session)
                setActiveSession(session)
            } else {
                setActiveSession(session)
                await receiverCompleteIfReady()
            }
        } else {
            session.receiverSlots[index] = .checking
            setActiveSession(session)
        }

        let sessionId = session.id
        let convId = session.conversationId
        Task {
            await sendSignal(
                conversationId: convId,
                body: "otp_pair_digit:\(sessionId.uuidString.lowercased()):\(index):\(digit)"
            )
        }
    }

    func receiverClearFrom(index: Int) {
        guard var session = activeSession, session.role == .receiver else { return }
        clearReceiverDigits(from: index, in: &session)
        session.errorMessage = nil
        setActiveSession(session)
    }

    func receiverCompleteIfReady() async {
        guard var session = activeSession,
              session.role == .receiver,
              let url = session.importURL,
              let userId,
              let store = boundStore,
              !session.isImporting,
              !session.isComplete
        else { return }

        guard session.receiverDigits.joined().count == 6,
              session.receiverSlots.allSatisfy({ $0 == .correct })
        else { return }

        session.isImporting = true
        session.errorMessage = nil
        setActiveSession(session)

        do {
            let vm = ChatViewModel(store: store, conversationId: session.conversationId, currentUserId: userId)
            try await vm.importVerifiedOtpBundleFile(url: url)
            session.isImporting = false
            await activateVerifiedOtpModeAfterPairing(conversationId: session.conversationId)
            session.isComplete = true
            setActiveSession(session)
            stopFastSyncIfComplete()
            let sessionId = session.id
            let convId = session.conversationId
            await sendSignal(
                conversationId: convId,
                body: "otp_pair_done:\(sessionId.uuidString.lowercased())"
            )
            await sendSignal(
                conversationId: convId,
                body: "otp_pair_activate:\(sessionId.uuidString.lowercased())"
            )
            VerifiedOtpImportCenter.shared.clear()
        } catch {
            session.isImporting = false
            session.errorMessage = error.localizedDescription
            setActiveSession(session)
        }
    }

    func cancelActiveSession() async {
        guard let session = activeSession else { return }
        await sendSignal(
            conversationId: session.conversationId,
            body: "otp_pair_cancel:\(session.id.uuidString.lowercased())"
        )
        clear()
    }

    private func clearReceiverDigits(from index: Int, in session: inout VaulteOtpPadPairingSession) {
        for i in index..<6 {
            session.receiverDigits[i] = ""
            session.receiverSlots[i] = .idle
        }
    }

    private func setActiveSession(_ session: VaulteOtpPadPairingSession) {
        let hadSession = activeSession != nil
        let wasComplete = activeSession?.isComplete ?? false
        activeSession = session
        if !hadSession {
            NotificationCenter.default.post(
                name: .vaulteOtpPairingDidStart,
                object: session.conversationId
            )
        }
        if session.isComplete, !wasComplete {
            NotificationCenter.default.post(
                name: .vaulteOtpPairingDidComplete,
                object: session.conversationId
            )
        }
        if session.isComplete {
            stopFastSyncIfComplete()
        } else {
            startFastSyncIfNeeded(for: session.conversationId)
        }
    }

    private func startFastSyncIfNeeded(for conversationId: UUID) {
        guard fastSyncTask == nil else { return }
        fastSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let session = self.activeSession, !session.isComplete else { break }
                await self.syncConversation(for: conversationId)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await MainActor.run {
                self?.fastSyncTask = nil
            }
        }
    }

    private func stopFastSyncIfComplete() {
        if activeSession?.isComplete == true {
            fastSyncTask?.cancel()
            fastSyncTask = nil
        }
    }

    private func sendPairingRequest(sessionId: UUID, conversationId: UUID) async {
        await sendSignal(
            conversationId: conversationId,
            body: "otp_pair_request:\(sessionId.uuidString.lowercased()):\(conversationId.uuidString.lowercased())"
        )
    }

    private func sendSignal(conversationId: UUID, body: String) async {
        guard let userId, let store = boundStore else { return }
        let vm = ChatViewModel(store: store, conversationId: conversationId, currentUserId: userId)
        await vm.sendSystemMessage(body)
        await syncConversation(for: conversationId)
    }

    private func activateVerifiedOtpModeAfterPairing(conversationId: UUID) async {
        guard let userId, let store = boundStore else { return }
        let vm = ChatViewModel(store: store, conversationId: conversationId, currentUserId: userId)
        try? await vm.enableVerifiedOtpModeIfReady()
    }

    private func syncConversation(for conversationId: UUID) async {
        guard let userId, let store = boundStore else { return }
        let vm = ChatViewModel(store: store, conversationId: conversationId, currentUserId: userId)
        await vm.syncFromServer()
    }
}

enum VaulteOtpPadPairingCode {
    static func generate() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
