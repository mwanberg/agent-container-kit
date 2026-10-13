#!/bin/bash
# Tests for the scratch-copy helper: copies, variants, --stdin, --done, the
# 3-day sweep, and every rejected input. Runs against a scratch root inside its own
# temporary folder, so the real scratch root is never touched.
# Usage: scratch-copy.test.sh [helper-path]
# The helper defaults to the DDEV sidecar's copy in this kit.
set -u
if ! date -d @0 >/dev/null 2>&1 || ! stat -c %a / >/dev/null 2>&1; then
  echo "scratch-copy.test.sh: needs GNU date and stat; run it on Linux or inside the sidecar." >&2
  exit 2
fi
helper="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/../ddev-sidecar/overlay/add/.ddev/claude" && pwd)/scratch-copy.sh}"
work=$(mktemp -d)
root="$work/root"
src="$work/src"
export SCRATCH_COPY_ROOT="$root"
pass=0
fail=0
out=""
status=0

mkdir "$src" "$src/other" "$src/dir"
printf '#!/bin/sh\necho a\n' > "$src/a.sh"
chmod 755 "$src/a.sh"
printf 'b\n' > "$src/b.txt"
chmod 640 "$src/b.txt"
printf 'other a\n' > "$src/other/a.sh"

run() { out=$("$helper" "$@" 2>&1); status=$?; }
run_at() { # root args...
  local r="$1"; shift
  out=$(SCRATCH_COPY_ROOT="$r" "$helper" "$@" 2>&1); status=$?
}
expect() { # name command...
  local name="$1"; shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name (status $status): $out"
  fi
}
folder() { printf '%s\n' "$out" | sed -n 's/^Folder: //p'; }
says() { [[ "$out" == *"$1"* ]]; }
succeeded() { [ "$status" -eq 0 ]; }
gone() { [ -n "$1" ] && [ ! -e "$1" ]; }
same_mode() { [ "$(stat -c %a "$1")" = "$(stat -c %a "$2" 2>/dev/null)" ]; }
named() { # folder label
  [ "${1%/*}" = "$root" ] && [[ "${1##*/}" =~ ^[0-9]{8}-[0-9]{6}-$2-[A-Za-z0-9]{6}$ ]]
}
holds() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }

# A rejected call exits non-zero, prints why, and leaves the scratch root as it was.
refused() { # text root-listing-before
  [ "$status" -ne 0 ] && says "$1" && [ "$(ls -A "$root" 2>/dev/null)" = "$2" ]
}
refuses() { # name text args...
  local name="$1" text="$2" before; shift 2
  before=$(ls -A "$root" 2>/dev/null)
  run "$@"
  expect "$name" refused "$text" "$before"
}
refuses_at() { # name text root args...
  local name="$1" text="$2" r="$3" before; shift 3
  before=$(ls -A "$root" 2>/dev/null)
  run_at "$r" "$@"
  expect "$name" refused "$text" "$before"
}

# Copies: default variant, content, mode, printed paths and notice.
run --label t-one "$src/a.sh" "$src/b.txt"
f=$(folder)
expect "copy succeeds" succeeded
expect "folder is <date-time>-<label>-<random> under the root" named "$f" t-one
expect "copy keeps content" cmp -s "$src/a.sh" "$f/original/a.sh"
expect "copy keeps the executable mode" same_mode "$src/a.sh" "$f/original/a.sh"
expect "copy keeps a restricted mode" same_mode "$src/b.txt" "$f/original/b.txt"
expect "copy prints each path" says "$f/original/b.txt"
expect "copy prints the notice" says "Temporary copies. Removed by --done"
run --done "$f"
expect "done succeeds" succeeded
expect "done removes the folder" gone "$f"

# Variants: every file in every variant.
run --label t-variants --variant original --variant new "$src/a.sh" "$src/b.txt"
f=$(folder)
expect "variant original holds the file" cmp -s "$src/a.sh" "$f/original/a.sh"
expect "variant new holds the file" cmp -s "$src/a.sh" "$f/new/a.sh"
expect "variant new holds the second file" cmp -s "$src/b.txt" "$f/new/b.txt"
run --done "$f"
expect "done removes a variant layout" gone "$f"

# --stdin: piped content under the given name, in every variant.
out=$(printf 'piped\n' | "$helper" --label t-stdin --stdin piped.sh --variant x --variant y 2>&1); status=$?
f=$(folder)
expect "stdin succeeds" succeeded
expect "stdin fills the first variant" holds "$f/x/piped.sh" piped
expect "stdin fills the second variant" holds "$f/y/piped.sh" piped
run --done "$f"
expect "done removes a stdin copy" gone "$f"

# --done leaves a file it did not create, and names it.
run --label t-added "$src/b.txt"
f=$(folder)
printf 'added\n' > "$f/original/added.txt"
run --done "$f"
expect "done removes the listed copy" [ -d "$f/original" -a ! -e "$f/original/b.txt" ]
expect "done leaves an added file" [ -f "$f/original/added.txt" ]
expect "done names the added file" says "Left behind: $f/original/added.txt"
rm -f "$f/original/added.txt"
rmdir "$f/original" "$f"

# The sweep: helper folders older than 3 days go at the start of any run.
run --label t-recent "$src/b.txt"
recent="$root/$(date -d '2 days ago' +%Y%m%d-%H%M%S)-t-recent-abcdef"
mv "$(folder)" "$recent"
run --label t-old "$src/b.txt"
old="$root/20000101-000000-t-old-abcdef"
mv "$(folder)" "$old"
foreign="$root/20000101-000000-foreign-abcdef"
mkdir "$foreign"
had_old=no
[ -f "$old/original/b.txt" ] && had_old=yes
run --label t-sweep "$src/b.txt"
f=$(folder)
expect "sweep removes a helper folder older than 3 days" [ "$had_old" = yes -a ! -e "$old" ]
expect "sweep keeps a helper folder 2 days old" [ -f "$recent/original/b.txt" ]
expect "sweep keeps a folder without the helper's list" [ -d "$foreign" ]
run --done "$f"
had_recent=no
[ -f "$recent/original/b.txt" ] && had_recent=yes
run --done "$recent"
expect "done removes a renamed folder" [ "$had_recent" = yes -a ! -e "$recent" ]
rmdir "$foreign"

# Rejected input: names, variants, files.
refuses "no label" "--label" "$src/a.sh"
refuses "uppercase label" "label" --label Bad "$src/a.sh"
refuses "label with a slash" "label" --label ../x "$src/a.sh"
refuses "label over 40 characters" "label" --label "$(printf 'a%.0s' {1..41})" "$src/a.sh"
refuses "bad variant name" "variant" --label t --variant 'a b' "$src/a.sh"
refuses "repeated variant" "variant" --label t --variant a --variant a "$src/a.sh"
refuses "repeated default variant" "variant" --label t --variant original --variant original "$src/a.sh"
refuses "two files with one name" "same name" --label t "$src/a.sh" "$src/other/a.sh"
refuses "a folder" "not a file" --label t "$src/dir"
refuses "a missing file" "not a file" --label t "$src/missing"
refuses "no files" "no files" --label t
refuses "an unknown option" "unknown option" --label t --force "$src/a.sh"
refuses "an option missing its value" "needs a value" --label
refuses "stdin name with a slash" "stdin" --label t --stdin a/b
refuses "stdin name of dots" "stdin" --label t --stdin ..
refuses "stdin with file arguments" "stdin" --label t --stdin x "$src/a.sh"

# Rejected input: the scratch root.
mkdir "$work/real" "$work/real/sub"
ln -s "$work/real" "$work/link"
printf 'x\n' > "$work/rootfile"
refuses_at "root that is a symlink" "plain path" "$work/link" --label t "$src/a.sh"
refuses_at "root reached through a symlink" "plain path" "$work/link/sub" --label t "$src/a.sh"
refuses_at "root with .." "plain path" "$work/real/../real/sub" --label t "$src/a.sh"
refuses_at "root owned by another user" "owned" /tmp --label t "$src/a.sh"
refuses_at "root that is a file" "not a folder" "$work/rootfile" --label t "$src/a.sh"
refuses_at "root outside /tmp" "under /tmp" /scratch-copy-test-root --label t "$src/a.sh"
expect "a rejected symlinked root gains nothing" [ -z "$(ls -A "$work/real/sub")" ]

# Rejected input: --done.
mkdir "$root/no-list"
refuses "done outside the root" "direct child" --done "$work/real"
refuses "done on the root itself" "direct child" --done "$root"
refuses "done on a folder without the list" "list" --done "$root/no-list"
refuses "done with other arguments" "only" --done "$root/no-list" --label t
rmdir "$root/no-list"
printf 'victim\n' > "$work/victim.txt"
run --label t-forged "$src/b.txt"
f=$(folder)
printf 'original/../../../victim.txt\n' >> "$f/.scratch-copy-list"
refuses "done with a list entry outside the folder" "outside" --done "$f"
expect "a forged entry's target survives" [ -f "$work/victim.txt" ]
expect "a rejected done removes nothing" [ -f "$f/original/b.txt" ]
rm -f "$f/original/b.txt" "$f/.scratch-copy-list" "$work/victim.txt"
rmdir "$f/original" "$f"

rm -f "$src/a.sh" "$src/b.txt" "$src/other/a.sh" "$work/rootfile" "$work/link"
rmdir "$src/other" "$src/dir" "$src" "$work/real/sub" "$work/real" "$root" "$work" 2>/dev/null
[ -e "$work" ] && echo "Left in $work:" && find "$work"
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
