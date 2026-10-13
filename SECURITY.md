# Security Policy

## Reporting a vulnerability

**Please don't report security vulnerabilities in public issues, discussions or pull requests.**

Report them privately through GitHub instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**. This uses [GitHub private vulnerability reporting](https://github.com/rutbergphilip/noteit/security/advisories/new).

Include:

- what's affected
- the steps or a proof of concept to reproduce it
- the impact you expect
- the NoteIt commit and macOS version

**Never include real passphrases, access keys or secrets.** Use throwaway credentials and test data.

We'll acknowledge the report as soon as we can, keep you updated while we work on a fix, and credit you in the advisory unless you'd rather stay anonymous.

## Supported versions

NoteIt has no versioned releases yet. Only the latest `main` gets security fixes.

| Version | Supported |
|---|---|
| latest `main` | ✅ |
| anything older | ❌ |

## Scope

Reports about any part of the app are welcome. These areas matter most:

- **Crypto:** key derivation, AES-GCM sealing, AAD handling, and the passphrase check (`Sources/NoteItSync/Crypto/`, `Model/Manifest`).
- **The sync engine:** anything that lets the storage, or another party with write access to it, read notes, forge or replay records, corrupt or delete data, or make a client crash or misbehave (`Sources/NoteItSync/Engine/`, `Storage/`).
- **Storage backends:**
  - S3 request signing (SigV4)
  - the TLS requirements per provider
  - the `http://` exception for local MinIO / NAS servers
  - folder locking and atomic writes
- **Secrets handling:** the Keychain storage of credentials and the passphrase, and any leak of them into logs, `UserDefaults`, crash output or the remote store.
- **Local data:** the notes in `~/Library/Application Support/NoteIt/`, including recovery and the `.trash/` folder.

**Out of scope:**

- attacks that need an already-compromised Mac or user account
- the security of your chosen storage provider itself
- weak passphrases that you choose yourself

## Threat model summary

The full design is in [`docs/specs/2026-10-12-sync-design.md`](docs/specs/2026-10-12-sync-design.md). In short:

- **The storage provider is untrusted.** NoteIt runs no server. Sync goes through a folder or S3-compatible bucket you own, and NoteIt assumes whoever operates that storage can read and modify everything in it.
- **End-to-end encryption is on by default.** Every record is sealed with AES-GCM before upload, using a 256-bit key derived from your passphrase with PBKDF2-HMAC-SHA256 (210,000 iterations, random 16-byte salt). Turning encryption off is an explicit choice, and the setup screen warns about it.
- **The only plaintext data object is `manifest.json`.** It holds the format version, created date, salt, iteration count and a key-check value. Note and notebook contents, titles, tombstones and device records are all encrypted, and objects are named by random IDs. Besides the manifest, NoteIt writes a few contentless helper files unencrypted: `inkwell/.canary/<uuid>` on S3 (a capability probe, deleted afterwards on a best-effort basis), and `.inkwell-lock` and `.noteit-probe-*` in the folder backend. None of them contains note data. (`inkwell` in these names and in the `inkwell/v1/` prefix is the sync protocol name from before the rename to NoteIt; it stays so existing stores keep working.)
- **AAD is bound to object keys.** Each sealed object uses its key path (e.g. `notes/<id>.meta`) as AES-GCM additional authenticated data, so a ciphertext can't be swapped or replayed under a different key without failing authentication.
- **The passphrase lives in the Keychain and is never uploaded.** It's stored, along with any S3 credentials, as a generic password under the service `io.github.rutbergphilip.noteit.sync` (secrets saved by Inkwell under `com.inkwell.app.sync` move there on first read). A lost passphrase can't be recovered by anyone.

**Known limitations, which aren't vulnerabilities:**

- Storage can still see object counts, sizes and timing.
- Someone with write access to the storage can delete data or roll it back to an older state.
- Folders synced by third-party tools, and S3 providers that ignore conditional writes, get only best-effort protection against concurrent writers.
