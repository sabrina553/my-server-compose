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
for Traefik's `172.21.17.249` on `vpn_ui`; FileBrowser can't check, so it sits on `filebrowser_proxy`
with Traefik alone and no internet. Prowlarr and Chaptarr skip their login
(Auth Method: External); their UIs bind only to their fixed address on `arr`,
shared with Traefik alone, and they reach Postgres, qBittorrent and
FlareSolverr over outbound-only links. pgAdmin (9.18+) checks the sender like
FreshRSS (`WEBSERVER_TRUSTED_PROXIES`, Traefik's fixed `172.21.7.249` on
`proxy_internal`). Grimmory can do neither, so it uses OIDC. This also relies on Authelia
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

**Access by LLDAP group, always two-factor.** (2026-10-10; replaces "any
user, one_factor for everyday apps") LLDAP has several users, and before this
any of them could reach every admin UI. Every forward-auth rule and OIDC client
now names the groups it admits: `admin` for `*.int` and the admin paths;
`privliged_user` for FileBrowser, Chaptarr, Leantime, Immich, Vaultwarden and
Linkwarden; `user` for Mealie, Grimmory and FreshRSS; `house_guest` for Home
Assistant only. Groups don't nest in LLDAP, so each rule lists every group it
admits. One-factor went because Chaptarr has no login of its own, and with a
one-month remember-me, two-factor costs little.
- Vaultwarden's own password login still works for existing accounts; the
  group check only gates SSO. Vaultwarden needs the master password either way.

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
- Traefik, Dozzle and Diun use a read-only proxy that allowlists the exact
  paths each one needs (see below).
- deunhealth's proxy adds container restart, stop and kill (the image's
  `ALLOW_RESTARTS` covers all three). At worst that stops containers.
- Nothing in the VPN's namespace reaches either proxy. (2026-10-10; replaces
  "the VPN joins `socket_proxy_ro` for Mousetrap's port monitor") The access
  was judged acceptable because secrets never sit in plain env, but that
  reasoning is wrong: GET `/containers/{id}/archive` (`docker cp`) returns
  any file from any container, `/run/secrets` included. And Mousetrap didn't
  need it: no port-monitor stacks were configured, its restart and exec
  features need write access that nothing gets, and a stack works with a
  manual IP. So it has no Docker access, and Gluetun has no
  `FIREWALL_OUTBOUND_SUBNETS`.
- The read-only proxy allowlists paths per client. (2026-10-10; replaces
  linuxserver's GET-only proxy) "GET only" still let Traefik, Dozzle and Diun
  read any container's files (`archive`) and filesystem (`export`).
  `socket-proxy-ro` is now wollomatic/socket-proxy, with each client's
  allowed method + path regexes in labels on that client, taken from a
  debug-logged discovery run: Traefik lists, inspects and watches events;
  Dozzle also reads logs, stats and info; Diun lists running containers and
  inspects images. Container IDs must be hex, and image names can't contain
  `..`. Anything unlabelled is refused. deunhealth's proxy is still
  linuxserver: only deunhealth reaches it, and it has no internet access.
- Diun may inspect images (2026-10-10): without it, it watched nothing.
  Read-only, and the images are public; pulling, building and deleting are
  refused.

**Only Traefik publishes ports, and only on the LAN address.** (2026-10-10;
was "Traefik's 80/443 on every interface") Docker's iptables rules bypass the
host firewall, and a host port bypasses Cloudflare. `*.int` names resolve to
the server's LAN address (removing the ports entirely broke them), so 80/443
are published on `TRAEFIK__BIND_IP` only: not IPv6, not the Docker bridges.
The router must not forward 80/443 to it. Public names come through
cloudflared over `external`; torrent traffic arrives through the VPN tunnel.
HTTP/3 is off (no UDP port), and Traefik verifies backend TLS (no global
`insecureSkipVerify`; every backend is plain HTTP anyway).

**The VPN container is not on `external`.** (2026-10-10) Gluetun's HTTP proxy
had no login, and through it any app on `external` reached `socket_proxy_ro`
and the Docker API (tested: CrossWatch got `200`). Mousetrap's UI and API have
no login and listen on all addresses (hard-coded). So `vpn` gets the internet
from `vpn_egress` (nothing else on it), Traefik reaches its UIs over `vpn_ui`,
and FlareSolverr reaches the proxy over `vpn_proxy`, its only way out. What
can reach the namespace now: Traefik, Chaptarr, Prowlarr and FlareSolverr.
The proxy listens on all of vpn's networks, because Chaptarr and Prowlarr use
it as their own proxy (binding it to `vpn_proxy` alone broke their searches).
That's acceptable because vpn is on no socket-proxy network.

**LDAP only between Authelia and LLDAP.** (2026-10-10) LDAP is plaintext with
no rate limit on binds, and was reachable from every app on `external`. It now
listens only on LLDAP's fixed address on `lldap_backend`. LLDAP stays on
`external` for its web UI and SMTP.

**VPN-network containers use `network_mode: service:vpn`.** (2026-10-09)
With `container:vpn`, Compose doesn't recreate them when Gluetun is
recreated, and they're left attached to a network that no longer exists.

## Containers and updates

**Hardening baseline on every service:** `no-new-privileges`, `cap_drop: ALL`,
log rotation, and no `apparmor:unconfined`. (2026-10-09) Each service adds
back only the capabilities its image is known to need (learned by testing):

| Kind of image | cap_add |
|---|---|
| starts as root, chowns, drops to a user (official DBs, Ghost, Grimmory, Chaptarr, CouchDB, Valkey) | `CHOWN DAC_READ_SEARCH FOWNER SETGID SETUID` |
| LLDAP: checks `/data` is *writable* while root | `CHOWN DAC_OVERRIDE FOWNER SETGID SETUID` |
| linuxserver (Prowlarr, qBittorrent): init chowns `/run/<app>-temp` | `CHOWN FOWNER SETGID SETUID` |
| FreshRSS: entrypoint `chown -R` / `chmod -R` on `./data` | `CHOWN DAC_READ_SEARCH FOWNER SETGID SETUID` |
| Leantime (its documented set) | `NET_BIND_SERVICE CHOWN SETGID SETUID` |
| Linkwarden: root throughout | `CHOWN FOWNER` |
| pgAdmin: listens on 8080 with plain python since 9.18 | none extra; `PGADMIN_DISABLE_POSTFIX=true` so no `sudo` |

**No host sockets in containers; Home Assistant's exception removed.**
(2026-10-10; replaces "Home Assistant keeps `apparmor:unconfined` for host
D-Bus/Bluetooth") Containers run as host root (no userns-remap), and the
host's system D-Bus treats them as root, so an app with `/run/dbus` can have
systemd run any command on the host. `:ro` doesn't restrict a socket. Home
Assistant has no Bluetooth integration; if one is ever needed, use an ESPHome
Bluetooth proxy.

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
