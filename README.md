# Homelab Docker stack

My self-hosted services, run from one Docker Compose project on a single
server. Everything sits behind a Cloudflare Tunnel and a Traefik reverse
proxy, with single sign-on through Authelia backed by an LLDAP user
directory.

This is a personal setup, published for reference. It isn't a turnkey
template: paths, domains and accounts are mine and live outside the repo.

```
Internet ──► Cloudflare Tunnel (cloudflared)
                  │
                  ▼
              Traefik ──── TLS (Let's Encrypt, DNS challenge), security headers
                  │
                  ├──► Authelia forward-auth ──► most web UIs
                  │        └── LLDAP (users/groups), Postgres (state)
                  │
                  └──► apps with their own login + Authelia OIDC SSO
                           (Vaultwarden, Immich, Home Assistant, Linkwarden, …)
```

## Services

| Area | Services |
|---|---|
| **Core** | Traefik (reverse proxy), cloudflared (tunnel), Authelia (SSO, 2FA, OIDC provider), LLDAP (users), two Docker socket proxies (read-only / restart-only), deunhealth (restarts unhealthy containers), Diun (update notifications), Dozzle (logs) |
| **Data** | Postgres (shared, one database and user per app), Valkey/Redis (Immich), pgAdmin |
| **Books and downloads** | Grimmory (library), Chaptarr (ebook/audiobook manager), Prowlarr + FlareSolverr (indexers), qBittorrent and Mousehole, all inside a Gluetun WireGuard VPN container |
| **Personal data** | Immich (photos), Vaultwarden (passwords), FileBrowser (files), CouchDB (Obsidian LiveSync), Home Assistant |
| **Organisation** | Mealie (recipes), Linkwarden (bookmarks), Leantime (projects) |
| **Other** | FreshRSS (feeds), The Lounge (IRC), Crosswatch (watch-history sync), Ghost (blog) |

Disabled for now (still in the repo): Audiobookshelf, Bookkeep, Mousetrap,
Watchtower (replaced by Diun).

## How it's secured

The short version. [`docs/decisions.md`](docs/decisions.md) has the reasoning
behind each point.

- **Authelia by default.** It's deny-by-default; apps behind forward-auth need
  an explicit rule. Apps with mobile clients use their own login plus an OIDC
  client that requires two-factor and PKCE.
- **No secrets in the repo or in environment variables.** Every password, key
  and token is a file in `secrets/`, mounted as a Docker secret. Apps without
  `*_FILE` support load them through a small wrapper entrypoint.
- **Network isolation.** Only Traefik publishes ports (80/443). Each database
  sits on its own internal-only network, reachable only by the apps that use
  it.
- **Minimal privileges.** Every container runs with `no-new-privileges`,
  `cap_drop: ALL` (plus only what its image needs) and Docker's default
  AppArmor profile. Nothing has write access to the Docker API.
- **Pinned versions.** Every image is pinned to an exact version. Diun emails
  when newer releases appear, and updates are applied by hand.

## Layout

```
compose.yaml                  networks, secret declarations, includes
compose/<service>/<service>.yaml   one file per service
compose/authelia/configuration.yml Authelia config (a Go template)
.env.example                  all settings; site values blanked (tracked)
.env                          generated from .env.example (not tracked)
secrets/                      secret files (not tracked)
scripts/                      helpers (below)
templates/template.compose.yaml    starting point for a new service
docs/                         decisions and journal
```

## Configuration

Settings live in **`.env.example`**: one `###SERVICE### <project link>` section
per service, with every image version pinned there. Values specific to my site
(domains, paths, providers) are in a `###SITE###` block at the top and blanked
as `CHANGE_ME`.

- **First run:** `cp .env.example .env && chmod 600 .env`, then fill in the
  SITE block.
- **To change a setting:** edit `.env.example`, then run
  `scripts/apply-env-example.sh`. It rebuilds `.env` from the template,
  keeping only the SITE values, and stops if `.env` was edited by hand.

## Scripts

| Script | What it does |
|---|---|
| `apply-env-example.sh` | Rebuild `.env` from `.env.example`, keeping the SITE values. |
| `make-env-example.sh` | The reverse: regenerate `.env.example` from `.env`. Recovery only. |
| `env-to-secret.sh` | Move a value from `.env` into a secret file without printing it. |
| `authelia-hash-oidc-secrets.sh` | Generate Authelia's PBKDF2 digests of the OIDC client secrets. |
| `hooks/pre-commit` | Block commits containing `.env*`, `secrets/` or site values. Enable with `git config core.hooksPath scripts/hooks`. |

## Common tasks

```sh
docker compose config -q                    # validate (should print nothing)
docker compose up -d                        # apply changes
docker compose up -d --force-recreate <svc> # recreate one service

# Updating a service after a Diun email:
#   bump its *_VERSION in .env.example, then
scripts/apply-env-example.sh && docker compose up -d <svc>
```

To add a service, copy `templates/template.compose.yaml` to
`compose/<name>/<name>.yaml`, add a section to `.env.example`, include the file
in `compose.yaml`, and (if it sits behind forward-auth) add an Authelia access
rule.
