#!/bin/sh
# Bake the reviewed Grok Build binary plus official GitHub Spec Kit into a VM.
# Every network input is pinned; runtime project initialization is offline.
set -eux

GROK_VERSION=1.0.0
SPEC_KIT_VERSION=0.12.17
SPEC_KIT_COMMIT=284e9a6a80106457129addeddedaf1641a374771

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    GROK_ARCH=x86_64
    GROK_SHA256=28dbc967a5843dae2374b6834dadbab95354e685c7e5c8dc750b92a4e5fc7c3e
    ;;
  aarch64|arm64)
    GROK_ARCH=aarch64
    GROK_SHA256=bb7c51116564a2219f6a49850815060f416918ac407f1f2ba82c53c0b0d4383f
    ;;
  *)
    echo "ERROR: unsupported architecture $ARCH for Grok Build" >&2
    exit 1
    ;;
esac

apk add --no-cache ca-certificates wget git python3 py3-pip

mkdir -p /opt/grok
wget -q -O /tmp/grok "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${GROK_VERSION}-linux-${GROK_ARCH}"
echo "${GROK_SHA256}  /tmp/grok" | sha256sum -c -
install -m 0755 /tmp/grok /opt/grok/grok
ln -sfn /opt/grok/grok /usr/local/bin/grok
rm -f /tmp/grok
grok --version | head -1

python3 -m venv /opt/specify-cli
/opt/specify-cli/bin/pip install --no-cache-dir \
  "git+https://github.com/github/spec-kit.git@${SPEC_KIT_COMMIT}"
ln -sfn /opt/specify-cli/bin/specify /usr/local/bin/specify
test "$(specify --version | awk 'NR == 1 { print $2 }')" = "$SPEC_KIT_VERSION"

[ -s /usr/local/libexec/devshot/ensure-grok-speckit.sh ] || {
  echo "ERROR: Grok Spec Kit provisioner is missing from the base image" >&2
  exit 1
}
install -m 0755 /usr/local/libexec/devshot/ensure-grok-speckit.sh \
  /usr/local/bin/devshot-ensure-grok-speckit

grok --version | head -1
specify --version | head -1
