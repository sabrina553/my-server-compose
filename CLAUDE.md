# Homelab Docker stack

Self-hosted services behind Cloudflare Tunnel → Traefik → Authelia (+ LLDAP).
Everything runs from this repo with Docker Compose. Read `README.md` for the
overview, `docs/decisions.md` before changing anything structural (don't undo
a decision without saying so), and `docs/journal/` (newest first) for history
and open to-dos.

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
- `templates/template.compose.yaml`: the starting point for new services.

## Conventions

**Secrets**
- Every secret is a file in `secrets/<app>/…`, declared in `compose.yaml`.
  Files are mode 444, folders 700.
- Use the app's native `*_FILE` variable when it has one (linuxserver images:
  `FILE__VAR`).
- Otherwise use the **wrapper entrypoint** pattern (see `ghost.yaml` or
  `linkwarden.yaml`): `/bin/sh -c 'VAR=$$(cat /run/secrets/x) && export VAR && exec "$$@"' -- <original ENTRYPOINT>`,
  plus `command:` set to the image's original CMD. Get both from
  `docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' <image>`,
  and re-check them after upgrades.

**Hardening** (baseline on every service)
- `no-new-privileges`, `cap_drop: ALL`, json-file log rotation.
- Never add `apparmor:unconfined`; the server runs AppArmor. Home Assistant
  is the one deliberate exception.
- Add back only the capabilities the image needs. Root-then-drop images:
  `CHOWN DAC_READ_SEARCH FOWNER SETGID SETUID`. Use `DAC_OVERRIDE` if the
  entrypoint checks writability as root (as LLDAP does). See the journal's
  table.

**Networks**
- `external`: internet access, and the network Traefik routes on by default.
- Backends sit on internal-only networks with just their consumers:
  `db_postgres`, `immich_backend`, `ghost_backend`, `leantime_backend`,
  `grimmory_backend`, `authelia_backend` (Authelia's Valkey session store).
- `filebrowser_proxy`: Traefik and FileBrowser only (FileBrowser trusts the
  `Remote-User` header).
- `proxy_internal` is for routed services with no internet access; they need
  the label `traefik.docker.network=proxy_internal`.
- Fixed IPs on `external`: cloudflared `.250`, Traefik `.249` (backends trust
  only `.249` as their proxy).
- Containers in the VPN's network use `network_mode: service:vpn`, never
  `container:vpn`.

**Docker API**
- `socket-proxy-ro` (GET only): Traefik, Dozzle, Diun, Mousetrap (the `vpn`
  container joins `socket_proxy_ro`, and its subnet is in Gluetun's
  `FIREWALL_OUTBOUND_SUBNETS`).
- `socket-proxy` (GET + container restart/stop/kill; `ALLOW_RESTARTS` has no
  restart-only mode): deunhealth.
- Nothing gets general write access.

**Authelia**
- `default_policy: deny`. Every forward-auth router needs a matching rule.
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
