# Homelab Docker stack

Self-hosted services behind Cloudflare Tunnel → Traefik → Authelia (+ LLDAP).
Everything runs from this repo with Docker Compose. Read `README.md` for the
overview and `docs/decisions.md` before changing anything structural (don't
undo a decision without saying so). History is the git log; there are no
journals in this repo, so don't add any.

## Where this runs

This is the live server. The repo is checked out at `/opt/docker` on the `dev`
branch, edited through VS Code Remote-SSH, and changes take effect here
directly. Commit to `dev` and push. **The GitHub repo is public.**

## Hard rules

- **Never read anything under `secrets/`.** Not with cat, grep, head or diff,
  and not through a container. If a secret's value or format matters, give the
  user a command that prints only a length, a match/differ result, or a
  yes/no (see `scripts/env-to-secret.sh` for the style).
- **Treat `.env` as radioactive.** It's this server's real config. Don't open,
  cat, grep, diff or edit it, and never print values from it. To change a
  setting:
  1. edit `.env.example` (tracked, public; SITE values are `CHANGE_ME`)
  2. run `scripts/apply-env-example.sh`, which rebuilds `.env` from the
     template and keeps only this server's SITE values. Its output is key
     names only.
  3. `docker compose config -q`, then deploy.

  If the script reports drift (someone edited `.env` by hand), tell the user
  the key names and let them decide; don't `--force` on your own.
- **Never print secret values** from anywhere else either (container env,
  rendered config, logs). Refer to variables by name.
- **Pipe logs, `docker inspect`, git history and volume reads through
  `scripts/redact.sh`** (`… 2>&1 | scripts/redact.sh`). It masks the SITE
  values, `.env.redact` terms, e-mails, IPs, hashes and tokens. The
  PreToolUse hook `.claude/hooks/redact-guard.py` blocks those commands
  otherwise (it scans the whole command text, so edit files with the editor,
  not heredocs that mention them). Hand-written `sed` masking has leaked
  before; don't rely on it.
- **Nothing personal in tracked files.** No domains, hostnames, usernames,
  e-mail addresses, IPs outside Docker's 172.x ranges, providers or paths
  from the SITE block; use the variable names. The pre-commit hook
  (`scripts/hooks/pre-commit`, enabled with
  `git config core.hooksPath scripts/hooks`) blocks staged SITE values,
  `.env*` and `secrets/`. Don't bypass it with `--no-verify`.
- Confirm before anything destructive or hard to undo: deleting volumes or
  data, changing database passwords, `docker compose down`, editing the
  CouchDB config volume.
- Work step by step. Explain the problem, make the change, validate it, say
  exactly how to deploy and test, then wait for the result before moving on.

## Layout

- `compose.yaml`: networks, secrets declarations, and `include:` of
  `compose/<service>/<service>.yaml` (commented-out includes = disabled).
- `.env.example`: the tracked template and **source of truth** for settings.
  One `###NAME### https://project-url` section per service, alphabetical.
  All image versions are pinned here. `.env` (gitignored) is built from it by
  `scripts/apply-env-example.sh`. (`scripts/make-env-example.sh` goes the
  other way; it's only for recovering from a hand-edited `.env`.)
- `compose/authelia/configuration.yml`: a **Go template** (`{{ }}` is
  evaluated even in comments). Access rules, and OIDC clients with PBKDF2
  digests from `scripts/authelia-hash-oidc-secrets.sh`.
- `templates/template.compose.yaml`: the starting point for new services, and
  the layout every compose file follows (key order, header comment, map-style
  `environment`). Its header lists the conventions; the short version:
  - From `.env.example`: `<APP>__NAME` (container), `<APP>__SUBDOMAIN`,
    image/version, `<APP>__VOLDIR` when the data folder isn't
    `${VOLDIR}/${<APP>__NAME}`, ports and app settings.
  - In the compose file on purpose (it's the security model): hardening,
    networks and fixed IPs, bind addresses, trusted proxies, the `.int`
    part of hostnames, `authelia@docker`.
  - Containers reach each other by service key, never by container name.
  - Authelia's rules and OIDC redirect URIs use `{{ env "SUBDOMAIN_<APP>" }}`;
    a new app needs its `SUBDOMAIN_<APP>` added to `authelia.yaml`.

## Conventions

**Secrets**
- Every secret is a file in `secrets/<app>/…`, declared in `compose.yaml`.
  Files are mode 444, folders 700.
- Naming: Docker secret `<app>_<item>` is always the file
  `secrets/<app>/<item>` (e.g. `immich_db_password` =
  `secrets/immich/db_password`). `<app>` is the app's short name
  (`homeassistant`, `vpn`, `traefik`…; `smtp` for the shared mail account).
  Item words: `db_password`, `db_root_password`, `db_url`,
  `oidc_client_id`, `oidc_client_secret`, and in Authelia
  `oidc_<app>_digest`; otherwise say what it is (`session_secret`,
  `storage_encryption_key`, `jwt_secret`).
- Use the app's native `*_FILE` variable when it has one (linuxserver images:
  `FILE__VAR`).
- Otherwise use the **wrapper entrypoint** pattern (see `ghost.yaml` or
  `linkwarden.yaml`): `/bin/sh -c 'VAR=$$(cat /run/secrets/x) && export VAR && exec "$$@"' -- <original ENTRYPOINT>`,
  plus `command:` set to the image's original CMD. Get both from
  `docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' <image>`,
  and re-check them after upgrades.

**Hardening** (baseline on every service)
- `no-new-privileges`, `cap_drop: ALL`, json-file log rotation.
- Never add `apparmor:unconfined`; the server runs AppArmor. No exceptions.
- Never mount host sockets (`/run/dbus`, `docker.sock`, …) into an app:
  containers run as host root, and `:ro` doesn't restrict a socket.
- Add back only the capabilities the image needs. Root-then-drop images:
  `CHOWN DAC_READ_SEARCH FOWNER SETGID SETUID`. Use `DAC_OVERRIDE` if the
  entrypoint checks writability as root (as LLDAP does). See the table in
  `docs/decisions.md`.

**Start-up**
- `restart: unless-stopped` everywhere.
- Apps that use Postgres wait for it with `condition: service_healthy`.

**Networks**
- `external`: internet access, and the network Traefik routes on by default.
- Backends sit on internal-only networks with just their consumers:
  `db_postgres`, `immich_backend`, `ghost_backend`, `leantime_backend`,
  `grimmory_backend`, `authelia_backend` (Authelia's Valkey session store).
- `filebrowser_proxy`: Traefik and FileBrowser only (FileBrowser trusts the
  `Remote-User` header).
- `arr` (172.21.10.0/24, has internet): Traefik, Prowlarr `.10`, Chaptarr `.11`.
  Both run with no login of their own and bind their UI to that address only.
  `chaptarr_downloads`, `prowlarr_downloads` (each with `vpn`) and
  `prowlarr_flaresolverr` are their outbound links; the two *arrs share only `arr`.
- `vpn` (Gluetun) is **not** on `external`: Mousetrap's UI in its namespace
  has no login and listens everywhere. It uses `vpn_egress` (itself only) for
  the tunnel, `vpn_ui` for Traefik (`.249`; the label
  `traefik.docker.network=vpn_ui` goes on **vpn**: Traefik reads it from the
  namespace owner and ignores it on qBittorrent/Mousetrap), and `vpn_proxy` for
  FlareSolverr, which has no other way out. Gluetun's HTTP proxy (no login)
  serves FlareSolverr, Chaptarr and Prowlarr (their in-app proxy setting).
- `lldap_backend`: Authelia and LLDAP; LDAP listens only on LLDAP's `.10` there,
  and Authelia uses the alias `lldap-ldap`, which exists only on that network.
  When two containers share several networks, a plain service name may
  resolve to the wrong one; use a per-network alias for bound addresses.
- `proxy_internal` is for routed services with no internet access; they need
  the label `traefik.docker.network=proxy_internal`.
- Fixed IPs on `external`: cloudflared `.250`, Traefik `.249` (backends trust
  only `.249` as their proxy).
- Host ports: Traefik's 80/443 only, bound to `TRAEFIK__BIND_IP` (the LAN
  address `*.int` resolves to). Public names arrive through cloudflared.
  Nothing else publishes ports, and nothing binds to all interfaces.
- Containers in the VPN's network use `network_mode: service:vpn`, never
  `container:vpn`.

**Docker API**
- `socket-proxy-ro` (wollomatic/socket-proxy): per-client allowlists in
  labels on each client (`socket-proxy.allow.get` / `.head`, single-quoted
  regexes). Traefik, Dozzle and Diun get only the paths they were seen using;
  a container without labels gets nothing. Never allow `.*`, `archive` or
  `export`: "GET only" still reads any container's files. To find what a
  client needs (new client, or one broken by an upgrade), set the proxy to
  `-loglevel=DEBUG` and read its "allowed/blocked request" lines.
- Nothing in the VPN namespace: Mousetrap has no Docker access (its port
  monitor doesn't need it), and `vpn` must never join a socket-proxy network.
- `socket-proxy` (GET + container restart/stop/kill; `ALLOW_RESTARTS` has no
  restart-only mode): deunhealth.
- Nothing gets general write access.

**Authelia**
- `default_policy: deny`. Every forward-auth router needs a matching rule.
- Every rule and OIDC client is `two_factor` and names its LLDAP groups:
  `admin` (`*.int` and admin paths), `privliged_user` (FileBrowser,
  Chaptarr, Leantime, Immich, Vaultwarden, Linkwarden), `user` (Mealie,
  Grimmory, FreshRSS), `house_guest` (Home Assistant only). Groups don't nest,
  so each rule lists every group it admits. OIDC clients use the
  `authorization_policies` (`privileged`, `everyday`, `homeassistant`).
- Apps with mobile apps or extensions (Vaultwarden, Linkwarden, Immich, Home
  Assistant) do **not** use forward-auth. They use their own login plus a
  two_factor OIDC client.
- OIDC clients require PKCE S256, except Leantime and FileBrowser (neither
  sends PKCE).

**Updates**
- Diun emails new versions. Bump the version in `.env.example`, run
  `scripts/apply-env-example.sh`, then `docker compose up -d <svc>`.
- Suffixed tag schemes need a `diun.include_tags` label. Use **single
  quotes**, because `\d` in double-quoted YAML is a parse error, and write `$`
  as `$$`.

## Validating changes

- `scripts/compose-diff.sh [--all] [<ref>]` shows what a change does to the
  rendered config (against HEAD by default; `--all` includes disabled
  services), redacted. A pure layout change prints "No differences". It
  renders both sides with today's `.env`, so a renamed variable makes the
  *old* side look empty; that's an artifact, not a change.
- `docker compose config -q` must be silent. Note that `docker compose config`
  prints `$` as `$$`; that's display only.
- To check whether an image tag exists:
  `docker manifest inspect <image:tag>`. For `tag@sha256:…` refs, inspect
  `repo@sha256:…`. Docker Hub rate-limits anonymous lookups, so a
  `MISSING` result can be spurious.
- After a deploy:
  - `docker compose ps -a` should show everything Up/healthy.
  - Grep the recent logs of each container for `permission denied`,
    `operation not permitted`, `connection refused` and
    `could not translate host`.

## Known gotchas

- The official MySQL image reads its `_FILE` secrets again as uid 999, so the
  files must be readable by that user (444 covers it).
- Overriding `entrypoint:` in Compose discards the image's CMD.
- Android in-app web views (HA Companion) can't use passkeys. The Authelia
  account has TOTP for that.
- CouchDB `roles_claim_path` rejects tokens missing the claim; use
  `roles_claim_name`.
- Diun's mail `From` must be a bare address.
- Linkwarden reads registration/credential settings only from its compose
  file. The old `.env` values were never passed through.
- When Gluetun (`vpn`) is **recreated** (any change to its service), Compose
  only restarts qBittorrent/Mousehole/Mousetrap, which leaves them in the old,
  dead network namespace (still "running"). Their healthcheck then goes
  unhealthy (no `tun0`). Fix: `docker compose up -d --force-recreate
  qbittorrent mousehole`. deunhealth can't fix it: a restart rejoins the old
  namespace.
