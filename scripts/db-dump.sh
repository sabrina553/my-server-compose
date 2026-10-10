#!/usr/bin/env bash
# Dump every database to plain SQL for restic to pick up.
#
#   sudo ./scripts/db-dump.sh            (cron: a few minutes before the backup)
#
# restic copies the live data folders too, but a copy of a running Postgres or
# MySQL isn't guaranteed to restore. These dumps are. Output is uncompressed on
# purpose: restic compresses and deduplicates it, gzip would defeat that.
#
# Passwords are read inside each container from its own /run/secrets files and
# passed in MYSQL_PWD, so they never reach this script, its log or `ps`.
# Postgres uses the image's local-socket trust, no password.
#
# CouchDB isn't dumped: its files are append-only and safe to copy while it runs.
#
# Restore (example):
#   docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres' < postgres.sql
#   docker compose exec -T leantime_db sh -c 'MYSQL_PWD="$(cat /run/secrets/leantime_db_root_password)" mysql -uroot' < leantime_db.sql
#   docker compose exec -T mariadb sh -c 'MYSQL_PWD="$(cat /run/secrets/grimmory_db_root_password)" mariadb -uroot' < mariadb.sql
set -euo pipefail

DOCKERDIR=${DOCKERDIR:-/opt/docker}
OUT=${DUMPDIR:-/var/backups/db-dumps}

umask 077
mkdir -p "$OUT"
chmod 700 "$OUT"
cd "$DOCKERDIR"

failed=0

# dump <service key> <command run inside the container>
# Writes to a temp file and only replaces the previous dump if this one worked.
dump() {
  local svc=$1 cmd=$2
  if docker compose exec -T "$svc" sh -c "$cmd" > "$OUT/$svc.sql.tmp" 2> "$OUT/$svc.err"; then
    mv "$OUT/$svc.sql.tmp" "$OUT/$svc.sql"
    rm -f "$OUT/$svc.err"
    echo "$(date '+%F %T') ok     $svc ($(du -h "$OUT/$svc.sql" | cut -f1))"
  else
    rm -f "$OUT/$svc.sql.tmp"
    echo "$(date '+%F %T') FAILED $svc (see $OUT/$svc.err; previous dump kept)"
    failed=1
  fi
}

mysql_dump() {   # <service key> <root password secret> <dump binary>
  dump "$1" "MYSQL_PWD=\"\$(cat /run/secrets/$2)\" exec $3 -uroot --all-databases --single-transaction --routines --events --triggers"
}

dump postgres 'exec pg_dumpall -U "$POSTGRES_USER"'
mysql_dump db          ghost_db_root_password    mysqldump      # Ghost
mysql_dump leantime_db leantime_db_root_password mysqldump
mysql_dump mariadb     grimmory_db_root_password mariadb-dump   # Grimmory

exit "$failed"
