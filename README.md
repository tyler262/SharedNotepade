# Shared Notepad

A shared notepad for two phones. Notes and shopping lists live **on both
phones**, and the phones sync directly to each other over your home Wi-Fi.
There is no server, no account, and nothing stored online.

Built with Flutter, for Android.

## What it does

- **Notes and shopping lists.** Any note can be flipped into a tickable list
  and back again. List items have a free-text amount ("2", "1 gallon", "a
  bunch"), a checkbox for crossing things off at the store, and drag-to-reorder
  so you can put them in aisle order.
- **Both phones stay in step.** Add bread at home while she's ticking off milk
  at the store — when the phones are next on the same Wi-Fi, both changes
  survive. Neither edit overwrites the other.
- **Nothing to sign into.** One phone starts a notepad and produces a pairing
  code; the other pastes it in once.
- **Your notes never leave your devices.** No cloud database, no company
  holding your grocery list.

## How the syncing works

Each phone keeps the whole notepad in a single JSON file — that file is the
source of truth, and the app works fully offline.

When both phones are on the same Wi-Fi:

1. Each one announces itself with a small UDP broadcast on port 51422.
2. When they spot each other, one POSTs its notes to the other's built-in HTTP
   endpoint (on a port the OS assigns), and gets the other's notes back in the
   same response. One round trip, both sides converge.
3. Every request is signed with the shared pad secret, which is never sent over
   the network. Unsigned or wrong-pad requests are rejected.

Merging is last-write-wins, but applied *per field* rather than per note. A
note's title, body and its individual list items each carry their own
timestamp, so ticking off an item never clobbers a title edit made on the other
phone. Deletes leave a tombstone for 30 days so they propagate instead of the
item reappearing. The rules are covered by the tests in `test/`.

### The honest limitation

**The phones only sync when they're on the same Wi-Fi.** If she's at the store
on mobile data and you add something at home, she won't see it until she's
back on the home network. Everything is saved safely on each phone in the
meantime and merges when they meet again — nothing is lost, it's just not
instant while you're apart.

That is the unavoidable trade of having no server: with nothing in the middle,
two phones need to be able to reach each other directly. If you decide you want
changes to appear while you're apart, the fix is to add one shared drop point
(a file in your own Google Drive is the smallest version of this) — the merge
logic here would carry over unchanged.

Two smaller caveats:

- Sync traffic is *authenticated* but not encrypted. It never leaves your home
  network, but someone already on your Wi-Fi could read a grocery list off the
  wire. If that matters, that's the thing to fix next.
- The merge trusts each phone's clock. Both phones get their time from the
  network, so this is fine in practice.

If your router has "client isolation" / "AP isolation" turned on, it blocks
phones from talking to each other and sync won't find a partner. Turning that
off in your router settings fixes it.

## Backups

Because everything is on-device, `Pairing & backup → Send a backup` exports the
whole notepad as text you can email or message to yourself. **Restore from
backup** merges it back on any phone. Having the notes on two phones already
means one broken phone can't lose them, but a backup covers losing both.

Internally, saves are written to a temp file and renamed into place, and the
previous good copy is kept as `notes.backup.json`. A save interrupted by a
crash can't corrupt your notes, and a corrupted file falls back to the backup.

## Building it

You need [Flutter](https://docs.flutter.dev/get-started/install) and Android
Studio (for the Android SDK).

```bash
flutter pub get
flutter test      # 26 tests covering merging, syncing and storage
flutter build apk --release
# APK lands in build/app/outputs/flutter-apk/app-release.apk
```

Copy the APK to both phones (Quick Share works well) and install. Android will
warn about installing from an unknown source — expected for a self-built app.

To run on a phone plugged in over USB: `flutter run --release`.

## Using it

1. **First phone:** open the app → *Set up* → *Start a new notepad* → *Send*,
   and text the pairing code to your partner.
2. **Second phone:** open the app → *Set up* → *Join with a code* → paste.
3. Make notes with **+**, or shopping lists with the checklist button. The
   checklist icon in a note's toolbar converts between the two — converting a
   note turns each line into its own tickable item.
4. Keep both phones on the home Wi-Fi with the app open for a moment to sync.
   The bar under the title tells you what sync is doing.

## Layout

```
lib/
  models/note.dart          Note + ChecklistItem, and the merge rules
  data/note_store.dart      On-device JSON storage, atomic saves, backups
  data/pairing.dart         Pad id, shared secret, pairing codes
  sync/sync_service.dart    UDP discovery + signed HTTP sync
  ui/                       Note list, editor, pairing screen
test/
  note_merge_test.dart      Merge correctness (concurrent edits, deletes)
  sync_test.dart            Two phones syncing over real sockets
  store_test.dart           Persistence, crash recovery, import/export
```

## Ideas for later

- Sync while apart, via a file in your own Google Drive
- A home-screen widget showing the current shopping list
- Encrypting sync traffic, not just signing it
- Connect-by-IP for routers that block broadcast (`syncWithAddress` already
  does the work; it just needs a text field in the UI)
