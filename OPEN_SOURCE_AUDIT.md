# Independent Source-Available Audit

Last updated: May 24, 2026

For a **post / announcement readiness review**, see [POST_AUDIT.md](POST_AUDIT.md).

## Critical

0. License model must match the intended distribution.
   - Status: source-available license in `LICENSE`
   - OTP / Verified OTP cannot be copied or reimplemented without permission

1. **Live relay secrets are still in source code**
   - `Vaulté Privé/Vaulté Privé/ChatAPIClient.swift` — `bundledFallback*` constants
   - `Vaulté Privé/Vaulté Privé.xcodeproj/project.pbxproj` — `INFOPLIST_KEY_VAULTE_RELAY_*`
   - Action: remove, rotate server-side, never publish repo until done

2. **`Messages 2/` folder in git index**
   - ~339 files, Signal-style naming (`OWS*`, `TS*`), not in Xcode target
   - Action: exclude from public repo or resolve licensing before publish

3. Rotate any relay secrets previously committed or shared in chat/builds.

## High Priority

1. Normalize Xcode signing — hardcoded `DEVELOPMENT_TEAM` in `project.pbxproj`
2. Review `NSAppTransportSecurity` — `NSAllowsArbitraryLoads = YES`
3. Remove duplicate `VaulteDisplayName 2.swift` files
4. Replace placeholder `privacy@vaulteprive.com` with a real contact
5. Sync README / CONTRIBUTING design copy (`gold` → actual white accent)

## Medium Priority

1. Split `ApplicationViews.swift` (~7500 lines)
2. Localize remaining hardcoded English (OTP flows, toasts)
3. Keep `relay-server/node_modules/`, `xcuserdata/`, `.build/` out of git
4. Remove `.cursor/plans/` from public repo if not needed
5. Clean git history before first public push

## Completed Since Last Audit

- Privacy policy rewritten in plain language, in-app UI with signature footer
- E2E / OTP implementation docs in app and `docs/`
- E2E+ mode removed from product
- `Secrets.example.xcconfig` + `.gitignore` for local secrets
- `PRIVACY_POLICY.md`, `LICENSE`, `CONTRIBUTING.md`, `README.md` scaffold
- Monochrome theme (ink + white), starfield, AMTypewriter shell
- Template-based relay config (partial — fallbacks still contain live values)

## Design Audit

Target: minimal, black/white, stars, AMTypewriter only.

Done: palette, shell, starfield, privacy/security screens.

Still recommended: unify chat bubble chrome, reduce legacy color noise, split mega view file.

## Local Secrets Template

Copy `Secrets.example.xcconfig` → `Secrets.xcconfig` (gitignored):

- `VAULTE_RELAY_BASE_URL`
- `VAULTE_RELAY_API_KEY`
- `VAULTE_RELAY_HMAC_SECRET`
- `VAULTE_RELAY_USERNAME_LOOKUP_PEPPER`
