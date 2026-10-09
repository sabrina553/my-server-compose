#!/usr/bin/env bash
# Mask personal and secret-looking values in text on stdin.
#
#   docker logs authelia 2>&1 | scripts/redact.sh
#   git log --format='%h %ae %s' | scripts/redact.sh
#
# Replaced, in this order:
#   - every value in .env's ###SITE### block (domain, paths, accounts...),
#     shown as <KEY>; values that are only digits or shorter than 4 characters
#     are skipped
#   - each non-empty line of .env.redact (optional, gitignored, one literal
#     per line, e.g. personal e-mail addresses or a username), as <redacted>
#   - e-mail addresses -> <email>
#   - IPv4 addresses outside Docker's 172.16.0.0/12 and 127.0.0.0/8 -> <ip>
#   - password hashes ($argon2.., $pbkdf2.., $2y$.., $apr1$..) -> <hash>
#   - token-like strings of 32+ characters -> <token>
#     (image digests written as sha256:<64 hex> are kept)
#
# Literal values are matched case-insensitively. The script never prints the
# values it reads from .env or .env.redact. It narrows what can leak; it can't
# hide a secret it has no pattern for.
set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 -I -c '
import re, sys

def site_values(path):
    vals, site = {}, False
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return vals
    for line in lines:
        if line.startswith("###SITE###"):
            site = True
            continue
        if site and line.startswith("###"):
            break
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$", line) if site else None
        if not m:
            continue
        v = m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"\x27":
            v = v[1:-1]
        if len(v) >= 4 and not v.isdigit():
            vals[v] = "<" + m.group(1) + ">"
    return vals

def extra_values(path):
    try:
        return {l.strip(): "<redacted>" for l in open(path, encoding="utf-8")
                if len(l.strip()) >= 3}
    except OSError:
        return {}

literals = {**site_values(".env"), **extra_values(".env.redact")}
lit_re = None
if literals:
    keys = sorted(literals, key=len, reverse=True)
    lit_re = re.compile("|".join(re.escape(k) for k in keys), re.I)
    lower = {k.lower(): v for k, v in literals.items()}

email_re = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ip_re = re.compile(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])")
hash_re = re.compile(r"\$(?:argon2(?:id|i|d)|pbkdf2-sha\d+|2[aby]|apr1|[156])\$[^\s\"\x27,;]+")
digest_re = re.compile(r"sha256:[0-9a-f]{64}")
token_re = re.compile(r"[A-Za-z0-9_~+/=.-]{32,}")

def ip(m):
    a, b = int(m.group(1)), int(m.group(2))
    if a == 127 or a == 0 or (a == 172 and 16 <= b <= 31):
        return m.group(0)
    return "<ip>"

def token(m):
    s = m.group(0)
    # Leave paths, dotted names and long words alone: a token has a digit
    # and no slash-separated path shape.
    if "/" in s.strip("/") and s.count("/") > 1:
        return s
    return "<token>" if re.search(r"\d", s) else s

def redact(line):
    if lit_re:
        line = lit_re.sub(lambda m: lower.get(m.group(0).lower(), "<redacted>"), line)
    line = email_re.sub("<email>", line)
    line = hash_re.sub("<hash>", line)
    keep = {}
    def stash(m):
        keep[f"\x00{len(keep)}\x00"] = m.group(0)
        return f"\x00{len(keep) - 1}\x00"
    line = digest_re.sub(stash, line)
    line = token_re.sub(token, line)
    for k, v in keep.items():
        line = line.replace(k, v)
    return ip_re.sub(ip, line)

for line in sys.stdin:
    sys.stdout.write(redact(line))
'
