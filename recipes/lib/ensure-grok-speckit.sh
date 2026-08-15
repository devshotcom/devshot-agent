#!/bin/sh
# Provision the official GitHub Spec Kit Grok skills into one Studio project.
# The CLI and all templates are baked into the image, so this runs offline.
set -eu

SPEC_KIT_VERSION=0.12.17
SPECIFY_BIN="${DEVSHOT_SPECIFY_BIN:-/opt/specify-cli/bin/specify}"

project_dir="${1:-}"
case "$project_dir" in
  /*) ;;
  *) echo "ERROR: absolute Studio project directory required" >&2; exit 2 ;;
esac
[ -d "$project_dir" ] || { echo "ERROR: Studio project directory not found: $project_dir" >&2; exit 2; }
[ -x "$SPECIFY_BIN" ] || { echo "ERROR: official Spec Kit CLI is not installed" >&2; exit 3; }

actual_version="$($SPECIFY_BIN --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
[ "$actual_version" = "$SPEC_KIT_VERSION" ] || {
  echo "ERROR: Spec Kit version mismatch: expected $SPEC_KIT_VERSION, got ${actual_version:-missing}" >&2
  exit 3
}

needs_init=0
grep -q '"ai"[[:space:]]*:[[:space:]]*"grok"' "$project_dir/.specify/init-options.json" 2>/dev/null || needs_init=1
grep -q '"ai_skills"[[:space:]]*:[[:space:]]*true' "$project_dir/.specify/init-options.json" 2>/dev/null || needs_init=1
grep -q '"speckit_version"[[:space:]]*:[[:space:]]*"0.12.17"' "$project_dir/.specify/init-options.json" 2>/dev/null || needs_init=1

for skill in constitution specify clarify plan tasks analyze checklist implement converge taskstoissues; do
  [ -s "$project_dir/.grok/skills/speckit-$skill/SKILL.md" ] || needs_init=1
done

if [ "$needs_init" -eq 1 ]; then
  (
    cd "$project_dir"
    "$SPECIFY_BIN" init --here --force --integration grok --script sh --ignore-agent-tools </dev/null
  )
fi

for skill in constitution specify clarify plan tasks analyze checklist implement converge taskstoissues; do
  [ -s "$project_dir/.grok/skills/speckit-$skill/SKILL.md" ] || {
    echo "ERROR: official Grok skill missing after Spec Kit initialization: speckit-$skill" >&2
    exit 4
  }
done

echo "GROK_SPECKIT_READY=$SPEC_KIT_VERSION"
