# File Browser Android Agent Notes

This directory is the Flutter Android client for the File Browser server in
the repository root. It follows the layout and stack of the Player app
(`snonux/player`, `player-android/`): Flutter, Riverpod, go_router, Dio and
flutter_secure_storage.

- The app uses the server's existing REST API, the same one the web UI in
  `../frontend/src/api/` calls. Keep `lib/api/filebrowser_api.dart` aligned
  with `../http/http.go` and those web client calls; no server change is
  needed for the app.
- Android is touch and menu driven: keep actions easy to find, give controls
  clear labels and tooltips, and usable tap targets.
- Run `flutter analyze` and `flutter test`, then `test/e2e/run_e2e.sh`, which
  builds the server from this checkout and drives the app against it. Every
  user-facing feature has a step there.
- Platform access (file picker, download folder, opening files) goes through
  `lib/services/device_files.dart` so tests can replace it.
- "On this phone": `lib/services/local_files.dart` does the file work with
  plain `dart:io`, which needs `MANAGE_EXTERNAL_STORAGE` (all-files access);
  `MainActivity.kt` answers storage roots and the access request on the
  `org.buetow.filebrowser/storage` channel.
- "Edit in TurboNotes": `lib/services/external_edits.dart` downloads the
  file into the cache, `MainActivity.kt` lends it to TurboNotes
  (`org.buetow.turbonotes`) with `ACTION_EDIT` through `EditProvider.kt`
  (read/write grant), and every change TurboNotes writes is uploaded with
  `PUT /api/resources`. TurboNotes' side is in snonux/turbonotes
  (`ExternalDocuments.kt`); keep the `text/*` `ACTION_EDIT` contract.
- Do not commit the generated `linux/` runner, `android/key.properties`, key
  stores, or build output.
- Releases use `android-vX.Y.Z` tags; `vX.Y.Z` tags belong to the server. To
  release: bump `pubspec.yaml` and the fastlane changelog, commit, push to
  `master` (the default branch, not `main`), then start the release workflow
  with the tag, which creates it:
  `gh workflow run android-release.yml -R snonux/filebrowser --ref master -f tag=android-vX.Y.Z`.
  Do not create or push the tag with git. This needs the workflow on `master`
  to have the tag-creating step; see
  [docs/fdroid-release.md](docs/fdroid-release.md) for the check and the
  release steps.
