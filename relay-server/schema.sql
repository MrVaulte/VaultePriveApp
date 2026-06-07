-- Recommended Supabase / PostgreSQL schema for the relay.
-- Use native UUID + timestamptz so $1::uuid and ::timestamptz casts match column types.

CREATE TABLE IF NOT EXISTS messages (
  message_id UUID PRIMARY KEY,
  conversation_id UUID NOT NULL,
  sender_id UUID NOT NULL,
  recipient_id UUID NOT NULL,
  pad_id UUID NOT NULL,
  ciphertext_base64 TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created
  ON messages (conversation_id, created_at ASC);

CREATE TABLE IF NOT EXISTS users (
  user_id UUID PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT,
  username_lookup_key TEXT,
  profile_ciphertext_b64 TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Migration: add display_name if it doesn't exist yet
ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS username_lookup_key TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS profile_ciphertext_b64 TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_b64 TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_lookup_key
  ON users (username_lookup_key) WHERE username_lookup_key IS NOT NULL;

-- Encrypted-profile mode stores HMAC(username) in `users.username`, so old plaintext
-- username CHECK constraints must be removed on upgraded deployments.
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'users'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%username%'
  LOOP
    EXECUTE format('ALTER TABLE users DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_username ON users (username);

CREATE TABLE IF NOT EXISTS user_badges (
  user_id UUID PRIMARY KEY,
  badge_type TEXT NOT NULL CHECK (badge_type IN ('official', 'verified', 'diamond')),
  granted_by TEXT NOT NULL DEFAULT 'admin',
  granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_identity_keys (
  user_id UUID PRIMARY KEY,
  key_type TEXT NOT NULL,
  public_key_base64 TEXT NOT NULL,
  signing_public_key_base64 TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_identity_keys_updated_at
  ON user_identity_keys (updated_at);

CREATE TABLE IF NOT EXISTS signed_prekeys (
  user_id UUID NOT NULL,
  key_id INTEGER NOT NULL,
  public_key_base64 TEXT NOT NULL,
  signature_base64 TEXT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, key_id)
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL,
  key_id INTEGER NOT NULL,
  public_key_base64 TEXT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_otp_prekeys_user ON one_time_prekeys (user_id);

CREATE TABLE IF NOT EXISTS pad_batches (
  token TEXT PRIMARY KEY,
  conversation_id UUID NOT NULL,
  direction TEXT NOT NULL,
  pads_json JSONB NOT NULL,
  owner_user_id UUID,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  consumed_at TIMESTAMPTZ,
  consume_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_pad_batches_expires_at
  ON pad_batches (expires_at);

-- ── Sealed / anonymous messages (stealth-address delivery) ─────────────────
-- No sender_id, no recipient_id. The relay only sees a one-time stealth tag
-- derived from the recipient's scan public key. Only the recipient can
-- recognise their own tag; the relay cannot link tags to users or to each other.

ALTER TABLE users ADD COLUMN IF NOT EXISTS scan_pubkey_b64 TEXT;

CREATE TABLE IF NOT EXISTS sealed_messages (
  envelope_id      UUID        PRIMARY KEY,
  -- One-time stealth tag: HKDF(ECDH(ephemeral_priv, recipient_scan_pubkey), "vaulte.stealth.tag.v1")
  -- 32 bytes, hex-encoded. Relay stores and indexes on this; knows nothing else about the recipient.
  recipient_tag    TEXT        NOT NULL,
  -- Sender's ephemeral X25519 public key (base64). Recipient uses this to re-derive the tag
  -- and decrypt the sealed ciphertext. Not linkable to the sender's long-term identity.
  ephemeral_pubkey_b64 TEXT   NOT NULL,
  -- ChaCha20-Poly1305 ciphertext (base64). Contains: real_message_ciphertext + sender_id (encrypted).
  -- The relay never decrypts this.
  sealed_ciphertext_b64 TEXT  NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Messages auto-expire after 7 days.
  expires_at       TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days'
);

CREATE INDEX IF NOT EXISTS idx_sealed_tag     ON sealed_messages (recipient_tag);
CREATE INDEX IF NOT EXISTS idx_sealed_created ON sealed_messages (created_at);
CREATE INDEX IF NOT EXISTS idx_sealed_expires ON sealed_messages (expires_at);
