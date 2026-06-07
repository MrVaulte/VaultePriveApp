# Vaulté Privé Whitepaper

Version 1.0 · Last updated: May 24, 2026

## Abstract

Vaulté Privé is a private messaging system for iOS. Message content is encrypted on the device before transmission. The relay forwards opaque ciphertext and routing metadata; it is not designed to hold readable conversations.

An optional One Time Pad mode adds a second layer based on pre-shared pad material exchanged directly between users. This document describes the security model, cryptographic layers, and operational boundaries of the production system.

## 1. Design principles

- Plaintext belongs on the device. The server path carries encrypted payloads, not message content.
- Stronger modes are explicit and user-controlled. One Time Pad is separate from standard end-to-end encryption and requires preparation on both sides.
- Minimize third-party data exposure. This release does not include advertising or analytics SDKs.
- Transparency. Implementation notes for E2E and OTP are published in-app for independent review.

## 2. System architecture

Each user runs an iOS client with local key material, encrypted storage, and optional pad files.

A relay server routes messages, profiles, and call signaling. Clients encrypt before upload and decrypt after download.

Cryptographic identity and session state live in the device Keychain. Conversation history is stored in a local encrypted database.

## 3. Standard encryption (E2E)

Direct chats establish a session through X3DH using Curve25519 identity keys, signed prekeys, and optional one-time prekeys.

Message traffic uses a Double Ratchet: each message derives a fresh key; ratchet steps limit the impact of a single key compromise.

Wire payloads use authenticated encryption. Legacy AES-GCM sessions remain supported for older conversations.

Safety numbers let users compare identity fingerprints out of band before trusting a contact.

## 4. One Time Pad mode

One Time Pad is an optional Elite mode layered on top of the standard encrypted payload.

Each conversation uses two directional pad bundles: one for sending, one for receiving. Bundles are exported as signed `.vaultepad` files and exchanged outside the app — AirDrop, Files, whatever works.

Pad bytes never upload to the relay. Each message consumes a unique slice of the send pad. HMAC authentication and replay tracking prevent reuse and tampering.

Activation requires both users to import matching bundles and mutually approve the mode switch in chat.

## 5. Relay visibility

**The relay may process:** user and conversation identifiers, timestamps, encrypted message blobs, profile fields you upload, and call signaling during active calls.

**By design, the relay should not receive:** decrypted message text, One Time Pad files, backup passphrases, or local search queries.

## 6. Voice calls

Calls capture audio on-device, encrypt frames client-side, and transmit them through the relay during an active session.

## 7. Local storage and backups

The client stores encryption keys in the Keychain, conversation data in an encrypted local database, and OTP pad files in protected app storage.

Premier and Elite users may export an encrypted `.vaultbackup` file protected by a user-chosen passphrase. Vaulté Privé does not escrow that passphrase.

## 8. Additional controls (Elite)

- **Disappearing messages** — timer-based deletion for new messages, signaled to the contact.
- **Screenshot and copy alerts** — in-chat notifications and optional approval before copy.

These controls reduce casual leakage. They do not protect against a compromised device or external cameras.

## 9. Trust and verification

Protect device access. Compare safety numbers when identity assurance matters. Verify OTP bundle fingerprints. Approve mode upgrades explicitly.

## 10. Source availability

Vaulté Privé is source-available for audit and security research. The One Time Pad implementation is not licensed for reuse in other products without written permission.

## 11. Scope and limitations

No messaging system can guarantee security on a fully compromised device. The relay still sees metadata. OTP security depends on pad secrecy and correct setup on both sides.

---

Technical supplements: [E2E-Implementation.md](E2E-Implementation.md) · [OTP-Implementation.md](OTP-Implementation.md) · [SECURITY.md](SECURITY.md) · [PRIVACY_POLICY.md](../PRIVACY_POLICY.md)
