#!/bin/sh
# Installs the kit into a DDEV project that already has upstream's ddev-claude
# add-on. Run on the host from the project root, in a terminal, since it
# prompts for answers:
#
#     sh /path/to/ddev-sidecar/install.sh
#
# First checks every file upstream's add-on installed against the hashes in
# upstream-files.sha256. Then prompts about the optional pieces, lists what it
# will write, and writes it only on a yes at that last prompt, so a no or
# stopping it before then leaves the project unchanged. It adds each file under overlay/add/ that the project lacks, never
# replacing one that exists, and replaces upstream's copies of the files under
# overlay/overwrite/. A re-run prompts only for what still applies and adds no
# line twice. Runs no DDEV command. POSIX sh only, for macOS's bash 3.2.
#
#     sh /path/to/ddev-sidecar/install.sh --exclude-lines
#
# Prints one .git/info/exclude line for every file the add-on and the kit put
# in a project, and changes nothing. It needs no terminal.
set -eu

kit=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
add="$kit/overlay/add"
overwrite="$kit/overlay/overwrite"
templates="$kit/templates"
template="$templates/php-toolchain.fragment.template"
note="$templates/agent-note.md"
# Line 1 names the upstream version the kit is built on; every other line is
# the SHA-256 of a file that version installs, then its path in the project.
hashes="$kit/upstream-files.sha256"
# The skill's folder also gets the kit's README and UNINSTALL, so the agent in
# the sidecar can read them.
skill=.claude/skills/ddev-sidecar
docs="README.md UNINSTALL.md"
settings=.ddev/claude/managed-settings.json
fragment=.ddev/claude.local/Dockerfile.fragment
# The Node major offered when .ddev/config.yaml sets no nodejs_version.
node_default=24
nl='
'

refuse() {
  printf 'install.sh: %s\n' "$@" >&2
  exit 1
}

[ $# -eq 0 ] || [ "$1" = --exclude-lines ] || refuse "unknown option $1; the only option is --exclude-lines."

if [ "${1:-}" != --exclude-lines ] && [ ! -t 0 ]; then
  refuse "this installer prompts for answers and has to be run in a terminal; nothing was checked or written."
fi

# Paths relative to the given folder, one per line, each prefixed ./ by find.
list_files() {
  (cd "$1" && find . -type f) | sort
}

exclude_lines() {
  printf '# ddev-claude add-on and agent-container-kit\n'
  sed 1d "$hashes" | while read -r sum f; do
    printf '/%s\n' "$f"
  done
  list_files "$add" | while IFS= read -r f; do
    printf '/%s\n' "${f#./}"
  done
  for d in $docs; do
    printf '/%s/%s\n' "$skill" "$d"
  done
  # Files the installer creates rather than copies.
  printf '/%s\n' "$fragment" .mcp.json
}

[ -d "$add" ] && [ -d "$overwrite" ] && [ -f "$hashes" ] && [ -f "$template" ] && [ -f "$note" ] ||
  refuse "the kit's overlay/ or templates/ folder or upstream-files.sha256 is not beside this script; run the install.sh that came with the kit."

if [ "${1:-}" = --exclude-lines ]; then
  exclude_lines
  exit 0
fi

[ -f .ddev/config.yaml ] ||
  refuse "$(pwd) is not a DDEV project root: it has no .ddev/config.yaml." \
    "Change to the project root and run this again."

# sha256sum where it exists, else shasum, which macOS ships.
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum < "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 < "$1"; }
else
  refuse "neither sha256sum nor shasum is installed, so upstream's files cannot be checked." \
    "Install one of them, then run this again."
fi

# Upstream's add-on must be in place, at the version the kit is built on and
# unchanged: the kit replaces some of its files and builds on the rest. A file
# the kit replaces may instead already be the kit's copy, so a re-run passes.
upstream=$(head -n 1 "$hashes")
missing=""
changed=""
while read -r sum f; do
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    missing="$missing$nl  $f"
    continue
  fi
  actual=$(sha256 "$f")
  [ "${actual%% *}" = "$sum" ] && continue
  [ -f "$overwrite/$f" ] && cmp -s "$overwrite/$f" "$f" && continue
  changed="$changed$nl  $f"
done <<EOF
$(sed 1d "$hashes")
EOF
[ -z "$missing" ] ||
  refuse "upstream's ddev-claude add-on is not installed here; these files are missing or not regular files:$missing" \
    "Install $upstream, then run this again. Nothing was written."
[ -z "$changed" ] ||
  refuse "these files differ from what $upstream installs:$changed" \
    "The kit builds only on that version as published, so it stops on a different version, a local edit, or any other change to these files." \
    "Move the files named above out of the project (reinstalling leaves in place any file without upstream's generated-file marker), install $upstream again, then run this again. Nothing was written."

# A project's own claude.yaml is never replaced, but the kit depends on its
# mount_mode and plugins lines (the reasons are in the kit's claude.yaml), so
# stop before writing anything when they are absent.
if [ -f .ddev/claude.yaml ]; then
  wanted=""
  for key in mount_mode plugins; do
    line=$(grep "^$key:" "$add/.ddev/claude.yaml")
    grep -qxF "$line" .ddev/claude.yaml || wanted="$wanted$nl  $line"
  done
  [ -z "$wanted" ] ||
    refuse "the project's .ddev/claude.yaml lacks settings the kit depends on; add these lines to it:$wanted" \
      "$add/.ddev/claude.yaml says why. Nothing was written. Run this again afterwards."
  # The php extra installs a second PHP into the image the fragment already
  # gives one.
  ! grep -qE '^[[:space:]]*-[[:space:]]*["'\'']?php["'\'']?[[:space:]]*(#.*)?$' .ddev/claude.yaml ||
    refuse "the project's .ddev/claude.yaml turns on the add-on's php extra." \
      "The kit's build fragment installs the project's PHP version, and the extra would install a second version into the same image. Remove php from extras, then run this again. Nothing was written."
fi

present() {
  [ -e "$1" ] || [ -L "$1" ]
}

# The kit's policy without its "statusLine" object. Prints nothing and fails
# unless the object is one top-level block on lines of its own, after a line
# ending in "{" or "," and before another top-level key, so removing exactly
# those lines leaves valid JSON.
without_statusline() {
  awk '
    $0 == "  \"statusLine\": {" { found++; inside = 1; before = prev; next }
    inside && $0 == "  }," { inside = 0; after = 1; next }
    inside && /^    / { next }
    inside { bad = 1 }
    after == 1 { after = 2; if ($0 !~ /^  "/) bad = 1 }
    { out = out $0 "\n"; prev = $0 }
    END {
      if (found != 1 || inside || after != 2 || bad || before !~ /[{,]$/) exit 1
      printf "%s", out
    }
  ' "$add/$settings"
}

# What the overlay would add, worked out before any question so the summary
# can list it. A project file that matches the kit's copy, or the kit's
# policy without its status line, counts as the kit's.
to_add=""
differing=""
plan_file() { # kit-source project-destination
  if present "$2"; then
    cmp -s "$1" "$2" || { [ "$2" = "$settings" ] && without_statusline | cmp -s - "$2"; } ||
      differing="$differing  $2 (kit's copy: $1)$nl"
  else
    to_add="$to_add$2 $1$nl"
  fi
}
while IFS= read -r f; do
  f=${f#./}
  plan_file "$add/$f" "$f"
done <<EOF
$(list_files "$add")
EOF
for d in $docs; do
  plan_file "$kit/$d" "$skill/$d"
done
# The add-on's files the kit replaces, skipping those already the kit's copy.
to_replace=""
while IFS= read -r f; do
  f=${f#./}
  cmp -s "$overwrite/$f" "$f" || to_replace="$to_replace$f$nl"
done <<EOF
$(list_files "$overwrite")
EOF
# On a project the kit is already installed in, the optional pieces asked
# about again default to no, so Enter repeats an earlier refusal.
rerun=n
[ -n "$to_add$to_replace" ] || rerun=y

answer() {
  read -r reply || {
    printf '\n'
    refuse "no answer was read, so nothing was written."
  }
}

# Succeeds on yes. Enter takes the default.
ask() { # default(y|n) question
  case $1 in
    y) choices='[Y/n]' ;;
    *) choices='[y/N]' ;;
  esac
  while :; do
    printf '%s %s ' "$2" "$choices"
    answer
    case $reply in
      '') reply=$1 ;;
      [Yy] | [Yy][Ee][Ss]) reply=y ;;
      [Nn] | [Nn][Oo]) reply=n ;;
      *)
        printf 'Answer y or n.\n'
        continue
        ;;
    esac
    [ "$reply" = y ]
    return
  done
}

# Prompts again until the value passes the form check, which prints what is
# wrong.
ask_value() { # question form-check
  while :; do
    printf '%s ' "$1"
    answer
    "$2" "$reply" && return
  done
}

# The forms the fragment's own placeholder checks accept.
php_form() {
  case $1 in
    [0-9].[0-9] | [0-9].[0-9][0-9]) ;;
    *)
      printf 'A PHP version is major.minor, such as 8.3.\n'
      return 1
      ;;
  esac
}
node_form() {
  case $1 in
    '' | *[!0-9]*)
      printf 'A Node major version is a whole number, such as %s.\n' "$node_default"
      return 1
      ;;
  esac
}

# A top-level value in .ddev/config.yaml, without quotes or a trailing comment.
config_value() {
  sed -n "s/^$1:[[:space:]]*//p" .ddev/config.yaml | head -n 1 |
    sed 's/[[:space:]]*#.*//; s/^["'\'']//; s/["'\'']$//'
}

# The line of the fragment's OPTIONAL block n that matches the pattern, with
# the comment marks the pattern names removed.
block_line() { # n pattern
  awk -v n="$1" -v pattern="$2" '
    /^# OPTIONAL: / { block++ }
    block == n && $0 ~ pattern { sub(pattern, ""); print; exit }
  ' "$template"
}

# The project files block n's phpunit call reads, relative to the project
# root, which the sidecar mounts at /var/www/html.
runner_files() {
  awk -v n="$1" '
    /^# OPTIONAL: / { block++ }
    block == n && /vendor\/bin\/phpunit -c / {
      for (i = 1; i <= NF; i++) {
        f = $i
        gsub(/\047/, "", f)
        if (sub(/^\/var\/www\/html\//, "", f)) print f
      }
      exit
    }
  ' "$template"
}

# The block named in block n's build-fragment-block-needs check, the block
# whose title starts with that name and without which its build stops.
block_needs() {
  awk -v n="$1" '
    /^# OPTIONAL: / { block++ }
    block == n && match($0, /build-fragment-block-needs .*needs="[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/.*needs="/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "$template"
}

# The Node major that block n's build-fragment-node-too-old check requires,
# or nothing when the block has no such check.
block_node_minimum() {
  awk -v n="$1" '
    /^# OPTIONAL: / { block++ }
    block == n && match($0, /build-fragment-node-too-old .*minimum="[0-9]+"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/.*minimum="/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "$template"
}

# The highest Node major any OPTIONAL block requires, or nothing.
blocks_node_minimum() {
  n=1
  highest=""
  while [ "$n" -le "$1" ]; do
    minimum=$(block_node_minimum "$n")
    [ -z "$minimum" ] || [ "${highest:-0}" -ge "$minimum" ] || highest=$minimum
    n=$((n + 1))
  done
  printf '%s' "$highest"
}

# Succeeds when the database block of .ddev/config.yaml sets type: postgres.
postgres_database() {
  awk '
    /^database:/ { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && /^[[:space:]]+type:[[:space:]]*["\047]?postgres["\047]?[[:space:]]*(#.*)?$/ { found = 1 }
    END { exit !found }
  ' .ddev/config.yaml
}

# The service names under the top-level services: key of each
# .ddev/docker-compose.*.yaml file, one per line.
compose_services() {
  for f in .ddev/docker-compose.*.yaml; do
    [ -f "$f" ] || continue
    awk '
      /^services:/ { inside = 1; indent = ""; next }
      /^[^[:space:]#]/ { inside = 0 }
      !inside || /^[[:space:]]*(#.*)?$/ { next }
      indent == "" { indent = $0; sub(/[^[:space:]].*/, "", indent) }
      index($0, indent) == 1 && substr($0, length(indent) + 1, 1) !~ /[[:space:]]/ {
        name = substr($0, length(indent) + 1)
        sub(/:.*/, "", name)
        gsub(/["\047]/, "", name)
        print name
      }
    ' "$f"
  done
}

statusline=keep
if ! present "$settings"; then
  printf '\nStatus line: the line at the bottom of Claude Code'\''s screen. The kit'\''s shows the current folder, the git branch, the model and its effort level, and how much of the context window is left.\n'
  printf 'To change what it shows later, edit .ddev/claude/statusline-command.sh on the host, then run ddev claude rebuild and ddev restart. Your own status line has to go in that file too: the kit'\''s policy runs only that script as the status line, so a status line in your own Claude Code settings does not run in the sidecar. If you answer no, the sidecar has no status line.\n'
  if ! ask y "Use the kit's status line?"; then
    statusline=off
    without_statusline >/dev/null ||
      refuse "the status line cannot be left out: in the kit's $add/$settings, the statusLine object is not one block on lines of its own followed by another top-level key, the form this script removes. Nothing was written." \
        "Restore that file from the kit's release, or answer yes and remove the entry from $settings after install."
  fi
fi

add_extension() { # extension what-needs-it
  php_extensions="$php_extensions $1"
  extension_notes="${extension_notes}PHP's $1 extension for the project's $2$nl"
}

# Offers OPTIONAL block n with its Prompt and Question lines. Skips it with a
# line when the project lacks a file its phpunit call reads, and without one
# when its build needs a block that was not chosen.
offer_block() {
  prompt=$(block_line "$1" '^## Prompt: ')
  name=${prompt%%:*}
  needs=$(block_needs "$1")
  if [ -n "$needs" ]; then
    case "$chosen_titles" in
      *"$nl$needs"*) ;;
      *)
        printf '\n%s: skipped, because it builds on the %s block, which is off.\n' "$name" "$needs"
        return 0
        ;;
    esac
  fi
  missing=""
  for f in $(runner_files "$1"); do
    [ -f "$f" ] || missing="${missing:+$missing or }$f"
  done
  if [ -n "$missing" ]; then
    printf '\n%s: skipped, because the project has no %s at its root. Step 3 of the README says how to turn it on later.\n' "$name" "$missing"
    return 0
  fi
  minimum=$(block_node_minimum "$1")
  if [ -n "$minimum" ] && [ "$node" -lt "$minimum" ]; then
    printf '\n%s: skipped, because it needs Node %s or newer and the sidecar gets Node %s. Step 3 of the README says how to change the Node version later.\n' "$name" "$minimum" "$node"
    return 0
  fi
  printf '\n%s\n' "$prompt"
  ask n "$(block_line "$1" '^## Question: ')" || return 0
  blocks="$blocks $1 "
  block_names="$block_names${block_names:+; }$name"
  chosen_titles="$chosen_titles$nl$(block_line "$1" '^# OPTIONAL: ')"
  if [ -n "$(block_line "$1" 'CORE-LINT-PACKAGES')" ]; then
    # The block's comment gives the command that prints the package list
    # from core's package.json, run in the docroot.
    docroot=$(config_value docroot)
    packages="${docroot:+$docroot/}core/package.json"
    derive=$(block_line "$1" '^##     ')
    case $derive in python3*) ;; *) derive="" ;; esac
    if [ -n "$derive" ] && [ -f "$packages" ] && command -v python3 >/dev/null 2>&1; then
      lint_packages=$(cd "./$docroot" && sh -c "$derive" 2>/dev/null) || lint_packages=""
    fi
    case $lint_packages in
      *@*) ;;
      *)
        lint_packages=""
        lint_todo="Replace CORE-LINT-PACKAGES in $fragment with what the command in the lint block's comment prints, run in ${docroot:-the project root} (the docroot in .ddev/config.yaml). The command needs python3 and $packages."
        printf '%s\n' "$lint_todo"
        ;;
    esac
  fi
}

blocks=""
block_names=""
chosen_titles=""
php_extensions=""
extension_notes=""
lint_packages=""
lint_todo=""
services_todo=""
if present "$fragment"; then
  fragment_new=n
  printf '\nBuild fragment: %s installs PHP and Node in the sidecar, matched to the project.\n' "$fragment"
  printf 'The project has one, so it is left as it is. The kit'\''s template is %s.\n' "$template"
else
  fragment_new=y
  php=$(config_value php_version)
  if ! php_form "$php" >/dev/null; then
    printf '\n'
    ask_value "Which PHP version does the web container run? (major.minor, such as 8.3)" php_form
    php=$reply
  fi

  count=$(grep -c '^# OPTIONAL: ' "$template") || count=0
  tools_minimum=$(blocks_node_minimum "$count")
  node=""
  if grep -q '^nodejs_version:' .ddev/config.yaml; then
    value=$(config_value nodejs_version)
    value=${value%%.*}
    # A value with no whole-number major, such as auto, gets the question
    # below on its own.
    if node_form "$value" >/dev/null; then
      printf '\nNode %s is set as nodejs_version in .ddev/config.yaml, the version the web container runs.\n' "$value"
      node=$value
    fi
  else
    printf '\n.ddev/config.yaml does not set nodejs_version. The kit'\''s default is Node %s.\n' "$node_default"
    node=$node_default
  fi
  if [ -n "$node" ]; then
    if [ -n "$tools_minimum" ] && [ "$node" -lt "$tools_minimum" ]; then
      printf 'The optional browser and accessibility tools offered below need Node %s or newer, so with Node %s they are not offered. The theme'\''s build scripts run on whichever version the sidecar gets.\n' "$tools_minimum" "$node"
    else
      printf 'Change it only if the theme'\''s build needs a different version.\n'
    fi
    ask y "Use Node $node in the sidecar?" || node=""
  fi
  if [ -z "$node" ]; then
    printf '\n'
    ask_value "Which Node major version should the sidecar use? (a whole number, such as $node_default)" node_form
    node=$reply
  fi

  # PHP extensions for the project's DDEV services, added without a prompt.
  # The firewall's service list is the user's edit (README step 4), named at
  # the end.
  services=$(compose_services)
  if postgres_database; then
    add_extension pgsql "Postgres database"
  fi
  for svc in redis memcached; do
    printf '%s\n' "$services" | grep -qx "$svc" || continue
    add_extension "$svc" "$svc service"
    services_todo="${services_todo}The project has a $svc service. If the site uses it, for example as its cache backend, add $svc to CLAUDE_SIDECAR_SERVICES in .ddev/docker-compose.zz-claude-overlay.yaml (README step 4), or drush cannot start the site.$nl"
  done

  printf '\nOptional tools for the agent. Each one makes the sidecar'\''s image larger and its first build longer.\n'
  n=1
  while [ "$n" -le "$count" ]; do
    offer_block "$n"
    n=$((n + 1))
  done
fi

mcp=""
if ! { [ -f .mcp.json ] && grep -q '"context7"' .mcp.json; }; then
  printf '\nContext7: gives the agent current documentation for libraries and frameworks. It needs the Context7 proxy running on your computer; its setup is in %s.\n' "$(dirname "$kit")/host/context7-proxy/README.md"
  if ask n "Turn on Context7 for this project?"; then
    if present .mcp.json; then mcp=merge; else mcp=create; fi
  fi
fi

note_line=$(head -n 1 "$note")
has_note() {
  [ -f "$1" ] && grep -qxF "$note_line" "$1"
}
note_offer=n
if ! has_note CLAUDE.md && ! has_note AGENTS.md && ! has_note CLAUDE.local.md; then
  note_offer=y
fi

# Asked before the agent note, whose file depends on the answer.
exclude=commit
if present .git && { [ -n "$to_add" ] || [ "$mcp" = create ] || [ "$note_offer" = y ]; }; then
  printf '\nThe installer adds files to your project, and git shows them as new. Most projects commit them or list them in .gitignore. If you can do neither, for example in a repository you are not allowed to change, the installer can hide them from git on this computer only.\n'
  printf 'A yes adds a line for each of those files to .git/info/exclude, which git reads on this computer only and never commits. .gitignore is not changed; the lines the add-on added to it stay there until you move them.\n'
  if ask n "Hide the kit's files from git on this computer only?"; then
    exclude=local
  fi
fi

note_target=""
if [ "$note_offer" = y ]; then
  # The tracked file the note would go in; hiding from git sends it to
  # CLAUDE.local.md instead.
  if [ -f CLAUDE.md ] || [ ! -f AGENTS.md ]; then
    note_target=CLAUDE.md
  else
    note_target=AGENTS.md
  fi
  tracked_target=$note_target
  [ "$exclude" = commit ] || note_target=CLAUDE.local.md
  printf '\nAgent note: a short note in %s saying the agent runs in the sidecar and where to find what the sidecar allows. Its text is in %s.\n' "$note_target" "$note"
  [ "$exclude" = commit ] ||
    printf 'It goes in CLAUDE.local.md instead of %s, so no file in the repository changes.\n' "$tracked_target"
  if [ -f "$note_target" ]; then
    question="Add it to $note_target?"
  else
    question="Create $note_target with it?"
  fi
  if [ "$rerun" = y ]; then
    ask n "$question" || note_target=""
  else
    ask y "$question" || note_target=""
  fi
fi

# A file this run creates outside the exclude list (which already names
# .mcp.json and the fragment), for .git/info/exclude when the user keeps the
# files out of git.
created=""
[ -z "$note_target" ] || [ -f "$note_target" ] || created="$created/$note_target$nl"
exclude_new=""
if [ "$exclude" = local ] && [ -d .git/info ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -f .git/info/exclude ] && grep -qxF "$line" .git/info/exclude && continue
    exclude_new="$exclude_new$line$nl"
  done <<EOF
$(exclude_lines)
$created
EOF
fi

# Makes sure the file, when it has content, ends in a newline before more is
# appended.
end_line() {
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
    printf '\n' >> "$1"
  fi
}

write_changes() {
  while read -r dest src; do
    [ -n "$dest" ] || continue
    mkdir -p "$(dirname "$dest")"
    if [ "$dest" = "$settings" ] && [ "$statusline" = off ]; then
      without_statusline > "$dest"
    else
      cp "$src" "$dest"
    fi
  done <<EOF
$to_add
EOF

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp "$overwrite/$f" "$f"
  done <<EOF
$to_replace
EOF
  chmod +x .ddev/commands/host/claude

  if [ "$fragment_new" = y ]; then
    mkdir -p "$(dirname "$fragment")"
    # Adds the detected PHP extensions after the baseline's php${PHP_VERSION}-
    # package lines, and uncomments each chosen block as the fragment's header
    # describes: one leading "#" and the space after it, from its "## Needs:"
    # line to the next divider. Then fills the ARG lines, and the lint
    # block's placeholder on its live lines only. sed's replacement treats \, &
    # and the | delimiter specially.
    escaped=$(printf '%s\n' "$lint_packages" | sed 's/[\\&|]/\\&/g')
    awk -v on="$blocks" -v extensions="$php_extensions" '
      /^# OPTIONAL: / { block++ }
      block == 0 && inlist && !/^ +php[$][{]PHP_VERSION[}]-[a-z0-9]+ \\$/ {
        count = split(extensions, name, " ")
        for (i = 1; i <= count; i++) print indent "php${PHP_VERSION}-" name[i] " \\"
        inlist = 0
      }
      block == 0 && /^ +php[$][{]PHP_VERSION[}]-[a-z0-9]+ \\$/ { inlist = 1; indent = $0; sub(/[^ ].*/, "", indent) }
      /^# -----/ { live = 0 }
      /^## Needs:/ && index(on, " " block " ") { live = 1 }
      live { sub(/^# ?/, "") }
      { print }
    ' "$template" |
      sed "/^ARG PHP_VERSION=/s|PHPVER|$php|; /^ARG NODE_MAJOR=/s|NODEMAJOR|$node|${lint_packages:+; /^#/!s|CORE-LINT-PACKAGES|$escaped|g}" > "$fragment"
  fi

  [ "$mcp" != create ] || cp "$templates/mcp.json.template" .mcp.json

  if [ -n "$note_target" ]; then
    if [ -s "$note_target" ]; then
      end_line "$note_target"
      printf '\n' >> "$note_target"
    fi
    cat "$note" >> "$note_target"
  fi

  if [ -n "$exclude_new" ]; then
    [ ! -f .git/info/exclude ] || end_line .git/info/exclude
    printf '%s' "$exclude_new" >> .git/info/exclude
  fi
}

written=n
if [ -z "$to_add$to_replace$note_target$exclude_new" ] && [ "$mcp" != create ] && [ "$fragment_new" = n ]; then
  printf '\nNothing to write.\n'
else
  printf '\nAbout to write in %s:\n' "$(pwd)"
  if [ -n "$to_add" ]; then
    printf '  add these files the project lacks:\n'
    printf '%s' "$to_add" | while read -r dest src; do
      printf '    %s\n' "$dest"
    done
  fi
  if [ -n "$to_replace" ]; then
    printf '  replace the add-on'\''s copies of these files with the kit'\''s:\n'
    printf '%s' "$to_replace" | sed 's|^|    |'
  fi
  [ "$statusline" = keep ] || printf '  leave the status line out of %s\n' "$settings"
  if [ "$fragment_new" = y ]; then
    # The extension notes joined as "a", "a and b", "a, b and c".
    extensions=$(printf '%s' "$extension_notes" | awk '
      { note[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) printf "%s%s", (i == 1 ? "" : (i == NR ? " and " : ", ")), note[i]
      }
    ')
    with_blocks="with no optional blocks"
    [ -z "$block_names" ] || with_blocks="with: $block_names"
    printf '  create %s for PHP %s and Node %s,%s %s\n' "$fragment" "$php" "$node" \
      "${extensions:+ with $extensions, and}" "$with_blocks"
  fi
  [ "$mcp" != create ] || printf '  create .mcp.json for Context7\n'
  if [ -n "$note_target" ]; then
    if [ -f "$note_target" ]; then
      printf '  append the agent note to %s\n' "$note_target"
    else
      printf '  create %s with the agent note\n' "$note_target"
    fi
  fi
  [ -z "$exclude_new" ] || printf '  add lines to .git/info/exclude\n'
  printf '\n'
  if ! ask y "Write these changes?"; then
    printf 'Nothing was written.\n'
    exit 0
  fi
  write_changes
  written=y
  printf '\nDone.\n'
fi

if [ -n "$differing" ]; then
  printf '\nLeft as they are, because the project has its own copy that differs from the kit'\''s. Compare each with the kit'\''s copy named beside it:\n%s' "$differing"
fi

if [ "$mcp" = merge ]; then
  printf '\nThe project has a .mcp.json, so it is left as it is. To turn on Context7, merge the context7 entry below into its mcpServers object:\n\n'
  cat "$templates/mcp.json.template"
fi
[ -z "$lint_todo" ] || printf '\n%s\n' "$lint_todo"
[ -z "$services_todo" ] || printf '\n%s' "$services_todo"

if [ "$exclude" = local ]; then
  exclude_file=.git/info/exclude
  if [ ! -d .git/info ]; then
    exclude_file="that exclude file"
    printf '\nThere is no .git/info/ folder here, so no exclude lines were added. In a worktree or submodule checkout, git rev-parse --git-path info/exclude prints the exclude file to add them to; sh %s/install.sh --exclude-lines prints them.\n' "$kit"
    [ -z "$created" ] || printf 'Add these lines too:\n%s' "$created"
  fi
  [ ! -f .gitignore ] ||
    printf '\nThe add-on appended its entries to .gitignore; grep -n '\''^/\\.ddev/'\'' .gitignore shows them. Move them to %s too.\n' "$exclude_file"
fi

if [ "$written" = y ]; then
  present .git ||
    printf '\nThis project has no .git at its root: remove the ../.git line from .ddev/docker-compose.zz-claude-overlay.yaml before building, or Docker creates an empty .git folder in the project (README, Before you start).\n'
  printf '\nNext, on the host from this folder:\n'
  printf '  1. README steps 3 and 4: the build fragment, and which services the sidecar may reach\n'
  printf '  2. ddev claude rebuild\n'
  printf '  3. ddev start, or ddev restart if the project is running\n'
  printf '  4. ddev claude\n'
fi
printf '%s/README.md says how to change these choices later.\n' "$kit"
