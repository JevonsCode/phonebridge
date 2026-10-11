#!/bin/sh
# PhoneBridge MCP bootstrap v1. Static, version-independent entry point.
set -eu
fail() { printf '%s\n' 'PhoneBridge MCP could not start. Check the current-user desktop installation and configuration.' >&2; exit 1; }
[ "$#" -eq 0 ] || fail
state=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || fail
config="$state/desktop-macos.json"
[ -f "$config" ] && [ ! -L "$config" ] || fail
uid=$(/usr/bin/id -u)
[ "$(/usr/bin/stat -f %u "$config")" = "$uid" ] || fail
[ "$(/usr/bin/stat -f %Lp "$config")" = 600 ] || fail
[ "$(/usr/bin/stat -f %z "$config")" -le 32768 ] || fail
[ "$(/usr/bin/plutil -extract schema raw -o - "$config")" = phonebridge-macos-desktop-v1 ] || fail
[ "$(/usr/bin/plutil -extract ownerUid raw -o - "$config")" = "$uid" ] || fail
root=$(/usr/bin/plutil -extract projectRoot raw -o - "$config") || fail
node=$(/usr/bin/plutil -extract nodePath raw -o - "$config") || fail
case "$root" in /*) ;; *) fail ;; esac
[ "$node" = "$root/runtime/node" ] && [ -x "$node" ] && [ -f "$root/desktop/mcp-bootstrap.mjs" ] || fail
unset NODE_OPTIONS NODE_PATH PHONEBRIDGE_TOKEN
exec "$node" "$root/desktop/mcp-bootstrap.mjs" "$config"
