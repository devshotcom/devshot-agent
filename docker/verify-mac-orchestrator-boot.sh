#!/usr/bin/env bash
# Boot the exact macOS/Homebrew orchestrator payload with TCG and prove that
# both QEMU Guest Agent and the DevShot OpenRC service are alive. Static qcow
# checks are intentionally insufficient: this gate exercises the kernel/disk
# pair that will be uploaded to users.
set -euo pipefail

readonly CANDIDATE_IMAGE="${1:-}"
readonly PAYLOAD_INPUT="${2:-}"
readonly BOOT_TIMEOUT_SECONDS="${MAC_BOOT_SMOKE_TIMEOUT_SECONDS:-1800}"
readonly LINUX_AF_UNIX_PATH_MAX_BYTES=108

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

case "$BOOT_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) fail 'MAC_BOOT_SMOKE_TIMEOUT_SECONDS must be an integer from 60 to 1800' ;;
esac
[ "$BOOT_TIMEOUT_SECONDS" -ge 60 ] && [ "$BOOT_TIMEOUT_SECONDS" -le 1800 ] \
  || fail 'MAC_BOOT_SMOKE_TIMEOUT_SECONDS must be an integer from 60 to 1800'

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
[[ "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+:[0-9]+$ ]] \
  || fail 'invalid GitHub Actions run identity'
[[ "$CANDIDATE_IMAGE" =~ ^devshot-arm64-candidate:${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-dom0$ ]] \
  || fail 'candidate image does not belong to this ARM64 Dom0 job'
[ -d "$PAYLOAD_INPUT" ] || fail 'payload directory does not exist'
readonly PAYLOAD_DIR="$(cd "$PAYLOAD_INPUT" && pwd -P)"

for path in \
  "$PAYLOAD_DIR/boot/Image-domu" \
  "$PAYLOAD_DIR/boot/devshot-guest-base.qcow2" \
  "$PAYLOAD_DIR/devshot-agent" \
  "$PAYLOAD_DIR/orchestrator-mac.qcow2"; do
  [ -s "$path" ] || fail "missing boot payload file: $path"
done
for command in docker id python3 timeout; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

RUNNER_UID="$(id -u)"
RUNNER_GID="$(id -g)"
readonly RUNNER_UID RUNNER_GID
[[ "$RUNNER_UID:$RUNNER_GID" =~ ^[0-9]+:[0-9]+$ ]] \
  || fail 'could not resolve the numeric runner uid:gid'

image_arch="$(timeout --foreground --signal=TERM --kill-after=10s 60s \
  docker image inspect --format '{{.Architecture}}' "$CANDIDATE_IMAGE")"
[ "$image_arch" = arm64 ] || fail "boot smoke requires an ARM64 candidate, got $image_arch"

readonly CONTAINER_NAME="devshot-mac-boot-smoke-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
WORK_DIR="$(mktemp -d "${RUNNER_TEMP%/}/devshot-mac-boot-smoke-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.XXXXXX")"
readonly WORK_DIR
if ! QGA_SOCKET_DIR="$(mktemp -d "/tmp/devshot-qga.XXXXXX")"; then
  rm -rf -- "$WORK_DIR"
  fail 'could not create short QGA socket directory'
fi
readonly QGA_SOCKET_DIR
readonly QGA_SOCKET="$QGA_SOCKET_DIR/qga.sock"
readonly CONSOLE_LOG="$WORK_DIR/orch-console.log"

remove_qga_socket_dir() {
  case "$QGA_SOCKET_DIR" in
    /tmp/devshot-qga.??????)
      rm -f -- "$QGA_SOCKET" || {
        echo "ERROR: could not remove QGA socket: $QGA_SOCKET" >&2
        return 1
      }
      rmdir -- "$QGA_SOCKET_DIR" || {
        echo "ERROR: refusing to recursively remove non-empty QGA socket directory: $QGA_SOCKET_DIR" >&2
        return 1
      }
      ;;
    *)
      echo "ERROR: refusing to remove unsafe QGA socket directory: $QGA_SOCKET_DIR" >&2
      return 1
      ;;
  esac
}

cleanup() {
  local status=$?
  local cleanup_failed=false
  trap - EXIT INT TERM HUP
  if [ "$status" -ne 0 ]; then
    echo '--- Mac orchestrator container log ---' >&2
    timeout --foreground --signal=TERM --kill-after=5s 30s \
      docker logs "$CONTAINER_NAME" >&2 2>/dev/null || true
    echo '--- Mac orchestrator serial log ---' >&2
    [ ! -f "$CONSOLE_LOG" ] || tail -n 300 "$CONSOLE_LOG" >&2 || true
  fi
  timeout --foreground --signal=TERM --kill-after=5s 30s \
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf -- "$WORK_DIR" || cleanup_failed=true
  remove_qga_socket_dir || cleanup_failed=true
  [ "$cleanup_failed" = false ] || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Linux sockaddr_un.sun_path has 108 bytes including the trailing NUL. Keep
# the host-visible QGA path independent from the often-long RUNNER_TEMP path;
# the payload and serial logs remain in the run-scoped Actions directory.
qga_socket_bytes="$(LC_ALL=C printf '%s' "$QGA_SOCKET" | wc -c | tr -d '[:space:]')"
case "$qga_socket_bytes" in
  ''|*[!0-9]*) fail 'could not measure QGA socket path length' ;;
esac
[ "$qga_socket_bytes" -lt "$LINUX_AF_UNIX_PATH_MAX_BYTES" ] \
  || fail "QGA AF_UNIX socket path is too long (${qga_socket_bytes} bytes): $QGA_SOCKET"

# Remove only the run-scoped container name. This recovers an interrupted retry
# without touching another workflow's Docker state.
timeout --foreground --signal=TERM --kill-after=5s 30s \
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

install -d -m 0700 "$WORK_DIR/boot" "$WORK_DIR/templates"
cp "$PAYLOAD_DIR/boot/Image-domu" "$WORK_DIR/boot/Image-domu"
cp "$PAYLOAD_DIR/boot/devshot-guest-base.qcow2" \
  "$WORK_DIR/boot/devshot-guest-base.qcow2"
cp "$PAYLOAD_DIR/devshot-agent" "$WORK_DIR/boot/agent"
chmod 0755 "$WORK_DIR/boot/agent"
cat > "$WORK_DIR/boot/agent.env" <<'ENVEOF'
DEVSHOT_SERVER_ID=00000000-0000-4000-8000-000000000048
DEVSHOT_HMAC_SECRET=0000000000000000000000000000000000000000000000000000000000000048
DEVSHOT_TUNNEL_URL=ws://10.0.2.2:9
DEVSHOT_TLS_SKIP=true
LOG_LEVEL=error
READY_TIMEOUT=600000
ENVEOF

# Keep QEMU in the foreground of a detached, exactly named container. The
# candidate supplies the ARM64 QEMU binary, so this also validates the runtime
# image that produced the Homebrew payload. The writable overlay guarantees the
# released base qcow is never modified by the smoke test.
container_id="$(timeout --foreground --signal=TERM --kill-after=30s 120s \
  docker run --detach \
    --name "$CONTAINER_NAME" \
    --user "$RUNNER_UID:$RUNNER_GID" \
    --label devshot.cleanup.scope=mac-boot-smoke \
    --label "devshot.github.repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
    --label "devshot.github.run-id=$GITHUB_RUN_ID" \
    --label "devshot.github.run-attempt=$GITHUB_RUN_ATTEMPT" \
    --entrypoint /bin/bash \
    --volume "$PAYLOAD_DIR:/artifact:ro" \
    --volume "$WORK_DIR:/smoke" \
    --volume "$QGA_SOCKET_DIR:/qga" \
    "$CANDIDATE_IMAGE" \
    -ceu '
      qemu-img create -q -f qcow2 -F qcow2 \
        -b /artifact/orchestrator-mac.qcow2 /smoke/orchestrator-overlay.qcow2
      exec qemu-system-aarch64 \
        -accel tcg,thread=multi \
        -machine virt,gic-version=3 \
        -cpu max \
        -smp 2 \
        -m 2048 \
        -display none \
        -kernel /artifact/boot/Image-domu \
        -append "root=/dev/vda rw console=ttyAMA0" \
        -drive file=/smoke/orchestrator-overlay.qcow2,format=qcow2,if=none,id=hd0 \
        -device virtio-blk-device,drive=hd0 \
        -netdev user,id=net0 \
        -device virtio-net-device,netdev=net0 \
        -fsdev local,id=boot_fs,path=/smoke/boot,security_model=none \
        -device virtio-9p-device,fsdev=boot_fs,mount_tag=devshot_boot \
        -fsdev local,id=tmpl_fs,path=/smoke/templates,security_model=none \
        -device virtio-9p-device,fsdev=tmpl_fs,mount_tag=devshot_templates \
        -serial file:/smoke/orch-console.log \
        -device virtio-serial-device \
        -chardev socket,id=qga0,path=/qga/qga.sock,server=on,wait=off \
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
    ')"
[[ "$container_id" =~ ^[0-9a-f]{64}$ ]] || fail 'Docker returned an invalid boot-smoke container ID'

# The protocol client performs the required guest-sync-delimited handshake,
# waits boundedly for QGA, then runs an in-guest assertion. Passing means the
# real disk booted, OpenRC reached the default runlevel, qemu-ga responds, and
# the production agent binary is executable and running.
timeout --foreground --signal=TERM --kill-after=30s "${BOOT_TIMEOUT_SECONDS}s" \
  python3 - "$QGA_SOCKET" "$CONTAINER_NAME" <<'PY'
import base64
import json
import os
import socket
import subprocess
import sys
import time

sock_path, container_name = sys.argv[1:]
total_window = max(1, int(os.environ.get("MAC_BOOT_SMOKE_TIMEOUT_SECONDS", "1800")) - 5)
deadline = time.monotonic() + total_window
# QGA may become reachable only near the end of a nested-TCG boot. Reserve a
# bounded slice of the total timeout for OpenRC and the agent to settle after
# the protocol handshake instead of racing a one-shot service assertion.
readiness_reserve = min(120, max(2, total_window // 5))
qga_deadline = deadline - readiness_reserve
last_error = "QGA socket has not appeared"

def recv_until(stream, delimiter):
    data = bytearray()
    while not data.endswith(delimiter):
        chunk = stream.recv(1)
        if not chunk:
            raise RuntimeError("QGA closed the socket")
        data.extend(chunk)
        if len(data) > 16 * 1024 * 1024:
            raise RuntimeError("QGA response exceeded 16 MiB")
    return bytes(data)

def roundtrip(stream, command):
    stream.sendall(json.dumps(command, separators=(",", ":")).encode() + b"\n")
    response = json.loads(recv_until(stream, b"\n"))
    if "error" in response:
        raise RuntimeError(f"QGA error: {response['error']}")
    return response.get("return")

def connect_qga(timeout_seconds):
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stream.settimeout(max(0.1, min(10, timeout_seconds)))
    stream.connect(sock_path)
    sync_id = int(time.time_ns() & 0x7FFFFFFFFFFFFFFF)
    request = json.dumps({"execute": "guest-sync-delimited", "arguments": {"id": sync_id}}, separators=(",", ":")).encode()
    stream.sendall(b"\xff" + request + b"\n")
    recv_until(stream, b"\xff")
    response = json.loads(recv_until(stream, b"\n"))
    if response.get("return") != sync_id:
        stream.close()
        raise RuntimeError(f"QGA sync mismatch: {response!r}")
    return stream

stream = None
while time.monotonic() < qga_deadline:
    remaining = qga_deadline - time.monotonic()
    state = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}", container_name],
        capture_output=True,
        text=True,
        timeout=max(0.1, min(15, remaining)),
    )
    if state.returncode != 0 or state.stdout.strip() != "true":
        raise SystemExit("QEMU boot-smoke container exited before QGA became ready")
    try:
        stream = connect_qga(max(0.1, qga_deadline - time.monotonic()))
        roundtrip(stream, {"execute": "guest-ping"})
        stream.settimeout(max(0.1, min(10, deadline - time.monotonic())))
        break
    except (OSError, ValueError, RuntimeError) as exc:
        last_error = str(exc)
        if stream is not None:
            stream.close()
            stream = None
        remaining = qga_deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(2, remaining))
else:
    raise SystemExit(
        f"QGA did not become ready before its bounded boot deadline: {last_error}"
    )

def decode_exec_result(result):
    if not isinstance(result, dict):
        raise RuntimeError(f"QGA guest-exec-status returned an invalid result: {result!r}")
    stdout = base64.b64decode(result.get("out-data", "")).decode(errors="replace")
    stderr = base64.b64decode(result.get("err-data", "")).decode(errors="replace")
    return result.get("exitcode"), stdout, stderr

def run_guest_command(command):
    started = roundtrip(stream, {
        "execute": "guest-exec",
        "arguments": {
            "path": "/bin/sh",
            "arg": ["-c", command],
            "capture-output": True,
        },
    })
    pid = started.get("pid") if isinstance(started, dict) else None
    if not isinstance(pid, int):
        raise RuntimeError(f"QGA guest-exec returned no PID: {started!r}")

    command_deadline = min(deadline, time.monotonic() + 30)
    while time.monotonic() < command_deadline:
        result = roundtrip(stream, {"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if not isinstance(result, dict):
            raise RuntimeError(
                f"QGA guest-exec-status returned an invalid result for PID {pid}: {result!r}"
            )
        if result.get("exited"):
            return result
        remaining = command_deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(1, remaining))
    raise RuntimeError(f"QGA guest-exec PID {pid} did not finish within 30 seconds")

static_command = (
    "set -eu; "
    "[ \"$(uname -m)\" = aarch64 ]; "
    "test -x /opt/devshot/agent; "
    "printf 'MAC_BOOT_STATIC_OK\\n'"
)
try:
    static_result = run_guest_command(static_command)
except (OSError, ValueError, RuntimeError) as exc:
    stream.close()
    raise SystemExit(f"in-guest static assertion could not complete: {exc}")
static_exit, static_stdout, static_stderr = decode_exec_result(static_result)
if static_exit != 0 or static_stdout.strip() != "MAC_BOOT_STATIC_OK":
    stream.close()
    raise SystemExit(
        "in-guest static assertion failed: "
        f"exit={static_exit} stdout={static_stdout!r} stderr={static_stderr!r}"
    )

readiness_command = (
    "set -u; "
    "qga_status=0; rc-service qemu-guest-agent status >/dev/null 2>&1 || qga_status=$?; "
    "if [ \"$qga_status\" -ne 0 ]; then "
    "rc-service qemu-guest-agent status >&2 || true; "
    "[ \"$qga_status\" -eq 8 ] && exit 75; exit \"$qga_status\"; fi; "
    "orchestrator_status=0; rc-service devshot-orchestrator status >/dev/null 2>&1 || orchestrator_status=$?; "
    "if [ \"$orchestrator_status\" -ne 0 ]; then "
    "rc-service devshot-orchestrator status >&2 || true; "
    "[ \"$orchestrator_status\" -eq 8 ] && exit 75; exit \"$orchestrator_status\"; fi; "
    "pgrep -f '^/opt/devshot/agent($| )' >/dev/null || "
    "{ printf 'DevShot agent process is not visible yet\\n' >&2; exit 76; }; "
    "printf 'MAC_BOOT_READY_OK\\n'"
)
last_readiness = "readiness probe has not completed"
while time.monotonic() < deadline:
    try:
        result = run_guest_command(readiness_command)
    except (OSError, ValueError, RuntimeError) as exc:
        stream.close()
        raise SystemExit(f"in-guest readiness probe could not complete: {exc}")
    exitcode, stdout, stderr = decode_exec_result(result)
    if exitcode == 0 and stdout.strip() == "MAC_BOOT_READY_OK":
        print("Verified real ARM64 Mac orchestrator boot: QGA and DevShot agent are running")
        stream.close()
        raise SystemExit(0)
    if exitcode not in (75, 76):
        stream.close()
        raise SystemExit(
            "in-guest readiness assertion failed permanently: "
            f"exit={exitcode} stdout={stdout!r} stderr={stderr!r}"
        )
    last_readiness = f"exit={exitcode} stdout={stdout!r} stderr={stderr!r}"
    remaining = deadline - time.monotonic()
    if remaining > 0:
        time.sleep(min(2, remaining))

stream.close()
raise SystemExit(
    f"in-guest services did not become ready before the bounded deadline: {last_readiness}"
)
PY

# Re-check that the VM remained alive through the complete in-guest probe.
[ "$(timeout --foreground --signal=TERM --kill-after=5s 30s \
  docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" = true ] \
  || fail 'QEMU boot-smoke container stopped after the QGA assertion'
echo 'Mac orchestrator kernel/qcow payload passed the real boot smoke'
