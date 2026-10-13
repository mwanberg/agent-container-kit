#!/bin/bash
#
# guardrail-protect.sh: PreToolUse guard hook for the ddev-claude sidecar.
#
# Registered in managed settings under one catch-all matcher, so it screens
# what any tool's input carries, including tools a later Claude Code release
# adds. A file-tool write to a protected path (ROLES below) is blocked or
# prompts the user to approve it, with a message naming what the file does;
# CLAUDE.md and CLAUDE.local.md files and skills and commands pass, as
# is_workflow below sets out. A command naming a protected path passes only as
# a recognized read or as the copy helper, and is otherwise denied with the
# routes that work. It never returns an ask decision, since the hook cannot
# determine what the command would write. Credentials and database dumps are screened apart from the roles, and
# git commands by git-screen.sh beside this file. Every decision's text comes
# from the kit's message file by id, except the fixed texts below.
#
# Baked root-owned into /usr/local/lib/agent-container-kit/ with guard-lib.sh,
# rather than into the Claude Code config folder, which is in the agent's home
# and writable by it.
#
# .ddev is protected because DDEV runs hooks from .ddev/config.*.yaml and
# commands from .ddev/commands/host/ on the host, and builds images from files
# under .ddev as root.
#
# Limits: the shell screens match command text, so variable indirection and
# encodings are not caught, and file-tool paths are matched as written, so a
# symlink in an unprotected path carries a write onto the protected file it
# points at. The read-only remounts of .ddev and .git and the managed policy
# are the controls that hold; this hook stops mistakes and returns the reason
# to the agent.
#
# PreToolUse hooks run before permission checks, so this fires in every
# permission mode. Across hooks, deny outranks ask.

set -uo pipefail

# Fixed decisions printed with the printf builtin alone, since they serve the
# paths where jq, the library or the hook itself has failed.
unreadable='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GUARDRAIL ask: the guard hook could not read this tool call (empty payload, unreadable JSON, or jq missing or broken), so nothing about it has been checked. Approve only if you know what the call does."}}'
crashed_ask='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GUARDRAIL ask: the guard hook stopped with an error before it could check this tool call. Approve only if you know what the call does."}}'
crashed_deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GUARDRAIL block: the guard hook stopped with an error before it could check this tool call, so the call is blocked. Stop and report the broken guard hook: to the user if you are the main session, or to the orchestrator if you are a subagent."}}'
fixed() { printf '%s\n' "$1"; exit 0; }

# A hook that exits non-zero without output lets the call through, so every
# error exit prints a decision: an ask while the tool is unknown, since a
# deny would also stop reads, and a deny once it is known.
on_crash=$crashed_ask
trap '[ $? -eq 0 ] || fixed "$on_crash"' EXIT

command -v jq >/dev/null 2>&1 || fixed "$unreadable"

# `read` is a builtin and reads fd 0 directly, so it works whether the harness
# supplies stdin as a pipe or a socket; a `$(</dev/stdin)` redirect reopens the
# path, which fails on a socket and leaves the payload empty. `|| true` because
# `read -d ''` returns non-zero at EOF, its normal end here.
IFS= read -r -d '' payload || true
[ -n "$payload" ] || fixed "$unreadable"

# With pipefail, a jq that is present but fails turns the pipeline non-zero and
# routes to an ask instead of an empty string every check falls through.
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty') || fixed "$unreadable"
[ -n "$tool" ] || fixed "$unreadable"

# Read-shaped tools carry a file_path they only open; the managed Read denies
# govern what they open. Every other tool is screened by its input.
case "$tool" in Read|Grep|Glob|LSP) exit 0 ;; esac

on_crash=$crashed_deny
. "${BASH_SOURCE[0]%/*}/guard-lib.sh" || exit 1

PROJECT=/var/www/html
USER_HOME=/home/claude
HELPER=/usr/local/bin/scratch-copy
PLAIN='^[A-Za-z0-9._/@+,:%-]+$'

# Protected paths by role. Fields: rule | what a file-tool write gets | roots |
# paths | message id for a file-tool write | message id for a command that is
# not a read. Roots "any" means at any depth; otherwise a path counts only
# under the listed roots, where sessions start and load it. A path ending in /
# is a folder and covers everything below it. A bare .claude covers a command
# that writes the folder itself, which can create settings or hooks inside it.
# Rows match in order: blocks first, and the narrower row over a folder before
# the folder. The file tools let CLAUDE.md and CLAUDE.local.md files, and
# skills and commands in any .claude folder, past the controls and instructions
# rows unless the folder holding them is protected (is_workflow below);
# commands are screened by every row. A command naming the login file is
# caught as a credentials file first.
ROLES=(
  "login|block|any|.claude/.credentials.json|guard-write-login|guard-bash-credentials"
  "mcp|block|any|.mcp.json|guard-write-mcp|guard-bash-mcp"
  "ddev|block|any|.ddev/|guard-write-ddev|guard-bash-ddev"
  "ddev|block|/mnt|ddev_config/|guard-write-ddev|guard-bash-ddev"
  "git|block|any|.git/|guard-write-git|guard-bash-git"
  "commit-hooks|block|any|.husky/|guard-write-commit-hooks|guard-bash-commit-hooks"
  "settings-and-hooks|ask|any|.claude/settings*.json .claude/hooks/ .claude|guard-write-settings|guard-bash-approval-path"
  "controls|ask|$PROJECT $USER_HOME|.claude/|guard-write-controls|guard-bash-approval-path"
  "instructions|ask|any|CLAUDE.md CLAUDE.local.md|guard-write-instructions|guard-bash-approval-path"
  "ci|ask|any|.github/|guard-write-ci|guard-bash-approval-path"
  "package-installs|ask|any|.npmrc .pnpmfile.cjs pnpm-workspace.yaml|guard-write-package-installs|guard-bash-approval-path"
)

set_role() {
  IFS='|' read -r ROLE_ID ROLE_DECISION ROLE_ROOTS ROLE_PATHS ROLE_WRITE ROLE_BASH <<< "$1"
}

normalize() { # absolute path -> NORM, with . and .. resolved lexically
  local part parts out=()
  IFS=/ read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) [ ${#out[@]} -gt 0 ] && unset 'out[-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  local IFS=/
  NORM="/${out[*]}"
}

# True when an absolute, normalized path falls under the current row.
path_in_role() { # path
  local p="$1" pat r pats roots
  read -ra pats <<< "$ROLE_PATHS"
  read -ra roots <<< "$ROLE_ROOTS"
  for pat in "${pats[@]}"; do
    for r in "${roots[@]}"; do
      [ "$r" = any ] && r='*'
      case "$pat" in
        */) case "$p" in $r/"${pat%/}"|$r/"${pat%/}"/*) return 0 ;; esac ;;
        *) case "$p" in $r/$pat) return 0 ;; esac ;;
      esac
    done
  done
  return 1
}

role_of_path() { # absolute path; sets ROLE_* for the first matching row
  local row
  normalize "$1"
  for row in "${ROLES[@]}"; do
    set_role "$row"; path_in_role "$NORM" && return 0
  done
  return 1
}

f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty') || fixed "$unreadable"
c=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty') || fixed "$unreadable"
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty') || fixed "$unreadable"
case "$cwd" in /*) ;; *) cwd=$PROJECT ;; esac

# ---- File tools --------------------------------------------------------------
#
# Edit, Write and MultiEdit carry file_path; NotebookEdit carries notebook_path.
# Credentials and dumps are blocks, so they come before the role asks.

# Nothing written to a CLAUDE.md or CLAUDE.local.md file, or to the skills and
# commands folders of any .claude, can lift a deny rule, skip a hook or open
# the firewall. So the file tools write them without prompting, unless the folder holding that .claude (or
# that file) is itself protected, or a row other than controls and instructions
# covers the path, such as settings or .git nested inside a skill. Commands get
# no such pass: a command writing either file anywhere, or a file in the live
# .claude folders, is denied. A nested .claude's skills and commands are not
# protected, so a command writing there is denied only when a word mentions
# .claude in a form whose location is unknown (relative, quoted, or holding a
# variable or glob).
is_workflow() { # normalized path
  local p="$1" holder skills commands row
  case "$p" in
    */.claude/skills/*|*/.claude/commands/*)
      skills="${p%%/.claude/skills/*}"; commands="${p%%/.claude/commands/*}"
      if [ ${#skills} -le ${#commands} ]; then holder=$skills; else holder=$commands; fi ;;
    */CLAUDE.md|*/CLAUDE.local.md) holder="${p%/*}"; holder="${holder%/.claude}" ;;
    *) return 1 ;;
  esac
  role_of_path "$holder" && return 1
  for row in "${ROLES[@]}"; do
    set_role "$row"
    case "$ROLE_ID" in controls|instructions) continue ;; esac
    path_in_role "$p" && return 1
  done
  return 0
}

if [ -n "$f" ]; then
  case "$f" in /*) ;; *) f="$cwd/$f" ;; esac
  normalize "$f"; f=$NORM
  shown=${f#"$PROJECT"/}
  case "$f" in
    */.env|*/.env.*|*/id_rsa*|*/.ssh/*|*/.aws/*) refuse guard-write-credentials "path=$shown" ;;
    *.sql|*.sql.*|*.dump|*.dump.*|*.mysql|*/database-backups/*|*/db_snapshots/*) refuse guard-write-dumps "path=$shown" ;;
  esac
  is_workflow "$f" && exit 0
  if role_of_path "$f"; then
    [ "$ROLE_DECISION" = ask ] || refuse "$ROLE_WRITE" "path=$shown"
    message ask "$ROLE_WRITE" "path=$shown"
    emit ask "$TEXT"
  fi
fi

# ---- Commands ----------------------------------------------------------------
[ -n "$c" ] || exit 0

# A boundary-normalized copy: quoting, separator and redirection characters
# become spaces, so a pattern can require a delimiter before a name without
# enumerating every shell spelling (--file=X, "X", rev:X, a,b, >X).
n=" ${c//[$'\n\r\t'\"\'\`:=,;()|&<>\\]/ } "

# Credentials, as a block whatever the command does. The file-tool denies say
# nothing about cat, grep or php opening the same file. .env needs a delimiter
# before it so a word containing it (chrome.environment.yaml) does not match.
case "$n" in
  *[[:space:]/].env*|*id_rsa*|*.ssh/*|*.aws/*|*.credentials.json*) refuse guard-bash-credentials ;;
esac

# True when a word that is not a plain absolute path (relative, quoted, or
# holding a variable or a glob) mentions a path of the current row. Where it
# would resolve is unknown, so a mention counts at any depth.
word_in_role() { # word
  local w="$1" pat core re pats
  read -ra pats <<< "$ROLE_PATHS"
  for pat in "${pats[@]}"; do
    core="${pat%%\**}"
    re="${core%/}"; re="${re//./\\.}"
    if [ "$core" != "$pat" ]; then :
    elif [ "${pat%/}" != "$pat" ]; then re="$re(\$|[^A-Za-z0-9_.-])"
    else re="$re(\$|[^A-Za-z0-9_./-])"
    fi
    [[ $w =~ $re ]] && return 0
  done
  return 1
}

role_of_word() { # word; sets ROLE_* for the first row it mentions
  local row
  for row in "${ROLES[@]}"; do
    set_role "$row"; word_in_role "$1" && return 0
  done
  return 1
}

# Words of a command, split at whitespace and shell punctuation, with one
# pair of surrounding quotes removed when they hold a plain path.
split_words() { # command -> WORDS
  local s="$1" w inner parts seps='[;&|<>()=]' dq='^"([^"]*)"$' sq="^'([^']*)'\$"
  s="${s//$seps/ }"; s="${s//$'\n'/ }"
  read -ra parts <<< "$s"
  WORDS=()
  for w in "${parts[@]}"; do
    inner=""
    [[ $w =~ $dq || $w =~ $sq ]] && inner="${BASH_REMATCH[1]}"
    [[ -n $inner && $inner =~ $PLAIN ]] && w="$inner"
    WORDS+=("$w")
  done
}

# Sets ROLE_* and HIT for the protected folder a command runs in, or else the
# first protected path it names. Words count as written first, so HIT names
# the word itself where one is protected. A plain relative word is then also
# resolved against the session's folder and against every plain absolute
# word, since any of those may be a cd target; any other word counts on a
# mention alone.
bash_role() { # command cwd
  local w b bases=()
  split_words "$1"
  if [[ $2 =~ $PLAIN ]]; then
    HIT="runs in $2"
    role_of_path "$2" && return 0
    bases+=("$2")
  fi
  for w in "${WORDS[@]}"; do
    HIT="names $w"
    if [[ $w == /* && $w =~ $PLAIN ]]; then
      role_of_path "$w" && return 0
      bases+=("$w")
    else
      role_of_word "$w" && return 0
    fi
  done
  for w in "${WORDS[@]}"; do
    [[ $w =~ $PLAIN && $w != -* && $w != /* ]] || continue
    for b in "${bases[@]}"; do
      HIT="names $w from $b"
      role_of_path "$b/$w" && return 0
    done
  done
  return 1
}

# The copy helper by its fixed path, alone or fed by git show <rev>:<file>,
# with nothing that could redirect, substitute, or chain another command.
is_helper_form() {
  local c="$1" spec w
  case "$c" in *[\$\`\<\>\;\&\\]*|*$'\n'*|*'|'*'|'*) return 1 ;; esac
  if [[ $c == *'|'* ]]; then
    read -ra w <<< "${c%%|*}"
    c="${c#*|}"
    case "${#w[@]}:${w[0]:-}:${w[1]:-}:${w[3]:-}" in
      3:git:show:*) spec="${w[2]}" ;;
      5:git:-C:show) spec="${w[4]}" ;;
      *) return 1 ;;
    esac
    case "$spec" in -*) return 1 ;; *:*) ;; *) return 1 ;; esac
  fi
  read -ra w <<< "$c"
  [ "${w[0]:-}" = "$HELPER" ]
}

# Programs that read and print and cannot write a file on their own. awk, sed,
# tee, pagers and interpreters are absent because each can open or write files.
# find -exec, xargs and env pass only when the program they hand off to is on
# this list; the readers with an output-file option are checked for it below.
READ_WORDS='grep egrep fgrep rg cat head tail ls find xargs env diff cmp wc stat file sha256sum sha1sum md5sum shasum tree readlink realpath basename dirname test [ echo printf true pwd which type cut sort uniq tr jq du df date printenv column nl od strings git'
HANDOFF_BLOCK='find xargs env git'

# Sets SKIP to the number of leading words that are options of env or xargs,
# their arguments, or (for env) assignments, so the word after them is the
# program run. An option taking an argument consumes the next word unless the
# value is attached, in a cluster too (-iu NAME). Over-counting is safe, since
# the word taken for the program must then be on the read list.
skip_options() { # env|xargs words...
  local p="$1" w i short long; shift
  if [ "$p" = env ]; then
    short=uCSa; long=' --unset --chdir --split-string --argv0 '
  else
    short=adEILnPs; long=' --arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var '
  fi
  SKIP=0
  while [ $# -gt 0 ]; do
    w="$1"; shift; SKIP=$((SKIP + 1))
    case "$w" in
      --) return ;;
      --*=*) ;;
      --*) case "$long" in *" $w "*) [ $# -gt 0 ] && { shift; SKIP=$((SKIP + 1)); } ;; esac ;;
      -?*)
        for ((i = 1; i < ${#w}; i++)); do
          case "$short" in
            *"${w:i:1}"*) [ $((i + 1)) -eq ${#w} ] && [ $# -gt 0 ] && { shift; SKIP=$((SKIP + 1)); }; break ;;
          esac
        done ;;
      [A-Za-z_]*=*) [ "$p" = env ] || { SKIP=$((SKIP - 1)); return; } ;;
      *) SKIP=$((SKIP - 1)); return ;;
    esac
  done
}

# True when the command can only read. Substitutions and heredocs are judged on
# the raw text, since double quotes do not stop them. Quoted spans are then
# masked so a | or > inside a pattern is not read as a pipe or a redirection.
# Redirections to /dev/null and the stderr merge are stripped; any remaining >
# is a file write. A read-side process substitution <( ) opens a segment that is
# checked like any other. A failed mask counts as not read-only.
is_read_only() {
  local c="$1" s seg first a sub
  case "$c" in *'$('*|*'`'*|*'<<'*|*'&>'*|*'>|'*|*'>('*) return 1 ;; esac
  s=$(printf '%s' "$c" | sed -E "s/'[^']*'/Q/g; s/\"[^\"]*\"/Q/g") || return 1
  [ -n "$s" ] || return 1
  s="${s//2>&1/}"; s="${s//2>\/dev\/null/}"; s="${s//>\/dev\/null/}"
  case "$s" in *'>'*) return 1 ;; esac
  s="${s//"||"/$'\n'}"; s="${s//"&&"/$'\n'}"; s="${s//"|"/$'\n'}"; s="${s//";"/$'\n'}"; s="${s//"<("/$'\n'}"
  set -f
  while IFS= read -r seg; do
    set -- $seg
    while [ $# -gt 0 ]; do
      case "$1" in [A-Za-z_]*=*) shift ;; *) break ;; esac
    done
    [ $# -gt 0 ] || continue
    first="${1##*/}"; shift
    # A shell run only to parse (-n among its leading options) runs nothing.
    case "$first" in
      bash|sh|dash|zsh)
        sub=""
        for a in "$@"; do
          case "$a" in -n) sub=n ;; -*) ;; *) break ;; esac
        done
        [ "$sub" = n ] || { set +f; return 1; }
        continue ;;
    esac
    in_list "$first" "$READ_WORDS" || { set +f; return 1; }
    case "$first" in
      find)
        while [ $# -gt 0 ]; do
          case "$1" in
            -delete|-ok|-okdir|-fprint*|-fls) set +f; return 1 ;;
            -exec|-execdir)
              shift; [ $# -gt 0 ] || { set +f; return 1; }
              in_list "${1##*/}" "$READ_WORDS" || { set +f; return 1; }
              in_list "${1##*/}" "$HANDOFF_BLOCK" && { set +f; return 1; } ;;
          esac
          shift
        done ;;
      xargs|env)
        # env -S splits its argument into a command line and runs it.
        if [ "$first" = env ]; then
          for a in "$@"; do case "$a" in --split-string*|-S*|-[!-]*S*) set +f; return 1 ;; esac; done
        fi
        skip_options "$first" "$@"; shift "$SKIP"
        [ $# -gt 0 ] || { [ "$first" = env ] && continue; set +f; return 1; }
        in_list "${1##*/}" "$READ_WORDS" || { set +f; return 1; }
        in_list "${1##*/}" "$HANDOFF_BLOCK" && { set +f; return 1; } ;;
      sort) for a in "$@"; do case "$a" in -o|--output*) set +f; return 1 ;; esac; done ;;
      tree) for a in "$@"; do case "$a" in -o) set +f; return 1 ;; esac; done ;;
      uniq) a=0; for sub in "$@"; do case "$sub" in -*) ;; *) a=$((a + 1)) ;; esac; done; [ "$a" -le 1 ] || { set +f; return 1; } ;;
      git)
        sub=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) shift 2 ;;
            -*) shift ;;
            *) sub="$1"; break ;;
          esac
        done
        in_list "$sub" "$GIT_READ" || { set +f; return 1; }
        git_read_writes "$@" && { set +f; return 1; }
        for a in "$@"; do case "$a" in --output*) set +f; return 1 ;; esac; done ;;
    esac
  done <<< "$s"
  set +f
  return 0
}

if bash_role "$c" "$cwd" && ! is_read_only "$c" && ! is_helper_form "$c"; then
  refuse "$ROLE_BASH" "hit=$HIT" "helper=$HELPER"
fi

# Dump files and folders, as an ask even for a read, since reading a dump is
# the exposure; a block has no override. The literal dot keeps mysql from
# matching.
case "$c" in
  *.sql*|*.dump*|*.mysql*|*database-backups*|*db_snapshots*)
    message ask guard-bash-dumps
    emit ask "$TEXT" ;;
esac

# Recursive deletes in spellings the permission prefix rules miss, since those
# only match a command that leads with the recursive flag.
case "$n" in
  *' rm -fR '*|*' rm -f -r '*|*' rm -f -R '*|*' rm --force '*)
    message ask guard-bash-recursive-delete
    emit ask "$TEXT" ;;
esac

exit 0
