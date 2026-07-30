#!/usr/bin/env bash
# Exercise the exact mount/chroot/validation/cleanup sequence used by Studio
# template bakes. This runs before the public mirror is updated, so a guest
# runtime that leaks a process through /dev cannot consume a downstream runner
# or publish a partial template generation.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 <image> [linux/amd64|linux/arm64] [validator-path]" >&2
    exit 2
fi

IMAGE="$1"
PLATFORM="${2:-}"
case "$PLATFORM" in
    ""|linux/amd64|linux/arm64) ;;
    *)
        echo "ERROR: unsupported platform: $PLATFORM" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR_PATH="${3:-apps/agent/roles/dom0/files/verify-studio-runtime-prerequisites.sh}"
case "$VALIDATOR_PATH" in
    /*|../*|*/../*|*/..)
        echo "ERROR: validator path must stay inside the repository: $VALIDATOR_PATH" >&2
        exit 2
        ;;
esac
VALIDATOR="$REPO_ROOT/$VALIDATOR_PATH"

[ -x "$VALIDATOR" ] || { echo "ERROR: missing executable validator: $VALIDATOR" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "ERROR: GNU timeout is required" >&2; exit 1; }
timeout --version 2>&1 | head -n 1 | grep -q '^timeout (GNU coreutils) ' \
    || { echo "ERROR: GNU timeout is required" >&2; exit 1; }

if [ -n "${GITHUB_RUN_ID:-}" ] || [ -n "${GITHUB_RUN_ATTEMPT:-}" ]; then
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] && [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] \
        || { echo "ERROR: invalid GitHub Actions run identity" >&2; exit 2; }
    [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || { echo "ERROR: invalid GitHub Actions repository identity" >&2; exit 2; }
    container_name="devshot-runtime-verify-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
    state_prefix="devshot-runtime-verify-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
    runtime_labels=(
        --label devshot.cleanup.scope=runtime-validator
        --label "devshot.github.repository=${GITHUB_REPOSITORY}"
        --label "devshot.github.run-id=${GITHUB_RUN_ID}"
        --label "devshot.github.run-attempt=${GITHUB_RUN_ATTEMPT}"
    )
else
    container_name="devshot-runtime-verify-local-$$"
    state_prefix="devshot-runtime-verify-local-$$"
    runtime_labels=()
fi

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
temp_root="${temp_root%/}"
case "$temp_root" in
    /*) ;;
    *) echo "ERROR: temporary root must be an absolute non-root path" >&2; exit 2 ;;
esac
[ "$temp_root" != "/" ] && [ -d "$temp_root" ] && [ -w "$temp_root" ] \
    || { echo "ERROR: temporary root must be a writable absolute non-root directory" >&2; exit 2; }

state_dir="$(mktemp -d "$temp_root/$state_prefix.XXXXXX")"
cidfile="$state_dir/container.cid"

cleanup() {
    status=$?
    trap - EXIT INT TERM
    cleanup_status=0
    container_ref="$container_name"
    remove_output=""
    remove_status=0

    if [ -s "$cidfile" ]; then
        IFS= read -r cid < "$cidfile" || true
        if [[ "${cid:-}" =~ ^[0-9a-f]{64}$ ]]; then
            container_ref="$cid"
        else
            echo "ERROR: validator produced an invalid Docker CID" >&2
            cleanup_status=1
        fi
    fi

    remove_output="$(
        timeout --foreground --signal=TERM --kill-after=10s 60s \
            docker rm -f "$container_ref" 2>&1
    )" || remove_status=$?
    if [ "$remove_status" -ne 0 ]; then
        case "$remove_output" in
            *"No such container: $container_ref"*) ;;
            *)
                [ -z "$remove_output" ] || printf '%s\n' "$remove_output" >&2
                echo "ERROR: failed to remove Studio runtime validator container: $container_ref" >&2
                cleanup_status=1
                ;;
        esac
    fi
    if ! rm -rf -- "$state_dir"; then
        echo "ERROR: failed to remove Studio runtime validator state: $state_dir" >&2
        cleanup_status=1
    fi

    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

timeout --foreground --signal=TERM --kill-after=10s 60s \
    docker image inspect "$IMAGE" >/dev/null

docker_args=(
    run --name "$container_name" --cidfile "$cidfile" --rm --privileged --network none
    "${runtime_labels[@]}"
    --entrypoint /bin/sh
    --volume "$VALIDATOR:/verify-studio-runtime-prerequisites.sh:ro"
)
if [ -n "$PLATFORM" ]; then
    docker_args+=(--platform "$PLATFORM")
fi

timeout --foreground --signal=TERM --kill-after=30s 900s \
docker "${docker_args[@]}" "$IMAGE" -ceu '
mkdir -p /mnt /mnt/proc /mnt/dev /mnt/sys /mnt/tmp
mount --bind / /mnt
mount -t proc proc /mnt/proc
mount --bind /dev /mnt/dev
mkdir -p /mnt/dev/pts
mount --bind /dev/pts /mnt/dev/pts
mount --bind /sys /mnt/sys
cp /verify-studio-runtime-prerequisites.sh /mnt/tmp/verify-studio-runtime-prerequisites.sh
chroot /mnt /bin/sh /tmp/verify-studio-runtime-prerequisites.sh

for comm in /proc/[0-9]*/comm; do
    [ "$(cat "$comm" 2>/dev/null)" != timeout ] || {
        echo "ERROR: validator left an orphan timeout process: $comm" >&2
        exit 1
    }
done

# Keep this identical to the template builders: child mount first, then the
# other pseudo-filesystems. The command must succeed immediately without a
# sleep, retry, ignored error, or lazy unmount.
umount /mnt/dev/pts /mnt/proc /mnt/dev /mnt/sys
for target in /mnt/dev/pts /mnt/proc /mnt/dev /mnt/sys; do
    mountpoint -q "$target" && {
        echo "ERROR: Studio runtime mount survived cleanup: $target" >&2
        exit 1
    }
done
umount /mnt
mountpoint -q /mnt && {
    echo "ERROR: Studio runtime root mount survived cleanup" >&2
    exit 1
}
echo "Studio runtime image mount lifecycle verified"
'
