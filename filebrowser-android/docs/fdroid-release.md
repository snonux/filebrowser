# Android releases for the snonux F-Droid repository

The [snonux F-Droid repository](https://github.com/snonux/fdroid) imports the
app's signed APKs from GitHub releases of `snonux/filebrowser`, and the store
text and icon from `filebrowser-android/fastlane/metadata/android` at the same
tag. The APKs keep the app's signing key; the F-Droid repository signs only
its index.

The server is released with `vX.Y.Z` tags, so the app uses `android-vX.Y.Z`.
The F-Droid sync only picks releases that carry APKs named
`filebrowser-android-vX.Y.Z-<abi>.apk`, so server releases are ignored.

## One-time setup

1. Move the workflows into place (an agent's token cannot write there):
   ```fish
   mkdir -p .github/workflows
   git mv ci/workflows/android-release.yml ci/workflows/android-ci.yml .github/workflows/
   git commit -m "ci: enable the Android workflows"; and git push
   ```
2. Create a release key outside the repository and keep a backup; losing it
   means installed copies can no longer be updated:
   ```fish
   mkdir -p ~/.config/filebrowser-android
   set pw (openssl rand -hex 16)
   keytool -genkeypair -noprompt -keystore ~/.config/filebrowser-android/release.jks \
     -storetype PKCS12 -alias filebrowser -keyalg RSA -keysize 4096 -validity 36500 \
     -dname "CN=File Browser" -storepass $pw -keypass $pw
   printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=filebrowser\nkeyPassword=%s\n' \
     ~/.config/filebrowser-android/release.jks $pw $pw > filebrowser-android/android/key.properties
   chmod 600 ~/.config/filebrowser-android/release.jks filebrowser-android/android/key.properties
   ```
3. Store it as repository secrets:
   ```fish
   function get; sed -n "s/^$argv[1]=//p" filebrowser-android/android/key.properties; end
   base64 -w0 (get storeFile) | gh secret set ANDROID_KEYSTORE
   gh secret set ANDROID_KEY_ALIAS --body (get keyAlias)
   gh secret set ANDROID_KEYSTORE_PASSWORD --body (get storePassword)
   gh secret set ANDROID_KEY_PASSWORD --body (get keyPassword)
   ```
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
3. Commit, then tag and push:
   ```fish
   git tag android-vX.Y.Z; and git push; and git push origin android-vX.Y.Z
   ```
4. The release workflow builds `armeabi-v7a`, `arm64-v8a` and `x86_64` APKs,
   checks they are not debug-signed and attaches them to the release.
5. F-Droid picks the release up on its next six-hour run, or at once with
   `gh workflow run publish.yml -R snonux/fdroid`.
