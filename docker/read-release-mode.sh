#!/usr/bin/env bash
set -euo pipefail

release_source="${1:-release-source.json}"
jq -e '
  .schema == 1
  and .repository == "devshotcom/devshot"
  and (.release_tag | test("^(backend-)?v[0-9]+[.][0-9]+[.][0-9]+$"))
  and (.source_sha | test("^[0-9a-f]{40}$"))
  and (.release_mode == "regular" or .release_mode == "full")
' "$release_source" >/dev/null
mode="$(jq -r '.release_mode' "$release_source")"
printf 'mode=%s\n' "$mode"
