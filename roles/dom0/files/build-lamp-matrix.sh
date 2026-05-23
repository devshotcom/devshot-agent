#!/bin/bash
# Build the LAMP template matrix (spec 058): a backing chain of
#
#   devshot-guest-base.qcow2
#     └─► devshot-guest-lamp-shared.qcow2     (intermediate: PHP+nginx+mariadb)
#            ├─► devshot-guest-lamp-wp-6.9.qcow2  (variant: WP 6.9.4)
#            ├─► devshot-guest-lamp-sw-6.7.qcow2  (variant: Shopware 6.7.10.0)
#            ├─► devshot-guest-lamp-t3-v14.qcow2  (variant: TYPO3 14.3.0)
#            └─► …
#
# The variant set is DISCOVERED at build time by discover-lamp-variants.py
# (queries WordPress API + Packagist for Shopware/TYPO3) and recorded in
# lamp-matrix.lock.json for reproducibility. Static wrapper files in
# apps/agent/recipes/lamp/<app>-<version>.sh were removed in favor of
# this — adding a new version means rebuilding (discovery picks it up),
# not editing the repo.
#
# Variant qcow2s only store the diff against lamp-shared (~30–80 MB each)
# instead of re-flattening the whole PHP/nginx/mariadb stack (~250 MB
# per variant if we flat-baked). qemu reads the chain transparently.
#
# Recipes:
#   apps/agent/recipes/lamp/_core.sh    — intermediate (PHP+nginx+mariadb)
#   apps/agent/recipes/lamp/_app_lib.sh — install_wordpress/shopware/typo3
#                                          + write_nginx_vhost helpers,
#                                          sourced by every variant
#
# Each variant's recipe is generated INLINE here from the discovered
# (app, version, port, doc_root) tuple — see build_variant().
#
# Usage:
#   build-lamp-matrix.sh <build-dir> <recipes-lamp-dir>
#
# Env knobs:
#   SKIP_SHARED=1      Reuse the existing lamp-shared.qcow2 (don't re-bake
#                      the intermediate). Speeds up iteration on variants.
#   MATRIX_LIMIT=N     Bake only the first N discovered variants. Useful
#                      for spot-checks before committing to the full set.
#   MATRIX_FILTER=re   Bake only variants whose variant_id matches the
#                      egrep regex. E.g. MATRIX_FILTER='^(wp-6\.[7-9]|sw-)'
set -euo pipefail

# Docker -v needs absolute paths or it interprets the argument as a
# named volume and rejects names with '/' or '.'. Canonicalize both
# inputs once at the top so every downstream invocation is safe even
# when the operator passed `./build` or similar.
BUILD_DIR_RAW="${1:?usage: build-lamp-matrix.sh <build-dir> <recipes-lamp-dir>}"
LAMP_DIR_RAW="${2:?usage: build-lamp-matrix.sh <build-dir> <recipes-lamp-dir>}"
mkdir -p "$BUILD_DIR_RAW"
BUILD_DIR="$(cd "$BUILD_DIR_RAW" && pwd)"
LAMP_DIR="$(cd "$LAMP_DIR_RAW" && pwd)"
BASE_QCOW="$BUILD_DIR/devshot-guest-base.qcow2"
SHARED_QCOW="$BUILD_DIR/devshot-guest-lamp-shared.qcow2"
CORE_RECIPE="$LAMP_DIR/_core.sh"
APP_LIB="$LAMP_DIR/_app_lib.sh"
DISCOVERY="$(dirname "$0")/discover-lamp-variants.py"

[ -f "$BASE_QCOW" ]   || { echo "ERROR: base qcow not found at $BASE_QCOW" >&2; exit 1; }
[ -d "$LAMP_DIR" ]    || { echo "ERROR: lamp recipes dir not found: $LAMP_DIR" >&2; exit 1; }
[ -f "$CORE_RECIPE" ] || { echo "ERROR: missing $CORE_RECIPE" >&2; exit 1; }
[ -f "$APP_LIB" ]     || { echo "ERROR: missing $APP_LIB" >&2; exit 1; }
[ -f "$DISCOVERY" ]   || { echo "ERROR: missing $DISCOVERY" >&2; exit 1; }

RECIPES_ROOT="$(cd "$LAMP_DIR/.." && pwd)"
DESKTOP_RECIPE="$RECIPES_ROOT/desktop.sh"
[ -f "$DESKTOP_RECIPE" ] || { echo "ERROR: shared desktop recipe missing: $DESKTOP_RECIPE" >&2; exit 1; }

echo "=== build-lamp-matrix ==="
echo "  base:        $BASE_QCOW"
echo "  intermediate: $CORE_RECIPE  ->  $SHARED_QCOW"

# ── Discovery ─────────────────────────────────────────────────────────────
# Resolves which variants to bake. Writes lamp-matrix.lock.json next to
# the qcow2 outputs so the same matrix can be replayed.
echo ""
echo "=== Discovery (upstream API query) ==="
MATRIX_JSON=$(python3 "$DISCOVERY" "$BUILD_DIR")
TOTAL_VARIANTS=$(echo "$MATRIX_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
echo "  resolved variants: $TOTAL_VARIANTS"

# Convert JSON to TSV for the bash loop. Order preserved; lock-file order
# is "newest major first" per app, so MATRIX_LIMIT=N gives the N newest.
MATRIX_TSV=$(echo "$MATRIX_JSON" | python3 -c '
import json, sys
for v in json.load(sys.stdin):
    print("\t".join([
        v["app"], v["resolved_version"], v["variant_id"],
        str(v["port"]), v["doc_root"], v["max_body"],
    ]))')

# Optional filter / limit. Limit applied AFTER filter.
if [ -n "${MATRIX_FILTER:-}" ]; then
  MATRIX_TSV=$(echo "$MATRIX_TSV" | awk -F'\t' -v re="$MATRIX_FILTER" '$3 ~ re')
  echo "  filtered to: $(echo "$MATRIX_TSV" | wc -l | tr -d ' ')"
fi
if [ -n "${MATRIX_LIMIT:-}" ]; then
  MATRIX_TSV=$(echo "$MATRIX_TSV" | head -n "$MATRIX_LIMIT")
  echo "  limited to: $(echo "$MATRIX_TSV" | wc -l | tr -d ' ')"
fi

# ── Inner bake script (unchanged from earlier iteration) ─────────────────
INNER_SCRIPT="$(mktemp)"
TMP_RECIPES_DIR="$(mktemp -d)"
trap 'rm -f "$INNER_SCRIPT"; rm -rf "$TMP_RECIPES_DIR"' EXIT
cat > "$INNER_SCRIPT" << 'INNEREOF'
#!/bin/bash
set -euxo pipefail

OUTPUT_NAME="${OUTPUT_NAME:?inner: missing OUTPUT_NAME}"
STAGE="${STAGE:?inner: missing STAGE (core|variant)}"
BASE_TEMPLATE="${BASE_TEMPLATE:-}"

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq qemu-utils e2fsprogs >/dev/null 2>&1

qemu-img convert -O raw /input/in.qcow2 /tmp/disk.raw
truncate -s 6G /tmp/disk.raw
e2fsck -fy /tmp/disk.raw 2>/dev/null || true
resize2fs /tmp/disk.raw 2>/dev/null || true

mkdir -p /mnt
mount -o loop /tmp/disk.raw /mnt
mount -t proc /proc /mnt/proc
mount -o bind /dev /mnt/dev
mount -o bind /dev/pts /mnt/dev/pts
mount -t sysfs /sys /mnt/sys

ORIG_RESOLV="$(cat /mnt/etc/resolv.conf 2>/dev/null || true)"
echo 'nameserver 1.1.1.1' > /mnt/etc/resolv.conf
echo 'nameserver 8.8.8.8' >> /mnt/etc/resolv.conf

cp /recipe.sh /mnt/tmp/recipe.sh
chmod +x /mnt/tmp/recipe.sh

if [ -d /recipe.d ]; then
  mkdir -p /mnt/tmp/recipe.d
  cp -r /recipe.d/. /mnt/tmp/recipe.d/
  cp /desktop-recipe.sh /mnt/tmp/recipe.d/desktop.sh
fi

if [ "$STAGE" = "core" ]; then
  sed -i 's|/alpine/v3\.[0-9]\+|/alpine/v3.23|g' /mnt/etc/apk/repositories || true
  chroot /mnt /sbin/apk update >/dev/null
  chroot /mnt /sbin/apk upgrade --no-cache >/dev/null
fi

chroot /mnt /bin/sh /tmp/recipe.sh

rm -rf /mnt/tmp/recipe.sh /mnt/tmp/recipe.d
if [ -n "$ORIG_RESOLV" ]; then
  printf '%s' "$ORIG_RESOLV" > /mnt/etc/resolv.conf
else
  : > /mnt/etc/resolv.conf
fi

sync
umount /mnt/dev/pts /mnt/proc /mnt/dev /mnt/sys
umount /mnt

OUT="/output/devshot-guest-${OUTPUT_NAME}.qcow2"

if [ "$STAGE" = "core" ] || [ -z "$BASE_TEMPLATE" ]; then
  qemu-img convert -f raw -O qcow2 -c /tmp/disk.raw "$OUT"
else
  # Compressed qcow2 with destination backing — see build-lamp-matrix.sh
  # for the full rationale. cd /output so the relative -B path resolves
  # both during convert (cluster diff) and later at template-load time
  # (qemu walking the chain on dom0).
  (
    cd /output
    qemu-img convert -f raw -O qcow2 -c \
      -B "devshot-guest-${BASE_TEMPLATE}.qcow2" \
      -F qcow2 \
      /tmp/disk.raw "./devshot-guest-${OUTPUT_NAME}.qcow2"
  )
fi
ls -lh "$OUT"

# ── Manifest sidecar ────────────────────────────────────────────────────
INTERMEDIATE="false"
[ "$STAGE" = "core" ] && INTERMEDIATE="true"

EXPOSED_PORTS=$(grep -m1 -E '^# *devshot:exposed_ports=' /recipe.sh \
  | sed -E 's|^# *devshot:exposed_ports=||' || true)
[ -z "$EXPOSED_PORTS" ] && EXPOSED_PORTS='[]'

UPSTREAM_VERSION=$(grep -m1 -E '^# *devshot:upstream_version=' /recipe.sh \
  | sed -E 's|^# *devshot:upstream_version=||' || true)
[ -z "$UPSTREAM_VERSION" ] && UPSTREAM_VERSION=""

MEMORY_MB=$(grep -m1 -E '^# *devshot:memory_mb=' /recipe.sh \
  | sed -E 's|^# *devshot:memory_mb=||' || true)
[ -z "$MEMORY_MB" ] && MEMORY_MB=0

BASE_PATH_FOR_MANIFEST="devshot-guest-base.qcow2"
[ -n "$BASE_TEMPLATE" ] && BASE_PATH_FOR_MANIFEST="devshot-guest-${BASE_TEMPLATE}.qcow2"

BASE_SHA=$(sha256sum /input/in.qcow2 | awk '{print $1}')
RECIPE_SHA=$(sha256sum /recipe.sh | awk '{print $1}')
SIZE=$(stat -c%s "$OUT")
BAKED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "/output/devshot-guest-${OUTPUT_NAME}.json" <<MANIFEST
{
  "name": "${OUTPUT_NAME}",
  "image": "devshot-guest-${OUTPUT_NAME}.qcow2",
  "base_path": "${BASE_PATH_FOR_MANIFEST}",
  "base_sha256": "${BASE_SHA}",
  "recipe_sha256": "${RECIPE_SHA}",
  "source": "prebaked",
  "baked_at": "${BAKED}",
  "bake_id": "make",
  "size_bytes": ${SIZE},
  "exit_code": 0,
  "exposed_ports": ${EXPOSED_PORTS},
  "memory_mb": ${MEMORY_MB},
  "intermediate": ${INTERMEDIATE},
  "base_template": "${BASE_TEMPLATE}",
  "upstream_version": "${UPSTREAM_VERSION}"
}
MANIFEST
ls -lh "/output/devshot-guest-${OUTPUT_NAME}.json"
INNEREOF

# ── Pass 1: bake the shared intermediate (or skip if SKIP_SHARED=1) ──────
if [ -n "${SKIP_SHARED:-}" ] && [ -f "$SHARED_QCOW" ]; then
  echo ""
  echo "=== Pass 1: SKIPPED (SKIP_SHARED=1, reusing existing $SHARED_QCOW) ==="
else
  echo ""
  echo "=== Pass 1: lamp-shared (intermediate) ==="
  docker run --rm --privileged \
    -e STAGE=core \
    -e OUTPUT_NAME=lamp-shared \
    -e BASE_TEMPLATE="" \
    -v "$INNER_SCRIPT:/build.sh:ro" \
    -v "$BASE_QCOW:/input/in.qcow2:ro" \
    -v "$CORE_RECIPE:/recipe.sh:ro" \
    -v "$LAMP_DIR:/recipe.d:ro" \
    -v "$DESKTOP_RECIPE:/desktop-recipe.sh:ro" \
    -v "$BUILD_DIR:/output" \
    debian:bookworm-slim bash /build.sh
fi
[ -f "$SHARED_QCOW" ] || { echo "ERROR: pass 1 produced no $SHARED_QCOW" >&2; exit 1; }

# ── Pass 2: bake every discovered variant ────────────────────────────────
SUCCEEDED=()
FAILED=()

# Subshell because the loop reads from a here-string while we want the
# arrays modified to stick. `< <(printf '%s\n' "$MATRIX_TSV")` keeps the
# loop in the current shell. Empty TSV (nothing matched the filter) is
# a real error — we want operator feedback, not a silent no-op.
if [ -z "$MATRIX_TSV" ]; then
  echo "ERROR: matrix is empty (filter/limit dropped everything?)" >&2
  exit 1
fi

while IFS=$'\t' read -r app version variant_id port doc_root max_body; do
  [ -z "$app" ] && continue
  out_name="lamp-${variant_id}"

  # Generate the variant recipe inline. Magic-comment header carries the
  # metadata the manifest writer (in $INNER_SCRIPT) greps for.
  variant_recipe="$TMP_RECIPES_DIR/${out_name}.sh"
  cat > "$variant_recipe" <<RECIPE
#!/bin/sh
# devshot:base_template=lamp-shared
# devshot:exposed_ports=[{"port":8080,"name":"editor","proto":"http"},{"port":${port},"name":"${app}","proto":"http"},{"port":5900,"name":"vnc","proto":"tcp"}]
# devshot:upstream_version=${version}
# devshot:memory_mb=1536
#
# Auto-generated by build-lamp-matrix.sh from the discovered matrix
# entry (${app} ${version}). Variant qcow2 is backed by lamp-shared.
#
# Three exposed ports — editor (:8080) is the primary entry, AppsTab
# defaults to that iframe so the user lands directly in VSCode with
# /var/www/<app> as the open folder. The live app on :${port} is
# reachable via a second tab (or the editor's port-forward panel)
# for preview. VNC (:5900) backs the public Desktop demo on the same
# machine. openvscode-server itself lives in lamp-shared so this layer
# just sets the workspace via set_editor_workspace inside install_<app>.

set -eux

# shellcheck disable=SC1091
. /tmp/recipe.d/_app_lib.sh

start_mariadb_for_bake
install_${app} "${version}"
write_nginx_vhost ${app} ${port} ${doc_root} ${max_body}
stop_mariadb_after_bake
finalize_app_bake

echo "=== lamp/${variant_id} (${app} ${version}) ==="
du -sh ${doc_root%/public} 2>/dev/null || du -sh ${doc_root} 2>/dev/null || true
RECIPE

  echo ""
  echo "=== Pass 2: $out_name ($app $version) ==="
  if docker run --rm --privileged \
    -e STAGE=variant \
    -e OUTPUT_NAME="$out_name" \
    -e BASE_TEMPLATE=lamp-shared \
    -v "$INNER_SCRIPT:/build.sh:ro" \
    -v "$SHARED_QCOW:/input/in.qcow2:ro" \
    -v "$variant_recipe:/recipe.sh:ro" \
    -v "$LAMP_DIR:/recipe.d:ro" \
    -v "$DESKTOP_RECIPE:/desktop-recipe.sh:ro" \
    -v "$BUILD_DIR:/output" \
    debian:bookworm-slim bash /build.sh; then
    SUCCEEDED+=("$out_name")
  else
    FAILED+=("$out_name")
    echo "WARN: variant '$out_name' failed — continuing with the rest" >&2
  fi
done < <(printf '%s\n' "$MATRIX_TSV")

echo ""
echo "=== build-lamp-matrix summary ==="
echo "  intermediate: lamp-shared"
echo "  succeeded:    ${#SUCCEEDED[@]} (${SUCCEEDED[*]:-none})"
echo "  failed:       ${#FAILED[@]} (${FAILED[*]:-none})"
ls -lh "$BUILD_DIR"/devshot-guest-lamp-*.qcow2 2>/dev/null || echo "  (no lamp qcow2s produced)"

if [ "${#SUCCEEDED[@]}" -eq 0 ]; then
  echo "ERROR: no variants succeeded" >&2
  exit 1
fi
exit 0
