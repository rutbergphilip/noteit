# NoteIt web (self-hosted)

A browser client for NoteIt and a small server you run yourself. The browser is a full sync peer of the Mac app:
it encrypts every note before upload, and the server only ever stores ciphertext. One server can serve a
household: everyone gets their own account, their own passphrase and their own isolated store.

The Mac app can sync with the same server through its existing S3 backend (the server speaks a small
S3-compatible subset at `/s3`).

> Status: first version. See "Not in this version" below.

## How it works

- **Encryption.** Notes use the same format as the Mac app (`noteit/v1/` store, AES-256-GCM, PBKDF2-SHA256).
  Your passphrase never leaves the browser. The server can't read notes, titles or tags.
- **Two secrets.** Your *password* signs you in to the server. Your *passphrase* encrypts your notes. Resetting a
  password doesn't touch the passphrase, and nobody (including the admin) can recover a lost passphrase.
- **Trust.** The browser runs whatever JavaScript the server sends. A modified server could capture your
  passphrase the next time you unlock. Use the web app only with a server you run or trust. The Mac app
  doesn't load code from the server.
- **Offline.** An encrypted copy lives in the browser's IndexedDB, so an open tab keeps working offline and
  syncs when it can.

## Run it

**[Self-hosting guide](../docs/self-hosting.md)**: Docker and Compose with the published image
(`ghcr.io/rutbergphilip/noteit-web`), every setting, reverse proxy examples (Caddy, nginx, Traefik), the first
admin, syncing your Mac through the NoteIt Server preset, backups, upgrades and running without Docker.

The short version:

```sh
docker run -d --name noteit -p 127.0.0.1:3000:3000 -v noteit-data:/data \
  -e NOTEIT_PUBLIC_URL=https://notes.example.com -e NOTEIT_TRUST_PROXY=true \
  ghcr.io/rutbergphilip/noteit-web:latest
docker logs noteit 2>&1 | grep "setup token"
```

Put it behind an HTTPS reverse proxy, open the site, paste the setup token and create the admin account.

## Develop

Node 22.12 or later and pnpm 10, from `web/`:

```sh
pnpm install --frozen-lockfile
pnpm dev                                   # Nuxt dev server; set NOTEIT_DATA_DIR to a scratch directory
pnpm -r test && pnpm -r typecheck          # tests and types for every package
pnpm --filter @noteit/web build            # production build in apps/web/.output
docker build -t noteit-web .               # the image (Dockerfile in this directory)
```

## Verify the client a server sends you

Each release signs a manifest of its client files with minisign. Check a server, or an unpacked
`noteit-web-static` tarball, against it from a checkout of this repository:

```sh
node scripts/verify-web-client.mjs https://notes.example.com --expect 0.7.0
```

Always pass `--expect <version>` or `--latest`; the version the server claims is only compared, never trusted.
This detects a modified client; it can't prove what a server that targets you serves to your browser. Details in
the [self-hosting guide](../docs/self-hosting.md#verifying-the-client).

## Not in this version

- Direct browser→S3 mode and OIDC sign-in.
- The multi-browser Playwright matrix and the native ⇄ web interop harness.
- Orphan-body sweep and "Clean up unused storage": superseded note bodies are deleted right after each
  publish; leftovers from interrupted publishes stay until a later version sweeps them.
- Sync-tool sidecar resolution (only relevant to folder stores, not this server).
- Remembering the key across reloads ("Remember on this device"): the web app always asks for the
  passphrase in a new tab.
- Editing legacy (RTFD) or locked notes: they're listed and can be pinned, moved and deleted, but their
  content opens read-only.
