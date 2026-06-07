//
//  VaulteImplementationDocsCopy.swift
//  Vaulté Privé
//

import Foundation

enum VaulteImplementationDocsCopy {
    struct Document: Identifiable {
        let id: String
        let fileName: String
        let title: String
        let intro: String
        let sections: [VaultePrivacyPolicyCopy.Section]
    }

    static let documents: [Document] = [
        Document(
            id: "e2e",
            fileName: "E2E-Implementation.md",
            title: "End-to-end encryption",
            intro: """
            How standard chat encryption works in Vaulté Privé. \
            Source files: VaulteRatchet.swift, ConversationKeyStore.swift, ChatViewModel.swift.
            """,
            sections: [
                .init(
                    id: "handshake",
                    title: "Session setup (X3DH)",
                    body: """
                    Before the first message, the app performs an X3DH handshake with the contact.

                    Each user has a Curve25519 identity key and a signed prekey uploaded to the relay. \
                    The initiator fetches the peer bundle, verifies the signed prekey signature with the peer's Ed25519 signing key, \
                    runs the DH exchanges (identity + ephemeral + signed prekey + optional one-time prekey), \
                    and derives a shared secret with HKDF.

                    That secret becomes the root key for the Double Ratchet session. Keys are stored locally in the Keychain — not on the relay.
                    """
                ),
                .init(
                    id: "ratchet",
                    title: "Double Ratchet",
                    body: """
                    After setup, messages use the Signal-style Double Ratchet.

                    Each message gets a fresh message key derived from chain keys. Sending advances the send chain; receiving advances the receive chain. \
                    A DH ratchet step mixes in new ephemeral keys when the peer sends from a new ratchet public key.

                    Wire prefix: e2:
                    Payload layout: ratchet public key (32) + previous chain length (4) + message number (4) + AES-GCM nonce (12) + ciphertext + tag (16).
                    """
                ),
                .init(
                    id: "legacy",
                    title: "Legacy AES fallback",
                    body: """
                    Older sessions may still use a static AES-GCM key per conversation (prefix e1: or raw base64). \
                    The app tries ratchet decryption first, then AES, when reading messages.
                    """
                ),
                .init(
                    id: "safety",
                    title: "Safety numbers",
                    body: """
                    The safety number shown in chat is derived from both users' X25519 identity public keys, sorted so the fingerprint is identical on both devices. \
                    Compare it out of band to confirm you are talking to the right person.
                    """
                ),
                .init(
                    id: "relay",
                    title: "What leaves the device",
                    body: """
                    Only ciphertext and routing metadata (sender id, recipient id, conversation id, timestamp) go to the relay. \
                    Plaintext exists on the phone after decryption.
                    """
                ),
            ]
        ),
        Document(
            id: "otp",
            fileName: "OTP-Implementation.md",
            title: "One Time Pad",
            intro: """
            How Verified OTP / One Time Pad mode works. \
            Source files: VerifiedOtpBundleCrypto.swift, VerifiedOtpBundle.swift, OTPCodec.swift, OTPStore.swift.
            """,
            sections: [
                .init(
                    id: "overview",
                    title: "Overview",
                    body: """
                    One Time Pad is a separate mode from standard E2E. It does not replace the session keys — it wraps the already-encrypted inner payload with pad bytes.

                    Each direction (send / receive) has its own pad bundle. Pads are generated on-device, exported as .vaultepad files, and exchanged out of band — AirDrop, Files, whatever works. \
                    The relay never receives pad bytes.
                    """
                ),
                .init(
                    id: "bundle",
                    title: "Bundle file (.vaultepad)",
                    body: """
                    A bundle contains random pad bytes plus a signed header.

                    The pad payload is encrypted with AES-GCM. The file key is wrapped via ECDH between your identity key and the pinned peer identity key, bound to bundle id and conversation id.

                    The header is signed with your Ed25519 signing key. Import verifies signature, fingerprint, and peer identity before the pad is stored locally in protected app storage.
                    """
                ),
                .init(
                    id: "direction",
                    title: "Directional pads",
                    body: """
                    You keep a send pad for outgoing OTP messages and a receive pad for incoming ones. \
                    Your contact's send pad is your receive pad, and vice versa.

                    Both directional bundles must be imported before the mode can be activated. Activation requires mutual approval in chat (Elite).
                    """
                ),
                .init(
                    id: "message",
                    title: "Message encoding",
                    body: """
                    For each OTP message the app reserves a unique byte range in the send pad. Plaintext is XOR-encrypted with that slice (OTPCodec).

                    An envelope JSON is attached with bundle id, sequence, offset, ciphertext, and an HMAC-SHA256 over the metadata + ciphertext using a key derived from the pad slice. \
                    Replay protection tracks consumed ranges so the same pad slice cannot be reused.
                    """
                ),
                .init(
                    id: "limits",
                    title: "Capacity and exhaustion",
                    body: """
                    Pad capacity is measured in bytes. One character of inner payload typically uses one pad byte.

                    When a pad runs low or is exhausted, sending stops until a new bundle is imported. The pads screen shows approximate remaining capacity for each direction.
                    """
                ),
                .init(
                    id: "license",
                    title: "License note",
                    body: """
                    The One Time Pad implementation in Vaulté Privé is source-available for audit. \
                    Copying or reusing this OTP logic in another product requires written permission. See LICENSE in the repository.
                    """
                ),
            ]
        ),
    ]
}
