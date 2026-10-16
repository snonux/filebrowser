# File Browser for Android

Android client for the File Browser server in this repository. It uses the
server's existing REST API (the one the web interface uses), so it works with
an unmodified server and needs no extra setup on it.

The installed app version appears at the bottom of **Settings**.

## Features

- **Sign in** with the server address, username and password. With **Stay
  signed in** (on by default) the password is kept in Android's encrypted
  storage, so the app signs in again by itself when the server's session
  expires (File Browser sessions last two hours by default and cannot be
  extended once expired). Without it, the app returns to the sign-in screen.
- **Sign in with fingerprint.** After a password sign-in on a phone with an
  enrolled fingerprint, the app offers to use the fingerprint next time. The
  password is then encrypted with an Android keystore key that only unlocks
  after a fingerprint check (`biometric_storage`), and the sign-in screen gets
  a **Sign in with fingerprint** button. Logging out keeps it; Settings turns
  it on or off. Password sign-in always works. If the password changes on the
  server or new fingerprints are enrolled (which invalidates the key), the app
  turns fingerprint sign-in off and asks for the password.
- **Proxy login** for servers behind a reverse proxy that asks for a username
  and password (HTTP basic auth). The proxy credentials are sent with every
  request to that server, including thumbnails and uploads.
- **Browse** folders with breadcrumbs, image thumbnails, pull to refresh,
  sorting by name, size or date (folders first), and a toggle for hidden
  files. The drawer on the first screen shows the disk usage.
- **Open** a folder, an image (full-screen viewer that swipes through the
  folder's images and pinch-zooms), a PDF (scrolling pages with pinch zoom
  and a page counter, rendered with PDFium), a video or audio file (streamed
  player with seeking), or a text file (editor; saving needs the modify
  permission). Any other file is downloaded and handed to the app Android
  picks for it. **Open with another app** in a file's ⋮ menu does the same
  for files the app can show itself, and the PDF viewer and player offer it
  when they cannot show a file.
- **Edit in TurboNotes**: the ⋮ menu of a text or Markdown file (and the
  text editor's toolbar) hands it to
  [TurboNotes](https://github.com/snonux/turbonotes), and every save there is
  uploaded back to the server within a few seconds. If someone changed the
  file on the server meanwhile, the edits are saved next to it as
  `name (edited <date> <time>).ext` instead of overwriting theirs. Without
  TurboNotes the action reads **Edit in another app** and Android asks which
  editor to use. Needs the modify and download permissions.
- **Upload** any number of files picked with Android's file picker. Uploads
  use the tus protocol in 10 MB chunks and resume from the server's offset
  after a failed chunk. Uploading over an existing name asks before replacing.
- **Share to File Browser** from any app: files of any type, one or many,
  and text. The app asks for the folder (the last one used is remembered),
  then uploads. Shared text becomes a file named after the sender's subject
  or the text's first line; it is saved as `.md` when it looks like Markdown
  (a heading, link, code block, table, bold text, a task list, or two weaker
  signs such as a list and a quote) and as `.txt` otherwise, with a switch to
  change it. Signing in first is asked for when needed.
- **Download** a file, or a folder as a zip, into the app's Download folder
  (`Android/data/org.buetow.filebrowser/files/Download`), then open it.
- **Create** folders and files; **rename**, **copy to**, **move to** and
  **delete**, for one item from its ⋮ menu or for several after a long press.
- **Available offline**: **Make available offline** in the ⋮ menu of a file
  or folder keeps a copy on the device; a folder keeps everything below it,
  subfolders included. Kept items show a check mark. The copies are updated
  when the app starts, when a kept folder is listed with changes, and with
  the sync button on **Available offline** in the drawer, which lists every
  kept item and its space on the device. They stay until **Remove offline
  copy** is chosen or the item is deleted (in the app, or on the server, which
  the next update notices); a rename or move in the app keeps them. When the
  server cannot be reached, folders show what is kept, with a banner, and
  kept files open as usual (text files read-only). Copies live in
  `Android/data/org.buetow.filebrowser/files/offline`, one folder per server
  and account, and are removed with the app.
- **Search** below the current folder.
- **Share links** with the options of the web UI: an optional lifetime in
  seconds, minutes, hours or days, and an optional password. **Share link** on
  an item lists the links it already has, each with copy, copy download link
  and delete, and creates new ones; a new link is copied to the clipboard.
  Links start with the server address the app is signed in to. **Share links**
  in the drawer lists every link of the account (an administrator sees
  everyone's, with the owner) for copying or deleting. Sharing is offered only
  to accounts that may both share and download, as on the server.
- **Info** shows path, size, type and date, and computes a SHA-256 checksum on
  the server.
- **Settings**: theme (system, light, dark), hidden files, log out.

Actions the account may not perform (from its File Browser permissions) are
not offered.

Not included: managing users and server settings, and running commands.
Those stay in the web interface.

## Build

```sh
cd filebrowser-android
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The Flutter version is pinned in `.flutter-version`. Release builds and
F-Droid publishing are described in
[docs/fdroid-release.md](docs/fdroid-release.md).

## End-to-end test

`test/e2e/run_e2e.sh` builds the server from this checkout, seeds a scratch
folder, starts the server with two accounts (an admin and a read-only user)
plus a basic-auth reverse proxy in front of it, and runs
`integration_test/app_test.dart`. That test drives the real UI and checks each
result on the server: sign-in errors, listing, hidden files, sorting, disk
usage, new folder and file, text editing, single and multi-chunk uploads,
replace on conflict, rename (with `+`, `%` and `#` in the name), copy, move,
multi-select delete, checksum, thumbnails and the image viewer, file and zip
downloads, opening a file in another app, search, share links (including the
public link, the download link and the per-item list), theme, session restore
after a restart, signing in again after the session is rejected, logout, the
read-only account, and the proxy.

By default it runs the app as a Linux desktop build under Xvfb; the Dart code
and every HTTP call are the same as on Android. That needs `clang`, `cmake`,
`ninja-build`, `libgtk-3-dev`, `libsecret-1-dev` and `xvfb`. The system file
picker and "open with" chooser are replaced by a fake, since a test cannot
operate them.

To run it on an Android emulator instead, start the emulator and pass its id:

```sh
FB_E2E_DEVICE=emulator-5554 test/e2e/run_e2e.sh
```

The script then points the app at `10.0.2.2`, the emulator's address for the
host. If port 18080 or 18081 is taken on the host, set `FB_E2E_PORT` and
`FB_E2E_PROXY_PORT`. Screenshots are written by the app itself: on Android,
set `FB_E2E_SHOTS` to a writable app directory and copy the images using
`adb exec-out run-as org.buetow.filebrowser` while the test is running.
Flutter removes the test app and its files when the run finishes.

For a deployed test instance, run:

```sh
flutter test integration_test/app_test.dart -d emulator-5554 \
  --dart-define-from-file=/path/to/private-defines.json
```

The defines file supplies `FB_E2E_URL`, `FB_E2E_ADMIN_USER`,
`FB_E2E_ADMIN_PASS`, `FB_E2E_VIEWER_USER`, `FB_E2E_VIEWER_PASS`,
`FB_E2E_PROXY_URL`, `FB_E2E_PROXY_USER`, and `FB_E2E_PROXY_PASS`.
The username defaults are `admin` and `viewer`. Use dedicated test scopes
with the fixtures from `test/e2e/run_e2e.sh`; the tests modify files and
share links. The server's HTTPS certificate must be trusted by Android.

`integration_test/deployed_features_test.dart` runs additional GUI checks
with the same defines: protected shares, multi-select copy, move conflicts,
cancelled deletion, pull refresh, editor discard, all themes, native video
seeking, PDF page navigation, image pinch zoom, upload replacement cancellation,
and checksum copying. Add a playable `media/clip.mp4` to the seeded fixtures
before running it.
