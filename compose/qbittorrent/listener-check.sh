#!/bin/sh
# Exit 0 when qBittorrent has a TCP listener on tun0's address and torrenting
# port, 1 when it doesn't. When Gluetun rebuilds tun0, libtorrent can lose that
# socket and never reopen it: the container stays healthy but is unreachable
# (tracker "not connectable", DHT 0 nodes). Used by the healthcheck and by the
# qbittorrent-reannounce service. Run as `sh`, so the file's mode doesn't matter.
# Listener state: /proc/net/tcp, st 0A = LISTEN, address is little-endian hex.
addr=$(ip -4 -o addr show tun0 2>/dev/null | awk '{sub("/.*", "", $4); print $4; exit}')
[ -n "$addr" ] || exit 1
set -- $(echo "$addr" | tr . ' ')
want=$(printf '%02X%02X%02X%02X:%04X' "$4" "$3" "$2" "$1" "$TORRENTING_PORT")
awk -v w="$want" '$2 == w && $4 == "0A" { f = 1 } END { exit !f }' /proc/net/tcp
