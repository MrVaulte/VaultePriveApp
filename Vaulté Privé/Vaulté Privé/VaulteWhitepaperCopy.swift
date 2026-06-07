//
//  VaulteWhitepaperCopy.swift
//  Vaulté Privé — production security whitepaper (in-app + docs/WHITEPAPER.md).
//

import Foundation

enum VaulteWhitepaperCopy {
    static let documentTitle = "Whatever works"
    static let documentSubtitle = "Security Architecture"
    static let version = "1.0"
    static let lastUpdated = "May 24, 2026"

    struct Section: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    static let abstract = """
    Vaulté Privé is a private messaging system for iOS. Message content is encrypted on the device before transmission. \
    The relay forwards opaque ciphertext and routing metadata; it is not designed to hold readable conversations.

    An optional One Time Pad mode adds a second layer based on pre-shared pad material exchanged directly between users. \
    This document describes the security model, cryptographic layers, and operational boundaries of the production system.
    """

    static let sections: [Section] = [
        Section(
            id: "principles",
            title: "1. Design principles",
            body: """
            Plaintext belongs on the device. The server path carries encrypted payloads, not message content.

            Stronger modes are explicit and user-controlled. One Time Pad is separate from standard end-to-end encryption and requires preparation on both sides.

            Minimize third-party data exposure. This release does not include advertising or analytics SDKs.

            Transparency. Implementation notes for E2E and OTP are published in-app for independent review.
            """
        ),
        Section(
            id: "architecture",
            title: "2. System architecture",
            body: """
            Each user runs an iOS client with local key material, encrypted storage, and optional pad files.

            A relay server routes messages, profiles, and call signaling. Clients encrypt before upload and decrypt after download.

            Cryptographic identity and session state live in the device Keychain. Conversation history is stored in a local encrypted database.
            """
        ),
        Section(
            id: "e2e",
            title: "3. Standard encryption (E2E)",
            body: """
            Direct chats establish a session through X3DH using Curve25519 identity keys, signed prekeys, and optional one-time prekeys.

            Message traffic uses a Double Ratchet: each message derives a fresh key; ratchet steps limit the impact of a single key compromise.

            Wire payloads use authenticated encryption. Legacy AES-GCM sessions remain supported for older conversations.

            Safety numbers let users compare identity fingerprints out of band before trusting a contact.
            """
        ),
        Section(
            id: "otp",
            title: "4. One Time Pad mode",
            body: """
            One Time Pad is an optional Elite mode layered on top of the standard encrypted payload.

            Each conversation uses two directional pad bundles: one for sending, one for receiving. Bundles are exported as signed .vaultepad files and exchanged outside the app — AirDrop, Files, whatever works.

            Pad bytes never upload to the relay. Each message consumes a unique slice of the send pad. HMAC authentication and replay tracking prevent reuse and tampering.

            Activation requires both users to import matching bundles and mutually approve the mode switch in chat.
            """
        ),
        Section(
            id: "relay",
            title: "5. Relay visibility",
            body: """
            The relay may process:

            user and conversation identifiers, timestamps, encrypted message blobs, profile fields you choose to upload, and call signaling while a call is active.

            By design, the relay should not receive:

            decrypted message text, One Time Pad files, backup passphrases, or search queries from local message search.

            Relay operators can observe who communicates with whom and when. They should not be able to read message content if clients function correctly.
            """
        ),
        Section(
            id: "calls",
            title: "6. Voice calls",
            body: """
            Calls capture audio on-device, encrypt frames client-side, and transmit them through the relay during an active session.

            The relay handles connection setup and routing. It does not receive decrypted audio when the encryption path is working as intended.
            """
        ),
        Section(
            id: "storage",
            title: "7. Local storage and backups",
            body: """
            The client stores encryption keys in the Keychain, conversation data in an encrypted local database, and OTP pad files in protected app storage.

            Premier and Elite users may export an encrypted .vaultbackup file. The backup key is derived from a passphrase chosen by the user. Vaulté Privé does not escrow that passphrase.

            Local search runs entirely on the device. Query text is not sent to the relay.
            """
        ),
        Section(
            id: "premium",
            title: "8. Additional controls (Elite)",
            body: """
            Disappearing messages: a timer applies to new messages; deletion is enforced locally and signaled to the contact.

            Screenshot and copy alerts: in-chat signals notify the other party and can require approval before content is copied.

            These controls reduce casual leakage. They do not protect against a compromised device or external cameras.
            """
        ),
        Section(
            id: "trust",
            title: "9. Trust and verification",
            body: """
            Users should protect device access with a passcode or biometrics.

            Compare safety numbers when identity assurance matters.

            For One Time Pad, verify bundle fingerprints and exchange pads only through channels you trust.

            Mode changes that increase protection require explicit approval from the other participant.
            """
        ),
        Section(
            id: "source",
            title: "10. Source availability",
            body: """
            Vaulté Privé is source-available for audit and security research.

            The One Time Pad implementation, bundle format, and related secure-mode logic are not licensed for reuse, copying, or reimplementation in other products without written permission.

            Public visibility of source code does not grant replication rights. See the project license for full terms.
            """
        ),
        Section(
            id: "limits",
            title: "11. Scope and limitations",
            body: """
            No messaging system can guarantee security on a fully compromised device.

            The relay still sees metadata: who talks to whom, when, and how often.

            One Time Pad security depends on pad secrecy, sufficient pad capacity, and correct import on both sides.

            Voice quality and delivery depend on network conditions and device hardware.

            This whitepaper describes intended behavior of the production client. Your operator, relay deployment, and app version may add separate obligations covered in the Privacy Policy.
            """
        ),
    ]
}
