# Shared Notepad

A shared notepad for two phones. Notes and shopping lists live **on both
phones**, and the phones keep each other in step — directly over your home
Wi-Fi, and optionally through a tiny relay you host on Cloudflare's free tier
so it also works when you're apart.

There is no account to create and no company holding your data.

Built with Flutter, for Android.

## What it does

- **Notes and shopping lists.** Any note flips into a tickable list and back.
  Items have a free-text amount ("2", "1 gallon", "a bunch"), a checkbox for
  crossing things off at the store, and drag-to-reorder for aisle order.
- **Both phones stay in step.** Add bread at home while she's ticking off milk
  at the store — both changes survive. Neither edit overwrites the other.
- **Works offline.** The phone's own copy is the source of truth, so the app
  never waits on a network.
- **Nothing to sign into.** One phone starts a notepad and produces a pairing
  code; the other pastes it in once.

## How syncing works

Each phone keeps the whole notepad in a single JSON file. That file is the
truth. Syncing is just two phones swapping copies and merging.

There are two ways a copy can travel, and both end in the same merge function:

**Over your Wi-Fi (no relay needed).** Each phone announces itself with a UDP
broadcast on port 51422. When they spot each other, one POSTs its notes to the
other's built-in HTTP endpoint and gets the other's notes back in the same
reply — one round trip, both converge. Requests are signed with the shared pad
secret, which never goes over the wire.

**Through the relay (anywhere).** Each phone writes its own copy into its own
slot on a Cloudflare Worker and reads the other phone's slot. Because a phone
only ever writes its *own* slot, two phones can never collide, so there's no
locking or retry logic. The relay never merges anything and doesn't need to
understand notes — it's a mailbox, not a database.

The relay also removes the need for both apps to be open at once: you leave
your notes in the mailbox, she collects them whenever she next opens the app.

### Merging

Last-write-wins, but **per field rather than per note**. A note's title and
body share a timestamp, and every list item carries its own. Ticking an item
deliberately does not bump the note's timestamp, so crossing milk off can't
clobber a title edit made on the other phone at the same time.

Deletes leave a tombstone for 30 days so they propagate instead of the item
reappearing on the next merge. The rules are pinned by tests in `test/`.

Because merging is idempotent and order-independent, it doesn't matter which
transport delivers an edit, or whether both do, or in what order.

### Known limitations

- **Sync happens while the app is open.** There's no background service, so a
  closed app doesn't pull. With the relay set up this matters much less —
  whatever you missed is waiting the next time you open it.
- **Without a relay, both apps must be open on the same Wi-Fi** at the same
  moment.
- **Relay traffic is HTTPS but not end-to-end encrypted.** Cloudflare could
  read your notes, the same as any normal cloud app. Wi-Fi sync is
  authenticated but not encrypted either, though it never leaves your house.
  Adding end-to-end encryption is a contained change if you want it.
- **Merging trusts each phone's clock.** Both get their time from the network,
  so this is fine in practice.
- If your router has "AP isolation" enabled it blocks phones from talking
  directly; the relay works around that entirely.

## Setting up the relay (optional, ~10 minutes)

Skip this if you only care about syncing at home.

You need a free Cloudflare account and [Node](https://nodejs.org).

```bash
cd worker
npm install
npx wrangler login

# Create the database, then paste the printed database_id into wrangler.toml
npx wrangler d1 create shared-notepad

npx wrangler d1 execute shared-notepad --remote --file=schema.sql
npx wrangler deploy
```

Wrangler prints a URL like `https://shared-notepad-relay.you.workers.dev`. In
the app, go to **Pairing & backup → Sync from anywhere** and paste it. The app
checks the address before saving it.

You only do this on one phone. The relay address rides along inside the pairing
code, so your partner's phone picks it up automatically when they join.

### What it costs

Nothing, comfortably. Cloudflare's free tier allows 100,000 Worker requests a
day and 100,000 D1 row writes a day. Two phones polling every 15 seconds while
the app is open use a few hundred requests a day — well under 1% of the
allowance. Even polling around the clock on both phones would sit near 17%.

Idle polls don't write at all: the app fingerprints what it last uploaded and
skips the upload when nothing changed.

## Backups

`Pairing & backup → Send a backup` exports the whole notepad as text you can
email or message to yourself; **Restore from backup** merges it back on any
phone. Having the notes on two phones already means one broken phone can't lose
them, and a backup covers losing both.

Saves are written to a temp file and renamed into place, with the previous good
copy kept as `notes.backup.json`. A save interrupted by a crash can't corrupt
your notes, and a corrupted file falls back to the backup.

## Building the app

You need [Flutter](https://docs.flutter.dev/get-started/install) and Android
Studio (for the Android SDK).

```bash
flutter pub get
flutter test                  # 36 tests
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```

Copy the APK to both phones (Quick Share works well) and install. Android warns
about installing from an unknown source — expected for a self-built app.

### Testing against a real relay

The suite runs fully offline by default; the relay contract tests skip
themselves unless you point them at a running Worker:

```bash
cd worker && npx wrangler dev --local --port 8787   # in one terminal
npx wrangler d1 execute shared-notepad --local --file=schema.sql

SNP_RELAY_URL=http://127.0.0.1:8787 flutter test    # in another
```

That runs the real app code against the real Worker, so the two can't drift
apart in what they expect on the wire.

## Using it

1. **First phone:** open the app → *Set up* → *Start a new notepad*. Add the
   relay if you want anywhere-syncing, then tap *Send* and text the pairing
   code to your partner.
2. **Second phone:** open the app → *Set up* → *Join with a code* → paste.
3. Make notes with **+**, or shopping lists with the checklist button. The
   checklist icon in a note's toolbar converts between the two — converting a
   note turns each line into its own tickable item.
4. The bar under the title says what sync is doing.

## Layout

```
lib/
  models/note.dart            Note + ChecklistItem, and the merge rules
  data/note_store.dart        On-device JSON storage, atomic saves, backups
  data/pairing.dart           Pad id, shared secret, relay address, pair codes
  sync/sync_service.dart      Wi-Fi: UDP discovery + signed HTTP exchange
  sync/cloud_sync.dart        Relay client: read other slots, write own slot
  sync/sync_coordinator.dart  Drives both transports on one schedule
  ui/                         Note list, editor, pairing screen
worker/
  src/index.js                The Cloudflare Worker (a mailbox, ~200 lines)
  schema.sql                  Two tables: pads and slots
test/
  note_merge_test.dart        Merge correctness (concurrent edits, deletes)
  sync_test.dart              Two phones syncing over real sockets
  cloud_sync_test.dart        Relay client against an in-process fake
  relay_contract_test.dart    The real client against the real Worker
  store_test.dart             Persistence, crash recovery, import/export
```

## Ideas for later

- A background job so the app pulls updates while closed
- End-to-end encryption, so the relay holds only ciphertext
- A home-screen widget showing the current shopping list
- Connect-by-IP for routers that block broadcast (`syncWithAddress` already
  does the work; it just needs a text field in the UI)
