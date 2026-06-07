import Foundation
import UniformTypeIdentifiers

@MainActor
@Observable
final class VerifiedOtpImportCenter {
    static let shared = VerifiedOtpImportCenter()

    private(set) var pendingURL: URL?

    private var lastImportKey: String?
    private var lastImportAt: Date?

    func handleIncomingURL(_ url: URL) {
        guard VaulteVaultepadDocumentType.isVaultepadURL(url) else { return }

        let importKey = url.standardizedFileURL.path
        let now = Date()
        if let lastImportKey,
           lastImportKey == importKey,
           let lastImportAt,
           now.timeIntervalSince(lastImportAt) < 1.5 {
            return
        }

        if let active = VaulteOtpPadPairingCenter.shared.activeSession,
           active.role == .receiver,
           !active.isComplete,
           !active.isImporting {
            return
        }

        lastImportKey = importKey
        lastImportAt = now

        guard let staged = stageIncomingFile(from: url) else { return }
        pendingURL = staged
        guard let data = try? Data(contentsOf: staged),
              let conversationId = VerifiedOtpBundleCrypto.peekConversationId(from: data)
        else { return }
        VaulteOtpPadPairingCenter.shared.attachReceiverImport(url: staged, conversationId: conversationId)
    }

    func clear() {
        pendingURL = nil
    }

    private func stageIncomingFile(from url: URL) -> URL? {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let destDir = fileManager.temporaryDirectory.appendingPathComponent("VaulteOtpImports", isDirectory: true)
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let dest = destDir.appendingPathComponent("\(UUID().uuidString.lowercased()).vaultepad")
        do {
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
