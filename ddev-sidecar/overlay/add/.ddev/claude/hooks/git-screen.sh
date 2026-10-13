#!/bin/bash
#
# git-screen.sh: PreToolUse hook for Bash that keeps git read-only in the
# ddev-claude sidecar.
#
# Recognized read verbs pass in any spelling: global options such as -C, -c and
# --no-pager are skipped before the verb is read, which a permission prefix rule
# cannot do. Every other git command is blocked with a reason and the read
# verbs. A git word the scanner cannot place (inside sh -c, a substitution, a
# quoted string, another program's text) is blocked too, since it cannot be
# shown to be a read, unless a read-only program holds it as data. Changing
# what git may do is a change to GIT_READ and git_read_writes in guard-lib.sh
# and the listing forms in classify_git. Every denial's text comes from the
# kit's message file by id, except the fixed texts below.
#
# Baked root-owned beside guardrail-protect.sh and guard-lib.sh. The read-only
# .git mount covers only the project's top-level checkout; for nested
# checkouts this screen and the guard hook's .git role are the only barriers,
# and both match command text, so a script or an interpreter running git is not
# caught.

set -u

# Fixed decisions printed with the printf builtin alone, since they serve the
# paths where jq, the library or the hook itself has failed.
unreadable='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GIT SCREEN: the git screen could not read this command (empty payload, unreadable JSON, or jq missing or broken), so nothing about it has been checked. Approve only if you know what the command does."}}'
crashed='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GIT SCREEN: the git screen stopped with an error before it could check this command, so the command is blocked. Stop and report the broken guard hook: to the user if you are the main session, or to the orchestrator if you are a subagent."}}'
fixed() { printf '%s\n' "$1"; exit 0; }

# A hook that exits non-zero without output lets the command through.
trap '[ $? -eq 0 ] || fixed "$crashed"' EXIT

command -v jq >/dev/null 2>&1 || fixed "$unreadable"

# `read` is a builtin and reads fd 0 directly, so it works whether stdin is a
# pipe or a socket. `|| true` because `read -d ''` returns non-zero at EOF.
IFS= read -r -d '' payload || true
[ -n "$payload" ] || fixed "$unreadable"
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty') || fixed "$unreadable"
[ -n "$cmd" ] || exit 0

. "${BASH_SOURCE[0]%/*}/guard-lib.sh" || exit 1

MSG=""
VALUES=()

# The first blocked segment supplies the message.
deny() { # id [name=value ...]
  [ -n "$MSG" ] && return
  MSG="$1"
  shift
  VALUES=("$@")
}

SHELL_WORDS='sh bash zsh dash ksh xargs eval find python python3 node perl'

# git bounded by shell punctuation anywhere in a string, including quoted
# program text such as php -r "exec('git commit')". A leading slash counts as a
# boundary (a path to the binary); a trailing one does not (a directory named
# git).
GIT_IN_TEXT='(^|[[:space:]"'"'"'`(;|&=$/])git([[:space:]"'"'"'`);|&]|$)'

# Programs that read files and print text, and never run their arguments.
# Their arguments are data, so git among them is not scanned, under two
# conditions on the whole command (see READONLY_EXEMPT below). The only
# options among them that run another program are the ones readonly_args_ok
# rejects. sort and file are absent because they can run programs
# (--compress-program, decompression).
READONLY_WORDS='grep ls cat head tail wc stat diff cmp du basename dirname realpath readlink cut uniq tr jq'

# grep may resolve to ugrep, whose --filter, --pager, --view and -Q run
# programs; diff -l pipes its output through pr.
readonly_args_ok() { # word args
  local w="$1" t; shift
  for t in "$@"; do
    case "$w:$t" in
      grep:--filter*|grep:--pager*|grep:--view*|grep:--query*|diff:--paginate) return 1 ;;
      grep:--*|diff:--*) ;;
      grep:-*Q*|diff:-*l*) return 1 ;;
    esac
  done
}

norm() { # token -> basename with wrapping punctuation removed
  local t="$1"
  t="${t#\$\(}"; t="${t#\(}"; t="${t#\`}"; t="${t#\"}"; t="${t#\'}"
  t="${t%\)}"; t="${t%\`}"; t="${t%\"}"; t="${t%\'}"
  printf '%s' "${t##*/}"
}

classify_git() {
  local a=("$@") i=0 sub="" t w
  for t in "$@"; do case "$t" in --version|--help|-h) return ;; esac; done
  while [ $i -lt ${#a[@]} ]; do
    case "${a[$i]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) sub="${a[$i]}"; i=$((i + 1)); break ;;
    esac
  done
  local rest=("${a[@]:$i}")
  [ -n "$sub" ] || return
  local shown="git $sub${rest[*]:+ ${rest[*]}}"
  if in_list "$sub" "$GIT_READ"; then
    git_read_writes "$sub" "${rest[@]}" && deny guard-git-write-form "command=$shown" "verb=$sub"
    return
  fi
  case "$sub" in
    reflog)
      case "${rest[0]:-}" in ""|show|-*) return ;; esac
      deny guard-git-write-form "command=$shown" "verb=$sub" ;;
    branch)
      for w in "${rest[@]}"; do
        case "$w" in
          -d|-D|-m|-M|-c|-C|-f|-u|-t|--delete|--force|--move|--copy|--set-upstream-to|--unset-upstream|--track|--edit-description|--create-reflog|[!-]*)
            deny guard-git-write-form "command=$shown" "verb=$sub"; return ;;
        esac
      done ;;
    tag)
      for w in "${rest[@]}"; do
        case "$w" in
          -l|--list|-n*|--contains|--no-contains|--merged|--no-merged|--points-at|--sort=*|--format=*|--column|--no-column|-i|--ignore-case) ;;
          *) deny guard-git-write-form "command=$shown" "verb=$sub"; return ;;
        esac
      done ;;
    remote)
      case "${rest[0]:-}" in ""|-v|--verbose|show|get-url) return ;; esac
      deny guard-git-write-form "command=$shown" "verb=$sub" ;;
    stash)
      case "${rest[0]:-}" in list|show) return ;; esac
      deny guard-git-write-form "command=$shown" "verb=$sub" ;;
    worktree)
      case "${rest[0]:-}" in list) return ;; esac
      deny guard-git-write-form "command=$shown" "verb=$sub" ;;
    config)
      local rd=0
      for w in "${rest[@]}"; do
        case "$w" in
          --get|--get-all|--get-regexp|--list|-l|--show-origin|--show-scope) rd=1 ;;
          --unset|--unset-all|--add|--replace-all|--edit|-e|--rename-section|--remove-section) rd=0; break ;;
        esac
      done
      [ $rd -eq 1 ] && return
      deny guard-git-config "command=$shown" ;;
    clone|submodule|init) deny guard-git-new-repository "command=$shown" ;;
    *) deny guard-git-write "command=$shown" "verb=$sub" ;;
  esac
}

# Splits a segment into its command word by basename (SEG_CW, empty when there
# is none) and the words after it (SEG_REST), past assignments and wrappers.
split_segment() {
  local -a w
  read -ra w <<< "$1"
  local i=0
  SEG_CW=""; SEG_REST=()
  while [ $i -lt ${#w[@]} ]; do
    case "${w[$i]}" in
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      command|exec|env|nohup|time|nice|builtin|sudo) i=$((i + 1)) ;;
      timeout) i=$((i + 1)); while [ $i -lt ${#w[@]} ] && [[ "${w[$i]}" =~ ^(-|[0-9]) ]]; do i=$((i + 1)); done ;;
      *) break ;;
    esac
  done
  [ $i -lt ${#w[@]} ] || return
  SEG_CW=$(norm "${w[$i]}")
  SEG_REST=("${w[@]:$((i + 1))}")
}

process_segment() {
  split_segment "$1"
  local cw="$SEG_CW" rest=("${SEG_REST[@]}")
  [ -n "$cw" ] || return
  if [ "$cw" = git ]; then
    classify_git "${rest[@]}"
  elif [[ "${rest[*]}" =~ $GIT_IN_TEXT ]]; then
    if [ "$READONLY_EXEMPT" = 1 ] && in_list "$cw" "$READONLY_WORDS" && readonly_args_ok "$cw" "${rest[@]}"; then
      return
    elif in_list "$cw" "$SHELL_WORDS"; then
      deny guard-git-shell-text "program=$cw"
    else
      deny guard-git-unclassified "segment=$cw ${rest[*]}"
    fi
  fi
}

# A newline, ;, &, && , || or | starts a new command. Builtin expansion rather
# than sed, so a missing binary cannot hide a segment.
segs="${cmd//"||"/$'\n'}"
segs="${segs//"&&"/$'\n'}"
segs="${segs//[;&|]/$'\n'}"

# The read-only exemption holds only when no text in the command can be run:
# no substitution or here-document anywhere, and no segment handing text to a
# shell, interpreter, or xargs, which would run what a read-only program prints.
READONLY_EXEMPT=1
case "$cmd" in *'$('*|*'`'*|*'<('*|*'>('*|*'<<'*) READONLY_EXEMPT=0 ;; esac
while IFS= read -r seg; do
  split_segment "$seg"
  in_list "$SEG_CW" "$SHELL_WORDS" && READONLY_EXEMPT=0
done <<< "$segs"

while IFS= read -r seg; do
  process_segment "$seg"
done <<< "$segs"

[ -z "$MSG" ] || refuse "$MSG" "${VALUES[@]}" "verbs=$GIT_READ"
exit 0
