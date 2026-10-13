#!/usr/bin/env python3
"""Claude Code PreToolUse hook (Bash): block commands whose output may carry
personal or secret values unless that output goes through scripts/redact.sh.

Risky: container logs and inspect output, the systemd journal, git history,
restic (snapshots and listings carry real paths and hostnames), and anything
reading Docker volumes, the database dumps or the /opt/bak backups. Such a command
must end in `| scripts/redact.sh` (any path to it), and `docker logs` /
`docker compose logs` must also merge stderr (2>&1), since that's where
containers' error output goes.

Exit 2 blocks the call; the message on stderr goes back to Claude.
This is a tripwire for honest mistakes, not a sandbox.
"""
import json
import re
import sys

RISKY = re.compile(
    r"\bdocker\s+(?:compose\s+)?logs\b"
    r"|\bdocker\s+(?:container\s+)?inspect\b"
    r"|\bjournalctl\b"
    r"|\bgit\s+(?:-C\s+\S+\s+)?(?:log|show|reflog|blame)\b"
    r"|\brestic\b"
    r"|/var/lib/docker/volumes"
    r"|/var/backups/db-dumps"
    r"|/opt/bak\b"
)
ENDS_REDACTED = re.compile(r"\|\s*(?:\S*/)?scripts/redact\.sh\s*$")
LOGS = re.compile(r"\b(?:docker\s+(?:compose\s+)?logs|journalctl)\b")


def main():
    try:
        cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except (ValueError, AttributeError):
        return 0
    if not isinstance(cmd, str) or not RISKY.search(cmd):
        return 0
    if not ENDS_REDACTED.search(cmd.rstrip()):
        print("Blocked by .claude/hooks/redact-guard.py: this command reads logs, "
              "inspect output, git history or volume data. End it with "
              "`| scripts/redact.sh` (wrap several commands in { ...; } 2>&1 | "
              "scripts/redact.sh).", file=sys.stderr)
        return 2
    if LOGS.search(cmd) and "2>&1" not in cmd:
        print("Blocked by .claude/hooks/redact-guard.py: log output goes partly "
              "to stderr, which redact.sh doesn't see. Add 2>&1 before the "
              "pipe.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
