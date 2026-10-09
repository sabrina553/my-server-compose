---
tags:
  - servers
---

# 2026-10-09 — Security Review and Hardening

A full-day pass over the Docker stack: a fresh-eyes security review, then
fixing everything it found, one item at a time, deploying and testing each on
the server before moving on. The evening went on to header logins, one
uniform compose layout, tooling to keep secrets off the screen, and a secret
rename. A log review after a full `down`/`up` the next day closed it out.

Nothing personal or secret is in this file: domains, usernames and values are
referred to by variable name only. The decisions behind all of this are in
[`docs/decisions.md`](../decisions.md).

---

## Where Things Started

The stack was already in decent shape:

- Authelia in front of most apps, **deny by default**, two-factor on `*.int`,
  login rate limiting, a password-strength check.
- Cloudflared → Traefik, with Traefik trusting `X-Forwarded-For` only from
  cloudflared's fixed IP.
- Most secrets already in `secrets/` as Docker secrets; Authelia stores only
  PBKDF2 digests of the OIDC client secrets.
- Git history clean (checked: nothing secret ever committed).

The review found four **High** issues (ways to bypass Authelia entirely, or
reach root on the host), five **Medium** and a few **Low**. All of them are now
fixed or deliberately accepted. Details below, in the order they were done.

---

## High

### 1. Gluetun Published Ports on Every Host Interface

**Problem:** `8080` (qBittorrent UI), `5010` (Mousehole), `39842` (Mousetrap)
and `8888` (Gluetun's HTTP proxy, no login) were bound to `0.0.0.0`. Docker's
iptables rules bypass the host firewall, so these skipped Traefik and Authelia,
and `8888` was an open proxy out through the VPN.

**Fix:** removed the whole `ports:` block from `gluetun.yaml`. Nothing needed it:

- Web UIs go through Traefik.
- FlareSolverr uses the proxy at `http://vpn:8888` over the Docker network.
- Torrent peers (and MAM's connectability check) arrive through the WireGuard
  tunnel via `FIREWALL_VPN_INPUT_PORTS`, not the host. Confirmed connectable
  afterwards.

### 2. A Path from qBittorrent to Root on the Host

**Problem:** Gluetun was on the `socket_proxy` network, and qBittorrent and
Mousehole share Gluetun's network stack. The socket proxy allowed `POST` +
`CONTAINERS`, which is enough to start a privileged container mounting `/`.
qBittorrent's "run external program" setting made that a short chain to root.
Traefik (internet-facing) had the same write access.

**Fix:**

- Gluetun taken off `socket_proxy`.
- Socket proxy split in two (`compose/socket-proxy/socket-proxy.yaml`):
  - `socket-proxy-ro`, GET only, network `socket_proxy_ro`: Traefik, Dozzle,
    Diun, and (from the evening) Mousetrap via the `vpn` namespace.
  - `socket-proxy`, network `socket_proxy`: originally Watchtower + deunhealth.
    Since Watchtower was replaced by Diun (see #8), it allows **GET + container
    restart/stop/kill only** (`POST=0`, `ALLOW_RESTARTS=1`; the image has no
    restart-only switch), for deunhealth.
- **End state: nothing in the stack can create or change containers through
  the Docker API.**
- `DOCKER_HOST_RO` has a fallback default in the compose files.

**Bonus fix found in Traefik's logs:** `aliasHeadersStrategy` was unset.
Lookalike headers (`Remote_User`, `Remote.User`) could spoof the `Remote-User`
header Authelia sets, for PHP backends like FreshRSS and Leantime. Set to
`delete` on `web` and `websecure`. (CVE-2026-88004, about request trailers, may
still be open in Traefik; worth watching release notes.)

### 3. Public Routes Relying on Weak App Settings

**Vaultwarden `/admin`**

- Admin token moved from a plaintext `.env` value to `ADMIN_TOKEN_FILE`
  (argon2 hash in a secret file).
- `/admin` now has its own Traefik router behind Authelia two-factor, plus a
  matching Authelia rule. The apps and extensions never use `/admin`, so the
  rest of Vaultwarden stays off forward-auth.
- Tested: works.

**Linkwarden**

- Registration was open (the `.env` setting was never passed through).
- Now set directly in `linkwarden.yaml`: `NEXT_PUBLIC_DISABLE_REGISTRATION=true`,
  `NEXT_PUBLIC_CREDENTIALS_ENABLED=false`. SSO only, with access tokens for the
  app/extension. No forward-auth (it breaks the clients).

**CouchDB (Obsidian LiveSync)**

- Fauxton (`/_utils`) and password login (`POST /_session`) moved behind
  Authelia two-factor via their own routers, plus an Authelia rule.
- Sync now uses **JWT** instead of passwords. Config file on the server:
  `<COUCHDB__VOLDIR>/config/local.d/zz-jwt.ini`.
  - ES256 key pair. The private key lives in each LiveSync client (and
    Vaultwarden). CouchDB holds only the public key, as `ec:livesync`.
  - Password login (`default_authentication_handler`) is removed.
  - `livesync` is a named member and admin of `obsidiandb` only. It has no
    password and no `_users` doc.
  - `require_valid_user = false` (otherwise Fauxton itself can't load), with
    every database restricted via `_security`, and `admin_only_all_dbs = true`.
  - `roles_claim_name = x_<random>` so tokens don't carry `_admin`. Note:
    `roles_claim_path` didn't work, because CouchDB rejects tokens missing that
    claim.
  - The `WWW-Authenticate` line in `docker.ini` is commented out, so there's no
    browser Basic-auth prompt.
- `scripts/couchdb-maintenance.sh` added for routine upkeep.

### 4. Authelia's Network Bypass Was Too Wide

**Problem:** a `bypass` rule for `/api` on Chaptarr, Prowlarr and qBittorrent
applied to all of `172.19.0.0/16` and `172.20.0.0/16`. That included the Docker
gateway, which LAN/IPv6 traffic to `:443` can appear to come from.

**Fix:** apps talk to each other directly over Docker networks
(`http://prowlarr:9696`, `http://chaptarr:8789`, `http://vpn:8080` for
qBittorrent), by service key. The bypass rule and `definitions.network` are
deleted. Also checked: qBittorrent's "bypass auth for whitelisted subnets" is
off. (In the evening Prowlarr and Chaptarr moved onto their own `arr`
network; see below.)

---

## Medium

### 5. Inline Secrets → Docker Secret Files

Every remaining secret in `.env` was moved into `secrets/`:

- **Read natively:** official MySQL (`MYSQL_*_PASSWORD_FILE`) for Ghost's and
  Leantime's databases; linuxserver MariaDB (`FILE__MYSQL_*`) for Grimmory's;
  Mealie and Vaultwarden (`*_FILE`); Gluetun (`WIREGUARD_*_SECRETFILE`).
- **Wrapper entrypoint** for apps that can't read files: Ghost, Leantime,
  Linkwarden, Chaptarr, Grimmory, FileBrowser, FreshRSS, Mousehole.
  - Pattern: `/bin/sh -c 'VAR=$$(cat /run/secrets/x) && export VAR && exec "$$@"' -- <original ENTRYPOINT>`,
    plus `command:` set to the image's original CMD, because overriding the
    entrypoint discards it.
  - Each file has a comment showing how to re-check the CMD after upgrades.
  - Verified: a missing secret file stops the container with a clear `cat:`
    error, instead of starting with a blank password.
- OIDC **client IDs** also come from the secret files now (same files Authelia
  reads).
- Linkwarden's `DATABASE_URL` is a secret file of its own.
- **Permissions:** secret files 444, folders 700. Containers can read their own
  files; nobody on the host can traverse the folders.
- **Naming** (evening): one scheme, Docker secret `<app>_<item>` is always the
  file `secrets/<app>/<item>`. 48 secrets renamed; see below.
- **Helper scripts:**
  - `scripts/env-to-secret.sh VAR path …`: copies a `.env` value into a secret
    file without printing it, and compares if the file already exists.
  - `scripts/authelia-hash-oidc-secrets.sh`: regenerates Authelia's
    client-secret digests. `--rotate <client>…` writes a new random client ID
    and secret (mode 444) and re-hashes only those clients. It prints only
    client names and file paths.

**Bugs fixed along the way**

- Leantime got the SMTP password file *path* as its password.
- Mealie's SMTP lines were missing `$`, and `SMTP_USER` pointed at a variable
  that doesn't exist, so Mealie email never worked.
- Leantime's app container received the MySQL **root** password it never needed.

### 6. Flat `internal` Network → Per-backend Networks

`internal` is gone. Every backend network is internal-only (no internet):

| Network | Members |
|---|---|
| `db_postgres` (172.21.2.0/24) | postgres + Authelia, LLDAP, Chaptarr, FreshRSS, Immich, Linkwarden, Mealie, Vaultwarden, pgAdmin |
| `immich_backend` (.3) | immich-server, redis, immich-machine-learning |
| `ghost_backend` (.4) | ghost, ghost-db |
| `leantime_backend` (.5) | leantime, leantime-mysql |
| `grimmory_backend` (.6) | grimmory, mariadb |
| `proxy_internal` (.7) | traefik (fixed `.249`), couchdb, pgadmin, dozzle |
| `authelia_backend` | authelia, authelia-redis (evening) |
| `filebrowser_proxy` | traefik, filebrowser (evening) |

- Traefik routes over `external` by default (`--providers.docker.network=external`).
  The `proxy_internal` services carry `traefik.docker.network=proxy_internal`.
- Redis (no auth) is now reachable by Immich only.
- Evening additions with internet access: `arr` (172.21.10.0/24: Traefik,
  Prowlarr `.10`, Chaptarr `.11`), plus the outbound links
  `chaptarr_downloads`, `prowlarr_downloads` (each with `vpn`) and
  `prowlarr_flaresolverr`.

### 7. Leantime Debug Mode

`LOG_LEVEL` follows the global setting. `LEAN_DEBUG=0` is set in the
compose file.

### 8. Supply Chain: Watchtower → Diun, Pinned Versions

- **Watchtower removed.** It auto-updated floating tags with
  `WATCHTOWER_REMOVE_VOLUMES=true`. Its compose file is kept, disabled, with a
  header explaining why.
- **Diun** (`compose/diun/diun.yaml`):
  - Read-only socket proxy. Checks registries every 6 h and emails `EMAIL_ADMIN`.
  - Workflow: Diun emails → bump the version in `.env.example` →
    `scripts/apply-env-example.sh` → `docker compose up -d <svc>`.
  - Default: report the newest plain `x.y.z` tag. Per-service
    `diun.include_tags` labels handle suffixed tags (`-openvino`, `-alpine`,
    `-stable`, `pg18-v…`, MySQL `8.0.x` / `8.4.x`, Redis `-bookworm`).
    Chaptarr has `diun.watch_repo=false`, because it only publishes `latest`.
  - Gotcha: `DIUN_NOTIF_MAIL_FROM` must be a bare address.
  - Gotcha (found 2026-10-10): it also needs `IMAGES=1` on the read-only
    proxy. Until then it watched nothing; see the log review.
- **Every image pinned to the exact version that was running**, in
  `.env.example`. The one exception is Chaptarr (only `latest` exists).
  pgAdmin and Leantime were looked up and pinned later in the day.

### 9. Container Hardening

Baseline everywhere: `no-new-privileges`, `cap_drop: ALL`, log rotation.
`apparmor:unconfined` was removed from everything except Home Assistant. The
server runs AppArmor, so this now actually applies Docker's default profile.

Capability sets (learned by testing):

| Kind of image | cap_add |
|---|---|
| starts as root, chowns, drops to a user (official DBs, Ghost, Grimmory, Chaptarr, CouchDB, Valkey) | `CHOWN DAC_READ_SEARCH FOWNER SETGID SETUID` |
| LLDAP: checks `/data` is *writable* while root | `CHOWN DAC_OVERRIDE FOWNER SETGID SETUID` |
| linuxserver (Prowlarr, qBittorrent): init chowns `/run/<app>-temp` | `CHOWN FOWNER SETGID SETUID` |
| FreshRSS: entrypoint `chown -R` / `chmod -R` on `./data` | `CHOWN DAC_READ_SEARCH FOWNER SETGID SETUID` |
| Leantime (its documented set) | `NET_BIND_SERVICE CHOWN SETGID SETUID` |
| Linkwarden: root throughout | `CHOWN FOWNER` |
| pgAdmin: listens on 8080 with plain python since 9.18 | none extra; `PGADMIN_DISABLE_POSTFIX=true` so no `sudo` |

`templates/template.compose.yaml` has the baseline built in.

---

## Your Original Two Items

- **Inline OIDC secrets in `.env`:** done (#5).
- **PKCE on the `TODO` clients:** all OIDC clients require PKCE with S256,
  **except Leantime and FileBrowser**. Neither sends `code_challenge` (Leantime
  500s without it), so they're `require_pkce: false` with a comment.

---

## Other Changes

- **Immich and Home Assistant** are off forward-auth, because their mobile apps
  can't do it. They rely on their own login plus the two_factor OIDC client.
  Immich password login is off. Both mobile apps tested.
- HA Companion app: Android's in-app web view can't use passkeys, so a
  **TOTP** method was added in Authelia for app logins.
- **Traefik fixed IP** `172.20.0.249` on `external` (cloudflared is `.250`), so
  backends can trust exactly Traefik:
  - FreshRSS `TRUSTED_PROXY` (now in the compose file, not `.env`: it decides
    who may assert the logged-in user)
  - HA `trusted_proxies: [172.20.0.249]`, set before `ip_ban_enabled` /
    `login_attempts_threshold`
- **Security headers** on every HTTPS response (middleware `secure-headers`):
  HSTS 1 year with subdomains (sticky!), nosniff, strict referrer policy,
  `SAMEORIGIN` framing.
- **Small fixes:** Mousehole only accepts its own hostname. Mealie local
  sign-up is off (OIDC sign-up still on). Mealie's theme colours are now
  actually passed through.
- **qBittorrent** uses `network_mode: service:vpn` (was `container:vpn`), so
  Compose recreates it whenever Gluetun is recreated. Otherwise it stays
  attached to the old, deleted network ("connection refused" on `vpn:8080`).
- **Ghost** cleaned up:
  - deleted the upstream example compose and its example `.env`
  - fixed the `mail__from=:` typo, which meant the From address was never set
  - the DB healthcheck no longer puts a password on the command line
- **`.env` rewritten:** 558 lines down to about 230.
  - One `###NAME### https://…` section per service, alphabetical.
  - Everything personal is in a `###SITE###` block at the top.
  - Zero secrets. Verified to render an identical config.
  - `.gitignore` ignores every `.env*` except `.env.example`.
  - Later in the day the direction flipped: see "Configuration" below.

---

## Later the Same Day

### Authelia

- **Consents remembered:** every OIDC client uses `consent_mode:
  pre-configured` with a one-year `pre_configured_consent_duration`.
- **Persistent sessions** in a Valkey of its own (`authelia-redis`, on
  `authelia_backend`), so a restart of Authelia no longer logs everyone out.
  - Fix after the first restart: Valkey's entrypoint runs `find /data … -exec
    chown` as root, and root without `DAC_READ_SEARCH` can't enter the
    `appendonlydir` (mode 700) that Valkey creates. The container looped, and
    Authelia (waiting for a healthy Valkey) took the stack with it. Sessions
    survived.

### No Second Login Behind Authelia

Apps behind forward-auth that had their own login now trust Authelia's
`Remote-User` header, but only where nothing except Traefik can reach them:

- **FreshRSS:** header login instead of a second OIDC round-trip.
- **FileBrowser:** header login, on `filebrowser_proxy` (Traefik and
  FileBrowser only). Its `config.yaml` was backed up first.
- **Prowlarr and Chaptarr:** `Auth Method: External`, UI bound to their fixed
  address on `arr` only. Neither is on `external` any more; outbound traffic
  goes over separate links whose addresses the UIs don't listen on.
- **pgAdmin:** webserver auth, accepting `Remote-User` only from Traefik's
  fixed `172.21.7.249` on `proxy_internal` (also in IPv4-mapped form, since it
  listens on `[::]`). Internal logins off, `config_local.py` mounted
  read-only. Port moved to 8080.

### Mousetrap and Mousehole

- **Mousetrap** fixed and re-enabled. It crashed at start because `LOGLEVEL`
  was set twice and uvicorn rejected the lower-case value; it now has its own
  `MOUSETRAP__LOGLEVEL`. Hardening restored, `apparmor:unconfined` dropped.
- Its port monitor reads containers through `socket-proxy-ro`, so the `vpn`
  container joins `socket_proxy_ro` (subnet added to Gluetun's
  `FIREWALL_OUTBOUND_SUBNETS`). The whole VPN namespace gets GET-only access;
  recorded as accepted in `decisions.md`.
- **Mousehole** disabled; Mousetrap replaces it.
- qBittorrent, Mousehole and Mousetrap get a healthcheck that fails when
  `tun0` is gone (a recreated Gluetun leaves them in a dead namespace;
  recreate, don't restart).

### One Layout for Every Compose File

- `templates/template.compose.yaml` defines key order, header comment,
  map-style `environment`, and what comes from `.env.example` (names,
  image/version, subdomain, paths, ports, settings) versus what stays in the
  compose file because it's the security model (hardening, networks and fixed
  IPs, bind addresses, trusted proxies, `.int` hostnames, `authelia@docker`).
- **Every** compose file follows it, disabled ones included. Containers reach
  each other by service key, never container name.
- Authelia's rules and OIDC redirect URIs read `{{ env "SUBDOMAIN_<APP>" }}`;
  `configuration.yml` has no hard-coded subdomains left.
- Bugs this surfaced: list-style env entries like `- VAR="${X}"` passed the
  quote characters as part of the value.
  - Immich got a quoted `TZ`, an invalid zone, so it ran on UTC.
  - FlareSolverr's `PROXY_URL` was literally `"http://vpn:8888"`.
  - Gluetun got quoted provider, countries, subnets, ports and `HTTPPROXY`.
  - Mealie's sender name and address included the quotes.
  - Leantime's `LEAN_LDAP_DEFAULT_ROLE_KEY` had a stray `;` (LDAP is unused).

### Configuration

- **`.env.example` is the source of truth.** `scripts/apply-env-example.sh`
  rebuilds `.env` from it, keeping only this server's SITE values, and stops
  on drift (someone edited `.env` by hand). `make-env-example.sh` is only for
  recovering from that.

### Secrets Renamed

- One scheme: Docker secret `<app>_<item>` = file `secrets/<app>/<item>`, with
  fixed item words (`db_password`, `oidc_client_id`, `oidc_client_secret`,
  Authelia's `oidc_<app>_digest`, …). 48 renamed, e.g. `homeassis_*` →
  `homeassistant_*`, `*_pg_password` → `*_db_password`, `wireguard_*` → `vpn_*`.
- `scripts/migrate-secret-names.sh` moved the files (`mv` only, never opened;
  dry run by default, `--reverse` to undo).
- Gotcha: Gluetun ignores `WIREGUARD_*_FILE`. It reads
  `WIREGUARD_*_SECRETFILE`, which defaults to `/run/secrets/wireguard_*`.
  That only worked because the old names matched; the three paths are now set
  explicitly.

### OIDC Credentials Rotated

New client IDs and secrets via `authelia-hash-oidc-secrets.sh --rotate` for
every client **except Grimmory, Immich and Home Assistant**, which need the
new values pasted into the app.

### Logs

- qBittorrent only wrote to its own log file; a linuxserver custom service
  (`compose/qbittorrent/custom-services.d`) now tails it to stdout for Dozzle.
- Vaultwarden no longer sets `LOG_FILE`; it kept a second, never-rotated copy
  in `/data`.

### Tooling and Docs

- `scripts/redact.sh` masks SITE values, `.env.redact` terms, e-mails,
  non-Docker IPs, hashes and tokens in piped output. A Claude Code
  PreToolUse hook (`.claude/hooks/redact-guard.py`) refuses log/inspect/git
  history/volume reads that aren't piped through it.
- `scripts/compose-diff.sh [--all] [<ref>]` shows what a change does to the
  rendered config. A pure layout change prints "No differences".
- Pre-commit hook (`scripts/hooks/pre-commit`) blocks staged SITE values,
  `.env*` and `secrets/`.
- `README.md`, `CLAUDE.md` and `docs/decisions.md` written.

---

## 2026-10-10: Log Review After a Full Restart

After `docker compose down` / `up`, every container was Up, and all with a
healthcheck were healthy. The logs showed:

**Fixed**

- **Diun watched nothing.** Every image inspect got `403 Forbidden` from
  `socket-proxy-ro` (`IMAGES=0`), so each run ended `added=0 … unchanged=0`.
  The earlier `diun notif test` only proved that mail works. Set `IMAGES=1`:
  still GET-only, so no pulling, building or deleting.
- **Chaptarr:** the three stuck pending imports were deleted from
  `PendingAuthorImport` (authors blacklisted, so they won't come back).

**Found, upstream**

- **Chaptarr's database is behind its code.** It stops at migration 107
  (2026-09-04); the image expects an `AudiobookMonitorExisting` column on
  `Authors` and `PendingAuthorImport` that no migration created (the start-up
  log shows `RebasedVersionCollisionSchemaRepair`, so upstream renumbered
  migrations). **Adding any new author fails** until that's fixed. Don't patch
  the schema by hand; report it upstream, or wait for an image that adds it.

**Noise, no action needed**

- Gluetun: `persisting public ip address: … permission denied` on every start.
  It creates the folder for that file without the execute bit, which root
  can't enter without `DAC_OVERRIDE`. Nothing reads the file, so it's
  ignored rather than given the capability. `PUBLICIP_FILE` moved back to its
  default on tmpfs (same error), and qBittorrent's unused mount of Gluetun's
  folder (for a retired healthcheck) is gone.
- Diun: `Cannot list tags` for `akane`'s image, which is built locally and is
  in no registry. It's outside this compose project, so it can't be labelled
  `diun.enable=false` here.

- Traefik: `middleware "authelia@docker" / "secure-headers@docker" does not
  exist` in the first second only, before Authelia registered. A start-up race.
- Authelia: two `408` timeouts, idle keep-alive connections from Traefik.
- cloudflared: QUIC blocked, falls back to HTTP/2. Works; see optional items.
- Valkey (both): `Memory overcommit must be enabled`. A host sysctl.
- FileBrowser: config uses the deprecated `loginMethod` field (migrated
  automatically).
- Grimmory: CORS allows `*`.
- Mousetrap: `ipdata lookup failed … HTTP 401` (no or invalid ipdata key).
- LLDAP `key_seed` notice, MySQL self-signed CA / pid-file warnings, Immich
  and The Lounge experimental-feature notices, pgAdmin's `sshtunnel`
  SyntaxWarning.
- Home Assistant: the Philips air purifier isn't reachable on the LAN, and a
  few phone sensors changed units (long-term stats paused for them).

---

## Accepted / Deliberately Left

- Leantime and FileBrowser without PKCE (they can't). They still have a client
  secret and two-factor.
- CouchDB `/_utils` is reachable by Dozzle and pgAdmin (they share
  `proxy_internal`). Fine: admin tools only, and CouchDB has its own auth.
- Linkwarden's archiver can still reach anything on its networks. Acceptable
  while it's single-user with registration closed.
- Everything in the VPN namespace (qBittorrent included) can read container
  and image metadata through `socket-proxy-ro`, for Mousetrap. Acceptable
  because no secret sits in plain env.
- Bookkeep (disabled): its old secrets were removed from `.env`. If it's ever
  revived: drop or re-password the `bookkeep` Postgres user, and give it new
  secrets (via a wrapper entrypoint) and its own Redis.

---

## Still to Do

### Finishing This Work

- [x] Re-check the rate-limited image tags, then
      `docker compose up -d --remove-orphans`.
- [x] Pin **pgAdmin** and **Leantime**, with `diun.include_tags` labels.
- [x] Diun mail works (`docker exec diun diun notif test`).
- [x] Diun actually watches: after `IMAGES=1`, `diun image list` shows every
      image.
- [ ] deunhealth with `POST=0`: no "forbidden" in its logs so far, but it
      hasn't had to restart anything yet. Check after the first real restart.
- [x] Home Assistant: `trusted_proxies` before `ip_ban_enabled` /
      `login_attempts_threshold`.
- [x] Delete `.env.bak-*` on the server.
- [x] Rotate OIDC client IDs/secrets: all file-based clients.
- [ ] Rotate **Grimmory, Immich, Home Assistant**, one at a time
      (`--rotate <client>`, then paste the new values into the app).
- [ ] Delete or check the old full backup of the stack in `/opt/bak`; it
      likely holds the pre-rotation `.env` and secrets.
- [ ] FileBrowser: delete the `config.yaml.bak-2026-10-09` backup from its
      volume after a few days of running fine.
- [ ] Chaptarr: report the missing `AudiobookMonitorExisting` migration
      upstream; until fixed, new authors can't be added.
- [ ] FreshRSS: delete the leftover `test-user`. Check whether `FOWNER` is
      really needed: `docker exec freshrss grep -nE 'chown|chmod' Docker/entrypoint.sh`.
- [ ] CouchDB (optional): LiveSync **Perform cleanup**, then **Compact** in
      Fauxton. Confirm **Check server requirements** *fails* in LiveSync,
      which proves the token isn't admin.
- [ ] Decide on `akane`: it lives outside this compose project, so none of
      this hardening applies to it. Any token it uses belongs in a secret
      file, not env.
- [ ] Watch Traefik releases for a fix to CVE-2026-88004.

### Optional Tidying (From the Log Review)

- [ ] cloudflared: allow outbound UDP 7844 for QUIC, and raise the UDP buffers
      (`net.core.rmem_max` / `wmem_max`), or pin `--protocol http2`.
- [ ] Host: `vm.overcommit_memory = 1` for Valkey.
- [ ] FileBrowser: move `loginMethod` to `account.loginMethod` in its config.
- [ ] Grimmory: set `app.cors.allowed-origins` to its own URL.
- [ ] Mousetrap: add an ipdata API key, or turn the lookup off.

### Your Own List

- [x] Authelia: remember consents.
- [x] Auto-login through forward-auth (`Remote-User`) where safe.
- [x] Tidy all compose files into one uniform layout.
- [x] Mousetrap re-enabled.
- [ ] Dozzle shows little or nothing for some containers. qBittorrent and
      Vaultwarden fixed; re-check CouchDB, CrossWatch, FreshRSS, Immich
      server, Leantime, Linkwarden and the socket proxies.
- [x] README.
- [x] Rename the secret files to one naming scheme.
- [x] Review the logs and find problems.
- [ ] Homepage.
- [ ] Manually go through each stack.
- [ ] Obsidian.
- [ ] Self-hosted AIOStreams (debrid / Nuvio): a new service; the template
      and conventions make it straightforward.
