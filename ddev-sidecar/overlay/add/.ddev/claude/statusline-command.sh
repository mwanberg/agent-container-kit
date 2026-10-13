#!/bin/bash
# Claude Code status line for the DDEV sidecar.
# Shows: current directory, git branch, model, effort level, context remaining
#
# Baked root-owned into the image at
# /usr/local/lib/agent-container-kit/statusline-command.sh, the path the
# statusLine block in managed-settings.json names, so a change here takes
# effect at the next image rebuild.
#
# Needs jq and git, both in the sidecar image. --no-optional-locks stops git
# taking optional locks, which need a writable .git.

input=$(cat)

dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

display_dir="$dir"
if [ -n "$dir" ]; then
  home_dir="$HOME"
  case "$dir" in
    "$home_dir"/*) display_dir="~${dir#$home_dir}" ;;
    "$home_dir") display_dir="~" ;;
  esac
fi

branch=""
if [ -n "$dir" ]; then
  branch=$(git --git-dir="$dir/.git" --no-optional-locks -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -z "$branch" ]; then
    branch=$(git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
  fi
fi

# Colors (bright/bold palette for visibility on dark backgrounds)
COLOR_DIR="\033[1;96m"    # bright cyan
COLOR_BRANCH="\033[1;93m" # bright yellow
COLOR_MODEL="\033[1;95m"  # bright magenta
COLOR_EFFORT="\033[1;94m" # bright blue
COLOR_CTX="\033[1;92m"    # bright green
RESET="\033[0m"
SEP="\033[1;37m|${RESET}"

parts=()

if [ -n "$display_dir" ]; then
  parts+=("$(printf "${COLOR_DIR}%s${RESET}" "$display_dir")")
fi

if [ -n "$branch" ]; then
  parts+=("$(printf "${COLOR_BRANCH}%s${RESET}" "$branch")")
fi

if [ -n "$model" ]; then
  if [ -n "$effort" ]; then
    parts+=("$(printf "${COLOR_MODEL}%s${RESET} ${COLOR_EFFORT}(%s)${RESET}" "$model" "$effort")")
  else
    parts+=("$(printf "${COLOR_MODEL}%s${RESET}" "$model")")
  fi
fi

if [ -n "$remaining" ]; then
  parts+=("$(printf "${COLOR_CTX}ctx %s%% left${RESET}" "$remaining")")
fi

output=""
for part in "${parts[@]}"; do
  if [ -z "$output" ]; then
    output="$part"
  else
    output="$output $(printf "$SEP") $part"
  fi
done

printf "%b\n" "$output"
