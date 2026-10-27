#!/usr/bin/env bash
# Installs the Claude Code solver kit from priv/claude_code/kit into a dedicated
# solver folder (default ~/eab-solver). The folder must not be a repository or hold
# project instructions; the controller refuses attempts from a drifted kit.
#
# Usage: scripts/install-claude-code-kit.sh [--url http://127.0.0.1:4000] [FOLDER]
set -euo pipefail

url="http://127.0.0.1:${PORT:-4000}"
target="$HOME/eab-solver"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="${2:?--url needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) target="$1"; shift ;;
  esac
done

url="${url%/}"
if ! [[ "$url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
  echo "The controller URL must be http://127.0.0.1:PORT or http://localhost:PORT: $url" >&2
  exit 1
fi

source="$(cd "$(dirname "$0")/.." && pwd)/priv/claude_code/kit"
mkdir -p "$target"
target="$(cd "$target" && pwd)"

dir="$target"
while :; do
  if [ -e "$dir/.git" ]; then echo "Refusing: $dir is a Git repository" >&2; exit 1; fi
  for file in CLAUDE.md CLAUDE.local.md AGENTS.md .claude/CLAUDE.md; do
    if [ -f "$dir/$file" ]; then echo "Refusing: instruction file $dir/$file would reach the solver" >&2; exit 1; fi
  done
  [ "$dir" = "/" ] && break
  dir="$(dirname "$dir")"
done
# Replace the whole .claude folder and .mcp.json so stale or extra files cannot survive.
rm -rf "$target/.claude" "$target/.mcp.json"
(cd "$source" && { echo .mcp.json; find .claude -type f -not -path '*/__pycache__/*' | sort; }) | while read -r file; do
  mkdir -p "$target/$(dirname "$file")"
  sed "s|__EAB_CONTROLLER_URL__|$url|g" "$source/$file" > "$target/$file"
done

echo "Installed the Claude Code solver kit in $target for $url"
echo "Open that folder in a new Claude desktop Code session, trust it, and type /solve-run."
