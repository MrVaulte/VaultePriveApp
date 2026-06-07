import Foundation
import UniformTypeIdentifiers

enum VaulteVaultepadDocumentType {
    static let identifier = "com.vaulteprive.vaultepad"
    static let fileExtension = "vaultepad"
    static let mimeType = "application/x-vaultepad"

    static var utType: UTType {
        UTType(exportedAs: identifier, conformingTo: .data)
    }

    static func isVaultepadURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == fileExtension {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = values.contentType {
            return contentType.conforms(to: utType) || contentType.identifier == identifier
        }
        return false
    }
}

extension UTType {
    static let vaulteVaultepad = VaulteVaultepadDocumentType.utType
}
