# Decisions

Why things are the way they are. Read before changing anything structural;
if a change reverses one of these, update this file and say why.
Newest decisions at the bottom of each section; dates are when decided.

## Access and authentication

**Default deny in Authelia.** (2026-10-09) A subdomain behind the
`authelia@docker` middleware is unreachable unless a rule allows it. Every new
forward-auth router needs a matching rule in `configuration.yml`.

**No forward-auth for apps with mobile apps or browser extensions:**
Vaultwarden, Linkwarden, Immich, Home Assistant. (2026-10-09) Their clients make
API calls that can't follow Authelia's login redirect. They rely on their own
login, with SSO through a two_factor OIDC client, and password login turned
off where the app allows it.
- Vaultwarden's `/admin` and CouchDB's `/_utils` and `POST /_session` are the
  exception: they're browser-only, so each has its own router with forward-auth
  in front of just those paths.

**Header login (Authelia's `Remote-User`) only where nothing but Traefik can
send it.** (2026-10-09) FreshRSS checks the sender's address
(`TRUSTED_PROXY`, Traefik's `172.20.0.249`); qBittorrent skips its login only
for that address; FileBrowser can't check, so it sits on `filebrowser_proxy`
with Traefik alone and no internet. Grimmory, pgAdmin and the *arrs can't do
either, so they keep their own login or OIDC. This also relies on Authelia
never using `policy: bypass` for these hosts: on a bypass, Traefik passes a
client-supplied `Remote-User` straight through.

**No network-based bypass rules in Authelia.** (2026-10-09) Docker's gateway
and cloudflared's own address are inside the Docker subnets, so "from Docker"
doesn't mean "trusted". Containers talk to each other by container name and
never go through Traefik.

**PKCE (S256) required for every OIDC client except Leantime and
FileBrowser.** (2026-10-09) Neither app's OIDC client sends a
`code_challenge`; with PKCE required, login fails after Authelia. Both still
authenticate with a client secret and require two-factor, and FileBrowser is
also behind forward-auth. Re-check after upgrades.

**CouchDB sync uses JWT, not passwords.** (2026-10-09) This removes password
login from the public API, which had no rate limiting. The key is ES256, and
CouchDB holds only the public key. Tokens carry no roles: `roles_claim_name`
is set to a random name, because `roles_claim_path` rejects tokens that don't
have the claim. The sync user is a member of its database only.

**TOTP alongside passkeys in Authelia.** (2026-10-09) Android in-app web views
(the Home Assistant Companion app) can't use passkeys.

## Secrets and configuration

**Secrets only in `secrets/`, never in `.env` or plain environment
variables.** (2026-10-09) Anything that can inspect containers (Traefik,
Dozzle, Diun through the read-only socket proxy) can read plain environment
variables.
- Use the app's native `*_FILE` variable when it has one.
- Otherwise use a wrapper entrypoint that reads the file at start-up. This
  costs a copy of the image's original command in the compose file, which has
  to be re-checked on upgrades.

**`.env.example` is the source of truth; `.env` is generated.** (2026-10-09)
The repo is public and the server's `.env` holds site-specific values.
Settings are changed in the template, and `scripts/apply-env-example.sh`
rebuilds `.env` while keeping only the server's `###SITE###` values. Nobody
opens `.env` by hand.

**Secret files 444, folders 700.** (2026-10-09) Several images read their
secrets as a non-root user (MySQL as uid 999) or as root without permission
overrides (`cap_drop: ALL`). Locking the folders keeps host users out.

## Network and Docker API

**One internal-only network per backend.** (2026-10-09) It holds just the
backend and the apps that use it. A compromised app reaches only its own
database: Redis (no password) is reachable by Immich only, each MySQL or
MariaDB by its one app, and Postgres by its nine users.

**Authelia's sessions live in their own Valkey.** (2026-10-09) In memory,
every Authelia restart logged everyone out. `authelia-redis` is password-
protected, persists to disk (AOF) and sits on its own internal network with
Authelia only. Immich's Redis isn't reused: it has no password, and sharing it
would bridge two backends.

**Traefik routes over `external` by default.** (2026-10-09) It has a fixed
address there (`172.20.0.249`) so backends can trust exactly one proxy.
Services with no internet access use `proxy_internal` and say so with a label.

**Nothing has general write access to the Docker API.** (2026-10-09) Write
access is effectively root on the host.
- Traefik, Dozzle and Diun use a GET-only proxy.
- deunhealth's proxy adds container restart, stop and kill (the image's
  `ALLOW_RESTARTS` covers all three). At worst that stops containers.
- Nothing on the VPN's network can reach deunhealth's proxy. The VPN's
  namespace does reach the GET-only one (for Mousetrap's port monitor;
  changed 2026-10-09), which lets everything else in it (qBittorrent) read
  container config too. That's acceptable only because secrets never sit in plain env.

**No host-published ports except Traefik's 80/443.** (2026-10-09) Docker's
iptables rules bypass the host firewall. Torrent traffic arrives through the
VPN tunnel, not the host.

**VPN-network containers use `network_mode: service:vpn`.** (2026-10-09)
With `container:vpn`, Compose doesn't recreate them when Gluetun is
recreated, and they're left attached to a network that no longer exists.

## Containers and updates

**Hardening baseline on every service:** `no-new-privileges`, `cap_drop: ALL`,
log rotation, and no `apparmor:unconfined`. (2026-10-09) Each service adds
back only the capabilities its image is known to need; see the journal's
table. Home Assistant keeps `apparmor:unconfined` for host D-Bus/Bluetooth.

**Diun notifies; nothing updates automatically.** (2026-10-09) Watchtower
auto-updated floating tags and could delete volumes
(`WATCHTOWER_REMOVE_VOLUMES=true`). It also needed Docker API write access to
pull images. Diun only reads, and emails you.

**Every image pinned to an exact version in `.env.example`.** (2026-10-09)
Updates are deliberate and reviewable. Diun watches each repo for newer
version tags (with `diun.include_tags` for suffixed schemes). The exception is
Chaptarr, which only publishes `latest`; Diun watches its digest.

**Security headers on every HTTPS response.** (2026-10-09) HSTS (1 year,
including subdomains), nosniff, strict referrer policy, `SAMEORIGIN` framing.
HSTS can't be undone quickly, so every subdomain must stay HTTPS.
