# Vaulté Privé

> **Under independent security audit.** Source published for transparency and review only.

A privacy-focused iOS messaging client. End-to-end encrypted by default. Minimal server footprint — the relay sees only ciphertext, never message content.

---

## How it works

### Standard mode — Double Ratchet (E2E)

Every conversation uses X3DH key exchange and the Double Ratchet algorithm, the same construction used by Signal. Keys are generated on-device and never leave it. The relay queues opaque ciphertext and deletes it after the recipient acknowledges delivery.

### One Time Pad mode (OTP)

A separate mode for conversations that require a stronger security model. Both parties generate a shared pad locally and exchange it directly — via QR code, AirDrop, or physical proximity. No pad material ever touches the relay. Messages are encrypted with the pre-shared pad (XOR), and each byte is consumed exactly once. The relay sees ciphertext with no knowledge of the pad.

### Verified OTP

An extension of OTP that adds mutual authentication. Pad bundles are signed and verified using Ed25519, and each bundle carries a replay-protection tracker. A mismatch in the signature or a reused range triggers an immediate alert.

### Relay

The relay is a stateless ciphertext queue. It does not store message content after delivery. Identity and session keys live in the device Keychain. Conversation history is in a local encrypted database — never on the server.

---

## Repository layout

```
Vaulté Privé/         iOS app (SwiftUI)
relay-server/         Relay backend (Node.js + PostgreSQL)
docs/
  WHITEPAPER.md       Security architecture
  E2E-Implementation.md   Double Ratchet / X3DH implementation notes
  OTP-Implementation.md   One Time Pad / Verified OTP mechanics
  SECURITY.md         Threat model and security policy
  PRICING.md          Subscription tiers
```

---

## iOS configuration

The app reads relay settings from `Info.plist` build settings. Copy the template and fill in your values:

```sh
cp Secrets.example.xcconfig Secrets.xcconfig
# fill in VAULTE_RELAY_BASE_URL, VAULTE_RELAY_API_KEY, etc.
```

The file is gitignored. Wire it into your Xcode build configuration, then run against your own relay deployment.

### Certificate pinning

To enable TLS pinning, generate the SPKI hash for your relay and add it to `Secrets.xcconfig`:

```sh
openssl s_client -connect <host>:443 </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64
```

Set the result as `VAULTE_PINNED_KEY_HASHES`. An empty value disables pinning (development only).

---

## Relay setup

See [`relay-server/README.md`](relay-server/README.md) for local setup and environment variables.

---

## Security

See [`docs/SECURITY.md`](docs/SECURITY.md) for the threat model and known limitations.  
See [`docs/WHITEPAPER.md`](docs/WHITEPAPER.md) for the full security architecture (also available in-app under Settings → Security Architecture).

---

## License

Source-available. See [`LICENSE`](LICENSE).

- You may read, audit, and evaluate the code.
- You may not copy, redistribute, or reimplement the One Time Pad / Verified OTP logic in another product without written permission.
- Public visibility does not grant permissive reuse rights.

---

## Privacy

See [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md).
