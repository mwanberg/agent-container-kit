#!/bin/sh
#
# key-check.sh: passes only when an OpenPGP key file holds exactly one primary
# key, the pinned one. That key's own subkeys pass with it. apt and gpg accept
# every key in a keyring they are given, so any other primary key, added or
# in place of the pin, fails.
#
# Usage: key-check.sh <key-file> <fingerprint> <message-id> [name=value ...]
#
# On failure it prints the fix-it block <message-id> to standard error, with
# {primaries} set to the primary-key fingerprints found and any name=value
# given passed on, and exits 1. Needs gpg and awk; fix-it.sh is found beside
# this script.

file=$1 pin=$2 id=$3
shift 3
# The fingerprint record that follows each pub record is a primary key's.
primaries="$(gpg --show-keys --with-colons "$file" \
  | awk -F: '$1 == "pub" { p = 1 } $1 == "fpr" && p { printf "%s%s", s, $10; s = " "; p = 0 }')"
[ -n "$pin" ] && [ "$primaries" = "$pin" ] && exit 0
"${0%/*}/fix-it.sh" "$id" primaries="${primaries:-none}" "$@" >&2
exit 1
