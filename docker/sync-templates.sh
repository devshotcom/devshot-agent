#!/bin/sh
# Materialize prebaked guest templates from the immutable image layer into
# the writable guests directory. KVM installs bind-mount GUESTS_DIR over
# /xen/guests, so files copied there at image build time are otherwise hidden.
set -eu

SOURCE_DIR="${DEVSHOT_TEMPLATE_SOURCE_DIR:-/opt/devshot/templates}"
TARGET_DIR="${DEVSHOT_TEMPLATE_TARGET_DIR:-${GUESTS_DIR:-/xen/guests}/templates}"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "  Templates: source not found (${SOURCE_DIR})"
  exit 0
fi

mkdir -p "$TARGET_DIR"

seen=0
updated=0
for src in "$SOURCE_DIR"/devshot-guest-*.qcow2 "$SOURCE_DIR"/devshot-guest-*.json; do
  [ -f "$src" ] || continue
  seen=$((seen + 1))
  name="$(basename "$src")"
  dst="$TARGET_DIR/$name"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    continue
  fi
  tmp="$TARGET_DIR/.${name}.tmp.$$"
  cp "$src" "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$dst"
  updated=$((updated + 1))
done

if [ "$seen" -eq 0 ]; then
  echo "  Templates: none bundled in ${SOURCE_DIR}"
else
  echo "  Templates: synchronized ${seen} files to ${TARGET_DIR} (${updated} updated)"
fi
