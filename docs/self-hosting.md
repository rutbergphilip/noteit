# Self-hosting the NoteIt web app

The NoteIt web app is a browser client plus a small server you run yourself. The browser encrypts every note
before it uploads it, so the server only stores ciphertext. One server can serve a household: each person gets an
account, their own passphrase and an isolated store, and the Mac app can sync with the same server.

This guide covers running the server with Docker or Node, putting it behind a reverse proxy, setting up the
first admin, connecting your Mac, backups and upgrades. For what the web app does and doesn't do yet, see
[web/README.md](../web/README.md) and the [feature parity](feature-parity.md) page.

## What you need

- A host that runs Docker (linux/amd64 or linux/arm64, so a Raspberry Pi 4 or 5 works), or Node.js 22.12 or later.
- A host name and **HTTPS**. Browsers only give web pages the encryption API (WebCrypto) on secure origins, so
  the web app doesn't work over plain `http://` except on `localhost`. A reverse proxy such as Caddy gets you a
  certificate in one line; on a LAN, use your proxy's internal CA or a DNS-challenge certificate.
- The server at the root of its own host name (`https://notes.example.com/`). Serving it under a path prefix
  (`https://example.com/notes/`) isn't supported.

## Release artefacts

Every release tag `vX.Y.Z` publishes:

| Artefact | Where |
|---|---|
| Docker image, linux/amd64 and linux/arm64 | `ghcr.io/rutbergphilip/noteit-web:X.Y.Z`, and `:latest` for full (non-pre-) releases |
| Static client, `noteit-web-static-X.Y.Z.tar.gz` | GitHub Release assets |
| Signed client manifest, `web-client-X.Y.Z.json` and `.json.minisig` | GitHub Release assets |

The image runs as uid 1000, keeps everything in the `/data` volume, and has a health check on
`/api/health/live`. The static tarball is the exact client the image serves (see
[Verifying the client](#verifying-the-client)); the web app still needs the server for sign-in and sync.

## Run it with Docker

```sh
docker volume create noteit-data
docker run -d --name noteit --restart unless-stopped \
  -p 127.0.0.1:3000:3000 \
  -v noteit-data:/data \
  -e NOTEIT_PUBLIC_URL=https://notes.example.com \
  -e NOTEIT_TRUST_PROXY=true \
  ghcr.io/rutbergphilip/noteit-web:0.7.0
docker logs noteit 2>&1 | grep "setup token"
```

The port is bound to loopback because a reverse proxy on the same host serves it (next section). Use
`-p 3000:3000` if the proxy runs on another machine, and keep the port off the internet.

If you bind-mount a host directory instead of a named volume, make it writable by uid 1000:
`mkdir -p /srv/noteit && sudo chown 1000:1000 /srv/noteit`, then `-v /srv/noteit:/data`.

## Run it with Docker Compose

[`web/docker-compose.yml`](../web/docker-compose.yml) uses the published image and lists every setting with a
comment. Copy it to your server, edit `NOTEIT_PUBLIC_URL`, then:

```sh
docker compose up -d
docker compose logs noteit | grep "setup token"
```

`docker compose up -d --build` builds the image from a checkout of `web/` instead of pulling it.

To pin a version (recommended, so upgrades happen when you choose), put `NOTEIT_TAG=0.7.0` in a `.env` file next
to the compose file.

## Configuration

Every setting is an environment variable. The secrets also accept `<NAME>_FILE`, a path to a file holding the
value, for Docker or Compose secrets (the file must be readable by uid 1000).

| Variable | Default | Meaning |
|---|---|---|
| `NOTEIT_PUBLIC_URL` | (request host) | The URL people use, such as `https://notes.example.com`. State-changing requests must come from this origin, and cookies are `Secure` when it's `https://`. Set it in production. |
| `NOTEIT_SETUP_TOKEN` (`_FILE`) | generated | One-time token that creates the first admin. Unset: generated, printed in the log once and kept in `/data/setup-token` until it's used. |
| `NOTEIT_SESSION_SECRET` (`_FILE`) | generated | Key that signs session cookies. Unset: generated into `/data/session-secret`. Changing it signs everyone out. |
| `NOTEIT_TRUST_PROXY` | `false` | Trust `X-Forwarded-For` and `X-Forwarded-Proto` from a reverse proxy. Turn it on only behind one. |
| `NOTEIT_TRUSTED_PROXY_HOPS` | `1` | How many proxies append to `X-Forwarded-For`. The client address (for sign-in rate limits) is that many entries from the right. Cloudflare in front of Caddy is `2`. |
| `NOTEIT_DEFAULT_QUOTA_MB` | `10240` | Storage for each new account. Admins can change it per user. |
| `NOTEIT_DEFAULT_MAX_OBJECTS` | `100000` | Object count for each new account. |
| `NOTEIT_MAX_OBJECT_MB` | `50` | Largest single upload. Bigger requests are refused while streaming. |
| `NOTEIT_INVITE_TTL_HOURS` | `72` | How long invite links work. |
| `NOTEIT_PASSWORD_LOGIN` | `true` | Password sign-in. |
| `NOTEIT_SOURCE_URL` | this repository | The source link in About (the AGPL source offer). Point it at your fork if you change the code. |
| `NOTEIT_STORE` | `disk` | Where the encrypted stores live: `disk` (the data volume) or `s3` (an upstream bucket, see [Store notes in an S3 bucket](#store-notes-in-an-s3-bucket)). |
| `NOTEIT_S3_ENDPOINT`, `NOTEIT_S3_BUCKET` | — | The upstream S3 endpoint URL and bucket, with `NOTEIT_STORE=s3`. |
| `NOTEIT_S3_ACCESS_KEY_ID`, `NOTEIT_S3_SECRET_ACCESS_KEY` (`_FILE`) | — | The upstream credentials. |
| `NOTEIT_S3_REGION` | `us-east-1` | The upstream region. |
| `NOTEIT_S3_PREFIX` | (bucket root) | Key prefix in the bucket; stores go under `<prefix>/users/<USER-ID>/`. |
| `NOTEIT_S3_PATH_STYLE` | `true` | Path-style URLs; `false` for virtual-hosted buckets (`bucket.endpoint`). |
| `NOTEIT_STORE_TIMEOUT_S` | `120` | Timeout of each upstream request. |
| `NOTEIT_DATA_DIR` | `/data` | Where everything is stored. The image sets it; change it only when running without Docker. |
| `PORT`, `HOST` | `3000`, `0.0.0.0` | Listen address. |
| `NOTEIT_VERSION`, `NOTEIT_COMMIT` | set by the image | Shown in About and checked by the client verifier. Don't override them. |

## Store notes in an S3 bucket

By default each person's encrypted store is a directory in the data volume. With `NOTEIT_STORE=s3` the server
keeps them in a bucket instead, under `<NOTEIT_S3_PREFIX>/users/<USER-ID>/`, and the volume only holds accounts and
keys. The bytes are the same ciphertext either way.

```sh
-e NOTEIT_STORE=s3 \
-e NOTEIT_S3_ENDPOINT=https://s3.eu-north-1.amazonaws.com -e NOTEIT_S3_REGION=eu-north-1 \
-e NOTEIT_S3_BUCKET=my-noteit -e NOTEIT_S3_PREFIX=noteit-server \
-e NOTEIT_S3_ACCESS_KEY_ID=… -e NOTEIT_S3_SECRET_ACCESS_KEY_FILE=/run/secrets/s3_secret
```

The upstream must support **conditional requests**: `If-None-Match: *` and `If-Match` on `PUT`, `If-Match` on
`DELETE`, and a new ETag for every new content. Sync relies on them to never overwrite a newer note. At startup the
server checks this on `<prefix>/server-canary/` and refuses to start if a check fails, naming it in the log (for
example "it ignores If-Match on DELETE"). Amazon S3 supports all of them; check other providers before relying on
them, or keep the default disk store.

Other things to know:

- The server must be the only writer to its prefix. Don't point the Mac app, rclone or another server at the
  same prefix; the Mac syncs through the server's `/s3` endpoint instead.
- If the upstream can't be reached at startup, the server keeps running and retries every 10 seconds. Until then
  `/api/health` answers 503 and every other route except `/api/health/live` answers 503. After three failed
  requests in a row later on, `/api/health` answers 503 until a probe succeeds; requests meanwhile fail with
  `502 storeUnavailable`. The container is never restarted for this, since the health check is liveness only.
- Give the key access to that bucket (and prefix) only. Backups of the volume no longer include the stores; back up
  the bucket (versioning, replication or rclone) as well.

## Reverse proxy

Terminate TLS in a reverse proxy in front of NoteIt. Whatever you use:

1. **Keep the `Host` header.** The `/s3` endpoint checks AWS SigV4 signatures, which cover the host name the
   client used. A proxy that rewrites `Host` breaks Mac sync with "signature does not match".
2. **Allow large request bodies.** A note with images can be tens of MB. Allow at least `NOTEIT_MAX_OBJECT_MB`.
3. **Set `X-Forwarded-For` and `X-Forwarded-Proto`**, and set `NOTEIT_TRUST_PROXY=true`.
4. **Don't buffer or transform responses** in ways that change bytes (no HTML minifying or script injection by the
   proxy or a CDN): the client verifier would rightly report it as tampered, and the page's CSP blocks injected
   scripts anyway.

The web app doesn't use WebSockets or server-sent events; sync is ordinary HTTP requests, so no upgrade headers or
long timeouts are needed.

### Caddy

```caddy
notes.example.com {
	request_body {
		max_size 60MB
	}
	reverse_proxy 127.0.0.1:3000
}
```

Caddy gets a certificate automatically, keeps `Host` and sets the `X-Forwarded-*` headers by default.

### nginx

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name notes.example.com;
    ssl_certificate     /etc/letsencrypt/live/notes.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/notes.example.com/privkey.pem;

    client_max_body_size 60m;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;
    }
}
```

### Traefik

With Traefik in Docker, label the NoteIt service (and drop its `ports:`; Traefik reaches it on the Docker
network):

```yaml
services:
  noteit:
    image: ghcr.io/rutbergphilip/noteit-web:0.7.0
    environment:
      NOTEIT_PUBLIC_URL: "https://notes.example.com"
      NOTEIT_TRUST_PROXY: "true"
    volumes:
      - noteit-data:/data
    labels:
      - traefik.enable=true
      - traefik.http.routers.noteit.rule=Host(`notes.example.com`)
      - traefik.http.routers.noteit.entrypoints=websecure
      - traefik.http.routers.noteit.tls.certresolver=letsencrypt
      - traefik.http.services.noteit.loadbalancer.server.port=3000
```

Traefik keeps `Host` and sets `X-Forwarded-*`, and doesn't limit body size unless you add a `buffering`
middleware; if you do, set its `maxRequestBodyBytes` to at least `NOTEIT_MAX_OBJECT_MB`.

## First admin

On first start the server has no accounts and waits for setup. Everything except setup and the health checks is
closed until then.

1. Get the setup token: `docker logs noteit 2>&1 | grep "setup token"` (or `docker compose logs noteit`). It's
   logged once, when it's generated, and kept in `/data/setup-token` until it's used. If you set your own with
   `NOTEIT_SETUP_TOKEN` or `NOTEIT_SETUP_TOKEN_FILE`, use that; it isn't logged.
2. Open `https://notes.example.com`, paste the token, and choose the admin's username and password.
3. Choose your **encryption passphrase**. It's separate from the password: the password signs you in to the
   server, the passphrase encrypts your notes in the browser and never leaves it. Nobody, including the admin,
   can recover a lost passphrase. If your Mac already syncs a library to this account, use the same passphrase.

The token works once; the server deletes it after setup. Invite other people from Settings › Users (admins see
it): an invite is a link that works for `NOTEIT_INVITE_TTL_HOURS`. Each person chooses their own password and
passphrase, and nobody can read anyone else's notes.

## Sync your Mac with the server

The server speaks a small S3-compatible API at `/s3`, and the Mac app has a preset for it.

1. In the web app, open Settings › Account › S3 Access Keys and click **Create Key**. Copy the access key ID and
   the secret: the secret is shown once.
2. On your Mac, open NoteIt › Settings › Sync and choose **NoteIt Server**. It fills in bucket `noteit`, region
   `us-east-1` and path-style addressing. Enter:
   - Endpoint: `https://notes.example.com/s3`
   - Access key ID and secret from step 1
   - Your encryption passphrase (the same one the web app uses)

Each key opens only its owner's store, so every person's Mac syncs with their own library. Revoke a key in the web
app to cut off a Mac.

The web app needs the store to use the `noteit-doc` note format. A store a Mac created before that format shows
"Open NoteIt on your Mac once to finish setting up web access"; a current Mac upgrades it on its next sync.

## Backups

Everything is in the data volume:

| Path | What |
|---|---|
| `users/<USER-ID>/noteit/v1/…` | Each person's encrypted store. Safe to copy; useless without the passphrase. |
| `accounts.json` (mode 0600) | Accounts, password hashes and S3 key secrets. Treat it as a secret. |
| `session-secret` | The session key. Losing it only signs everyone out. |

For a consistent copy, stop the server, copy the volume, start it again:

```sh
docker stop noteit
docker run --rm -v noteit-data:/data:ro -v "$PWD":/backup alpine \
  tar -czf /backup/noteit-data-$(date +%F).tar.gz -C /data .
docker start noteit
```

A filesystem or volume snapshot (ZFS, Btrfs, LVM) of a running server also works. Restore by extracting the
archive into an empty volume owned by uid 1000.

To back up only your own notes without server access, use rclone against `/s3` with your S3 key: `type = s3`,
`provider = Other`, `endpoint = https://notes.example.com/s3`, `force_path_style = true`, `list_version = 2`,
`no_check_bucket = true`, path `noteit:noteit/noteit/`, and `rclone copy --checksum`.

## Upgrades

1. Read the release notes for the version you're moving to.
2. Back up the data volume.
3. Pull and recreate:

   ```sh
   # Compose: set NOTEIT_TAG to the new version, then
   docker compose pull && docker compose up -d
   # docker run: stop and remove the old container, then start the new tag with the same volume and settings
   docker pull ghcr.io/rutbergphilip/noteit-web:0.7.1
   docker rm -f noteit && docker run -d --name noteit … ghcr.io/rutbergphilip/noteit-web:0.7.1
   ```

4. Reload open browser tabs so they run the new client.

Run one server per data volume; two containers on the same volume can corrupt account data. Downgrading isn't
supported: restore the backup from before the upgrade instead.

## Run it without Docker

Build from the release tag (Node.js 22.12 or later and pnpm 10):

```sh
git clone --branch v0.7.0 https://github.com/rutbergphilip/noteit.git
cd noteit/web
pnpm install --frozen-lockfile
NOTEIT_BUILD_ID=noteit-0.7.0 pnpm --filter @noteit/web build
```

`apps/web/.output` is the whole app (its `node_modules` includes the argon2 binding built for this machine, so
build on the machine or architecture you run it on). Start it with:

```sh
NODE_ENV=production NOTEIT_DATA_DIR=/var/lib/noteit NOTEIT_PUBLIC_URL=https://notes.example.com \
  NOTEIT_TRUST_PROXY=true NOTEIT_VERSION=0.7.0 PORT=3000 HOST=127.0.0.1 \
  node apps/web/.output/server/index.mjs
```

A systemd unit:

```ini
[Unit]
Description=NoteIt web
After=network-online.target

[Service]
User=noteit
WorkingDirectory=/opt/noteit/web
Environment=NODE_ENV=production NOTEIT_DATA_DIR=/var/lib/noteit NOTEIT_VERSION=0.7.0
Environment=NOTEIT_PUBLIC_URL=https://notes.example.com NOTEIT_TRUST_PROXY=true HOST=127.0.0.1 PORT=3000
ExecStart=/usr/bin/node apps/web/.output/server/index.mjs
Restart=on-failure
StateDirectory=noteit
StateDirectoryMode=0700
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/noteit

[Install]
WantedBy=multi-user.target
```

## Health checks

| Endpoint | Answers |
|---|---|
| `GET /api/health/live` | `{"ok":true}` while the process serves requests. The image's Docker health check uses it. |
| `GET /api/health` | `{"ok":true,"mode":"server","needsSetup":…}`, or 503 `{"ok":false,"reason":"storeUnavailable"}` while an upstream S3 store is unreachable. Use it for readiness and uptime monitors. |

## Verifying the client

The browser runs whatever JavaScript the server sends, so a modified server could capture a passphrase. Each
release's client files are listed with their SHA-256 in `web-client-X.Y.Z.json`, signed with the maintainer's
minisign key (the public key is `scripts/noteit-release.pub` and is printed in every release's notes). From a
checkout of this repository:

```sh
node scripts/verify-web-client.mjs https://notes.example.com --expect 0.7.0
node scripts/verify-web-client.mjs https://notes.example.com --latest
node scripts/verify-web-client.mjs ./noteit-web-static-0.7.0 --expect 0.7.0   # an unpacked tarball
```

It downloads the signed manifest for the version **you** name (or the latest GitHub release), checks the
signature, and compares the server's page, its Content-Security-Policy and every client file. Always pass
`--expect` or `--latest`: the version the server claims is only compared, so an older client served as a
rollback fails unless you pass `--allow-older`. This is detection only: a server that targets you can serve honest
files to the verifier and different ones to your browser.

## Troubleshooting

- **Unlocking or creating a store fails over `http://`.** The browser withholds WebCrypto from insecure pages.
  Use HTTPS (see [What you need](#what-you-need)).
- **"Cross-origin request refused" (403) on sign-in or every save.** `NOTEIT_PUBLIC_URL` doesn't match the
  address in the browser. They must match exactly, scheme and port included.
- **Mac sync fails with a signature error.** The reverse proxy changes `Host`, or the endpoint in the Mac's
  settings doesn't match the public host name.
- **Uploads fail at a fixed size.** Raise the proxy's body limit (and `NOTEIT_MAX_OBJECT_MB` if needed).
- **Lost setup token.** Until setup is done it's in `/data/setup-token`:
  `docker exec noteit cat /data/setup-token`.
