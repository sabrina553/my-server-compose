#!/usr/bin/env bash
# Generate Authelia PBKDF2-SHA512 digests of each app's OIDC client secret, so
# Authelia never holds the plaintext. Optionally rotate client IDs/secrets.
#
#   ./scripts/authelia-hash-oidc-secrets.sh                  hash every client
#   ./scripts/authelia-hash-oidc-secrets.sh --rotate <client>...
#        new random client ID + secret for those clients, then hash them
#
#   reads:  secrets/<client>/oidc_client_id, secrets/<client>/oidc_client_secret  (the app uses these)
#   writes: secrets/authelia/oidc_<client>_digest                                (Authelia uses this)
#
# Missing or empty client-ID / secret files are created first: you're prompted
# to paste the app's existing value or generate a new one.
#
# Nothing is printed except client names and file paths. Values are generated
# and hashed inside throwaway Authelia containers (no network), and the
# plaintext goes in on stdin, so it never appears in the process list.
set -euo pipefail
cd "$(dirname "$0")/.."

# Same Authelia image as the stack (from .env.example), unless overridden.
IMAGE=${AUTHELIA_IMAGE:-$(sed -nE 's/^AUTHELIA__IMAGE="(.*)"/\1/p' .env.example):$(sed -nE 's/^AUTHELIA__VERSION="(.*)"/\1/p' .env.example)}
[[ $IMAGE == *authelia*:?* ]] || { echo "Can't read AUTHELIA__IMAGE/VERSION from .env.example" >&2; exit 1; }
SECRETS=secrets

# Authelia client names. Each one's files follow the naming scheme
# (Docker secret <app>_<item> = secrets/<app>/<item>):
#   secrets/<client>/oidc_client_id, secrets/<client>/oidc_client_secret,
#   secrets/authelia/oidc_<client>_digest
declare -A SRC=()
for c in filebrowser freshrss grimmory homeassistant immich leantime linkwarden mealie vaultwarden; do
  SRC[$c]=$c/oidc_client_secret
done

# Compose service to restart after a rotation.
declare -A SERVICE=(
  [filebrowser]=filebrowser [freshrss]=freshrss [grimmory]=grimmory
  [homeassistant]=homeassistant [immich]=immich-server [leantime]=leantime
  [linkwarden]=linkwarden [mealie]=mealie [vaultwarden]=vaultwarden
)

# Apps that keep their own copy of the ID/secret instead of reading the files.
declare -A MANUAL=(
  [grimmory]="Grimmory: Settings > OIDC"
  [immich]="Immich: Administration > Settings > OAuth"
)

id_file() { echo "$1/oidc_client_id"; }
digest_file() { echo "authelia/oidc_$1_digest"; }

# Write a value to a secret file atomically: mode 444, folder 700.
write_secret() {
  local path=$1 value=$2 tmp
  install -d -m 700 "$(dirname "$path")"
  tmp=$(mktemp "$path.XXXXXX")
  printf '%s' "$value" > "$tmp"
  chmod 444 "$tmp"
  mv -f "$tmp" "$path"
}

# Random value in the format Authelia recommends for client IDs and secrets.
random_value() {
  docker run --rm --network none "$IMAGE" \
    authelia crypto rand --length 72 --charset rfc3986 | sed -n 's/^Random Value: //p'
}

rotate=()
if [[ ${1:-} == --rotate ]]; then
  shift
  (( $# )) || { echo "usage: $0 --rotate <client>... (one of: ${!SRC[*]})" >&2; exit 1; }
  for c in "$@"; do
    [[ -n ${SRC[$c]:-} ]] || { echo "unknown client: $c (one of: ${!SRC[*]})" >&2; exit 1; }
  done
  rotate=("$@")
elif (( $# )); then
  echo "usage: $0 [--rotate <client>...]" >&2; exit 1
fi

docker pull -q "$IMAGE" >/dev/null

# 1. Rotate: overwrite the client ID and secret with new random values.
for c in "${rotate[@]}"; do
  for f in "$(id_file "$c")" "${SRC[$c]}"; do
    value=$(random_value)
    [[ ${#value} -ge 64 ]] || { echo "FAILED to generate a value for $f" >&2; exit 1; }
    write_secret "$SECRETS/$f" "$value"
    unset value
    echo "new  $SECRETS/$f"
  done
done

# 2. Fill in any missing/empty client ID or secret file.
clients=("${rotate[@]}")
(( ${#clients[@]} )) || clients=("${!SRC[@]}")
for c in "${clients[@]}"; do
  for f in "$(id_file "$c")" "${SRC[$c]}"; do
    path=$SECRETS/$f
    [[ -s $path ]] && continue
    [[ -t 0 ]] || { echo "MISSING or empty: $path (run interactively to create it)" >&2; exit 1; }

    echo
    echo "MISSING or empty: $path"
    if [[ $f == */oidc_client_id ]]; then
      read -rp "  Paste the existing client ID, or press Enter to generate one: " value
    else
      read -rsp "  Paste the existing client secret (hidden), or press Enter to generate one: " value
      echo
    fi
    [[ -n $value ]] || value=$(random_value)
    [[ -n $value ]] || { echo "FAILED to generate a value for $f" >&2; exit 1; }
    write_secret "$path" "$value"
    unset value
    echo "  wrote $path"
  done
done

# 3. Hash each secret for Authelia.
for c in "${clients[@]}"; do
  digest=$(docker run --rm -i --network none --entrypoint sh "$IMAGE" -c \
    'authelia crypto hash generate pbkdf2 --variant sha512 --password "$(cat)"' \
    < "$SECRETS/${SRC[$c]}" | sed -n 's/^Digest: //p')
  [[ $digest == '$pbkdf2-sha512$'* ]] || { echo "FAILED to hash $c" >&2; exit 1; }
  write_secret "$SECRETS/$(digest_file "$c")" "$digest"
  echo "ok   $c"
done
unset digest

echo "Done. Digests are in $SECRETS/authelia/oidc_<client>_digest"

# 4. What to do next.
if (( ${#rotate[@]} )); then
  svcs=()
  for c in "${rotate[@]}"; do svcs+=("${SERVICE[$c]}"); done
  echo
  for c in "${rotate[@]}"; do
    [[ -n ${MANUAL[$c]:-} ]] || continue
    echo "$c keeps its own copy. Paste the new values into ${MANUAL[$c]}:"
    echo "  client ID: sudo cat $SECRETS/$(id_file "$c")"
    echo "  secret:    sudo cat $SECRETS/${SRC[$c]}"
  done
  echo "Then: docker compose up -d --force-recreate authelia ${svcs[*]}"
else
  echo "Then: docker compose up -d --force-recreate authelia"
fi
