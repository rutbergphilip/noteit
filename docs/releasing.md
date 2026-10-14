# Releasing NoteIt

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml) when a `vX.Y.Z` tag is pushed. The workflow builds a universal app, signs it with the Developer ID certificate, notarizes and staples the app and a DMG, publishes a GitHub Release with the version's notes from [`CHANGELOG.md`](../CHANGELOG.md), uploads a signed Sparkle appcast, and updates the Homebrew cask in [rutbergphilip/homebrew-tap](https://github.com/rutbergphilip/homebrew-tap).

## One-time setup

The workflow reads these repository secrets. A tag build stops before building anything if a secret it needs is missing, so an unsigned build is never published and a release never stops halfway. Every secret is required for full releases; pre-releases don't need `HOMEBREW_TAP_DEPLOY_KEY`.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate and private key, as a base64 `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you gave the `.p12` export |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer team ID |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `NOTARY_KEY_P8_BASE64` | The API key's `.p8` file, base64 |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key that signs updates |
| `HOMEBREW_TAP_DEPLOY_KEY` | SSH private key of a deploy key with write access to the tap |

### Developer ID certificate

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list), create a **Developer ID Application** certificate (or use the one you have) and install it in your login keychain.
2. In Keychain Access, open *My Certificates*, select the *Developer ID Application: …* certificate together with its private key, choose **File › Export Items…**, save it as `DeveloperID.p12` and set a strong password.
3. Store it:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64
   gh secret set DEVELOPER_ID_CERT_PASSWORD     # paste the export password
   gh secret set APPLE_TEAM_ID --body ABCDE12345
   rm DeveloperID.p12
   ```

### Notarization API key

1. In [App Store Connect › Users and Access › Integrations › Team Keys](https://appstoreconnect.apple.com/access/integrations/api), create a key with the **Developer** role.
2. Note the **Key ID** and the **Issuer ID** shown above the key list, and download `AuthKey_<KEYID>.p8`. It can only be downloaded once.
3. Store it:

   ```sh
   gh secret set NOTARY_KEY_ID --body <KEYID>
   gh secret set NOTARY_ISSUER_ID --body <ISSUER-UUID>
   base64 -i AuthKey_<KEYID>.p8 | gh secret set NOTARY_KEY_P8_BASE64
   ```

   Keep the `.p8` somewhere safe, such as a password manager, or revoke the key and create a new one if it's lost.

### Sparkle signing key

Updates are signed with an Ed25519 key pair that already exists. The public key is committed as `SUPublicEDKey` in `scripts/build_app.sh`. The private key is in the maintainer's login keychain, as a *https://sparkle-project.org* item with the account `noteit`, on the Mac where the pair was created. On that Mac, export it with `generate_keys` from the [Sparkle release](https://github.com/sparkle-project/Sparkle/releases) (`bin/generate_keys`), check it against a built app, and store it:

```sh
(umask 077 && ./bin/generate_keys --account noteit -x sparkle-private-key)
./scripts/check_sparkle_key.sh sparkle-private-key ~/Applications/NoteIt.app
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key
rm sparkle-private-key
```

Never run `generate_keys --account noteit` without `-x` or `-p` on a Mac that doesn't have the key: it creates a new, different key pair. Every release run checks the secret with `scripts/check_sparkle_key.sh` and stops if it doesn't match `SUPublicEDKey`. The script needs OpenSSL 3 (`brew install openssl@3`), because the system LibreSSL has no Ed25519.

**Back up the private key**, for example in a password manager. Installed copies of NoteIt only accept updates signed with the key that matches their `SUPublicEDKey`. If the key is lost, or replaced with a new one, existing users stop getting updates and have to download a new version by hand once.

### Homebrew tap deploy key

```sh
ssh-keygen -t ed25519 -N "" -C "noteit release" -f tap_deploy_key
gh repo deploy-key add tap_deploy_key.pub --repo rutbergphilip/homebrew-tap --title "noteit release" --allow-write
gh secret set HOMEBREW_TAP_DEPLOY_KEY < tap_deploy_key
rm tap_deploy_key tap_deploy_key.pub
```

## Cutting a release

1. Make sure `## [Unreleased]` in `CHANGELOG.md` lists the user-facing changes. `git cliff --unreleased` (optional, configured in `cliff.toml`) prints the `feat`, `fix` and `perf` commits since the last tag as a starting point; rewrite them for users.
2. On an up-to-date, clean `main`, run:

   ```sh
   ./scripts/release.sh 1.2.0
   ```

   It checks the version is newer than the last tag, renames `## [Unreleased]` to `## [1.2.0] - <today>`, adds a new empty `## [Unreleased]`, updates the links at the bottom, commits `chore: release 1.2.0` and creates the annotated tag `v1.2.0`. Nothing is pushed.
3. Check the result with `git show v1.2.0`, then push:

   ```sh
   git push origin main v1.2.0
   ```

4. Watch the run with `gh run watch`. When it finishes, the release is on the [Releases page](https://github.com/rutbergphilip/noteit/releases), Sparkle offers it through `releases/latest/download/appcast.xml`, and `brew upgrade --cask noteit` picks it up.

### Pre-releases

`./scripts/release.sh 1.3.0-beta.1` only creates the tag `v1.3.0-beta.1` and leaves `CHANGELOG.md` alone; push it with `git push origin v1.3.0-beta.1`. It's published as a GitHub pre-release with the `## [Unreleased]` section as its notes, so Unreleased keeps collecting changes and the final 1.3.0 lists all of them. The Homebrew cask isn't updated, and Sparkle doesn't offer pre-releases, because the feed URL follows the latest full release.

### Dry run

To try the pipeline without publishing, for example before the signing secrets exist:

```sh
gh workflow run release.yml -f dry_run=true          # current default branch
gh workflow run release.yml -f dry_run=true --ref my-branch
```

A dry run runs the tests and builds the same universal app, ad-hoc signed and not notarized. It makes the DMG, takes the notes from the newest released section of the changelog (or `Unreleased` before the first release), and writes an appcast that is signed if `SPARKLE_PRIVATE_KEY` is set. The DMG, `appcast.xml` and `notes.md` are uploaded as a workflow artifact (`gh run download`). Nothing is released and the tap isn't touched.

## What the workflow does

1. Checks the tag is `vMAJOR.MINOR.PATCH[-prerelease]`, that `CHANGELOG.md` has a non-empty section for it, and that all secrets are set.
2. Runs `swift test`.
3. Imports the `.p12` into a temporary keychain, which is deleted at the end of the job even if it fails.
4. Builds with `NOTEIT_UNIVERSAL=1 NOTEIT_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build_app.sh`. The build number (`CFBundleVersion` and `sparkle:version`) is the time of the run in UTC to the second, `YYYYMMDDHHMMSS`. Sparkle uses it to decide what's newer: each run gets its own number, later runs get higher ones as long as the runner's clock is right, and its 14 digits are always higher than the 12-digit `YYYYMMDDHHMM` that local `build_app.sh` builds use by default, so a source build never looks newer than a release. Rebuilding the same tag gives a new build number. Release runs are serialized (one at a time across all tags and branches) so the numbers follow run order; while one runs, GitHub keeps only the newest waiting run and cancels older waiting ones, so push release tags one at a time.
5. Notarizes the app (zipped with `ditto`) with `scripts/notarize.sh`, which runs `xcrun notarytool submit --wait` and prints the notary log if it's rejected, then staples the app and checks it with `spctl -t exec` and `xcrun stapler validate`.
6. Makes `NoteIt-X.Y.Z.dmg` from the stapled app (`scripts/make_dmg.sh`), signs it, notarizes and staples it the same way, and checks it with `spctl -t open` and `xcrun stapler validate`.
7. Signs the final DMG for Sparkle (after checking the key matches the app's `SUPublicEDKey`) with `sign_update` from a checksum-pinned Sparkle download, and writes `appcast.xml` (`scripts/make_appcast.py`).
8. Creates the GitHub Release `NoteIt X.Y.Z` with the changelog section as its notes (`scripts/release_notes.sh`) and the DMG and appcast as assets.
9. For full releases, writes `Casks/noteit.rb` (`scripts/update_cask.sh`) and pushes it to the tap as `noteit X.Y.Z`.

To bump Sparkle's tools, change `SPARKLE_VERSION` and `SPARKLE_SHA256` at the top of the workflow (`shasum -a 256 Sparkle-<version>.tar.xz`).

## Troubleshooting

- **Missing secrets:** the first failing step lists every missing secret by name.
- **Notarization rejected:** the step prints the notary log, which lists each problem with its file path, such as a binary without the hardened runtime or a secure timestamp. To see the log of an earlier submission:

  ```sh
  xcrun notarytool history --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
  xcrun notarytool log <submission-id> --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
  ```

- **No Developer ID identity found:** the `.p12` must contain the private key, and the certificate's team must match `APPLE_TEAM_ID`. Export it again from *My Certificates*, not *Certificates*.
- **A step failed for an outside reason** (a notary service outage, a network error): `gh run rerun <run-id> --failed` reruns only the failed jobs, so a release that was already created isn't created twice. `gh workflow run release.yml --ref vX.Y.Z -f dry_run=false` starts a fresh release run for an existing tag.
- **A release failed after the tag was pushed:** fix the problem on `main`, delete the GitHub release if one was created, move the tag (`git tag -fa vX.Y.Z -m "NoteIt X.Y.Z" && git push -f origin vX.Y.Z`), or release a new patch version instead. Only move a tag if nobody has downloaded the release yet.
- **Tap push rejected:** check that the deploy key on `rutbergphilip/homebrew-tap` has write access and matches `HOMEBREW_TAP_DEPLOY_KEY`.
