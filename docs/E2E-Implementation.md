# E2E Implementation

How standard chat encryption works in Vaulté Privé.

Source: `VaulteRatchet.swift`, `ConversationKeyStore.swift`, `ChatViewModel.swift`

## Session setup (X3DH)

Before the first message, the app performs an X3DH handshake with the contact.

Each user has a Curve25519 identity key and a signed prekey uploaded to the relay. The initiator fetches the peer bundle, verifies the signed prekey signature with the peer's Ed25519 signing key, runs the DH exchanges (identity + ephemeral + signed prekey + optional one-time prekey), and derives a shared secret with HKDF.

That secret becomes the root key for the Double Ratchet session. Keys are stored locally in the Keychain — not on the relay.

## Double Ratchet

After setup, messages use the Signal-style Double Ratchet.

Each message gets a fresh message key derived from chain keys. Wire prefix: `e2:`.

Payload layout: ratchet public key (32) + previous chain length (4) + message number (4) + AES-GCM nonce (12) + ciphertext + tag (16).

## Legacy AES fallback

Older sessions may still use a static AES-GCM key per conversation. The app tries ratchet decryption first, then AES.

## Safety numbers

The safety number is derived from both users' X25519 identity public keys, sorted so the fingerprint matches on both devices.

## What leaves the device

Only ciphertext and routing metadata go to the relay. Plaintext stays on the phone after decryption.
