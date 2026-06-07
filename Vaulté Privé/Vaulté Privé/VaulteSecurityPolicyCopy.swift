//
//  VaulteSecurityPolicyCopy.swift
//  Vaulté Privé
//

import Foundation

enum VaulteSecurityPolicyCopy {
    static let documentTitle = "Security"

    struct Section: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    static let intro = """
    Messages are decrypted only on your devices. The relay stores encrypted payloads and basic routing info — \
    who sent what to whom, conversation IDs, timestamps.
    """

    static let sections: [Section] = [
        Section(
            id: "relay-sees",
            title: "What the relay sees",
            body: """
            Sender and recipient IDs, encrypted message blobs, conversation IDs, timestamps, \
            and profile fields you uploaded (username, name, avatar).
            """
        ),
        Section(
            id: "relay-not",
            title: "What the relay does not see",
            body: """
            Message text when end-to-end encryption is working. One Time Pad files — those are exchanged between you and your contact directly.
            """
        ),
        Section(
            id: "modes",
            title: "Encryption modes",
            body: """
            Standard E2E uses session keys (Double Ratchet / AES) to encrypt each message.

            One Time Pad is a separate mode for Elite users. Both sides import matching pad files before it can be turned on.
            """
        ),
        Section(
            id: "you",
            title: "Your part",
            body: """
            Lock your phone. Compare safety numbers with contacts when you want to verify identity. \
            Keep pad files private and share them only with the person you trust.
            """
        ),
        Section(
            id: "backup",
            title: "Backups",
            body: """
            Encrypted backups use AES-GCM with a key derived from a passphrase you choose. \
            We do not store that passphrase anywhere.
            """
        ),
    ]
}
