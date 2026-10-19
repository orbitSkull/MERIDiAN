# MERIDiAN

A campus messenger. Talk to one person or to a group, send photographs, and get
told about a conversation when the app is closed.

Built with Flutter. The API is a separate service
([MERIDiAN-server](https://github.com/orbitSkull/MERIDiAN-server)) and lives at
`https://meridian-api-gvmr.onrender.com`.

---

## What it does

- **Direct and group chats.** Create a group with a name and any number of
  people, add and remove people, rename, or leave.
- **Messages that arrive when you are offline.** Every send is queued on the
  device with a stable id, so a retry is the same message rather than a
  duplicate, and a message sent in a tunnel is sent when the tunnel ends.
- **Photographs.** Pick, resize and send. They expire after seven days.
- **Live updates** over a WebSocket: new messages, delivery and read receipts,
  and a typing indicator.
- **Push notifications**, so a conversation wakes the phone when the app is
  closed.
- **Offline reading.** The device is the archive; the server keeps a recent
  window (messages 28 days, media 7) and the app syncs what is newer.

## Requirements

- Flutter 3.x (Dart 3)
- Android SDK, `minSdk 24`
- Node is not used; this repository is the app only

## Getting started

```bash
flutter pub get
flutter run
```

A debug build points at `http://10.0.2.2:8000`, the Android emulator's alias for
your machine. To use a real server instead:

```bash
flutter run --dart-define=API_BASE_URL=https://meridian-api-gvmr.onrender.com
```

### Release build

A release build with no override already points at the hosted API, so this
produces something that works:

```bash
flutter build apk --release
```

The result is at `build/app/outputs/flutter-apk/app-release.apk`.

It is a fat APK containing every CPU architecture (about 54 MB). For
per-architecture APKs, which is what you want when actually shipping:

```bash
flutter build apk --release --split-per-abi
```

> **Signing.** The release build is currently signed with the Android *debug*
> key, which installs and runs but is rejected by the Play Store. Replace
> `signingConfigs` in `android/app/build.gradle.kts` with a real keystore before
> publishing.

## Firebase

Push notifications need a Firebase project. There are two files involved and
they are not interchangeable.

**1. The app's config.** In the Firebase console, add an Android app whose
package name is exactly:

```
com.meridian.app
```

It must match `applicationId` in `android/app/build.gradle.kts`, and Firebase
does not let you change it afterwards. Download `google-services.json` and put
it at:

```
android/app/google-services.json
```

`flutter build apk` fails without it — deliberately. `flutter analyze` and
`flutter test` are unaffected, so the rest of the app stays verifiable without
it.

**2. The server's credentials.** In **Project settings → Service accounts**,
generate a private key. That is a password for your project: never commit it.

Set on the server (Render):

```
FIREBASE_CREDENTIALS=/opt/render/project/src/<filename>.json
```

The file itself is uploaded through Render's **Secret Files**, which mount at
`/opt/render/project/src/`. With the variable unset, the server logs
`push notifications are off` once and everything else keeps working.

To check registration worked:

```sql
SELECT id, user_id, platform, push_enabled, last_seen_at FROM devices;
```

## Tests

```bash
flutter analyze
flutter test
```

The golden-image previews are skipped by default because they capture one
machine's fonts. Where they belong:

```bash
flutter test --tags preview --run-skipped --update-goldens
```

If you change the chat UI, regenerate them or they will disagree with the code.

## How it is put together

```
lib/
  main.dart                 providers, theme, lifecycle observer
  data/
    chat_models.dart        messages, conversations, members
    chat_store.dart         the local-database interface
    sqlite_chat_store.dart  messages, conversations and the outbox in one file
    media_cache.dart        short-lived links to photographs
  screens/
    session_gate.dart       decides the first screen; opens a notified chat
    home/                   chats list, new chat, conversation, group info
    settings/               account, app, blocks, backup, sessions
  services/
    api_client.dart         the HTTP transport
    meridian_api.dart       what the screens are allowed to ask for
    chat_environment.dart   owns the store, outbox, sync and socket
    chat_lifecycle.dart     stops the socket while backgrounded
    realtime_client.dart    the WebSocket, with backoff
    outbox.dart             queued sends
    push_service.dart       Firebase, behind an interface
    push_registration.dart  ties the push token to the session
  theme/                    light and dark
```

A few decisions worth knowing before changing things:

- **The device is the archive; the server is a window.** Sync never deletes a
  local message, because the server forgets after 28 days. The one exception is
  leaving a conversation, which does delete — the person asked for it to be gone
  from their phone.
- **The outbox holds text only.** A photograph is not queued: that would mean
  copying every picture onto the device to retry later. Media needs a
  connection, and says so.
- **A phone holding an open socket is never pushed to.** It already has the
  message. Pushing as well lights up the lock screen while the app is in front
  of you, which is the fastest way to have notifications turned off for good.
- **Notifications say who, not what.** A lock screen is a public place.
- **A push token is removed on sign-out.** Firebase does not know who signed
  out, so without this a sold phone keeps telling the next owner about the
  previous owner's messages.
- **Only `paused` stops the socket**, not `inactive`. The notification shade, a
  phone call and the app switcher all fire `inactive`, several times an hour.

## Known gaps

- App lifecycle is handled, but a conversation list does not live-update while
  you are reading another screen; it refreshes on open and on resume.
- Media sends require a connection.
- The lock-screen notification icon is the launcher icon, which Android renders
  as a white silhouette. It works and looks wrong.