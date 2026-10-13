#!/bin/sh
#
# fix-it.sh: prints one fix-it block from fix-it-messages.txt, the file beside
# this script, to standard output.
#
# Usage: fix-it.sh <id> [name=value ...]
#
# Each {name} in the block becomes its value, and a {name} with no value is
# printed as it stands. An unknown id, or a missing message file, prints a block
# saying so and exits 2, so a stop never goes unexplained.
#
# Shell builtins only: the image build runs it under /bin/sh, the firewall runs
# it as root with a pinned PATH, and a script on the host can run it with no
# other tools.

id=${1:-}
[ $# -eq 0 ] || shift
file="${0%/*}/fix-it-messages.txt"

# Replaces each {name} in $1 with its value from the name=value arguments that
# follow, scanning left to right so a value is never itself expanded.
expand() {
  rest=$1 out=
  shift
  while :; do
    case $rest in *"{"*"}"*) ;; *) break ;; esac
    out=$out${rest%%"{"*}
    rest=${rest#*"{"}
    key=${rest%%"}"*}
    for pair in "$@"; do
      case $pair in
        "$key="*) out=$out${pair#*=}; rest=${rest#*"}"}; continue 2 ;;
      esac
    done
    out=$out"{"
  done
  printf '%s\n' "$out$rest"
}

found=0 step=0
if [ -n "$id" ] && [ -r "$file" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "[$id]") found=1; continue ;;
      "["*"]") [ "$found" = 0 ] || break; continue ;;
    esac
    [ "$found" = 1 ] || continue
    case $line in
      "stage: "*) expand "AGENT-CONTAINER-KIT: ${line#stage: } STOPPED [$id]" "$@" ;;
      "failed: "*) expand "What failed: ${line#failed: }" "$@" ;;
      "asks: "*) expand "AGENT-CONTAINER-KIT: GUARD ASKS [$id]" "$@"; expand "${line#asks: }" "$@" ;;
      "means: "*) expand "What it means: ${line#means: }" "$@" ;;
      "fix: "*) step=$((step + 1)); expand "Step $step: ${line#fix: }" "$@" ;;
    esac
  done < "$file"
fi

if [ "$found" = 0 ]; then
  printf '%s\n' "AGENT-CONTAINER-KIT: STOPPED [${id:-no id}]" \
    "What failed: the kit stopped, and $file holds no message with this id." \
    "Step 1: Read the lines above this block for the failing step's own output."
  exit 2
fi
