# NoteIt

A native macOS notes app (SwiftPM, `Sources/`) and a self-hosted web app (`web/`, Nuxt 4 + Nuxt UI) that read and write the same end-to-end encrypted store. Start with [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Standing rules

- **Feature parity.** Every user-facing feature change lands on both the Mac app and the web app, or is recorded in [docs/feature-parity.md](docs/feature-parity.md) with its status and reason. Keep that page current in the same change; `web/apps/web/test/parity.test.ts` checks that every native palette command and web command has a row.
- **Shared formats move together.** Synced or exported data (records, the noteit-doc body, `#tag`/`@due`/`@remind` tokens, the search language) changes only with the golden vectors updated and tested on both sides: `fixtures/golden/`, `Tests/NoteItCoreTests/Vectors/organise-vectors.json`, and the Markdown fixtures in `Tests/NoteItMarkdownTests/Fixtures/`. Port Swift behaviour into `web/packages/core` or `web/packages/doc`; never invent a web-only format. Data the Mac keeps only locally stays local: say so in the parity page instead of syncing it.
- **Web server endpoints** for the control plane are nuxt-safe-action actions in `web/apps/web/server/actions/`, using the zod schemas in `shared/schemas.ts`; `/api/storage/*` and `/s3` stay plain routes.
- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for user-facing changes, in its existing style.

## Checks

- Swift: `swift build`, `swift test` (or `swift test --filter <Suite>`).
- Web, from `web/`: `pnpm -r test`, `pnpm --filter @noteit/web typecheck`, `pnpm --filter @noteit/web build`.
- Scratch runs use `NOTEIT_DATA_DIR`; never touch `~/Library/Application Support/NoteIt`.
