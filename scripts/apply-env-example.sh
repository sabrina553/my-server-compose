#!/usr/bin/env bash
# Rebuild .env from .env.example, keeping this machine's ###SITE### values.
#
#   ./scripts/apply-env-example.sh            (run from anywhere in the repo)
#   ./scripts/apply-env-example.sh --force    (skip the drift check, see below)
#
# .env.example is the source of truth: change settings there (it's tracked),
# run this, then `docker compose up -d`. .env is never opened by hand.
#
# Only the values inside ###SITE### come from the current .env; every other
# line comes from .env.example. Before writing, it stops if:
#   - a setting outside SITE differs between .env and .env.example (someone
#     edited .env directly: copy that change into .env.example first), or
#   - .env has a SITE key that .env.example no longer has (it would be lost).
# Output names keys only, never values. The old .env is kept as .env.bak-<time>.
set -euo pipefail
cd "$(dirname "$0")/.."

force=0
[[ ${1:-} == --force ]] && force=1

[[ -f .env.example ]] || { echo ".env.example not found" >&2; exit 1; }
if [[ ! -f .env ]]; then
  echo "No .env yet. Start one with: cp .env.example .env && chmod 600 .env," >&2
  echo "then fill in the ###SITE### values." >&2
  exit 1
fi

# Every KEY=... line, tagged with whether it sits inside the SITE block.
# Output: SECTION <TAB> KEY <TAB> raw line
lines() {
  awk '
    /^###SITE###/ { site = 1; next }
    site && /^###/ { site = 0 }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
      key = $0; sub(/[[:space:]]*=.*/, "", key)
      print (site ? "SITE" : "MAIN") "\t" key "\t" $0
    }' "$1"
}

# 1. Drift check: settings outside SITE must match the template exactly.
drift=$(awk -F'\t' '
  NR == FNR { ex[$1 FS $2] = $3; next }
  $1 == "MAIN" && (($1 FS $2) in ex) && ex[$1 FS $2] != $3 { print "  differs:      " $2 }
  $1 == "MAIN" && !(($1 FS $2) in ex)                       { print "  only in .env: " $2 }
  $1 == "SITE" && !(("SITE" FS $2) in ex)                   { print "  SITE key not in template (would be lost): " $2 }
' <(lines .env.example) <(lines .env))

if [[ -n $drift ]]; then
  echo "Your .env has changes that aren't in .env.example:"
  echo "$drift"
  if (( ! force )); then
    echo "Copy them into .env.example (or confirm they can go), then re-run." >&2
    echo "Re-run with --force to discard them." >&2
    exit 1
  fi
  echo "--force given: discarding them."
fi

# 2. Build the new .env: the template, with SITE values from the current .env.
tmp=$(mktemp .env.new.XXXXXX)
missing_list=$(mktemp)
trap 'rm -f "$tmp" "$missing_list"' EXIT
chmod 600 "$tmp"

awk -F'\t' -v miss="$missing_list" '
  NR == FNR { if ($1 == "SITE") site[$2] = $3; next }
  /^###SITE###/ { in_site = 1; print; next }
  in_site && /^###/ { in_site = 0 }
  in_site && /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
    key = $0; sub(/[[:space:]]*=.*/, "", key)
    if (key in site) { print site[key]; next }
    print "  " key > miss
  }
  { print }
' <(lines .env) .env.example > "$tmp"
missing=$(cat "$missing_list")

# 3. Swap it in, keeping a backup.
backup=".env.bak-$(date +%F-%H%M%S)"
cp -p .env "$backup"
chmod 600 "$backup"
mv "$tmp" .env
rm -f "$missing_list"
trap - EXIT

added=$(comm -13 <(lines "$backup" | cut -f2 | sort -u) <(lines .env | cut -f2 | sort -u) | sed 's/^/  + /')
removed=$(comm -23 <(lines "$backup" | cut -f2 | sort -u) <(lines .env | cut -f2 | sort -u) | sed 's/^/  - /')

echo "Rebuilt .env from .env.example (old one saved as $backup)."
[[ -n $added ]]   && { echo "New settings:"; echo "$added"; }
[[ -n $removed ]] && { echo "Removed settings:"; echo "$removed"; }
if [[ -n $missing ]]; then
  echo "SITE values still to fill in (left as in the template):"
  echo "$missing"
fi
echo "Next: docker compose config -q && docker compose up -d"
echo "Delete $backup once everything works."
