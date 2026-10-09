#!/usr/bin/env bash
# Move secrets from .env into Docker secret files, without printing them.
#
#   sudo DOCKERDIR=/opt/docker ./scripts/env-to-secret.sh VAR secrets/path [VAR secrets/path ...]
#
# For each VAR / path pair:
#   - secret file missing or empty -> writes the .env value into it (mode 600)
#   - secret file already there    -> reports whether it matches the .env value
#                                     (never overwritten; decide which is current)
#
# Existing database passwords must be copied, not regenerated: the database
# already has the old one. Rotate separately if you want a new value.
#
# This script never edits .env. Delete the line yourself once the service
# reads the file and has been tested.
set -euo pipefail

DOCKERDIR=${DOCKERDIR:-/opt/docker}
ENV_FILE="$DOCKERDIR/.env"

if (( $# == 0 || $# % 2 )); then
  echo "usage: $0 VAR secrets/path [VAR secrets/path ...]" >&2
  exit 2
fi

# Value of $1 in .env, following Compose's rules closely enough for secrets:
# last assignment wins, quotes are stripped, " #..." on an unquoted value is a comment.
env_value() {
  local line v
  line=$(grep -E "^$1[[:space:]]*=" "$ENV_FILE" | tail -n1) || return 1
  v=${line#*=}
  v=${v#"${v%%[![:space:]]*}"}
  case $v in
    \"*) v=${v#\"}; v=${v%%\"*} ;;
    \'*) v=${v#\'}; v=${v%%\'*} ;;
    *)   v=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v") ;;
  esac
  printf '%s' "$v"
}

while (( $# )); do
  var=$1 rel=$2
  shift 2
  path="$DOCKERDIR/$rel"

  if ! value=$(env_value "$var"); then
    echo "skip   $var: not in .env"
    continue
  fi
  if [[ -z $value ]]; then
    echo "skip   $var: empty in .env"
    continue
  fi
  if [[ $value == *'${'* ]]; then
    echo "skip   $var: uses \${...} interpolation; write $rel by hand"
    continue
  fi

  if [[ -s $path ]]; then
    if [[ "$(cat "$path")" == "$value" ]]; then
      echo "match  $var == $rel"
    else
      echo "DIFFER $var != $rel  (file kept)"
    fi
  else
    install -d -m 700 "$(dirname "$path")"
    (umask 077; printf '%s' "$value" > "$path")
    echo "wrote  $rel  <- $var"
  fi
done
unset value
