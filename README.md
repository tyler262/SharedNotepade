# Shared Notepad

A shared notepad app for two phones. Made for couples who keep their life in
the notes widget — grocery lists, important info, reminders — and never want
to lose it again.

- **Synced in real time.** Edit a note on one phone and it appears on the other
  within seconds.
- **Backed up in the cloud.** Notes live in Google Firebase (Firestore), not
  just on the phone. Lose the widget, the app, or the whole phone — your notes
  are safe.
- **Works offline.** Notes are cached on-device; edits made offline sync
  automatically when you're back online.
- **Home-screen widget.** Pin a note (tap the ★ on it) and it shows on your
  home screen, just like the Samsung notepad widget. Tap ↻ on the widget to
  refresh, or tap the widget to open the app.
- **No accounts or passwords.** One of you creates the notepad and gets an
  8-character share code; the other types it in once. Done.

## One-time setup (about 15 minutes)

The app needs its own (free) Firebase project to store the notes. You only do
this once:

1. Go to [console.firebase.google.com](https://console.firebase.google.com)
   and sign in with any Google account. Click **Create a project** (any name,
   e.g. "shared-notepad"). Google Analytics can be turned off.
2. In the project, click the **Android icon** to add an Android app:
   - Package name: `com.sharednotepad.app`
   - Download the `google-services.json` it gives you and **replace** the
     placeholder file at `app/google-services.json` in this repo.
3. In the left sidebar, open **Build → Authentication → Get started →
   Sign-in method**, and enable **Anonymous**.
4. Open **Build → Firestore Database → Create database**, choose production
   mode and a region near you.
5. In Firestore's **Rules** tab, paste the contents of
   [`firestore.rules`](firestore.rules) from this repo and click **Publish**.

The free tier limits (50k reads / 20k writes per day) are far more than two
people taking notes will ever use.

## Building the app

Open the project in [Android Studio](https://developer.android.com/studio),
let it sync, then **Run** it on a phone connected over USB — or build an APK
from the command line:

```bash
./gradlew assembleDebug
# APK lands in app/build/outputs/apk/debug/app-debug.apk
```

Copy the APK to both phones (e.g. via Quick Share) and install it. Android
will ask to allow installing from unknown sources — that's expected for a
self-built app.

## Using it

1. On the first phone: open the app → **Create a new shared notepad** → tap
   the share icon (top right) to see the 8-character code.
2. On the second phone: open the app → enter the code → **Join existing
   notepad**.
3. Add notes with **+**. Tap the **★** on a note to pin it — the pinned note
   is what the home-screen widget shows.
4. Long-press your home screen → **Widgets** → **Shared Notepad** to add the
   widget.

### Notes on the widget

The widget shows the last-synced copy of the pinned note. It refreshes when
you open the app, roughly every 30 minutes on its own, or instantly when you
tap **↻** on it.

### Security model

The share code is a random 8-character secret (~40 bits). Anyone who has the
code can read/write that one notepad — treat it like a house key and don't
post it anywhere public. All traffic additionally requires Firebase anonymous
authentication, so the database is not open to unauthenticated requests.

## Ideas for later

- Checklists with checkboxes for groceries (tap to mark off)
- Push notification / instant widget update when the other person edits
- Edit history / trash can for accidental deletions
