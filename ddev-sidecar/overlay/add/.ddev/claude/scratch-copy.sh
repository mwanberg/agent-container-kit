#!/bin/bash
# scratch-copy: copies files into a fresh scratch folder, one subfolder per
# variant, so a protected file can be read, diffed or edited as a copy without
# touching it. Baked root-owned as /usr/local/bin/scratch-copy; the guard hook
# lets agents run it on protected files by that exact path.
#   scratch-copy --label <label> [--variant <name>]... <file>...
#   git show <rev>:<file> | scratch-copy --label <label> --stdin <filename> [--variant <name>]...
#   scratch-copy --done <folder>
# Every run first sweeps helper folders older than 3 days. Removal is by the
# folder's own list, one entry at a time and never recursive, so a file the
# helper did not create is left in place and named. No git, no network.
# SCRATCH_COPY_ROOT moves the scratch root for tests. A root outside /tmp is
# rejected, so it cannot become a write route into a protected folder.
set -u

LIST=.scratch-copy-list
DEFAULT_VARIANT=original
root="${SCRATCH_COPY_ROOT:-/tmp/scratch-copies}"
root="${root%/}"

die() { printf 'scratch-copy: %s\n' "$1" >&2; exit 2; }
valid_name() { [[ "$1" =~ ^[a-z0-9-]{1,40}$ ]]; }

# A list entry is "<variant>/" or "<variant>/<filename>", nothing that leaves
# the folder.
valid_entry() {
  local v="${1%%/*}" rest="${1#*/}"
  case "$1" in */*) ;; *) return 1 ;; esac
  valid_name "$v" || return 1
  [ -z "$rest" ] && return 0
  case "$rest" in */*|.|..) return 1 ;; esac
}

# Removes what the folder's list names, files first, then the emptied
# folders. Prints anything left behind and returns 1 when something is.
clear_folder() { # folder
  local d="$1" e
  while IFS= read -r e; do
    valid_entry "$e" || { printf 'scratch-copy: %s lists an entry outside the folder: %s\n' "$d/$LIST" "$e" >&2; return 2; }
  done < "$d/$LIST"
  while IFS= read -r e; do
    case "$e" in */) ;; *) if [ -f "$d/$e" ] || [ -L "$d/$e" ]; then rm -f -- "$d/$e"; fi ;; esac
  done < "$d/$LIST"
  while IFS= read -r e; do
    case "$e" in */) rmdir -- "$d/$e" 2>/dev/null ;; esac
  done < "$d/$LIST"
  rm -f -- "$d/$LIST"
  rmdir -- "$d" 2>/dev/null && return 0
  find "$d" -mindepth 1 | sed 's/^/Left behind: /'
  return 1
}

# A fresh folder per run under a root this user owns, with no symlink in its
# path, means no planted link can sit at a destination.
check_root() {
  [ "$(realpath -m -- "$root")" = "$root" ] || die "scratch root $root is not a plain path: it runs through a symlink or holds . or .. or //."
  case "$root" in /tmp|/tmp/*) ;; *) die "scratch root $root is not under /tmp." ;; esac
  [ -e "$root" ] || mkdir -m 700 -- "$root" || die "cannot create scratch root $root."
  [ -d "$root" ] || die "scratch root $root is not a folder."
  [ "$(stat -c %u -- "$root")" = "$(id -u)" ] || die "scratch root $root is owned by another user."
}

# Folder names start with their creation time, so the cutoff compares as text.
sweep() {
  local cutoff d name
  cutoff=$(date -d '3 days ago' +%Y%m%d-%H%M%S)
  for d in "$root"/*/; do
    d="${d%/}"; name="${d##*/}"
    [[ "$name" =~ ^[0-9]{8}-[0-9]{6}- ]] || continue
    [ ! -L "$d" ] && [ -f "$d/$LIST" ] && [ ! -L "$d/$LIST" ] || continue
    [[ "${name:0:15}" < "$cutoff" ]] && clear_folder "$d"
  done
}

label="" stdin_name="" done_dir="" has_stdin=0 variants=() files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --label|--variant|--stdin|--done) [ $# -ge 2 ] || die "$1 needs a value." ;;
  esac
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --variant) variants+=("$2"); shift 2 ;;
    --stdin) stdin_name="$2"; has_stdin=1; shift 2 ;;
    --done) done_dir="$2"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) die "unknown option $1." ;;
    *) files+=("$1"); shift ;;
  esac
done

if [ -n "$done_dir" ]; then
  [ -z "$label" ] && [ $has_stdin -eq 0 ] && [ ${#variants[@]} -eq 0 ] && [ ${#files[@]} -eq 0 ] \
    || die "--done takes only a folder."
  check_root
  done_dir="${done_dir%/}"
  name="${done_dir##*/}"
  [ "${done_dir%/*}" = "$root" ] && [ -n "$name" ] && [ "$name" != . ] && [ "$name" != .. ] \
    || die "$done_dir is not a direct child of the scratch root $root."
  [ -d "$done_dir" ] && [ ! -L "$done_dir" ] || die "$done_dir is not a folder."
  [ -f "$done_dir/$LIST" ] && [ ! -L "$done_dir/$LIST" ] || die "$done_dir holds no scratch-copy list."
  sweep
  clear_folder "$done_dir"
  exit
fi

valid_name "$label" || die "--label must be 1 to 40 lowercase letters, digits or hyphens."
[ ${#variants[@]} -gt 0 ] || variants=("$DEFAULT_VARIANT")
for i in "${!variants[@]}"; do
  valid_name "${variants[$i]}" || die "variant '${variants[$i]}' must be 1 to 40 lowercase letters, digits or hyphens."
  for ((j = 0; j < i; j++)); do
    [ "${variants[$j]}" = "${variants[$i]}" ] && die "variant '${variants[$i]}' is given twice."
  done
done
names=()
if [ $has_stdin -eq 1 ]; then
  [ ${#files[@]} -eq 0 ] || die "--stdin takes no file arguments."
  case "$stdin_name" in ''|*/*|.|..|*$'\n'*) die "--stdin needs a plain filename." ;; esac
  names=("$stdin_name")
else
  [ ${#files[@]} -gt 0 ] || die "no files given."
  for f in "${files[@]}"; do
    [ -f "$f" ] || die "$f is not a file."
    n="${f##*/}"
    case "$n" in *$'\n'*) die "$f has a newline in its name." ;; esac
    for m in "${names[@]}"; do
      [ "$m" = "$n" ] && die "two files share the same name: $n."
    done
    names+=("$n")
  done
fi

check_root
sweep
folder=$(mktemp -d -- "$root/$(date +%Y%m%d-%H%M%S)-$label-XXXXXX") || die "cannot create a folder in $root."
: > "$folder/$LIST"
echo "Folder: $folder"
first="$folder/${variants[0]}"
for v in "${variants[@]}"; do
  mkdir -- "$folder/$v" || die "cannot create $folder/$v."
  printf '%s/\n' "$v" >> "$folder/$LIST"
  if [ $has_stdin -eq 1 ]; then
    if [ "$v" = "${variants[0]}" ]; then
      cat > "$folder/$v/$stdin_name" || die "cannot write $folder/$v/$stdin_name."
    else
      cp -- "$first/$stdin_name" "$folder/$v/$stdin_name" || die "cannot write $folder/$v/$stdin_name."
    fi
    printf '%s/%s\n' "$v" "$stdin_name" >> "$folder/$LIST"
  else
    for f in "${files[@]}"; do
      cp --preserve=mode -- "$f" "$folder/$v/${f##*/}" || die "cannot copy $f."
      printf '%s/%s\n' "$v" "${f##*/}" >> "$folder/$LIST"
    done
  fi
  for n in "${names[@]}"; do echo "$folder/$v/$n"; done
done
echo "Temporary copies. Removed by --done <folder>, automatically after 3 days, or when the container is recreated. Record anything you need to keep separately, not here."
