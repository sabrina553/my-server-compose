#!/usr/bin/env bash
# Check that the backups are happening and actually restore; e-mail the result.
#
#   sudo ./scripts/backup-verify.sh daily       (cron, Mon-Sat after the morning backup)
#   sudo ./scripts/backup-verify.sh weekly      (cron, Sunday, instead of daily)
#   sudo ./scripts/backup-verify.sh test-db mariadb   (one database's restore test, no mail)
#   sudo ./scripts/backup-verify.sh test-mail   (send one test e-mail)
#
# daily: e-mails only when something fails.
#   - each database dump (scripts/db-dump.sh) is fresh, finished, and hasn't
#     shrunk below half its previous size (an empty database dumps small)
#   - the server's newest MAIN snapshot is fresh and contains the dumps
#   - the PC's repos have a recent snapshot (the PC may be off: if it can't be
#     reached, the last snapshot time seen is used instead)
#   - the disk isn't nearly full
#
# weekly: the daily checks, then a restore test, and always e-mails, so silence
# never passes for success.
#   - restic check, reading back a different tenth of the stored data each week
#   - the newest snapshot is restored in full to a scratch folder with
#     --verify (every restored file is checked against the snapshot)
#   - each restored dump is loaded into a throwaway container of the live
#     database's image (no network), and its per-database table and row counts
#     are compared with the live database
#   Scratch space and containers are removed afterwards.
#
# Mail goes to EMAIL_ADMIN from BACKUP__MAIL_FROM. SMTP settings come from .env
# (read here, never printed); the password from secrets/smtp/password, handed
# to curl on a file descriptor, not argv.
set -uo pipefail

DOCKERDIR=${DOCKERDIR:-/opt/docker}
RESTIC_SCRIPTS=${RESTIC_SCRIPTS:-/srv/restic-repo/scripts}
DUMPDIR=${DUMPDIR:-/var/backups/db-dumps}
STATE=${STATE:-/var/lib/backup-verify}
SCRATCH=${SCRATCH:-/var/tmp/backup-verify}
ENV_FILE="$DOCKERDIR/.env"

DUMPS=(postgres db leantime_db mariadb)   # service keys, as in db-dump.sh
MAX_DUMP_AGE_H=14       # dumps run 06:20 and 18:20
MAX_LOCAL_AGE_H=14      # backup runs 06:30 and 18:30
MAX_PC_AGE_D=3          # the PC isn't always on
MAX_DISK_PCT=85
MIN_SCRATCH_GB=15       # restore (~5G) plus loaded databases
ROW_TOLERANCE_PCT=10    # live data moves on after the dump; allow some drift
ROW_TOLERANCE_MIN=500

umask 077
mkdir -p "$STATE"
cd "$DOCKERDIR" || exit 1

# --- .env ---------------------------------------------------------------------
# Value of $1 in .env (last assignment wins, quotes stripped), with ${VAR}
# references expanded from .env too. Same rules as env-to-secret.sh.
env_value() {
  local line v ref
  line=$(grep -E "^$1[[:space:]]*=" "$ENV_FILE" | tail -n1) || return 1
  v=${line#*=}
  v=${v#"${v%%[![:space:]]*}"}
  case $v in
    \"*) v=${v#\"}; v=${v%%\"*} ;;
    \'*) v=${v#\'}; v=${v%%\'*} ;;
    *)   v=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$v") ;;
  esac
  while [[ $v =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    ref=${BASH_REMATCH[1]}
    v=${v//"\${$ref}"/$(env_value "$ref")}
  done
  printf '%s' "$v"
}

# --- results ------------------------------------------------------------------
REPORT=()
FAILED=0
ok()   { REPORT+=("ok    $*"); }
fail() { REPORT+=("FAIL  $*"); FAILED=1; }
note() { REPORT+=("      $*"); }

age_hours() { echo $(( ($(date +%s) - $1) / 3600 )); }

# --- restic -------------------------------------------------------------------
# restic against one of the repos in the restic scripts (LOCAL, SAPPHIRE, ...).
r() {
  local repo=$1; shift
  (cd "$RESTIC_SCRIPTS" && timeout "${R_TIMEOUT:-0}" restic \
    --repository-file="identities/${repo}_REPO" \
    --password-file="identities/${repo}_PASSWORD" "$@")
}

# Epoch of the newest snapshot (optionally with a tag), or nothing.
latest_snapshot() {
  local repo=$1 tag=${2:-} t
  t=$(R_TIMEOUT=300 r "$repo" --no-lock snapshots --json --latest 1 ${tag:+--tag "$tag"} 2>/dev/null \
      | jq -r 'map(.time) | sort | last // empty') || return 1
  [[ -n $t ]] && date -d "$t" +%s
}

# --- daily checks -------------------------------------------------------------
check_dumps() {
  local svc f size prev age
  for svc in "${DUMPS[@]}"; do
    f="$DUMPDIR/$svc.sql"
    if [[ -e "$DUMPDIR/$svc.err" ]]; then
      fail "dump $svc: last run failed (see $svc.err)"
    fi
    if [[ ! -s $f ]]; then
      fail "dump $svc: missing or empty"; continue
    fi
    age=$(age_hours "$(stat -c %Y "$f")")
    if (( age > MAX_DUMP_AGE_H )); then
      fail "dump $svc: ${age}h old"; continue
    fi
    if ! tail -n 5 "$f" | grep -q -E 'Dump completed|database cluster dump complete'; then
      fail "dump $svc: no end marker (cut short?)"; continue
    fi
    size=$(stat -c %s "$f")
    prev=$(cat "$STATE/size.$svc" 2>/dev/null || echo 0)
    if (( prev > 0 && size * 2 < prev )); then
      fail "dump $svc: shrank from $(numfmt --to=iec "$prev") to $(numfmt --to=iec "$size")"
      continue   # keep the old size, so the alert repeats until it's looked at
    fi
    echo "$size" > "$STATE/size.$svc"
    ok "dump $svc: ${age}h old, $(numfmt --to=iec "$size")"
  done
}

check_local() {
  local t age n
  if ! t=$(latest_snapshot LOCAL MAIN) || [[ -z $t ]]; then
    fail "server backup: can't read the LOCAL repo"; return
  fi
  age=$(age_hours "$t")
  if (( age > MAX_LOCAL_AGE_H )); then
    fail "server backup: newest snapshot is ${age}h old"
  else
    ok "server backup: newest snapshot ${age}h old"
  fi
  n=$(r LOCAL --no-lock ls latest "$DUMPDIR" 2>/dev/null | grep -c '\.sql$')
  if (( n < ${#DUMPS[@]} )); then
    fail "server backup: newest snapshot has $n of ${#DUMPS[@]} dumps"
  else
    ok "server backup: contains all ${#DUMPS[@]} dumps"
  fi
}

check_pc() {
  local repo t age seen=""
  for repo in SAPPHIRE SAPPHIRE_IMMICH; do
    if t=$(latest_snapshot "$repo") && [[ -n $t ]]; then
      echo "$t" > "$STATE/pc.$repo"
    else
      t=$(cat "$STATE/pc.$repo" 2>/dev/null || true)
      seen=" (PC unreachable, last seen)"
    fi
    if [[ -z $t ]]; then
      fail "PC $repo: unreachable, and no snapshot seen yet"; continue
    fi
    age=$(( $(age_hours "$t") / 24 ))
    if (( age > MAX_PC_AGE_D )); then
      fail "PC $repo: newest snapshot is ${age} days old$seen"
    else
      ok "PC $repo: newest snapshot ${age} days old$seen"
    fi
  done
}

check_disk() {
  local pct
  pct=$(df --output=pcent / | tail -n1 | tr -dc 0-9)
  if (( pct > MAX_DISK_PCT )); then
    fail "disk: / is ${pct}% full"
  else
    ok "disk: / is ${pct}% full"
  fi
}

# --- weekly: repository -------------------------------------------------------
check_repo() {
  local part out
  part=$(( 10#$(date +%V) % 10 + 1 ))
  if out=$(r LOCAL check --read-data-subset="$part/10" 2>&1); then
    ok "restic check: no errors (read back data part $part/10)"
  else
    fail "restic check: errors (data part $part/10)"
    while IFS= read -r l; do note "$l"; done < <(grep -v '^$' <<<"$out" | tail -n 5)
  fi
}

restore_latest() {
  local out files
  if out=$(r LOCAL restore latest --target "$SCRATCH/restore" --verify 2>&1); then
    files=$(grep -o -E 'finished verifying [0-9]+ files' <<<"$out" | grep -o -E '[0-9]+')
    ok "restore: newest snapshot restored and verified (${files:-?} files, $(du -sh "$SCRATCH/restore" | cut -f1))"
  else
    fail "restore: failed"
    while IFS= read -r l; do note "$l"; done < <(grep -v '^$' <<<"$out" | tail -n 5)
    return 1
  fi
}

# --- weekly: databases --------------------------------------------------------
# Every query prints "<database> <tables> <rows>" lines, sorted, rows counted
# exactly (the statistics views are estimates).

SQL_PG_DBS="SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1"
SQL_PG_COUNT="SELECT count(*), coalesce(sum((xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint), 0) FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')"

pg_counts() {   # <user> <exec prefix...>
  local user=$1 db; shift
  for db in $("$@" psql -At -U "$user" -d postgres <<<"$SQL_PG_DBS"); do
    printf '%s %s\n' "$db" "$("$@" psql -At -F ' ' -U "$user" -d "$db" <<<"$SQL_PG_COUNT")"
  done | sort
}

# Builds one UNION ALL of exact counts over every user table, then runs it.
SQL_MY_GEN="SET SESSION group_concat_max_len = 100000000; SELECT GROUP_CONCAT(CONCAT('SELECT ', QUOTE(table_schema), ', COUNT(*) FROM \`', table_schema, '\`.\`', table_name, '\`') SEPARATOR ' UNION ALL ') FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')"

my_counts() {   # <client> <exec prefix...>
  local client=$1 q; shift
  q=$("$@" "$client" -N -r -uroot <<<"$SQL_MY_GEN") || return 1
  [[ -z $q || $q == NULL ]] && return 0
  "$@" "$client" -N -r -uroot <<<"$q" \
    | awk '{ t[$1]++; r[$1] += $2 } END { for (s in t) print s, t[s], r[s] }' | sort
}

# compare <service> <live counts> <restored counts>
compare_counts() {
  local svc=$1 live=$2 rest=$3 db lt lr rt rr tol bad=0 n=0 total=0
  while read -r db lt lr; do
    [[ -z $db ]] && continue
    n=$((n + 1)); total=$((total + lr)); rt=; rr=
    read -r rt rr < <(awk -v d="$db" '$1 == d { print $2, $3 }' <<<"$rest")
    if [[ -z ${rt:-} ]]; then
      fail "restore $svc: database $db missing"; bad=1; continue
    fi
    tol=$(( lr * ROW_TOLERANCE_PCT / 100 )); (( tol < ROW_TOLERANCE_MIN )) && tol=$ROW_TOLERANCE_MIN
    if (( rt != lt )); then
      fail "restore $svc: $db has $rt tables, live has $lt"; bad=1
    elif (( rr - lr > tol || lr - rr > tol )); then
      fail "restore $svc: $db has $rr rows, live has $lr"; bad=1
    fi
  done <<<"$live"
  if (( n == 0 )); then
    fail "restore $svc: couldn't count the live databases"
  elif (( ! bad )); then
    ok "restore $svc: $n databases, tables match, $total rows (within ${ROW_TOLERANCE_PCT}% of live)"
  fi
}

# Wait until the throwaway accepts TCP connections on 127.0.0.1. During first
# start each image runs a setup server on the socket only, so this also waits
# for setup to finish.
wait_ready() {   # <container> <command...>
  local c=$1 i; shift
  for i in $(seq 1 120); do
    docker exec "$c" "$@" >/dev/null 2>&1 && return 0
    [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] || return 1
    sleep 3
  done
  return 1
}

# Throwaway: same image as the live service, no network, the usual hardening.
# The data folder is 755 like the live ones (Postgres drops to its own user
# before creating PGDATA inside it).
throwaway() {   # <name> <service> <env file> <data mount> [docker run args...]
  local name=$1 svc=$2 envf=$3 mount=$4 image; shift 4
  image=$(docker inspect -f '{{.Config.Image}}' "$(docker compose ps -q "$svc")")
  docker rm -f "$name" >/dev/null 2>&1
  mkdir -p "$SCRATCH/$name"
  chmod 755 "$SCRATCH/$name"
  docker run -d --name "$name" --network none \
    --security-opt no-new-privileges:true --cap-drop ALL \
    --cap-add CHOWN --cap-add DAC_READ_SEARCH --cap-add FOWNER --cap-add SETGID --cap-add SETUID \
    --env-file "$envf" -v "$SCRATCH/$name:$mount" "$@" "$image" >/dev/null
}

load_failed() {   # <service> <log file>
  fail "restore $1: loading the dump failed"
  while IFS= read -r l; do note "$l"; done < <(tail -n 3 "$2")
}

test_postgres() {
  local name=bv-postgres dump="$SCRATCH/restore$DUMPDIR/postgres.sql" user live rest errs
  user=$(docker compose exec -T postgres sh -c 'printf %s "$POSTGRES_USER"')
  printf 'POSTGRES_USER=%s\nPOSTGRES_HOST_AUTH_METHOD=trust\n' "$user" > "$SCRATCH/$name.env"
  throwaway "$name" postgres "$SCRATCH/$name.env" /var/lib/postgresql
  if ! wait_ready "$name" pg_isready -h 127.0.0.1 -U "$user"; then
    fail "restore postgres: throwaway database didn't start"; return
  fi
  docker exec -i "$name" psql -q -U "$user" -d postgres < "$dump" > "$SCRATCH/$name.log" 2>&1
  # pg_dumpall recreates the superuser the throwaway already has: expected.
  errs=$(grep 'ERROR:' "$SCRATCH/$name.log" | grep -v 'already exists')
  if [[ -n $errs ]]; then
    fail "restore postgres: $(grep -c . <<<"$errs") errors while loading"
    while IFS= read -r l; do note "$l"; done < <(head -n 3 <<<"$errs")
  fi
  live=$(pg_counts "$user" docker compose exec -T postgres)
  rest=$(pg_counts "$user" docker exec -i "$name")
  compare_counts postgres "$live" "$rest"
  docker rm -f "$name" >/dev/null
}

test_mysql() {   # <service> <root password secret> <client> <admin> <data mount> [extra env lines] [docker run args...]
  local svc=$1 secret=$2 client=$3 admin=$4 mount=$5 extra=${6:-} name="bv-$1" live rest
  shift 5; shift $(( $# > 0 ))
  local dump="$SCRATCH/restore$DUMPDIR/$svc.sql"
  # Runs "$0 $@" inside the throwaway with its root password (from its env;
  # MYSQL_PWD in the env itself would break the image's first-start setup).
  # BV_NO_PASSWORD: the image leaves root@localhost without one (linuxserver).
  local as_root=(docker exec -i "$name" sh -c \
    '[ -n "${BV_NO_PASSWORD:-}" ] || export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec "$0" "$@"')
  printf 'MYSQL_ROOT_PASSWORD=%s\n%s' "$(head -c 24 /dev/urandom | base64 | tr -dc A-Za-z0-9)" "$extra" \
    > "$SCRATCH/$name.env"
  throwaway "$name" "$svc" "$SCRATCH/$name.env" "$mount" "$@"
  # ping exits 0 even when access is denied: it only waits for the server.
  if ! wait_ready "$name" "$admin" ping -h 127.0.0.1 --silent; then
    fail "restore $svc: throwaway database didn't start"; return
  fi
  # The dump replaces the grant tables, but without FLUSH PRIVILEGES, so the
  # throwaway's root password keeps working for the counts below.
  if ! "${as_root[@]}" "$client" -uroot < "$dump" > "$SCRATCH/$name.log" 2>&1; then
    load_failed "$svc" "$SCRATCH/$name.log"
  else
    live=$(my_counts "$client" docker compose exec -T "$svc" \
      sh -c "MYSQL_PWD=\"\$(cat /run/secrets/$secret)\" exec \"\$0\" \"\$@\"")
    rest=$(my_counts "$client" "${as_root[@]}")
    compare_counts "$svc" "$live" "$rest"
  fi
  docker rm -f "$name" >/dev/null
}

cleanup() {
  docker rm -f bv-postgres bv-db bv-leantime_db bv-mariadb >/dev/null 2>&1
  # Only ever a folder of its own under /var/tmp, never an empty path.
  [[ $SCRATCH == /var/tmp/?* ]] && rm -rf -- "$SCRATCH"
}

# Restore test for one database service (its dump must be restored already).
test_db() {
  case $1 in
    postgres)    test_postgres ;;
    db)          test_mysql db          ghost_db_root_password    mysql mysqladmin /var/lib/mysql ;;
    leantime_db) test_mysql leantime_db leantime_db_root_password mysql mysqladmin /var/lib/mysql ;;
    # linuxserver's first-run setup creates /config/* as root, after chowning
    # /config to PUID: without DAC_OVERRIDE root can't write there. Only this
    # throwaway gets it (no network, deleted afterwards); the live one never
    # runs that setup.
    mariadb)     test_mysql mariadb grimmory_db_root_password mariadb mariadb-admin /config \
                   "$(printf 'PUID=%s\nPGID=%s\nBV_NO_PASSWORD=1\n' "$(env_value PUID)" "$(env_value PGID)")" \
                   --cap-add DAC_OVERRIDE ;;
    *)           fail "restore $1: no test for this service" ;;
  esac
}

# Prepare the scratch folder; fails if there isn't room.
scratch_ready() {
  local free
  cleanup
  mkdir -p "$SCRATCH"
  free=$(df --output=avail -BG "$(dirname "$SCRATCH")" | tail -n1 | tr -dc 0-9)
  if (( free < MIN_SCRATCH_GB )); then
    fail "restore: only ${free}G free for the test (needs ${MIN_SCRATCH_GB}G)"; return 1
  fi
  trap cleanup EXIT
}

weekly_restore() {
  local svc
  scratch_ready || return
  check_repo
  restore_latest || return
  for svc in "${DUMPS[@]}"; do test_db "$svc"; done
}

# One database only, from the newest snapshot's dump (no mail).
single_restore() {
  scratch_ready || return
  if ! r LOCAL restore latest --target "$SCRATCH/restore" --include "$DUMPDIR/$1.sql" >/dev/null 2>&1; then
    fail "restore $1: couldn't restore its dump"; return
  fi
  test_db "$1"
}

# --- mail ---------------------------------------------------------------------
send_mail() {   # <subject>, body on stdin
  local subject=$1 host port user from to proto msg
  host=$(env_value SMTP__HOST); port=$(env_value SMTP__PORT)
  user=$(env_value SMTP__USERNAME); from=$(env_value BACKUP__MAIL_FROM)
  to=$(env_value EMAIL_ADMIN)
  [[ $(env_value SMTP__USE_SSL) == true ]] && proto=smtps || proto=smtp
  msg=$(mktemp)
  {
    printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n' \
      "$from" "$to" "$subject" "$(date -R)"
    printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
    cat
  } > "$msg"
  # Credentials through a file descriptor: never in argv, so not in `ps`.
  if curl -sS --ssl-reqd --max-time 60 "$proto://$host:$port" \
       -K <(printf 'user = "%s:%s"\n' "$user" "$(cat "$DOCKERDIR/secrets/smtp/password")") \
       --mail-from "$from" --mail-rcpt "$to" --upload-file "$msg"; then
    echo "mail sent: $subject"
  else
    echo "mail FAILED: $subject"
  fi
  rm -f "$msg"
}

finish() {   # <mode> <always mail?>
  echo "== backup-verify $1 $(date '+%F %T')"
  printf '%s\n' "${REPORT[@]}"
  if (( FAILED )); then
    printf '%s\n' "${REPORT[@]}" | send_mail "Backups: problem on $(hostname)"
  elif [[ $2 == yes ]]; then
    printf '%s\n' "${REPORT[@]}" | send_mail "Backups: weekly check OK on $(hostname)"
  fi
  exit "$FAILED"
}

# --- main ---------------------------------------------------------------------
case ${1:-daily} in
  daily)
    check_dumps; check_local; check_pc; check_disk
    finish daily no
    ;;
  weekly)
    t0=$SECONDS
    check_dumps; check_local; check_pc; check_disk
    weekly_restore
    note "took $(( (SECONDS - t0) / 60 )) min"
    finish weekly yes
    ;;
  test-db)
    t0=$SECONDS
    single_restore "${2:?usage: $0 test-db <service>}"
    printf '%s\n' "${REPORT[@]}"
    echo "took $(( SECONDS - t0 ))s"
    exit "$FAILED"
    ;;
  test-mail)
    echo "Test from scripts/backup-verify.sh." | send_mail "Backups: test from $(hostname)"
    ;;
  *)
    echo "usage: $0 daily|weekly|test-db <service>|test-mail" >&2; exit 2 ;;
esac
