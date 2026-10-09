#!/usr/bin/env bash
# CouchDB housekeeping from the host, without exposing the admin password.
#
#   ./scripts/couchdb-maintenance.sh            list databases: docs, deleted docs, sizes
#   ./scripts/couchdb-maintenance.sh --compact  also compact each database and clean up
#                                               old view indexes (runs in the background)
#
# Basic auth is disabled on this CouchDB (sync uses JWT), so this logs in at
# /_session for a cookie. The password is read here (hidden) and passed into
# the container on stdin, so it never appears in a process list or in shell
# history. The session is closed again on exit.
set -euo pipefail

mode=report
[[ ${1:-} == --compact ]] && mode=compact

read -rp "CouchDB admin user: " user
read -rsp "Password (hidden): " pass
echo

printf '%s\n%s\n' "$user" "$pass" | docker exec -i couchdb sh -c '
  set -u
  base=http://localhost:5984
  read -r u; read -r p
  c=$(mktemp)
  trap "curl -s -b $c -X DELETE $base/_session >/dev/null; rm -f $c" EXIT

  code=$(printf %s "$p" | curl -s -o /dev/null -w "%{http_code}" -c "$c" \
    --data-urlencode "name=$u" --data-urlencode "password@-" "$base/_session")
  p=
  [ "$code" = 200 ] || { echo "Login failed (HTTP $code)." >&2; exit 1; }

  num() { grep -o "\"$1\":[0-9]*" | head -n1 | cut -d: -f2; }
  mb()  { awk -v b="${1:-0}" "BEGIN { printf \"%.1f\", b / 1048576 }"; }

  printf "%-24s %8s %8s %10s %10s\n" database docs deleted "file MB" "active MB"
  for db in $(curl -s -b "$c" "$base/_all_dbs" | tr -d "[]\"" | tr , " "); do
    info=$(curl -s -b "$c" "$base/$db")
    printf "%-24s %8s %8s %10s %10s\n" "$db" \
      "$(echo "$info" | num doc_count)" "$(echo "$info" | num doc_del_count)" \
      "$(mb "$(echo "$info" | num file)")" "$(mb "$(echo "$info" | num active)")"
    if [ "$1" = compact ]; then
      for op in _compact _view_cleanup; do
        r=$(curl -s -b "$c" -X POST -H "Content-Type: application/json" "$base/$db/$op")
        echo "$r" | grep -q "\"ok\":true" || echo "  $op on $db: $r"
      done
    fi
  done
  [ "$1" = compact ] && echo "Compaction started; re-run without --compact in a minute to compare sizes."
' sh "$mode"
