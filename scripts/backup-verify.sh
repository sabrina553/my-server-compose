#!/usr/bin/env bash
# Check that the backups are actually happening, and e-mail when they aren't.
#
#   sudo ./scripts/backup-verify.sh daily       (cron, after the morning backup)
#   sudo ./scripts/backup-verify.sh test-mail   (send one test e-mail)
#
# Daily checks:
#   - each database dump (scripts/db-dump.sh) is fresh, finished, and hasn't
#     shrunk below half its previous size (an empty database dumps small)
#   - the server's newest MAIN snapshot is fresh and contains the dumps
#   - the PC's repos have a recent snapshot (the PC may be off: if it can't be
#     reached, the last snapshot time seen is used instead)
#   - the disk isn't nearly full
#
# Any failure sends an e-mail to EMAIL_ADMIN from BACKUP__MAIL_FROM. On Sundays
# an "all OK" summary is sent too, so silence never passes for success.
#
# SMTP settings come from .env (read here, never printed); the password from
# secrets/smtp/password, handed to curl on a file descriptor, not argv.
set -uo pipefail

DOCKERDIR=${DOCKERDIR:-/opt/docker}
RESTIC_SCRIPTS=${RESTIC_SCRIPTS:-/srv/restic-repo/scripts}
DUMPDIR=${DUMPDIR:-/var/backups/db-dumps}
STATE=${STATE:-/var/lib/backup-verify}
ENV_FILE="$DOCKERDIR/.env"

DUMPS=(postgres db leantime_db mariadb)   # service keys, as in db-dump.sh
MAX_DUMP_AGE_H=14       # dumps run 06:20 and 18:20
MAX_LOCAL_AGE_H=14      # backup runs 06:30 and 18:30
MAX_PC_AGE_D=3          # the PC isn't always on
MAX_DISK_PCT=85

umask 077
mkdir -p "$STATE"

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

age_hours() { echo $(( ($(date +%s) - $1) / 3600 )); }

# --- restic -------------------------------------------------------------------
# restic against one of the repos in the restic scripts (LOCAL, SAPPHIRE, ...).
r() {
  local repo=$1; shift
  (cd "$RESTIC_SCRIPTS" && timeout 300 restic --no-lock \
    --repository-file="identities/${repo}_REPO" \
    --password-file="identities/${repo}_PASSWORD" "$@")
}

# Epoch of the newest snapshot (optionally with a tag), or nothing.
latest_snapshot() {
  local repo=$1 tag=${2:-} t
  t=$(r "$repo" snapshots --json --latest 1 ${tag:+--tag "$tag"} 2>/dev/null \
      | jq -r 'map(.time) | sort | last // empty') || return 1
  [[ -n $t ]] && date -d "$t" +%s
}

# --- checks -------------------------------------------------------------------
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
  n=$(r LOCAL ls latest "$DUMPDIR" 2>/dev/null | grep -c '\.sql$')
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

# --- main ---------------------------------------------------------------------
case ${1:-daily} in
  daily)
    check_dumps; check_local; check_pc; check_disk
    echo "== backup-verify daily $(date '+%F %T')"
    printf '%s\n' "${REPORT[@]}"
    if (( FAILED )); then
      printf '%s\n' "${REPORT[@]}" | send_mail "Backups: problem on $(hostname)"
    elif [[ $(date +%u) == 7 ]]; then
      printf '%s\n' "${REPORT[@]}" | send_mail "Backups: all OK on $(hostname)"
    fi
    exit "$FAILED"
    ;;
  test-mail)
    echo "Test from scripts/backup-verify.sh." | send_mail "Backups: test from $(hostname)"
    ;;
  *)
    echo "usage: $0 daily|test-mail" >&2; exit 2 ;;
esac
