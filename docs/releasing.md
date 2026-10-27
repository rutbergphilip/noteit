# Releasing NoteIt

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml) when a `vX.Y.Z` tag is pushed. The workflow builds a universal app, signs it with the Developer ID certificate, notarizes and staples the app and a DMG, publishes a GitHub Release with the version's notes from [`CHANGELOG.md`](../CHANGELOG.md), uploads a signed Sparkle appcast, and updates the Homebrew cask in [rutbergphilip/homebrew-tap](https://github.com/rutbergphilip/homebrew-tap).

## One-time setup

The workflow reads these repository secrets. A tag build stops before building anything if a secret it needs is missing, so an unsigned build is never published and a release never stops halfway.

| Secret | What it is | Needed |
|---|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate and private key, as a base64 `.p12` | always |
| `DEVELOPER_ID_CERT_PASSWORD` | The `.p12` password | always |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer team ID | always |
| `SPARKLE_PRIVATE_KEY` | Sparkle Ed25519 private key that signs updates | always |
| `HOMEBREW_TAP_DEPLOY_KEY` | SSH private key of a deploy key with write access to the tap | full releases |
| `APPLE_ID`, `APPLE_APP_PASSWORD` | Apple ID and an app-specific password, for notarization | one notarization method |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8_BASE64` | App Store Connect API key, for notarization | one notarization method |

Notarization uses the API key when all three of its secrets are set, and the Apple ID otherwise. The log says which one, and if neither set is complete the error lists what each one is missing.

### Developer ID certificate

You can create the certificate without Xcode. This needs OpenSSL 3 (`brew install openssl@3`) for `-legacy`, which makes a `.p12` the macOS keychain can import:

```sh
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
(umask 077 && "$OPENSSL" genrsa -out developer-id.key 2048)
"$OPENSSL" req -new -key developer-id.key -out developer-id.csr -subj "/emailAddress=you@example.com/CN=Your Name/C=SE"
```

1. In [Certificates, Identifiers & Profiles › Certificates](https://developer.apple.com/account/resources/certificates/list), click **+**, choose **Developer ID Application**, upload `developer-id.csr` and download the `.cer`.
2. Build the `.p12` with Apple's Developer ID intermediate certificate included, and set a strong password when asked:

   ```sh
   curl -fsSLO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
   "$OPENSSL" x509 -inform DER -in developerID_application.cer -out developer-id.pem
   "$OPENSSL" x509 -inform DER -in DeveloperIDG2CA.cer -out developer-id-ca.pem
   "$OPENSSL" pkcs12 -export -legacy -inkey developer-id.key -in developer-id.pem \
     -certfile developer-id-ca.pem -name "Developer ID Application" -out DeveloperID.p12
   ```

3. Store it, then keep `DeveloperID.p12` and its password in a password manager and delete the other files:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64
   gh secret set DEVELOPER_ID_CERT_PASSWORD     # paste the .p12 password
   gh secret set APPLE_TEAM_ID --body ABCDE12345
   ```

If the certificate is already in your login keychain, you can instead export it from Keychain Access (*My Certificates*, select it with its private key, **File › Export Items…**).

### Notarization: Apple ID (simplest)

1. At [appleid.apple.com](https://appleid.apple.com), go to **Sign-In and Security › App-Specific Passwords**, and create one named "NoteIt notarization".
2. Store it with the Apple ID of your developer account:

   ```sh
   gh secret set APPLE_ID --body you@example.com
   gh secret set APPLE_APP_PASSWORD     # paste the app-specific password
   ```

Revoke the password at the same place if it leaks; changing your Apple ID password also revokes it.

### Notarization: App Store Connect API key (alternative)

An API key isn't tied to your Apple ID password. The first time, an Account Holder has to click **Request Access** in App Store Connect › Users and Access › Integrations.

1. Under [Integrations › Team Keys](https://appstoreconnect.apple.com/access/integrations/api), create a key with the **Developer** role.
2. Note the **Key ID** and the **Issuer ID**, and download `AuthKey_<KEYID>.p8`. It can only be downloaded once.
3. Store it:

   ```sh
   gh secret set NOTARY_KEY_ID --body <KEYID>
   gh secret set NOTARY_ISSUER_ID --body <ISSUER-UUID>
   base64 -i AuthKey_<KEYID>.p8 | gh secret set NOTARY_KEY_P8_BASE64
   ```

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

### Web app: release signing key and image visibility

The same tag also runs [`.github/workflows/web-release.yml`](../.github/workflows/web-release.yml), which needs two
things once.

**A minisign key pair** that signs the web client's manifest (`web-client-X.Y.Z.json`). You, the maintainer, keep
the secret key; nobody else sets the secret.

```sh
brew install minisign
minisign -G -W -p scripts/noteit-release.pub -s noteit-release.key   # -W: no password; the secret is the protection
gh secret set MINISIGN_KEY < noteit-release.key
git add scripts/noteit-release.pub && git commit -m "chore: web release signing key"
```

Keep `noteit-release.key` in a password manager and delete the file. If you'd rather keep a password on it, drop
`-W` and also `gh secret set MINISIGN_PASSWORD`. `scripts/noteit-release.pub` is what `verify-web-client.mjs`
checks against, and the workflow prints it in every release's notes. A tag build without `MINISIGN_KEY` or without
`scripts/noteit-release.pub` stops before publishing anything web-related. Rotating the key means committing the new
public key and saying so in the release notes, since older checkouts keep trusting the old one.

**Public image.** The workflow pushes `ghcr.io/rutbergphilip/noteit-web` with the repository's `GITHUB_TOKEN`
(`packages: write`); no secret is needed. The image's `org.opencontainers.image.source` label links the package to
this repository. A new GHCR package starts private, and Actions can't change that, so after the first release:
open the package (Profile › Packages › noteit-web, or the repository's Packages sidebar) › Package settings ›
Change visibility › **Public**. The workflow's last image step checks for an anonymous pull and warns until this
is done. It's needed once per package.

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

The web workflow has the same switch: `gh workflow run web-release.yml -f dry_run=true` builds the static client,
its manifest (signed with a throwaway key unless `MINISIGN_KEY` is set) and the image for both architectures,
smoke-tests the amd64 image, and uploads the tarball and manifest as a workflow artifact. Nothing is pushed to
GHCR and no release is touched.

## What the workflow does

1. Checks the tag is `vMAJOR.MINOR.PATCH[-prerelease]`, that `CHANGELOG.md` has a non-empty section for it, and that all secrets are set, and picks the notarization method.
2. Runs `swift test`.
3. Imports the `.p12` into a temporary keychain, which is deleted at the end of the job even if it fails.
4. Builds with `NOTEIT_UNIVERSAL=1 NOTEIT_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build_app.sh`. The app itself is signed with `Resources/NoteIt.entitlements`, which only grants Apple Events (`com.apple.security.automation.apple-events`) so it can import from the Notes app; `Info.plist` gets the matching `NSAppleEventsUsageDescription`. Sparkle's helpers are signed without it. Local ad-hoc builds get the same entitlement, so `codesign -d --entitlements - build/NoteIt.app` shows it either way. The build number (`CFBundleVersion` and `sparkle:version`) is the time of the run in UTC to the second, `YYYYMMDDHHMMSS`. Sparkle uses it to decide what's newer: each run gets its own number, later runs get higher ones as long as the runner's clock is right, and its 14 digits are always higher than the 12-digit `YYYYMMDDHHMM` that local `build_app.sh` builds use by default, so a source build never looks newer than a release. Rebuilding the same tag gives a new build number. Release runs are serialized (one at a time across all tags and branches) so the numbers follow run order; while one runs, GitHub keeps only the newest waiting run and cancels older waiting ones, so push release tags one at a time.
5. Notarizes the app (zipped with `ditto`) with `scripts/notarize.sh`, which runs `xcrun notarytool submit --wait` (credentials come from the environment, never the log) and prints the notary log if it's rejected, then staples the app with `scripts/staple.sh` (which retries, since Apple's ticket service can briefly fail right after notarization) and checks it with `spctl -t exec` and `xcrun stapler validate`.
6. Makes `NoteIt-X.Y.Z.dmg` from the stapled app (`scripts/make_dmg.sh`), signs it, notarizes and staples it the same way, and checks it with `spctl -t open` and `xcrun stapler validate`.
7. Signs the final DMG for Sparkle (after checking the key matches the app's `SUPublicEDKey`) with `sign_update` from a checksum-pinned Sparkle download, and writes `appcast.xml` (`scripts/make_appcast.py`).
8. Creates the GitHub Release `NoteIt X.Y.Z` with the changelog section as its notes (`scripts/release_notes.sh`) and the DMG and appcast as assets.
9. For full releases, writes `Casks/noteit.rb` (`scripts/update_cask.sh`) and pushes it to the tap as `noteit X.Y.Z`.

### The web workflow

`web-release.yml` runs on the same tag, alongside `release.yml`:

1. **bundle**: typechecks and tests the web workspace, builds the client with `NOTEIT_BUILD_ID=noteit-X.Y.Z` (a fixed
   build id keeps the build reproducible; `scripts/check_reproducible_build.sh` checks that in CI), and runs
   `scripts/build-web-client-manifest.mjs`. That starts the built server once to capture the page it serves at `/`
   and its CSP, writes the static client, and writes `web-client-X.Y.Z.json` (`{version, commit, csp, files}` with a
   SHA-256 per file). It packs `noteit-web-static-X.Y.Z.tar.gz` (sorted, fixed owner and mtime) and signs the
   manifest with `minisign -S`, then checks the signature and the unpacked tarball with `verify-web-client.mjs`.
2. **image**: builds `web/Dockerfile` for linux/amd64, runs it, waits for the health check, checks the setup token
   is logged, and runs `verify-web-client.mjs` against the container, so the image provably serves the signed
   client. Then it builds linux/amd64 and linux/arm64 and pushes `ghcr.io/rutbergphilip/noteit-web:X.Y.Z`, plus
   `:latest` for full releases (never for pre-releases).
3. **attach**: waits (up to two hours) for `release.yml` to create the GitHub Release, uploads the tarball, the
   manifest and its `.minisig` with `--clobber`, and appends a "Web app" section with the pull command, the
   verification command and the public key to the notes (once; a re-run doesn't add it twice).

Only `release.yml` creates the release, so the two workflows never race over it, and re-running either one is
safe: `release.yml` replaces its assets if the release exists, and `attach` replaces the web assets. If the Mac
release fails, `attach` times out; re-run it with `gh run rerun <run-id> --failed` once the release exists.

To bump Sparkle's tools, change `SPARKLE_VERSION` and `SPARKLE_SHA256` at the top of the workflow (`shasum -a 256 Sparkle-<version>.tar.xz`).

## Troubleshooting

- **Missing secrets:** the first failing step lists every missing secret by name.
- **Notarization rejected:** the step prints the notary log, which lists each problem with its file path, such as a binary without the hardened runtime or a secure timestamp. To see the log of an earlier submission:

  ```sh
  xcrun notarytool history --apple-id you@example.com --team-id ABCDE12345     # asks for the app-specific password
  xcrun notarytool log <submission-id> --apple-id you@example.com --team-id ABCDE12345
  ```

  With an API key, use `--key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>` instead.

- **No Developer ID identity found:** the `.p12` must contain the private key, and the certificate's team must match `APPLE_TEAM_ID`. Export it again from *My Certificates*, not *Certificates*.
- **A step failed for an outside reason** (a notary service outage, a network error): `gh run rerun <run-id> --failed` reruns only the failed jobs, so a release that was already created isn't created twice. `gh workflow run release.yml --ref vX.Y.Z -f dry_run=false` starts a fresh release run for an existing tag.
- **A release failed after the tag was pushed:** fix the problem on `main`, delete the GitHub release if one was created, move the tag (`git tag -fa vX.Y.Z -m "NoteIt X.Y.Z" && git push -f origin vX.Y.Z`), or release a new patch version instead. Only move a tag if nobody has downloaded the release yet.
- **Web release stopped at "Check signing key":** set `MINISIGN_KEY` and commit `scripts/noteit-release.pub` (see above), then `gh workflow run web-release.yml --ref vX.Y.Z -f dry_run=false`.
- **The image isn't pullable without logging in:** make the GHCR package public (see above).
- **Tap push rejected:** check that the deploy key on `rutbergphilip/homebrew-tap` has write access and matches `HOMEBREW_TAP_DEPLOY_KEY`.
