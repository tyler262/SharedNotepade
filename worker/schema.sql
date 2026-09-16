-- Shared Notepad relay schema.
--
-- The relay is a mailbox, not a database of notes. It stores one opaque blob
-- per (pad, device) and never interprets what is inside. Each phone writes
-- only its own row, so two phones can never conflict over a write and no
-- locking or retry logic is needed anywhere.

CREATE TABLE IF NOT EXISTS pads (
  pad_id      TEXT PRIMARY KEY,
  secret_hash TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS slots (
  pad_id     TEXT NOT NULL,
  device_id  TEXT NOT NULL,
  blob       TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (pad_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_slots_pad_updated ON slots (pad_id, updated_at);
