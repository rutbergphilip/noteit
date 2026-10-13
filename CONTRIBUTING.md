# Contributing to NoteIt

Thanks for your interest in NoteIt. This guide covers how to get a dev build running, what we expect in a pull request, and how sign-off works.

By taking part, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Please report security issues privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## Dev setup

You need:

- macOS 14 Sonoma or later.
- Xcode 16 or later. The Command Line Tools can build the app, but they don't ship XCTest, so the tests need Xcode.
- Docker, but only for the optional live S3 tests.

There are no third-party dependencies, so there's nothing to install.

```sh
swift build                                   # debug build
swift run NoteIt                              # run the app unbundled
./scripts/build_app.sh                        # release .app → ~/Applications/NoteIt.app
```

**Use a scratch library while developing.** `NOTEIT_DATA_DIR` keeps a dev build away from your real notes:

```sh
NOTEIT_DATA_DIR=~/scratch/noteit swift run NoteIt
```

The older `INKWELL_*` names still work as a fallback. To try the Inkwell → NoteIt library migration without touching your real notes, debug builds accept `NOTEIT_APP_SUPPORT_DIR=<folder>` as a stand-in for `~/Library/Application Support`.

Debug builds also accept launch arguments for screenshots, such as `--debug-open-settings --debug-settings-tab sync` and `--debug-dark`, plus self-test environment variables. They're all listed in the [engineer section of the design handoff](docs/design/HANDOFF.md#11-for-engineers), which is also the best map of the architecture.

## Tests

```sh
# Unit tests (149 cases; the 3 live emulator tests are skipped)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# A subset
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SyncPlannerTests

# Live S3 tests against Floci emulators in Docker (Amazon S3 and Google Cloud Storage)
./scripts/live_s3_tests.sh [aws] [gcp]

# Live S3 tests against your own server, such as MinIO
NOTEIT_LIVE_S3_ENDPOINT=http://nas.local:9000 NOTEIT_LIVE_S3_BUCKET=noteit-test \
NOTEIT_LIVE_S3_ACCESS_KEY=… NOTEIT_LIVE_S3_SECRET=… NOTEIT_LIVE_S3_CREATE_BUCKET=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveS3EmulatorTests
```

- The app layer has no XCTest target. It's covered by the debug-only `NOTEIT_SYNC_SELFTEST=1` and `NOTEIT_EDITOR_SELFTEST=1` modes. Always run them with `NOTEIT_DATA_DIR` set.
- CI runs `swift build`, `swift test` and `swift build -c release` on every push and pull request to `main`. It can't run the live emulator tests, because the macOS runners have no Docker. If your change touches the S3 backend, run `./scripts/live_s3_tests.sh` locally and say so in the PR.

## Code style

- **Match the existing code.** Use the same structure, naming and SwiftUI/AppKit patterns as the surrounding files. Keep the package free of third-party dependencies.
- **Keep comments minimal.** Comment only where the reason isn't obvious from the code, such as a workaround or a platform quirk.
- **Keep the sync library platform-neutral.** `NoteItSync` uses Foundation, CryptoKit, CommonCrypto and Security only. Don't import AppKit or app types into it.
- **Keep changes focused.** Put one logical change in each PR, and leave unrelated refactors for a separate PR.
- **Write commit messages as [Conventional Commits](https://www.conventionalcommits.org/):** `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `ci:`, `perf:`, and so on. Add a scope when it helps, for example `fix(sync): …`.

## Pull requests

- **Sync, crypto or storage changes need tests.** Add or update cases in `Tests/NoteItSyncTests/`. Planner changes need a row in the decision-table tests. Changes to the on-disk or remote format must stay readable by existing libraries, or bump the format version deliberately and explain why. The `inkwell` in remote names (`inkwell/v1/`, `inkwell/.canary/`, `.inkwell-lock`, the key-check plaintext) is the protocol name from before the rename to NoteIt; don't change it.
- **UI changes need screenshots.** Include light and dark mode where relevant, and before and after shots if it's a change.
- **Check the build and tests:** `swift build` and `swift test` must pass.
- **Update the docs** when you change behavior. That means the README, the design handoff, or the sync spec.
- **Don't include secrets.** Never commit or paste real access keys, secrets or passphrases, including in test fixtures, logs or screenshots.

## Sign-off (DCO)

Every commit must be signed off under the [Developer Certificate of Origin](https://developercertificate.org/) (DCO):

```sh
git commit -s -m "fix(sync): handle empty listings"
```

This adds a `Signed-off-by: Your Name <you@example.com>` line, certifying that you wrote the change or otherwise have the right to submit it under the project's license.

**Why a DCO and not a CLA?** NoteIt is licensed under the AGPL-3.0-or-later, and there's no Contributor License Agreement. You keep the copyright to your contributions and license them to everyone under the same AGPL-3.0-or-later terms as the rest of the project. Nobody, including the maintainers, gets special rights to relicense your work. The sign-off is a lightweight record that you're allowed to contribute the code.

If you forgot to sign off on a commit in your PR, run `git commit --amend -s` for the latest commit, or `git rebase --signoff main` for several, on your own branch.

## License

By contributing, you agree that your contributions are licensed under the [GNU AGPL-3.0-or-later](LICENSE).
