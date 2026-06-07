# Vaulté Privé — Security & privacy

This document mirrors the in-app summary (`VaulteSecurityPolicyCopy`) and can be published on your marketing site.

## Threat model (short)

Vaulté Privé is designed so that **message contents stay on your devices** in decrypted form. The relay stores **opaque ciphertext** plus routing metadata (user ids, conversation ids, timestamps).

## What the relay can see

- Who sent a message and who receives it (`sender_id`, `recipient_id`).
- Opaque `ciphertext_base64` (the server does not decrypt it in normal operation).
- Conversation routing identifiers and timestamps.
- Account profile fields you upload (username, display name, avatar image).

## What the relay cannot see (by design)

- Plaintext chat content when end-to-end encryption is used correctly.
- One Time Pad bytes (pads are exchanged out of band, for example via AirDrop or Files).

## Encryption modes

- **E2E (standard):** Uses your established session material (Double Ratchet and/or AES) to protect payloads on the wire.
- **One Time Pad (Elite):** A separate stronger mode using pre-generated directional bundles. Requires both users to import matching pads before activation.

## Your responsibilities

- Protect device passcodes / biometrics.
- Compare **safety numbers** with contacts when you need strong assurance of identity keys.
- Keep relay API keys and admin tokens out of source control in production.

## Premium backups

Encrypted backup files (`.vaultbackup`) wrap your local SQLite store with **AES-GCM** using a key derived via **PBKDF2-SHA256** from a passphrase you choose. The passphrase is not escrowed by the app.

## Relay admin (operators)

Set `RELAY_ADMIN_TOKEN` on the relay. Clients send `X-Relay-Admin-Token: <token>`.

- `GET /admin/summary` — aggregate counts only (users, messages, suspended users). No ciphertext.
- `POST /admin/users/:userId/suspend` — JSON body `{ "suspended": true|false }`. Suspended senders cannot insert new messages.

## App Store subscriptions

Product identifiers expected by the iOS client:

- `com.vaulteprive.premium.premier.annual` (entry tier; backup export, local search, premium tooling)
- `com.vaulteprive.premium.elite.annual` (top tier; set a lower annual price in App Store Connect if you want “premium feel, gentler price”)
- `com.vaulteprive.premium.personal.annual` (legacy entry tier; still honored if a user already subscribed)
- `com.vaulteprive.premium.pro.annual` (legacy top tier; still honored in the app if a user already subscribed)

Create matching auto-renewable subscriptions in App Store Connect and enable StoreKit testing as needed. Suggested price anchors and the local `.storekit` file are in [docs/PRICING.md](PRICING.md).
