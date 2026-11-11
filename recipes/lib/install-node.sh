#!/bin/sh
# Install the newest Node.js release of one LTS line into a guest image.
#
# Alpine's `nodejs` package trails nodejs.org by months: on 2026-10-21 both
# v3.23 and v3.24 still shipped releases older than that day's security fixes
# (22.23.4 / 24.22.1 / 26.12.1: TLS certificate checks, DNS, Brotli RCE), and
# every template baked from them carried the old interpreter. This installs the
# musl build the Node.js project publishes on unofficial-builds.nodejs.org — the
# same tarball the official `node:*-alpine` images are made from — checked
# against its SHASUMS256, into /usr/local, and points /usr/bin/node at it so
# OpenRC services that name /usr/bin/node run the current release too.
#
# The version is resolved from nodejs.org's release index at bake time, so a
# rebake is all it takes to pick up the next security release. Call it right
# after the recipe's `apk add … nodejs npm`: anything npm installs afterwards
# is built against the new runtime.
#
# Offline bakes (9p apk cache, no route out) keep the apk Node and warn: the
# image still works, and the next networked rebake replaces it. Any other
# failure — checksum, wrong version after install — fails the bake.
#
#   install-node.sh [major]        default: $DEVSHOT_NODE_MAJOR or 24
set -eu

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MAJOR="${1:-${DEVSHOT_NODE_MAJOR:-24}}"
case "$MAJOR" in
  ''|*[!0-9]*) echo "ERROR: Node.js major must be a number, got '$MAJOR'" >&2; exit 2 ;;
esac
INDEX_URL="${DEVSHOT_NODE_INDEX_URL:-https://nodejs.org/dist/index.json}"
DIST_URL="${DEVSHOT_NODE_DIST_URL:-https://unofficial-builds.nodejs.org/download/release}"

case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "ERROR: no Node.js musl build for $(uname -m)" >&2; exit 1 ;;
esac

fetch() {
  curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 "$@"
}

# Every release of the line, newest first. index.json lists releases newest
# first; the musl build of the newest one is not always published yet, so the
# bake must be able to step back to the newest release that actually has one
# (2026-11-11: the newest v24 had no musl tarball yet and the bake died on
# a 404).
index=$(fetch "$INDEX_URL" 2>/dev/null || true)
VERSIONS=$(printf '%s' "$index" | tr '{' '\n' | grep -o "\"version\":\"v${MAJOR}\.[0-9]*\.[0-9]*\"" | cut -d'"' -f4 | awk '!seen[$0]++')
VERSION=$(printf '%s' "$VERSIONS" | head -1)
if [ -z "$VERSION" ]; then
  if command -v node >/dev/null 2>&1; then
    echo "WARN: nodejs.org unreachable — keeping $(node -v) from apk; the next networked rebake installs the current v${MAJOR} release" >&2
    exit 0
  fi
  echo "ERROR: nodejs.org unreachable and no Node.js installed" >&2
  exit 1
fi

if [ "$(/usr/local/bin/node -v 2>/dev/null || true)" = "$VERSION" ]; then
  echo "node $VERSION already installed"
else
  apk add --no-cache libstdc++ libgcc ca-certificates curl tar >/dev/null
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  installed=""
  for candidate in $VERSIONS; do
    NAME="node-${candidate}-linux-${ARCH}-musl"
    if ! fetch -o "$work/SHASUMS256.txt" "$DIST_URL/$candidate/SHASUMS256.txt"; then
      echo "WARN: no SHASUMS256 for node $candidate; trying the next release" >&2
      continue
    fi
    expected=$(awk -v f="$NAME.tar.gz" '$2 == f { print $1 }' "$work/SHASUMS256.txt")
    if [ -z "$expected" ]; then
      echo "WARN: node $candidate has no musl build for ${ARCH}; trying the next release" >&2
      continue
    fi
    if ! fetch -o "$work/$NAME.tar.gz" "$DIST_URL/$candidate/$NAME.tar.gz"; then
      echo "WARN: node $candidate tarball is not downloadable; trying the next release" >&2
      continue
    fi
    actual=$(sha256sum "$work/$NAME.tar.gz" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
      echo "ERROR: checksum mismatch for $NAME.tar.gz" >&2
      exit 1
    fi
    VERSION="$candidate"
    installed=1
    break
  done
  if [ -z "$installed" ]; then
    echo "ERROR: no musl build of Node ${MAJOR} could be downloaded" >&2
    exit 1
  fi
  NAME="node-${VERSION}-linux-${ARCH}-musl"

  # Drop the apk runtime first: npm depends on nodejs, and leaving either in
  # place lets a later `apk upgrade` put the old binary back on PATH.
  apk del --no-cache nodejs nodejs-current npm >/dev/null 2>&1 || true
  rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack
  tar -xzf "$work/$NAME.tar.gz" -C /usr/local --strip-components=1 --no-same-owner \
    "$NAME/bin" "$NAME/lib" "$NAME/include" "$NAME/share"
fi

# A package that still depends on nodejs keeps /usr/bin/node; replace it either
# way so absolute /usr/bin/node and /usr/bin/npm callers get this release.
for tool in node npm npx corepack; do
  [ -e "/usr/local/bin/$tool" ] || continue
  rm -f "/usr/bin/$tool"
  ln -s "/usr/local/bin/$tool" "/usr/bin/$tool"
done

for bin in /usr/local/bin/node /usr/bin/node node; do
  got=$($bin -v 2>/dev/null || true)
  [ "$got" = "$VERSION" ] || { echo "ERROR: $bin is '${got:-missing}', expected $VERSION" >&2; exit 1; }
done
npm -v >/dev/null || { echo "ERROR: npm does not run under $VERSION" >&2; exit 1; }
echo "NODE_READY=$VERSION"
