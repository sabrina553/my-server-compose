#!/usr/bin/env bash
# Show what a change to the compose files does to the rendered configuration.
#
#   scripts/compose-diff.sh            working tree vs HEAD
#   scripts/compose-diff.sh <ref>      working tree vs <ref> (commit, branch, tag)
#   scripts/compose-diff.sh --all [<ref>]
#        also render the disabled services: on copies of both sides, the
#        commented-out `# - compose/...` includes in compose.yaml are enabled
#        (the repo itself is never changed)
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
all=0
[[ ${1:-} == --all ]] && { all=1; shift; }
ref=${1:-HEAD}

git rev-parse --verify -q "$ref^{commit}" >/dev/null || { echo "Unknown ref: $ref" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/base"
git archive "$ref" | tar -x -C "$tmp/base"
new=$repo
if (( all )); then
  # Copy the working tree (tracked + untracked, minus ignored files such as
  # .env and secrets/) and enable every commented-out include on both sides.
  new=$tmp/new
  mkdir "$new"
  git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - | tar -x -C "$new"
  for side in "$tmp/base" "$new"; do
    sed -i -E 's|^([[:space:]]*)#[[:space:]]*- (compose/)|\1- \2|' "$side/compose.yaml"
  done
fi

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
render "$new" "$tmp/new.json" "working tree"

python3 -I - "$tmp/base.json" "$tmp/new.json" "$tmp/base" "$repo" "$ref" "$new" > "$tmp/diff" <<'EOF'
import difflib, json, sys
base_f, new_f, base_dir, repo, ref, new_dir = sys.argv[1:]

def load(path):
    # Relative paths resolve to the side's own directory; absolute ones (from
    # .env, e.g. $DOCKERDIR) to the real repo. Make both look the same.
    text = (open(path).read().replace(base_dir, "<repo>")
            .replace(new_dir, "<repo>").replace(repo, "<repo>"))
    return json.dumps(json.loads(text), indent=2, sort_keys=True).splitlines()

a, b = load(base_f), load(new_f)
diff = list(difflib.unified_diff(a, b, ref, "working tree", n=3, lineterm=""))
print("\n".join(diff) if diff else "No differences.")
EOF

scripts/redact.sh < "$tmp/diff"
grep -qx 'No differences.' "$tmp/diff" && exit 0 || exit 1
