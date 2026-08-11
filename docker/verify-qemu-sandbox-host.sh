#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_root="$(cd "$script_dir/.." && pwd)"
bin_dir="${DEVSHOT_SANDBOX_BIN_DIR:-$agent_root/bin}"
docker_bin="${DOCKER_BIN:-docker}"
timeout_bin="${TIMEOUT_BIN:-timeout}"
profile_loader_image="${DEVSHOT_SANDBOX_PROFILE_LOADER_IMAGE:-}"
probe_image="${DEVSHOT_SANDBOX_PROBE_IMAGE:-$profile_loader_image}"

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
[ -n "$profile_loader_image" ] || { echo "ERROR: DEVSHOT_SANDBOX_PROFILE_LOADER_IMAGE is required" >&2; exit 2; }
if [[ ! "$profile_loader_image" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]]; then
  echo "ERROR: invalid AppArmor profile loader image reference: $profile_loader_image" >&2
  exit 2
fi
if [[ ! "$probe_image" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]]; then
  echo "ERROR: invalid sandbox probe image reference: $probe_image" >&2
  exit 2
fi
case "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true)" in
  Y|y) ;;
  *) echo "ERROR: AppArmor is not enabled on the QEMU build host" >&2; exit 2 ;;
esac
[ -d /sys/kernel/security ] || { echo "ERROR: AppArmor securityfs is unavailable" >&2; exit 2; }

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/devshot-qemu-sandbox-probe.XXXXXXXX")"
profile_name="devshot-qemu-sandbox-probe-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}-$$"
profile_path="$probe_dir/$profile_name"
profile_loaded=0
pull_dependency_image() {
  local image_ref="$1"
  local description="$2"
  local attempt
  for attempt in 1 2 3 4; do
    if "$timeout_bin" --foreground --signal=TERM --kill-after=5s 300s \
      "$docker_bin" pull "$image_ref"; then
      return 0
    fi
    if [ "$attempt" -lt 4 ]; then
      echo "$description pull attempt $attempt failed; resuming on the next attempt" >&2
    fi
  done
  echo "ERROR: failed to pull $description image after four bounded attempts: $image_ref" >&2
  return 1
}
run_profile_parser() {
  local operation="$1"
  "$timeout_bin" --foreground --signal=TERM --kill-after=5s 60s \
    "$docker_bin" run --rm --pull=never --privileged --network=none \
      --security-opt apparmor=unconfined \
      --mount type=bind,src=/sys/kernel/security,dst=/sys/kernel/security \
      --mount "type=bind,src=$profile_path,dst=/tmp/$profile_name,readonly" \
      --entrypoint /usr/sbin/apparmor_parser \
      "$profile_loader_image" "$operation" "/tmp/$profile_name"
}
cleanup() {
  status=$?
  trap - EXIT INT TERM
  cleanup_failed=0
  if [ "$profile_loaded" -eq 1 ]; then
    if ! run_profile_parser --remove >/dev/null 2>&1; then
      echo "ERROR: failed to unload AppArmor sandbox probe profile $profile_name" >&2
      cleanup_failed=1
    fi
  fi
  case "$probe_dir" in
    "${TMPDIR:-/tmp}"/devshot-qemu-sandbox-probe.*)
      rm -f -- "$profile_path"
      rmdir "$probe_dir" 2>/dev/null || cleanup_failed=1
      ;;
    *) echo "ERROR: refusing unsafe sandbox probe cleanup: $probe_dir" >&2; cleanup_failed=1 ;;
  esac
  if [ "$cleanup_failed" -ne 0 ]; then status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pull_dependency_image "$profile_loader_image" "AppArmor profile loader"
if [ "$probe_image" != "$profile_loader_image" ]; then
  pull_dependency_image "$probe_image" "sandbox probe"
fi

cat > "$profile_path" <<EOF
#include <tunables/global>
profile $profile_name flags=(chroot_relative) {
  /** mr,
  /bin/** rix,
  /sbin/** rix,
  /usr/bin/** rix,
  /usr/sbin/** rix,
  /run/devshot/ rw,
  /run/devshot/** rw,
  unix (create, bind, listen, accept, connect, send, receive, getattr, setattr, getopt, setopt, shutdown) type=stream,
  /tmp/ rw,
  /tmp/** rw,
  /dev/null rw,
  deny capability,
  deny mount,
  deny umount,
  deny remount,
  deny pivot_root,
}
EOF
run_profile_parser -r
profile_loaded=1

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
socat -T 5 UNIX-LISTEN:/run/devshot/probe.sock EXEC:/bin/cat &
socket_server_pid=$!
socket_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if test -S /run/devshot/probe.sock; then
    socket_ready=1
    break
  fi
  kill -0 "$socket_server_pid"
  sleep 0.1
done
test "$socket_ready" = 1
test "$(printf unix-socket-ok | socat -T 5 - UNIX-CONNECT:/run/devshot/probe.sock)" = unix-socket-ok
wait "$socket_server_pid"
rm -f /run/devshot/probe.sock
mkdir -p /tmp/devshot-mount-probe
if mount -t tmpfs none /tmp/devshot-mount-probe 2>/dev/null; then
  echo "ERROR: sandboxed process retained mount capability" >&2
  exit 1
fi
test ! -e /workspace
printf "DEVSHOT_QEMU_SANDBOX_HOST_OK uid=%s gid=%s pid=%s\n" "$(id -u)" "$(id -g)" "$namespace_pid"
'

"$timeout_bin" --foreground --signal=TERM --kill-after=5s 45s \
  "$docker_bin" run --rm --pull=never --privileged --network=none \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    --tmpfs /workspace:exec,mode=0755 \
    --mount "type=bind,src=$namespace_helper,dst=/usr/local/bin/devshot-userns-run,readonly" \
    --mount "type=bind,src=$sandbox_init,dst=/usr/local/bin/devshot-sandbox-init,readonly" \
    -e "DEVSHOT_APPARMOR_PROFILE=$profile_name" \
    -e "DEVSHOT_SANDBOX_PROBE=$probe" \
    --entrypoint /bin/sh "$probe_image" -eu -c '
      mkdir -p /workspace/root/run/devshot/tmp
      printf host-visible > /workspace/root/run/devshot/host-marker
      chown -R 20001:108 /workspace/root
      /usr/local/bin/devshot-userns-run --uid=20001 --gid=108 --net -- \
        /usr/local/bin/devshot-sandbox-init \
          --chroot=/workspace/root --uid=20001 --gid=108 \
          --apparmor="$DEVSHOT_APPARMOR_PROFILE" -- \
          /bin/sh -eu -c "$DEVSHOT_SANDBOX_PROBE"
      test "$(cat /workspace/root/run/devshot/guest-marker)" = guest-visible
    '
