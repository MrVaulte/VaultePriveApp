# Vaulté Privé — Subscription Tiers

## Free — always free, no account required

| Feature | |
|---|---|
| E2E encrypted messaging | Double Ratchet / X3DH (Signal protocol) |
| Encrypted voice calls | ChaCha20-Poly1305, per-frame, ephemeral keys |
| Unlimited conversations | No cap, ever |
| Disappearing messages | Custom timer: 10 seconds to 7 days |
| Screenshot & copy controls | Always enforced — privacy is not a premium feature |
| Certificate-pinned relay | HMAC-authenticated WebSocket |

---

## Premier — $59.99 / year · $6.99 / month

Everything in Free, plus:

| Feature | |
|---|---|
| Encrypted backup & restore | AES-256-GCM, passphrase-locked |
| Full-text message search | On-device, encrypted index |
| Delivery & read receipts | |
| Custom conversation nicknames | |

App Store product IDs:
- `com.vaulteprive.premium.premier.annual`
- `com.vaulteprive.premium.premier.monthly`
- `com.vaulteprive.premium.personal.annual` *(grandfathered)*

---

## Elite — $299.99 / year · $29.99 / month

Everything in Premier, plus:

| Feature | |
|---|---|
| One Time Pad (OTP) | Information-theoretically secure |
| Verified OTP | Ed25519-signed pad bundles, TOFU peer binding, single-use files |
| Trusted device roster | See and revoke linked devices |

App Store product IDs:
- `com.vaulteprive.premium.elite.annual`
- `com.vaulteprive.premium.elite.monthly`
- `com.vaulteprive.premium.pro.annual` *(grandfathered)*

---

## Notes

- Subscriptions managed by Apple StoreKit 2 — Vaulté Privé never sees payment details.
- All encryption runs on-device. The relay has zero access to plaintext.
- Calls are E2E encrypted on every tier.
- Screenshot protection and disappearing messages are not gated — they are core privacy features available to all users.
