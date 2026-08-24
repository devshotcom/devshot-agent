#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: run-vmm-integration.sh <qemu|firecracker> <candidate-image> <TestIntegrationQEMU|TestIntegrationFirecracker|TestIntegrationEscape>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
backend="$1"
candidate_image="$2"
test_name="$3"

case "$backend:$test_name" in
  qemu:TestIntegrationQEMU|qemu:TestIntegrationEscape|firecracker:TestIntegrationFirecracker|firecracker:TestIntegrationEscape) ;;
  *)
    echo "ERROR: test $test_name is not valid for backend $backend" >&2
    exit 2
    ;;
esac
if [[ ! "$candidate_image" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]]; then
  echo "ERROR: invalid candidate image reference" >&2
  exit 2
fi

docker_bin="${DOCKER_BIN:-docker}"
timeout_bin="${TIMEOUT_BIN:-timeout}"
kvm_device="${DEVSHOT_KVM_DEVICE:-/dev/kvm}"
tun_device="${DEVSHOT_TUN_DEVICE:-/dev/net/tun}"
if [[ "$kvm_device" != /* ]] || [ ! -c "$kvm_device" ]; then
  echo "ERROR: real VMM integration requires a character-device KVM path, got $kvm_device" >&2
  exit 4
fi
if [[ "$tun_device" != /* ]] || [ ! -c "$tun_device" ]; then
  echo "ERROR: real VMM integration requires a character-device TUN path, got $tun_device" >&2
  exit 4
fi
command -v "$docker_bin" >/dev/null 2>&1 || { echo "ERROR: docker is unavailable" >&2; exit 4; }
command -v "$timeout_bin" >/dev/null 2>&1 || { echo "ERROR: GNU timeout is unavailable" >&2; exit 4; }

host_arch="$($docker_bin info --format '{{.Architecture}}')"
image_arch="$($docker_bin image inspect --format '{{.Architecture}}' "$candidate_image")"
case "$host_arch" in
  x86_64) host_arch=amd64 ;;
  aarch64) host_arch=arm64 ;;
esac
case "$image_arch" in
  x86_64) image_arch=amd64 ;;
  aarch64) image_arch=arm64 ;;
esac
case "$host_arch" in amd64|arm64) ;; *) echo "ERROR: unsupported Docker host architecture $host_arch" >&2; exit 4 ;; esac
if [ "$image_arch" != "$host_arch" ]; then
  echo "ERROR: candidate image architecture $image_arch does not match KVM host $host_arch" >&2
  exit 4
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent_root="$(cd "$script_dir/.." && pwd)"
test_binary="${DEVSHOT_VMM_INTEGRATION_BINARY:-$agent_root/bin/devshot-agent-integration-linux-$host_arch}"
if [ ! -f "$test_binary" ] || [ ! -x "$test_binary" ] || [ -L "$test_binary" ]; then
  echo "ERROR: exact $host_arch integration test binary is missing, non-executable, or a symlink: $test_binary" >&2
  exit 4
fi

workspace="$(mktemp -d "${TMPDIR:-/tmp}/devshot-vmm-integration.XXXXXXXX")"
chmod 0755 "$workspace"
container_name="devshot-vmm-it-${backend}-$(date +%s)-$$"
container_started=0
cleanup() {
  status=$?
  trap - EXIT INT TERM
  cleanup_failed=0
  local -a cleanup_command
  cleanup_command=(
    "$docker_bin" run --rm --name "${container_name}-cleanup"
    --privileged --network=none
  )
  if [ "$backend" = qemu ]; then
    cleanup_command+=(
      --security-opt apparmor=unconfined
      --mount type=bind,src=/sys/kernel/security,dst=/sys/kernel/security
    )
  fi
  cleanup_command+=(
    --mount "type=bind,src=$workspace,dst=/workspace"
    --entrypoint /bin/sh "$candidate_image" -eu -c '
      for profile in /workspace/.apparmor-cleanup/*; do
        [ -f "$profile" ] || continue
        command -v apparmor_parser >/dev/null
        apparmor_parser --remove "$profile"
      done
      find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    '
  )
  if [ "$container_started" -eq 1 ]; then
    if [ "$backend" = qemu ]; then
      "$timeout_bin" --foreground --signal=TERM --kill-after=5s 20s \
        "$docker_bin" exec "$container_name" /bin/sh -eu -c '
          mkdir -p /workspace/.apparmor-cleanup
          for profile in /etc/apparmor.d/devshot-vmm-qemu-bake-*; do
            [ -f "$profile" ] || continue
            cp "$profile" /workspace/.apparmor-cleanup/
          done
        ' >/dev/null 2>&1 || true
    fi
    "$timeout_bin" --foreground --signal=TERM --kill-after=5s 20s \
      "$docker_bin" rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  # Spec 295 — keep the evidence. This whole cleanup used to run under
  # >/dev/null 2>&1, so a failure surfaced only as "could not prove all
  # temporary resources absent" with no way to learn WHY. The integration tests
  # themselves passed; the job died here, and the reason was discarded.
  cleanup_log="$(mktemp "${TMPDIR:-/tmp}/devshot-vmm-integration-cleanup.XXXXXXXX")"
  if ! "$timeout_bin" --foreground --signal=TERM --kill-after=5s 30s \
    "${cleanup_command[@]}" >>"$cleanup_log" 2>&1; then
    cleanup_failed=1
    "$timeout_bin" --foreground --signal=TERM --kill-after=5s 20s \
      "$docker_bin" rm -f "${container_name}-cleanup" >>"$cleanup_log" 2>&1 || true
  fi
  case "$workspace" in
    "${TMPDIR:-/tmp}"/devshot-vmm-integration.*)
      # A leftover mount inside the workspace (the QEMU/Firecracker backends
      # bind and overlay-mount under it) makes both `rm -rf` and `rmdir` fail
      # with EBUSY. Detaching deepest-first turns that recoverable state into a
      # clean proof instead of a hard job failure; anything that still refuses
      # to unmount is reported below rather than swallowed.
      while IFS= read -r mount_point; do
        [ -n "$mount_point" ] || continue
        umount "$mount_point" >>"$cleanup_log" 2>&1 \
          || umount -l "$mount_point" >>"$cleanup_log" 2>&1 \
          || true
      done <<EOF_MOUNTS
$(awk -v w="$workspace/" 'index($2, w) == 1 { print $2 }' /proc/self/mounts 2>/dev/null | sort -r)
EOF_MOUNTS
      if ! rmdir "$workspace" >>"$cleanup_log" 2>&1; then cleanup_failed=1; fi
      ;;
    *) echo "ERROR: refusing unsafe integration workspace cleanup: $workspace" >&2; cleanup_failed=1 ;;
  esac
  if [ "$cleanup_failed" -ne 0 ]; then
    echo "ERROR: candidate integration cleanup could not prove all temporary resources absent: $workspace" >&2
    echo "--- cleanup output ---" >&2
    tail -n 40 "$cleanup_log" >&2 2>/dev/null || true
    echo "--- workspace contents ---" >&2
    ls -la "$workspace" >&2 2>&1 || true
    awk -v w="$workspace" 'index($2, w) == 1 { print "still mounted: " $2 }' /proc/self/mounts >&2 2>/dev/null || true
    status=1
  fi
  rm -f "$cleanup_log" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

selector="^${test_name}$"
if [ "$test_name" = TestIntegrationEscape ]; then
  test_timeout=15m
  host_timeout=960s
else
  test_timeout=12m
  host_timeout=780s
fi

common_env=(
  -e DEVSHOT_REAL_VMM_INTEGRATION=1
  -e "DEVSHOT_INTEGRATION_BACKEND=$backend"
  -e DEVSHOT_INTEGRATION_WORKSPACE=/workspace
  -e DEVSHOT_QEMU_RUNTIME=/workspace/qemu
  -e DEVSHOT_FC_RUNTIME=/workspace/fc
  -e DEVSHOT_STRICT_ACCEL=1
)
common_mounts=(
  --mount "type=bind,src=$workspace,dst=/workspace"
  --mount "type=bind,src=$test_binary,dst=/integration/devshot-agent-integration.test,readonly"
)

require_exact_test() {
  local output="$1"
  local count
  count="$(printf '%s\n' "$output" | grep -Fxc "$test_name" || true)"
  if [ "$count" -ne 1 ]; then
    echo "ERROR: required candidate integration gate selected $count tests for $test_name" >&2
    exit 5
  fi
}

if [ "$backend" = qemu ]; then
  "$timeout_bin" --foreground --signal=TERM --kill-after=10s 90s \
    "$docker_bin" run -d --name "$container_name" \
      --privileged --device "$kvm_device:/dev/kvm" --device "$tun_device:/dev/net/tun" \
      --cgroupns=host --network=none \
      --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
      --mount type=bind,src=/sys/fs/cgroup,dst=/sys/fs/cgroup \
      --mount type=bind,src=/sys/kernel/security,dst=/sys/kernel/security \
      --mount type=bind,src=/dev/null,dst=/etc/systemd/system/devshot-vmm-qemu.service,readonly \
      --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
      "${common_env[@]}" "${common_mounts[@]}" \
      --entrypoint /sbin/init "$candidate_image" >/dev/null
  container_started=1

  systemd_ready=0
  for _ in $(seq 1 30); do
    state="$($timeout_bin --foreground --signal=TERM --kill-after=5s 10s \
      "$docker_bin" exec "$container_name" systemctl is-system-running 2>/dev/null || true)"
    if [ "$state" = running ] || [ "$state" = degraded ]; then
      if "$timeout_bin" --foreground --signal=TERM --kill-after=5s 15s \
        "$docker_bin" exec "$container_name" systemd-run --quiet --wait --collect --unit=devshot-integration-probe /bin/true; then
        systemd_ready=1
        break
      fi
    fi
    sleep 1
  done
  if [ "$systemd_ready" -ne 1 ]; then
    echo "ERROR: candidate QEMU container has no operational systemd cgroup manager" >&2
    exit 6
  fi

  # The production image enables the orchestrator unit. Keep systemd alive for
  # delegated test scopes, but mask that unit before PID 1 reads its wants and
  # prove no production agent/backend process can race the integration binary.
  if ! "$timeout_bin" --foreground --signal=TERM --kill-after=5s 30s \
    "$docker_bin" exec "$container_name" /bin/bash -euo pipefail -c '
      unit=devshot-vmm-qemu.service
      systemctl stop "$unit"
      enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      [ "$enabled" = masked ] || {
        echo "production unit is not masked: $enabled" >&2
        exit 1
      }
      active="$(systemctl is-active "$unit" 2>/dev/null || true)"
      if [ "$active" != inactive ]; then
        echo "production unit did not reach the exact inactive state: $active" >&2
        exit 1
      fi

      for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid="${proc##*/}"
        [ "$pid" != 1 ] || continue
        exe="$(readlink "$proc/exe" 2>/dev/null || true)"
        executable="${exe##*/}"
        first="$(tr "\000" "\n" < "$proc/cmdline" 2>/dev/null | sed -n "1p" || true)"
        second="$(tr "\000" "\n" < "$proc/cmdline" 2>/dev/null | sed -n "2p" || true)"
        case "$executable" in
          agent|qemu-system-*|firecracker|jailer|qemu-nbd|dnsmasq)
            echo "production/backend process survived mask: pid=$pid exe=$exe" >&2
            exit 1
            ;;
        esac
        if [ "$first" = /opt/devshot/entrypoint.sh ] || [ "$second" = /opt/devshot/entrypoint.sh ]; then
          echo "production entrypoint survived mask: pid=$pid" >&2
          exit 1
        fi
      done

      for runtime_root in /workspace/qemu /workspace/fc; do
        [ ! -e "$runtime_root" ] || [ -d "$runtime_root" ] || {
          echo "candidate runtime root has an invalid type: $runtime_root" >&2
          exit 1
        }
        if [ -d "$runtime_root" ] && [ -n "$(find "$runtime_root" -mindepth 1 -print -quit)" ]; then
          echo "production agent mutated candidate runtime root: $runtime_root" >&2
          exit 1
        fi
      done
      : devshot-vmm-production-quiescence
    '; then
    echo "ERROR: candidate QEMU production agent/backend was not proven quiescent" >&2
    exit 6
  fi

  list_output="$($timeout_bin --foreground --signal=TERM --kill-after=5s 30s \
    "$docker_bin" exec "${common_env[@]}" "$container_name" \
      /integration/devshot-agent-integration.test -test.list "$selector")"
  printf '%s\n' "$list_output"
  require_exact_test "$list_output"
  "$timeout_bin" --foreground --signal=TERM --kill-after=30s "$host_timeout" \
    "$docker_bin" exec "${common_env[@]}" "$container_name" \
      /integration/devshot-agent-integration.test \
      -test.v -test.count=1 -test.timeout="$test_timeout" -test.run "$selector"
else
  container_started=1
  list_output="$($timeout_bin --foreground --signal=TERM --kill-after=5s 30s \
    "$docker_bin" run --rm --name "$container_name" \
      --privileged --device "$kvm_device:/dev/kvm" --device "$tun_device:/dev/net/tun" --network=none \
      "${common_env[@]}" "${common_mounts[@]}" \
      --entrypoint /integration/devshot-agent-integration.test "$candidate_image" \
      -test.list "$selector")"
  container_started=0
  printf '%s\n' "$list_output"
  require_exact_test "$list_output"
  container_started=1
  "$timeout_bin" --foreground --signal=TERM --kill-after=30s "$host_timeout" \
    "$docker_bin" run --rm --name "$container_name" \
      --privileged --device "$kvm_device:/dev/kvm" --device "$tun_device:/dev/net/tun" --network=none \
      "${common_env[@]}" "${common_mounts[@]}" \
      --entrypoint /integration/devshot-agent-integration.test "$candidate_image" \
      -test.v -test.count=1 -test.timeout="$test_timeout" -test.run "$selector"
  container_started=0
fi
