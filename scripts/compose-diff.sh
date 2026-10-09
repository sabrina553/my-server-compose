#!/usr/bin/env bash
# Show what a change to the compose files does to the rendered configuration.
#
#   scripts/compose-diff.sh            working tree vs HEAD
#   scripts/compose-diff.sh <ref>      working tree vs <ref> (commit, branch, tag)
#
# Both sides are rendered with `docker compose config` against this server's
# real .env, normalised (sorted JSON, repo paths made identical) and compared.
# Only the differences are printed, and they go through scripts/redact.sh, so
# SITE values, e-mails, IPs and tokens are masked. Rendered values never leave
# this script otherwise. Exit code: 0 no differences, 1 differences, 2 error.
#
# Note that Compose already normalises styles: list vs map environments and
# labels, and key order, render identically. A refactor that only touches
# layout should print "No differences."
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
ref=${1:-HEAD}

git rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "Unknown ref: $ref" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/base"
git archive "$ref" | tar -x -C "$tmp/base"

render() { # <project dir> <output file>
  (cd "$1" && docker compose --env-file "$repo/.env" --project-name docker \
     config --format json) > "$2" 2> "$2.err" || {
    echo "Rendering failed for $3:" >&2
    scripts_dir=$repo/scripts
    "$scripts_dir/redact.sh" < "$2.err" >&2
    exit 2
  }
}
render "$tmp/base" "$tmp/base.json" "$ref"
render "$repo" "$tmp/new.json" "working tree"

python3 -I - "$tmp/base.json" "$tmp/new.json" "$tmp/base" "$repo" "$ref" > "$tmp/diff" <<'EOF'
import difflib, json, sys
base_f, new_f, base_dir, repo, ref = sys.argv[1:]

def load(path):
    # Relative paths resolve to the side's own directory; absolute ones (from
    # .env, e.g. $DOCKERDIR) to the real repo. Make both look the same.
    text = open(path).read().replace(base_dir, "<repo>").replace(repo, "<repo>")
    return json.dumps(json.loads(text), indent=2, sort_keys=True).splitlines()

a, b = load(base_f), load(new_f)
diff = list(difflib.unified_diff(a, b, ref, "working tree", n=3, lineterm=""))
print("\n".join(diff) if diff else "No differences.")
EOF

scripts/redact.sh < "$tmp/diff"
grep -qx 'No differences.' "$tmp/diff" && exit 0 || exit 1
