#!/usr/bin/env bash
# Regenerate .env.example from .env, replacing every value in the ###SITE###
# block with a placeholder. .env stays gitignored; .env.example is safe to commit.
#
# NOTE: the normal direction is the reverse: edit .env.example, then run
# scripts/apply-env-example.sh. Use this only to recover from a .env that was
# edited by hand, and review `git diff .env.example` before committing.
#
#   ./scripts/make-env-example.sh            (run from the docker/ directory)
#
# Only the SITE block is rewritten, so keep anything personal or site-specific
# in that block. The script refuses to run if .env contains something that
# looks like a secret (secrets belong in secrets/, not .env).
set -euo pipefail
cd "$(dirname "$0")/.."

# Anything assigned a literal value (not a /run/secrets path) under a name
# that sounds secret is a mistake worth stopping for.
if grep -nE '^[A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|_KEY|PASS)[A-Za-z0-9_]*=' .env \
    | grep -vE '_FILE=|="?/run/secrets/|="?file:///run/secrets/|="?(true|false)"?$'; then
  echo "Refusing: the lines above look like secrets in .env. Move them to secrets/ first." >&2
  exit 1
fi

awk '
  /^###SITE###/                 { site = 1; print; next }
  site && /^###/                { site = 0 }
  site && /^[A-Za-z_][A-Za-z0-9_]*=/ {
    split($0, kv, "=")
    print kv[1] "=\"CHANGE_ME\""
    next
  }
  { print }
' .env > .env.example

echo "Wrote .env.example ($(grep -c '="CHANGE_ME"' .env.example) SITE values blanked)"
