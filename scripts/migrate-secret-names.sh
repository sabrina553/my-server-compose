#!/usr/bin/env bash
# One-off: move the files in secrets/ to the uniform naming scheme
# (Docker secret <app>_<item> = secrets/<app>/<item>; see CLAUDE.md).
# The repo already uses the new names; this brings the files on disk in line.
#
#   sudo scripts/migrate-secret-names.sh              dry run: show what would move
#   sudo scripts/migrate-secret-names.sh --apply      move the files
#   sudo scripts/migrate-secret-names.sh --reverse    undo a previous --apply
#
# Files are only moved (mv), never opened; output is paths only. Moved files
# keep their mode (444), new folders get 700. Unused secrets (no longer
# declared) go to /tmp/secrets-removed/ for you to delete by hand.
#
# Run it right before `docker compose up -d`: running containers keep the
# files they mounted, but a container that merely restarts in between would
# look for the old paths.
set -euo pipefail
cd "$(dirname "$0")/.."
S=secrets
ATTIC=/tmp/secrets-removed

mode=dry
case ${1:-} in
  "") ;;
  --apply) mode=apply ;;
  --reverse) mode=reverse ;;
  *) echo "usage: $0 [--apply|--reverse]" >&2; exit 1 ;;
esac
[[ $mode == dry ]] || (( EUID == 0 )) || { echo "Run as root (sudo)." >&2; exit 1; }

# old path -> new path, relative to secrets/
MOVES=$(cat <<'LIST'
cloudflare/dns_api_token traefik/cloudflare_dns_api_token
cloudflare/tunnel_token cloudflared/tunnel_token
authelia/jwt authelia/jwt_secret
authelia/secret_key authelia/session_secret
authelia/pg_password authelia/db_password
authelia/encryption authelia/storage_encryption_key
authelia/hmac_secret authelia/oidc_hmac_secret
authelia/jwks authelia/oidc_jwks_key
authelia/oidc/filebrowser authelia/oidc_filebrowser_digest
authelia/oidc/freshrss authelia/oidc_freshrss_digest
authelia/oidc/grimmory authelia/oidc_grimmory_digest
authelia/oidc/homeassistant authelia/oidc_homeassistant_digest
authelia/oidc/immich authelia/oidc_immich_digest
authelia/oidc/leantime authelia/oidc_leantime_digest
authelia/oidc/linkwarden authelia/oidc_linkwarden_digest
authelia/oidc/mealie authelia/oidc_mealie_digest
authelia/oidc/vaultwarden authelia/oidc_vaultwarden_digest
filebrowser/oidc_clientid filebrowser/oidc_client_id
filebrowser/oidc_secret filebrowser/oidc_client_secret
freshrss/oidc_clientid freshrss/oidc_client_id
freshrss/oidc_secret freshrss/oidc_client_secret
freshrss/pg_password freshrss/db_password
grimmory/mdb_password grimmory/db_root_password
grimmory/oidc_clientid grimmory/oidc_client_id
leantime/oidc_clientid leantime/oidc_client_id
leantime/oidc_secret leantime/oidc_client_secret
leantime/mysql_root_password leantime/db_root_password
leantime/mysql_password leantime/db_password
leantime/session_password leantime/session_secret
homeassis/oidc_clientid homeassistant/oidc_client_id
immich/oidc_clientid immich/oidc_client_id
immich/pg_password immich/db_password
linkwarden/oidc_clientid linkwarden/oidc_client_id
linkwarden/oidc_secret linkwarden/oidc_client_secret
linkwarden/database_url linkwarden/db_url
lldap/user_pass lldap/admin_password
lldap/database_url lldap/db_url
mealie/oidc_clientid mealie/oidc_client_id
mealie/oidc_secret mealie/oidc_client_secret
mealie/pg_password mealie/db_password
vaultwarden/pg_url vaultwarden/db_url
vaultwarden/oidc_clientid vaultwarden/oidc_client_id
vaultwarden/oidc_clientsecret vaultwarden/oidc_client_secret
vaultwarden/push_id vaultwarden/push_installation_id
vaultwarden/push_key vaultwarden/push_installation_key
wireguard/private_key vpn/wireguard_private_key
wireguard/preshared_key vpn/wireguard_preshared_key
wireguard/addresses vpn/wireguard_addresses
grimmory/oidc_secret grimmory/oidc_client_secret
homeassis/oidc_secret homeassistant/oidc_client_secret
immich/oidc_secret immich/oidc_client_secret
LIST
)
# unused: moved out of secrets/ to $ATTIC
DROPPED=$(cat <<'LIST'
linkwarden/pg_password
LIST
)

moved=0 missing=0 clash=0
move() { # <from> <to>
  local from=$1 to=$2
  if [[ ! -e $from ]]; then
    [[ -e $to ]] && return 0          # already done
    echo "  missing: $from"; missing=$((missing + 1)); return 0
  fi
  if [[ -e $to ]]; then echo "  CLASH (both exist): $from / $to"; clash=$((clash + 1)); return 0; fi
  if [[ $mode == dry ]]; then echo "  would move: $from -> $to"; moved=$((moved + 1)); return 0; fi
  install -d -m 700 "$(dirname "$to")"
  mv "$from" "$to"
  echo "  moved: $from -> $to"; moved=$((moved + 1))
}

while read -r old new; do
  [[ -n $old ]] || continue
  if [[ $mode == reverse ]]; then move "$S/$new" "$S/$old"; else move "$S/$old" "$S/$new"; fi
done <<< "$MOVES"

while read -r p; do
  [[ -n $p ]] || continue
  name=${p//\//_}
  if [[ $mode == reverse ]]; then move "$ATTIC/$name" "$S/$p"
  else
    [[ $mode == apply ]] && install -d -m 700 "$ATTIC"
    move "$S/$p" "$ATTIC/$name"
  fi
done <<< "$DROPPED"

# Remove folders the old scheme used, if now empty.
if [[ $mode == apply ]]; then
  for d in authelia/oidc cloudflare homeassis wireguard; do
    [[ -d $S/$d ]] && rmdir "$S/$d" 2>/dev/null && echo "  removed empty folder: $S/$d"
  done
fi

echo
echo "${mode}: $moved to move/moved, $missing missing, $clash clashes."
(( clash == 0 )) || { echo "Clashes: resolve them by hand before applying." >&2; exit 1; }
[[ $mode == dry ]] && echo "Nothing changed. Re-run with --apply."
[[ $mode == apply ]] && echo "Next: docker compose config -q && docker compose up -d"
exit 0
