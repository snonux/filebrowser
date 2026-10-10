# Android releases for the snonux F-Droid repository

The [snonux F-Droid repository](https://github.com/snonux/fdroid) imports the
app's signed APKs from GitHub releases of `snonux/filebrowser`, and the store
text and icon from `filebrowser-android/fastlane/metadata/android` at the same
tag. The APKs keep the app's signing key; the F-Droid repository signs only
its index.

The server is released with `vX.Y.Z` tags, so the app uses `android-vX.Y.Z`.
The F-Droid sync only picks releases that carry APKs named
`filebrowser-android-vX.Y.Z-<abi>.apk`, so server releases are ignored.

## Signing key and secrets

This is set up; the steps are kept for a new machine or a lost secret.

The release key is in foostore as `keys/f-droid/filebrowser-release.jks.txt`,
with the keystore (`filebrowser-release.jks`) and `key.properties` attached.
Losing it means installed copies can no longer be updated, so never create a
second one. Its certificate has the SHA-256 fingerprint
`1C:A2:5C:7E:5A:AA:1E:CA:A0:60:86:57:F2:BF:A0:2A:EB:77:44:E2:F9:A9:95:F6:F9:75:56:10:4C:58:8A:51`.

1. Restore the key for local release builds (`storeFile` in `key.properties`
   points at `~/.config/filebrowser-android/release.jks`):
   ```fish
   set e keys/f-droid/filebrowser-release.jks.txt
   mkdir -p ~/.config/filebrowser-android
   foostore read $e/filebrowser-release.jks > ~/.config/filebrowser-android/release.jks
   foostore read $e/key.properties > filebrowser-android/android/key.properties
   chmod 600 ~/.config/filebrowser-android/release.jks filebrowser-android/android/key.properties
   ```
2. The release workflow reads the same key from repository secrets:
   ```fish
   function get; sed -n "s/^$argv[1]=//p" filebrowser-android/android/key.properties; end
   base64 -w0 (get storeFile) | gh secret set ANDROID_KEYSTORE -R snonux/filebrowser
   gh secret set ANDROID_KEY_ALIAS -R snonux/filebrowser --body (get keyAlias)
   gh secret set ANDROID_KEYSTORE_PASSWORD -R snonux/filebrowser --body (get storePassword)
   gh secret set ANDROID_KEY_PASSWORD -R snonux/filebrowser --body (get keyPassword)
   ```
   `-R` names the repository because in a fork checkout `gh` may otherwise
   pick the upstream one.
   Optionally set `FDROID_DISPATCH_TOKEN` (a fine-grained token with
   *Contents: read and write* on snonux/fdroid) so a release reaches F-Droid
   at once instead of within six hours.

With `android/key.properties` present, a local `flutter build apk --release`
is signed with the release key; without it, release builds use the debug key
and are for development only.

## Cut a release

1. Increment `version: X.Y.Z+N` in `pubspec.yaml`. `N` must exceed every
   earlier release; with `--split-per-abi` Flutter derives the per-ABI version
   codes from it.
2. Rewrite `fastlane/metadata/android/en-US/changelogs/default.txt`.
3. Commit and push to `master` (the default branch here is `master`, not
   `main`). Do not create or push a tag.
4. Start the release workflow on `master` with the new tag:
   ```fish
   gh workflow run android-release.yml -R snonux/filebrowser --ref master -f tag=android-vX.Y.Z
   ```
   Its first step, "Create the tag if it does not exist yet", reads
   `filebrowser-android/pubspec.yaml` at the head of the branch the run is
   started on (`--ref`), stops with an error if `android-v<version>` there is
   not the tag given, and otherwise creates the tag on that commit. Releases
   are started on `master`, so start the run only after the bump commit is on
   `master`. Agent sessions release this way too: they can start workflows
   but cannot push tags.

   This needs that step to be present in
   `.github/workflows/android-release.yml` on `master` on GitHub; check the
   remote branch, not the local checkout:
   ```fish
   git fetch origin; and git grep -c 'Create the tag if it does not exist yet' origin/master -- .github/workflows/android-release.yml
   ```
   This prints the file name with a count of 1
   (`origin/master:.github/workflows/android-release.yml:1`) when the step is
   present and prints nothing when it is missing. Without the step a manual
   run only rebuilds an existing tag, so a release then still needs a pushed
   `android-vX.Y.Z` tag. While the step is missing, the edited workflow is at
   `filebrowser-android/docs/android-release.yml`; install it from the
   repository root with
   `git mv -f filebrowser-android/docs/android-release.yml .github/workflows/android-release.yml`
   followed by a commit, and push that to `master`.
5. The workflow then builds `armeabi-v7a`, `arm64-v8a` and `x86_64` APKs,
   checks they are not debug-signed and attaches them to the release.
6. F-Droid picks the release up on its next six-hour run, or at once with
   `gh workflow run publish.yml -R snonux/fdroid`.

Running the workflow again with a tag that exists rebuilds that tag, e.g.
after fixing a secret; it never moves a tag. A tag pushed by hand still starts
the workflow as before, but is no longer needed.
