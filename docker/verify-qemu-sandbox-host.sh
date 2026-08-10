#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_root="$(cd "$script_dir/.." && pwd)"
bin_dir="${DEVSHOT_SANDBOX_BIN_DIR:-$agent_root/bin}"
docker_bin="${DOCKER_BIN:-docker}"
timeout_bin="${TIMEOUT_BIN:-timeout}"
probe_image="${DEVSHOT_SANDBOX_PROBE_IMAGE:-debian:bookworm-slim}"

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "ERROR: unsupported sandbox probe architecture $(uname -m)" >&2; exit 2 ;;
esac

namespace_helper="$bin_dir/devshot-userns-run-linux-$arch"
sandbox_init="$bin_dir/devshot-sandbox-init-linux-$arch"
for binary in "$namespace_helper" "$sandbox_init"; do
  [ -f "$binary" ] && [ -x "$binary" ] && [ ! -L "$binary" ] || {
    echo "ERROR: sandbox probe binary is missing, non-executable, or a symlink: $binary" >&2
    exit 2
  }
done
command -v "$docker_bin" >/dev/null 2>&1 || { echo "ERROR: docker is unavailable" >&2; exit 2; }
command -v "$timeout_bin" >/dev/null 2>&1 || { echo "ERROR: GNU timeout is unavailable" >&2; exit 2; }

probe='\
test "$(id -u)" = 20001
test "$(id -g)" = 108
cap_eff=
no_new_privs=
namespace_pid=
while read -r key values; do
  case "$key" in
    CapEff:) cap_eff="$values" ;;
    NoNewPrivs:) no_new_privs="$values" ;;
    NSpid:) for value in $values; do namespace_pid="$value"; done ;;
  esac
done < /proc/self/status
test "$cap_eff" = 0000000000000000
test "$no_new_privs" = 1
test "$namespace_pid" = 1
test "$(cat /run/devshot/host-marker)" = host-visible
printf guest-visible > /run/devshot/guest-marker
mkdir -p /tmp/devshot-mount-probe
if mount -t tmpfs none /tmp/devshot-mount-probe 2>/dev/null; then
  echo "ERROR: sandboxed process retained mount capability" >&2
  exit 1
fi
test ! -e /workspace
printf "DEVSHOT_QEMU_SANDBOX_HOST_OK uid=%s gid=%s pid=%s\n" "$(id -u)" "$(id -g)" "$namespace_pid"
'

"$timeout_bin" --foreground --signal=TERM --kill-after=5s 45s \
  "$docker_bin" run --rm --privileged --network=none \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    --tmpfs /workspace:exec,mode=0755 \
    --mount "type=bind,src=$namespace_helper,dst=/usr/local/bin/devshot-userns-run,readonly" \
    --mount "type=bind,src=$sandbox_init,dst=/usr/local/bin/devshot-sandbox-init,readonly" \
    -e "DEVSHOT_SANDBOX_PROBE=$probe" \
    --entrypoint /bin/sh "$probe_image" -eu -c '
      mkdir -p /workspace/root /workspace/control/tmp
      printf host-visible > /workspace/control/host-marker
      chown -R 20001:108 /workspace /workspace/root /workspace/control
      /usr/local/bin/devshot-userns-run --uid=20001 --gid=108 --net -- \
        /usr/local/bin/devshot-sandbox-init \
          --chroot=/workspace/root --control-dir=/workspace/control \
          --uid=20001 --gid=108 -- \
          /bin/sh -eu -c "$DEVSHOT_SANDBOX_PROBE"
      test "$(cat /workspace/control/guest-marker)" = guest-visible
    '
