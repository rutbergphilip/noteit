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

### Docker (recommended)

```sh
cd web
docker compose up -d --build
docker compose logs noteit | grep "setup token"
```

Open the site, paste the setup token, and create the admin account. Then choose your encryption passphrase.
If your Mac already syncs a library to this account (see below), use the same passphrase.

Edit `docker-compose.yml` first: set `NOTEIT_PUBLIC_URL` to the address people will use.

### Without Docker

Node 22.12 or later and pnpm 10:

```sh
cd web
pnpm install --frozen-lockfile
pnpm build
NOTEIT_DATA_DIR=./data NOTEIT_PUBLIC_URL=http://localhost:3000 node apps/web/.output/server/index.mjs
```

For development: `pnpm dev` (Nuxt dev server; set `NOTEIT_DATA_DIR`). Tests: `pnpm -r test`, types:
`pnpm -r typecheck`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `NOTEIT_PUBLIC_URL` | (request host) | The URL people use, e.g. `https://notes.example.lan`. Writes must come from this origin (CSRF). Set it in production. |
| `NOTEIT_DATA_DIR` | `/data` | Accounts, sessions secret and every user's encrypted store. |
| `PORT` | `3000` | Listen port. |
| `NOTEIT_SETUP_TOKEN` (`_FILE`) | generated | One-time token for the first admin. If unset, one is generated, logged once and stored in `/data/setup-token` until used. |
| `NOTEIT_SESSION_SECRET` (`_FILE`) | generated | HMAC key for session cookies; generated into `/data/session-secret` if unset. |
| `NOTEIT_PASSWORD_LOGIN` | `true` | Password sign-in. |
| `NOTEIT_DEFAULT_QUOTA_MB` | `10240` | Storage per new account. |
| `NOTEIT_DEFAULT_MAX_OBJECTS` | `100000` | Object count per new account. |
| `NOTEIT_MAX_OBJECT_MB` | `50` | Largest single upload. Bigger requests are refused while streaming, before they are buffered. |
| `NOTEIT_INVITE_TTL_HOURS` | `72` | How long invite links work. |
| `NOTEIT_TRUST_PROXY` | `false` | Trust `X-Forwarded-For` / `X-Forwarded-Proto` from a reverse proxy. Only turn this on behind a proxy. |
| `NOTEIT_TRUSTED_PROXY_HOPS` | `1` | How many proxies append to `X-Forwarded-For`. The client address (used for login rate limits) is that many entries **from the right**; anything further left was sent by the client and is ignored. Two proxies in a row (e.g. Cloudflare → Caddy) → `2`. |
| `NOTEIT_SOURCE_URL` | GitHub | Shown in About (AGPL source offer). |

## Reverse proxy

Terminate TLS in front of NoteIt. Two things matter:

1. **Keep the `Host` header.** `/s3` checks AWS SigV4 signatures, which include the host the client used.
2. **Allow large uploads.** Note bodies with images can be tens of MB; match `NOTEIT_MAX_OBJECT_MB`.

Caddy:

```
notes.example.lan {
  reverse_proxy 127.0.0.1:3000
}
```

nginx:

```nginx
location / {
  proxy_pass http://127.0.0.1:3000;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  client_max_body_size 60m;
}
```

With either, set `NOTEIT_TRUST_PROXY=true` and `NOTEIT_TRUSTED_PROXY_HOPS=1`.

## Sync your Mac with this server

1. In the web app: Settings → Account → S3 access keys → Create Key. Copy the secret (it's shown once).
2. In NoteIt on your Mac: Settings → Sync → S3-compatible:
   - Endpoint: `https://notes.example.lan/s3`
   - Bucket: `noteit` · Region: `us-east-1` · Path-style: on
   - Access key and secret from step 1, and your encryption passphrase.

Each key opens only its owner's store, so every Mac in a family syncs with its own library.

The web app needs the store to use the `noteit-doc` note format. A store the Mac created before it supported
that format shows "Open NoteIt on your Mac once to finish setting up web access"; a Mac with `noteit-doc`
support upgrades the store on its next sync, and the web app continues by itself. A store created by the web
app starts in the new format, so a Mac must support `noteit-doc` to open it.

## Backups

Everything is in the data volume:

- `users/<USER-ID>/noteit/v1/…` — encrypted stores (safe to copy; useless without the passphrase)
- `accounts.json` (mode 0600) — accounts, password hashes and S3 key secrets
- `session-secret` — rotating it signs everyone out

Back up the whole volume while the server is stopped, or snapshot it. To back up only your own notes, use
rclone against `/s3` (`type = s3`, `provider = Other`, `force_path_style = true`, `list_version = 2`,
`no_check_bucket = true`), path `noteit:noteit/noteit/`, with `rclone copy --checksum`.

## Not in this version

- Upstream S3 storage for the server (it stores on its own disk), direct browser→S3 mode, OIDC sign-in.
- Signed release manifest, the multi-browser Playwright matrix, the native ⇄ web interop harness.
- Orphan-body sweep and "Clean up unused storage": superseded note bodies are deleted right after each
  publish; leftovers from interrupted publishes stay until a later version sweeps them.
- Sync-tool sidecar resolution (only relevant to folder stores, not this server).
- Remembering the key across reloads ("Remember on this device"): the web app always asks for the
  passphrase in a new tab.
- Editing legacy (RTFD) or locked notes: they're listed and can be pinned, moved and deleted, but their
  content opens read-only.
