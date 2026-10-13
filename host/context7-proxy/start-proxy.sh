#!/bin/sh
# Starts the Context7 proxy in the foreground: loads the API key, then runs
# Caddy with the Caddyfile beside this script. Ctrl-C stops it.
#
# The key comes from CONTEXT7_API_KEY when it is already set, for example by a
# password manager's command line tool, and otherwise from the first line of
# the file CONTEXT7_API_KEY_FILE names, by default
# ~/.config/context7-proxy/api-key. That file must be readable by its owner only.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

die() {
  printf 'start-proxy.sh: %s\n' "$*" >&2
  exit 1
}

command -v caddy >/dev/null 2>&1 ||
  die "caddy is not installed. Install it (https://caddyserver.com/docs/install) and run this again."

if [ -z "${CONTEXT7_API_KEY:-}" ]; then
  key_file=${CONTEXT7_API_KEY_FILE:-$HOME/.config/context7-proxy/api-key}
  [ -f "$key_file" ] ||
    die "no API key: set CONTEXT7_API_KEY, or put the key in $key_file (README.md shows how)."
  # ls -l's mode column reads the same on macOS and Linux; -L reports the
  # file a symlink points to.
  case $(ls -ldL "$key_file") in
    -???------*) ;;
    *) die "$key_file can be read by other users. Run: chmod 600 \"$key_file\"" ;;
  esac
  read -r CONTEXT7_API_KEY <"$key_file" || true
fi
[ -n "$CONTEXT7_API_KEY" ] || die "the API key is empty."
export CONTEXT7_API_KEY

exec caddy run --config "$here/Caddyfile" --adapter caddyfile
