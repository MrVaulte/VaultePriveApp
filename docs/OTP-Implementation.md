# OTP Implementation

How Verified OTP / One Time Pad mode works in Vaulté Privé.

Source: `VerifiedOtpBundleCrypto.swift`, `VerifiedOtpBundle.swift`, `OTPCodec.swift`, `OTPStore.swift`

## Overview

One Time Pad is a separate mode from standard E2E. It wraps the already-encrypted inner payload with pad bytes.

Each direction (send / receive) has its own pad bundle. Pads are exported as `.vaultepad` files and exchanged out of band. The relay never receives pad bytes.

## Bundle file (.vaultepad)

A bundle contains random pad bytes plus a signed header.

The pad payload is encrypted with AES-GCM. The file key is wrapped via ECDH between your identity key and the pinned peer identity key.

The header is signed with your Ed25519 signing key. Import verifies signature, fingerprint, and peer identity.

## Directional pads

You keep a send pad for outgoing OTP messages and a receive pad for incoming ones. Your contact's send pad is your receive pad, and vice versa.

Both bundles must be imported before the mode can be activated (Elite, mutual approval).

## Message encoding

For each OTP message the app reserves a unique byte range in the send pad. Plaintext is XOR-encrypted with that slice.

An envelope JSON includes bundle id, sequence, offset, ciphertext, and HMAC-SHA256 for authentication. Replay protection tracks consumed ranges.

## Capacity

Pad capacity is measured in bytes. When a pad is exhausted, sending stops until a new bundle is imported.

## License note

The OTP implementation is source-available for audit. Copying or reusing this logic in another product requires written permission. See LICENSE.
