#!/usr/bin/env bash
# Link the xirp-hierarchy skill into pi, Claude Code, and Codex skill directories.
# Usage: ./install.sh [pi|claude|codex ...]        (default: all)
#        ./install.sh --uninstall [targets...]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/skills/xirp-hierarchy"
NAME="xirp-hierarchy"

dest_for() {
  case "$1" in
    pi) echo "$HOME/.pi/skills";;
    claude) echo "$HOME/.claude/skills";;
    codex) echo "$HOME/.codex/skills";;
  esac
}

uninstall=0
targets=()
for a in "$@"; do
  case "$a" in
    --uninstall) uninstall=1;;
    pi|claude|codex) targets+=("$a");;
    *) echo "unknown argument: $a" >&2; exit 1;;
  esac
done
[[ ${#targets[@]} -gt 0 ]] || targets=(pi claude codex)

chmod +x "$SRC/scripts/hierarchy.sh"

for t in "${targets[@]}"; do
  dir="$(dest_for "$t")"; link="$dir/$NAME"
  if [[ $uninstall -eq 1 ]]; then
    if [[ -L "$link" ]]; then rm "$link"; echo "removed  $link"; else echo "skip     $link (not a symlink)"; fi
    continue
  fi
  mkdir -p "$dir"
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "skip     $link exists and is not a symlink; remove it manually" >&2; continue
  fi
  ln -sfn "$SRC" "$link"
  echo "linked   $link -> $SRC"
done
