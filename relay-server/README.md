# Vaulte Prive Relay Server

Production-oriented opaque relay: stores ciphertext + routing metadata only. **Never decrypts** payloads.

## API

| Method | Path | Notes |
|--------|------|--------|
| `GET` | `/` | Plain text: `Vaulte relay running` |
| `GET` | `/healthz` | Liveness: `{ ok: true }` (no DB) |
| `GET` | `/readyz` | Readiness: checks PostgreSQL (`SELECT 1`) |
| `POST` | `/messages` | Store one message |
| `GET` | `/conversations/:conversationId/messages` | List messages (pagination) |
| `DELETE` | `/conversations/:conversationId/messages?user_id=<uuid>` | Delete all server messages in conversation for that user |
| `GET` | `/users/:userId` | Fetch user profile (`username`) |
| `PUT` | `/users/:userId` | Set/update unique username |
| `GET` | `/users/resolve?username=<name>` | Resolve `@username` -> `user_id` |
| `GET` | `/users/search?q=<prefix>&limit=20` | Prefix search in usernames |
| `GET` | `/keys/:userId` | Fetch published identity key (`x25519`) |
| `PUT` | `/keys/:userId` | Publish/update identity key (`x25519`) |
| `POST` | `/pad-batches` | Store pad batch and return short QR token |
| `POST` | `/pad-batches/:token/consume` | One-time consume pad batch by token |

### Message payload (`POST /messages`, snake_case JSON)

```json
{
  "message_id": "uuid",
  "conversation_id": "uuid",
  "sender_id": "uuid",
  "recipient_id": "uuid",
  "pad_id": "uuid",
  "ciphertext_base64": "base64",
  "created_at": "2026-04-13T20:24:10.123Z"
}
```

Responses include `request_id` (also in header `X-Request-Id`) for tracing logs.

### Identity key payload (`PUT /keys/:userId`)

```json
{
  "key_type": "x25519",
  "public_key_base64": "base64_32_bytes"
}
```

### Pad batch token flow (QR)

QR should contain only short token payload (example: `VP-7F3A9C-K2`), not pads.

`POST /pad-batches` body:

```json
{
  "conversation_id": "uuid",
  "direction": "inbound",
  "pads": [
    { "id": "uuid", "bytes_b64": "...", "created_at": "2026-04-14T12:00:00.000Z" }
  ],
  "owner_user_id": "uuid",
  "ttl_seconds": 86400
}
```

Returns: `{ token, expires_at }`.

`POST /pad-batches/:token/consume` body:

```json
{
  "requester_user_id": "uuid"
}
```

Behavior:
- first valid consume -> returns batch and marks `consumed_at`
- repeated consume -> `410 batch_consumed`
- expired batch -> `410 batch_expired`
- if `owner_user_id` exists, `requester_user_id` must match

### GET messages — query params

- `since` — ISO8601; default `1970-01-01T00:00:00.000Z`
- `limit` — **1–200**; if **omitted**, default **50**. Load more pages by increasing `since` to the last row’s `created_at` (the iOS client loops with `limit=200`).

### Database types

Use **`UUID`** for all `*_id` columns and **`TIMESTAMPTZ`** for `created_at` / `received_at`. See `schema.sql`. If `conversation_id` is `TEXT` while the query uses `$1::uuid`, you get fragile implicit casts — align types with the schema.

Username rules: lowercase `a-z`, digits `0-9`, underscore `_`, length `3...24`, globally unique.

### Encrypted payload policy

Decoded ciphertext must not look like long printable ASCII-only text (anti-accidental-plaintext). OTP/XOR/AEAD output should pass.

### PostgreSQL

- `message_id` must be **PRIMARY KEY** or have **UNIQUE** constraint for `ON CONFLICT (message_id) DO NOTHING`.

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | **yes** | Supabase Postgres connection string |
| `PORT` | no | Default `3000` (Render sets this) |
| `RELAY_API_KEY` | no | If set, require `Authorization: Bearer <key>` **or** `X-API-Key: <key>` on `/messages` and GET messages |
| `RELAY_HMAC_SECRET` | no | If set, require HMAC signature headers: `X-Relay-Timestamp` + `X-Relay-Signature` |
| `RELAY_HMAC_WINDOW_SEC` | no | Signature freshness window in seconds (default `300`) |
| `RELAY_ALLOWED_ORIGINS` | no | Comma-separated origins for CORS (browser tools). Omit = allow all (fine for native apps) |
| `TRUST_PROXY_HOPS` | no | Default `1` (Render / reverse proxy) |
| `RATE_LIMIT_POST_PER_MIN` | no | Default `120` |
| `RATE_LIMIT_GET_PER_MIN` | no | Default `300` |
| `PG_POOL_MAX` | no | Default `20` |
| `PG_IDLE_MS` | no | Default `30000` |
| `PG_CONNECT_TIMEOUT_MS` | no | Default `10000` |

## Run locally

```bash
cd relay-server
npm install
export DATABASE_URL="postgresql://..."
npm start
```

## Render deploy

- Root directory: `relay-server`
- Build: `npm install`
- Start: `npm start`
- Runtime: Node 20+
- Set `DATABASE_URL` from Supabase. Use `/readyz` for health checks if your platform supports HTTP readiness.

## iOS client + `RELAY_API_KEY`

If you enable `RELAY_API_KEY`, add the same key to the app (header `X-API-Key` or `Authorization`) in `ChatAPIClient` — otherwise leave `RELAY_API_KEY` unset.

## Optional HMAC signing

When `RELAY_HMAC_SECRET` is enabled, each protected request must include:

- `X-Relay-Timestamp`: unix time (seconds)
- `X-Relay-Signature`: `hex(HMAC_SHA256(secret, canonical))`

Canonical payload:

`<timestamp>.<METHOD>.<originalUrl>.<rawBodyUtf8>`

Example for `POST /messages` with JSON body:

`1713123456.POST./messages.{"message_id":"...","conversation_id":"..."...}`
