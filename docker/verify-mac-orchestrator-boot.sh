#!/usr/bin/env bash
# Boot the exact macOS/Homebrew orchestrator payload with TCG and prove that
# both QEMU Guest Agent and the DevShot OpenRC service are alive. Static qcow
# checks are intentionally insufficient: this gate exercises the kernel/disk
# pair that will be uploaded to users.
set -euo pipefail

readonly CANDIDATE_IMAGE="${1:-}"
readonly PAYLOAD_INPUT="${2:-}"
readonly BOOT_TIMEOUT_SECONDS="${MAC_BOOT_SMOKE_TIMEOUT_SECONDS:-1200}"

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
for command in docker python3 timeout; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

image_arch="$(timeout --foreground --signal=TERM --kill-after=10s 60s \
  docker image inspect --format '{{.Architecture}}' "$CANDIDATE_IMAGE")"
[ "$image_arch" = arm64 ] || fail "boot smoke requires an ARM64 candidate, got $image_arch"

readonly CONTAINER_NAME="devshot-mac-boot-smoke-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
WORK_DIR="$(mktemp -d "${RUNNER_TEMP%/}/devshot-mac-boot-smoke-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.XXXXXX")"
readonly WORK_DIR
readonly QGA_SOCKET="$WORK_DIR/orch-qga.sock"
readonly CONSOLE_LOG="$WORK_DIR/orch-console.log"

cleanup() {
  local status=$?
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
  rm -rf -- "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

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
    --label devshot.cleanup.scope=mac-boot-smoke \
    --label "devshot.github.repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
    --label "devshot.github.run-id=$GITHUB_RUN_ID" \
    --label "devshot.github.run-attempt=$GITHUB_RUN_ATTEMPT" \
    --entrypoint /bin/bash \
    --volume "$PAYLOAD_DIR:/artifact:ro" \
    --volume "$WORK_DIR:/smoke" \
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
        -chardev socket,id=qga0,path=/smoke/orch-qga.sock,server=on,wait=off \
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
deadline = time.monotonic() + max(1, int(os.environ.get("MAC_BOOT_SMOKE_TIMEOUT_SECONDS", "1200")) - 5)
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

def connect_qga():
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stream.settimeout(10)
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
while time.monotonic() < deadline:
    state = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}", container_name],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if state.returncode != 0 or state.stdout.strip() != "true":
        raise SystemExit("QEMU boot-smoke container exited before QGA became ready")
    try:
        stream = connect_qga()
        roundtrip(stream, {"execute": "guest-ping"})
        break
    except (OSError, ValueError, RuntimeError) as exc:
        last_error = str(exc)
        if stream is not None:
            stream.close()
            stream = None
        time.sleep(2)
else:
    raise SystemExit(f"QGA did not become ready before the deadline: {last_error}")

command = (
    "set -eu; "
    "[ \"$(uname -m)\" = aarch64 ]; "
    "test -x /opt/devshot/agent; "
    "rc-service qemu-guest-agent status >/dev/null; "
    "rc-service devshot-orchestrator status >/dev/null; "
    "pgrep -f '^/opt/devshot/agent($| )' >/dev/null; "
    "printf 'MAC_BOOT_SMOKE_OK\\n'"
)
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
    raise SystemExit(f"QGA guest-exec returned no PID: {started!r}")

while time.monotonic() < deadline:
    result = roundtrip(stream, {"execute": "guest-exec-status", "arguments": {"pid": pid}})
    if result.get("exited"):
        stdout = base64.b64decode(result.get("out-data", "")).decode(errors="replace")
        stderr = base64.b64decode(result.get("err-data", "")).decode(errors="replace")
        if result.get("exitcode") != 0 or stdout.strip() != "MAC_BOOT_SMOKE_OK":
            raise SystemExit(f"in-guest boot assertion failed: exit={result.get('exitcode')} stdout={stdout!r} stderr={stderr!r}")
        print("Verified real ARM64 Mac orchestrator boot: QGA and DevShot agent are running")
        stream.close()
        raise SystemExit(0)
    time.sleep(1)
raise SystemExit("QGA guest-exec did not finish before the deadline")
PY

# Re-check that the VM remained alive through the complete in-guest probe.
[ "$(timeout --foreground --signal=TERM --kill-after=5s 30s \
  docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" = true ] \
  || fail 'QEMU boot-smoke container stopped after the QGA assertion'
echo 'Mac orchestrator kernel/qcow payload passed the real boot smoke'
