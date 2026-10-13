# guard-lib.sh: shared by the sidecar's PreToolUse hooks, which source it
# from beside themselves. It holds the git read verbs and the decision emitter,
# which takes each decision's text from the kit's message file by id, through
# fix-it.sh beside it.
#
# Baked root-owned and read-only with the hooks, fix-it.sh and
# fix-it-messages.txt: a hook that sources or runs a file the agent can write
# is as editable as that file.

FIX_IT="${BASH_SOURCE[0]%/*}/fix-it.sh"

GIT_READ='status diff log show blame ls-files ls-tree cat-file rev-parse rev-list describe shortlog grep merge-base for-each-ref check-ignore name-rev diff-tree count-objects fsck var help version check-attr show-ref ls-remote range-diff'

in_list() { # word list
  local w="$1" x
  for x in $2; do [ "$w" = "$x" ] && return 0; done
  return 1
}

# True when a read verb's arguments make it write: fsck --lost-found writes
# into the repository's lost-found folder. git takes any unambiguous prefix of
# a long option, and --lost-found is fsck's only option starting --l.
git_read_writes() { # verb args...
  local a
  [ "$1" = fsck ] || return 1
  shift
  for a in "$@"; do case "$a" in --l*) return 0 ;; esac; done
  return 1
}

# jq escapes the text. If jq fails here, the decision still goes out with a
# fixed reason, never as silence. Claude Code shows a deny's reason to the
# agent and an ask's reason to the user in the permission prompt.
emit() { # decision reason
  local out
  out=$(jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}' 2>/dev/null) \
    || out='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"'"$1"'","permissionDecisionReason":"A guard hook stopped this call, and jq failed while writing the reason. Report this to the user, or to the orchestrator if you are a subagent."}}'
  printf '%s\n' "$out"
  exit 0
}

# Sets TEXT to message <id> from the message file, each {name} in it filled
# from the name=value pairs that follow. When the lookup fails, a fixed text
# for the decision stands in, so the decision still carries a reason.
message() { # ask|deny id [name=value ...]
  local decision="$1" id="$2"
  shift
  TEXT=$("$FIX_IT" "$@" 2>/dev/null) && [ -n "$TEXT" ] && return
  if [ "$decision" = deny ]; then
    TEXT="GUARDRAIL block [$id]: the guard blocked this call, and its message file could not be read. Stop and report the broken guard hook: to the user if you are the main session, or to the orchestrator if you are a subagent."
  else
    TEXT="GUARDRAIL ask [$id]: this call needs your approval, and the guard could not read its message file. Approve only if you know what the call does."
  fi
}

refuse() { # id [name=value ...]
  message deny "$@"
  emit deny "$TEXT"
}
