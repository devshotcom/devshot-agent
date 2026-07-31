#!/usr/bin/env bash
# Fail-closed lifecycle helpers for the persistent self-hosted image builder.
# Every cleanup target is scoped to the current Actions run. Never add a
# system-wide Docker prune or delete host toolchains from this script.
set -euo pipefail

readonly STORAGE_PROBE_IMAGE='alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40'
readonly STALE_RESOURCE_MIN_AGE_SECONDS=28800

usage() {
  echo "usage: $0 initialize <dom0|kvm|runtime> | prepare <minimum-gib> | verify-memory <minimum-gib> [meminfo-path] | verify-docker-storage <minimum-gib> | cleanup [exact-image ...]" >&2
  exit 64
}

verify_memory() {
  local minimum_gib="${1:-}" meminfo_path="${2:-/proc/meminfo}" required_kib available_kib
  required_kib="$(minimum_kib "$minimum_gib")"
  case "$meminfo_path" in
    /*) ;;
    *)
      echo "ERROR: meminfo path must be absolute" >&2
      exit 64
      ;;
  esac
  [ "$meminfo_path" != "/" ] && [ -r "$meminfo_path" ] || {
    echo "ERROR: meminfo path must be a readable absolute file" >&2
    exit 64
  }
  available_kib="$(
    awk '
      $1 == "MemAvailable:" || $1 == "SwapFree:" { total += $2 }
      END { if (total > 0) print total }
    ' "$meminfo_path"
  )"
  assert_available_kib 'memory plus swap' "$available_kib" "$required_kib"
}

require_numeric_run_identity() {
  : "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
  : "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

  case "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" in
    *[!0-9:]*)
      echo "ERROR: invalid GitHub Actions run identity" >&2
      exit 64
      ;;
  esac
}

initialize() {
  local state_suffix="${1:-}" runner_temp docker_config
  require_numeric_run_identity
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${GITHUB_ENV:?GITHUB_ENV is required}"

  case "$state_suffix" in
    dom0|kvm|runtime) ;;
    *)
      echo "ERROR: invalid self-hosted state suffix: $state_suffix" >&2
      exit 64
      ;;
  esac

  runner_temp="${RUNNER_TEMP%/}"
  case "$runner_temp" in
    /*) ;;
    *)
      echo "ERROR: RUNNER_TEMP must be an absolute non-root path" >&2
      exit 64
      ;;
  esac
  if [ "$runner_temp" = "/" ]; then
    echo "ERROR: RUNNER_TEMP must be an absolute non-root path" >&2
    exit 64
  fi
  case "$GITHUB_ENV" in
    "$runner_temp"/*) ;;
    *)
      echo "ERROR: refusing GITHUB_ENV outside RUNNER_TEMP" >&2
      exit 64
      ;;
  esac

  docker_config="$runner_temp/devshot-docker-config-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$state_suffix"
  printf 'DOCKER_CONFIG=%s\n' "$docker_config" >> "$GITHUB_ENV"
}

require_run_identity() {
  local runner_temp
  require_numeric_run_identity
  : "${GITHUB_JOB:?GITHUB_JOB is required}"
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${DOCKER_CONFIG:?DOCKER_CONFIG is required}"
  : "${BUILDER_NAME:?BUILDER_NAME is required}"

  runner_temp="${RUNNER_TEMP%/}"
  case "$runner_temp" in
    /*) ;;
    *)
      echo "ERROR: RUNNER_TEMP must be an absolute non-root path" >&2
      exit 64
      ;;
  esac
  [ "$runner_temp" != "/" ] || {
    echo "ERROR: RUNNER_TEMP must be an absolute non-root path" >&2
    exit 64
  }

  case "$DOCKER_CONFIG" in
    "$runner_temp"/devshot-docker-config-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-dom0|\
    "$runner_temp"/devshot-docker-config-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-kvm|\
    "$runner_temp"/devshot-docker-config-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-runtime) ;;
    *)
      echo "ERROR: refusing unsafe DOCKER_CONFIG path: $DOCKER_CONFIG" >&2
      exit 64
      ;;
  esac

  case "$BUILDER_NAME" in
    devshot-build-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-dom0|\
    devshot-build-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-kvm|\
    devshot-build-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-runtime) ;;
    *)
      echo "ERROR: refusing unsafe Buildx builder name: $BUILDER_NAME" >&2
      exit 64
      ;;
  esac
}

minimum_kib() {
  local minimum_gib="${1:-}"
  case "$minimum_gib" in
    ''|*[!0-9]*)
      echo "ERROR: minimum GiB must be an integer" >&2
      exit 64
      ;;
  esac
  if [ "$minimum_gib" -lt 1 ] || [ "$minimum_gib" -gt 1024 ]; then
    echo "ERROR: minimum GiB must be between 1 and 1024" >&2
    exit 64
  fi
  echo $((minimum_gib * 1024 * 1024))
}

assert_available_kib() {
  local label="$1"
  local available_kib="$2"
  local required_kib="$3"
  case "$available_kib" in
    ''|*[!0-9]*)
      echo "ERROR: could not resolve available space for $label" >&2
      exit 1
      ;;
  esac
  echo "$label available: $((available_kib / 1024 / 1024)) GiB"
  if [ "$available_kib" -lt "$required_kib" ]; then
    echo "ERROR: $label requires at least $((required_kib / 1024 / 1024)) GiB free" >&2
    exit 1
  fi
}

probe_name() {
  printf 'devshot-storage-probe-%s-%s-%s' \
    "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$GITHUB_JOB" \
    | tr -c '[:alnum:]_.-' '-'
}

bounded_docker() {
  local seconds="$1"
  shift
  timeout --foreground --signal=TERM --kill-after=15s "${seconds}s" \
    env -u GITHUB_API_TOKEN docker "$@"
}

remove_exact_buildx_volume() {
  local volume="$1" observation volumes operation_failed=0
  [[ "$volume" =~ ^buildx_buildkit_devshot-build-[0-9]+-[0-9]+-(dom0|kvm|runtime)[0-9]+_state$ ]] || {
    echo "ERROR: refusing unsafe Buildx volume cleanup target: $volume" >&2
    return 64
  }

  # Docker can continue deleting a large local volume in the daemon after the
  # bounded CLI request times out. Treat the exact postcondition as
  # authoritative and allow a bounded propagation window before failing.
  if ! bounded_docker 300 volume rm -f "$volume" >/dev/null; then
    operation_failed=1
  fi
  for observation in {1..12}; do
    if ! volumes="$(bounded_docker 60 volume ls --format '{{.Name}}')"; then
      if [ "$observation" -eq 12 ]; then
        return 1
      fi
    elif ! grep -Fxq -- "$volume" <<< "$volumes"; then
      if [ "$operation_failed" -ne 0 ]; then
        echo "Verified exact Buildx volume absent after a transient cleanup error: $volume"
      fi
      return 0
    fi
    if [ "$observation" -lt 12 ]; then
      sleep 5
    fi
  done
  return 1
}

remove_buildx_builder() {
  local builder="$1" attempt builders containers container volumes volume operation_failed verification_failed
  [[ "$builder" =~ ^devshot-build-[0-9]+-[0-9]+-(dom0|kvm|runtime)$ ]] || {
    echo "ERROR: refusing unsafe Buildx builder cleanup target: $builder" >&2
    return 64
  }

  for attempt in 1 2; do
    operation_failed=0
    if ! bounded_docker 120 buildx rm --force "$builder" >/dev/null; then
      operation_failed=1
    fi

    # buildx can remove its metadata and driver container, then time out while
    # deleting the state volume. Clean only resources whose exact generated
    # names belong to this run-scoped builder and verify every postcondition.
    if ! containers="$(bounded_docker 60 ps -a --format '{{.Names}}')"; then
      operation_failed=1
      containers=""
    fi
    while IFS= read -r container; do
      [[ "$container" =~ ^buildx_buildkit_${builder}[0-9]+$ ]] || continue
      bounded_docker 120 rm -f "$container" >/dev/null || operation_failed=1
    done <<< "$containers"

    if ! volumes="$(bounded_docker 60 volume ls --format '{{.Name}}')"; then
      operation_failed=1
      volumes=""
    fi
    while IFS= read -r volume; do
      [[ "$volume" =~ ^buildx_buildkit_${builder}[0-9]+_state$ ]] || continue
      remove_exact_buildx_volume "$volume" || operation_failed=1
    done <<< "$volumes"

    verification_failed=0
    if ! builders="$(bounded_docker 60 buildx ls --format '{{.Name}}')" \
      || grep -Fxq -- "$builder" <<< "$builders"; then
      verification_failed=1
    fi
    if ! containers="$(bounded_docker 60 ps -a --format '{{.Names}}')" \
      || grep -Eq -- "^buildx_buildkit_${builder}[0-9]+$" <<< "$containers"; then
      verification_failed=1
    fi
    if ! volumes="$(bounded_docker 60 volume ls --format '{{.Name}}')" \
      || grep -Eq -- "^buildx_buildkit_${builder}[0-9]+_state$" <<< "$volumes"; then
      verification_failed=1
    fi
    if [ "$verification_failed" -eq 0 ]; then
      if [ "$operation_failed" -ne 0 ]; then
        echo "Verified exact Buildx resources absent after a transient cleanup error: $builder"
      fi
      return 0
    fi
    if [ "$attempt" -lt 2 ]; then
      echo "WARNING: retrying verified removal of exact Buildx builder resources: $builder" >&2
      sleep 5
    fi
  done
  return 1
}

path_age_seconds() {
  python3 -c 'import os,sys,time; print(max(0, int(time.time() - os.stat(sys.argv[1]).st_mtime)))' "$1"
}

created_age_seconds() {
  python3 -c 'import datetime,sys,time; created=datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")); print(max(0, int(time.time() - created.timestamp())))' "$1"
}

owner_run_is_completed() {
  local run_id="$1" response
  local -a curl_args=(
    --fail --silent --show-error
    --connect-timeout 10 --max-time 30
    --retry 2 --retry-all-errors
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
  )

  if [ -n "${GITHUB_API_TOKEN:-}" ]; then
    if ! response="$(
      env -u GITHUB_API_TOKEN curl "${curl_args[@]}" --config - \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runs/$run_id" \
        <<< "header = \"Authorization: Bearer $GITHUB_API_TOKEN\""
    )"; then
      echo "WARNING: could not prove liveness for GitHub Actions run $run_id; leaving its resources untouched" >&2
      return 2
    fi
  elif ! response="$(
    curl "${curl_args[@]}" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runs/$run_id"
  )"; then
    echo "WARNING: could not prove liveness for GitHub Actions run $run_id; leaving its resources untouched" >&2
    return 2
  fi

  GITHUB_REPOSITORY="$GITHUB_REPOSITORY" RUN_ID="$run_id" python3 -c '
import json, os, sys
try:
    run = json.load(sys.stdin)
    valid_owner = str(run.get("id", "")) == os.environ["RUN_ID"] and (run.get("repository") or {}).get("full_name") == os.environ["GITHUB_REPOSITORY"]
    if not valid_owner:
        raise SystemExit(2)
    raise SystemExit(0 if run.get("status") == "completed" else 1)
except (KeyError, TypeError, ValueError):
    raise SystemExit(2)
' <<< "$response"
}

old_enough() {
  local age="$1"
  [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -ge "$STALE_RESOURCE_MIN_AGE_SECONDS" ]
}

reap_stale_buildx_resources() {
  local runner_temp config basename run_id attempt suffix age owner_status state_dir
  local builders builder containers container volumes volume metadata owner images image failed=0 config_failed
  local resource_kind expected_scope labels label_status
  runner_temp="${RUNNER_TEMP%/}"

  # Builder metadata lives inside each run-scoped DOCKER_CONFIG. Only open and
  # delete an old directory after both an eight-hour age floor and the GitHub API
  # prove that its owning run is completed. This avoids touching a concurrent
  # build even when two jobs share the same Docker daemon.
  for config in "$runner_temp"/devshot-docker-config-*; do
    [ -d "$config" ] || continue
    basename="${config##*/}"
    if ! [[ "$basename" =~ ^devshot-docker-config-([0-9]+)-([0-9]+)-(dom0|kvm|runtime)$ ]]; then
      continue
    fi
    run_id="${BASH_REMATCH[1]}"
    attempt="${BASH_REMATCH[2]}"
    suffix="${BASH_REMATCH[3]}"
    if ! age="$(path_age_seconds "$config")" || ! old_enough "$age"; then
      continue
    fi
    if owner_run_is_completed "$run_id"; then
      owner_status=0
    else
      owner_status=$?
    fi
    [ "$owner_status" -eq 0 ] || continue

    config_failed=0
    if ! builders="$(DOCKER_CONFIG="$config" bounded_docker 60 buildx ls --format '{{.Name}}')"; then
      echo "ERROR: could not inspect stale Buildx state: $config" >&2
      failed=1
      continue
    fi
    while IFS= read -r builder; do
      [ -n "$builder" ] || continue
      if [ "$builder" = "devshot-build-$run_id-$attempt-$suffix" ]; then
        echo "Removing completed stale Buildx builder: $builder (${age}s old)"
        if ! DOCKER_CONFIG="$config" remove_buildx_builder "$builder"; then
          echo "ERROR: failed to remove completed stale Buildx builder: $builder" >&2
          failed=1
          config_failed=1
        fi
      fi
    done <<< "$builders"
    if [ "$config_failed" -eq 0 ]; then
      if ! rm -rf -- "$config"; then
        echo "ERROR: failed to remove completed stale Docker configuration: $config" >&2
        failed=1
      fi
    fi
  done

  # A hard-killed rolling-tag promotion or runtime validator can leave small
  # run-scoped state directories behind. Delete only exact, old paths whose
  # owning Actions run is proven complete.
  for state_dir in \
    "$runner_temp"/devshot-promotion-auth-* \
    "$runner_temp"/devshot-amd64-promotion-auth-* \
    "$runner_temp"/devshot-family-recovery-* \
    "$runner_temp"/devshot-mac-boot-smoke-* \
    "$runner_temp"/devshot-runtime-verify-*; do
    [ -d "$state_dir" ] || continue
    basename="${state_dir##*/}"
    if [[ "$basename" =~ ^devshot-promotion-auth-([0-9]+)-([0-9]+)$ ]] \
      || [[ "$basename" =~ ^devshot-amd64-promotion-auth-([0-9]+)-([0-9]+)$ ]] \
      || [[ "$basename" =~ ^devshot-mac-boot-smoke-([0-9]+)-([0-9]+)\.[A-Za-z0-9]+$ ]] \
      || [[ "$basename" =~ ^devshot-runtime-verify-([0-9]+)-([0-9]+)\.[A-Za-z0-9]+$ ]]; then
      run_id="${BASH_REMATCH[1]}"
    elif [[ "$basename" =~ ^devshot-family-recovery-(amd64|arm64)-([0-9]+)-([0-9]+)\.[A-Za-z0-9]+$ ]]; then
      run_id="${BASH_REMATCH[2]}"
    else
      continue
    fi
    if ! age="$(path_age_seconds "$state_dir")" || ! old_enough "$age"; then
      continue
    fi
    if owner_run_is_completed "$run_id"; then
      owner_status=0
    else
      owner_status=$?
    fi
    [ "$owner_status" -eq 0 ] || continue
    echo "Removing completed stale run state: $basename (${age}s old)"
    if ! rm -rf -- "$state_dir"; then
      echo "ERROR: failed to remove completed stale run state: $state_dir" >&2
      failed=1
    fi
  done

  # A killed buildx client can lose its metadata while leaving the driver
  # container behind. Apply the same age + completed-owner proof before exact
  # name cleanup; unknown, young, or active owners are always skipped.
  if ! containers="$(bounded_docker 60 ps -a --format '{{.Names}}')"; then
    echo "ERROR: could not list Docker containers for scoped stale cleanup" >&2
    return 1
  fi
  while IFS= read -r container; do
    [ -n "$container" ] || continue
    if [[ "$container" =~ ^buildx_buildkit_(devshot-build-([0-9]+)-([0-9]+)-(dom0|kvm|runtime))[0-9]+$ ]]; then
      owner="${BASH_REMATCH[1]}"
      run_id="${BASH_REMATCH[2]}"
      attempt="${BASH_REMATCH[3]}"
      resource_kind=buildx
    elif [[ "$container" =~ ^devshot-runtime-verify-([0-9]+)-([0-9]+)$ ]]; then
      owner="$container"
      run_id="${BASH_REMATCH[1]}"
      attempt="${BASH_REMATCH[2]}"
      resource_kind=runtime-validator
      expected_scope=runtime-validator
    elif [[ "$container" =~ ^devshot-mac-boot-smoke-([0-9]+)-([0-9]+)$ ]]; then
      owner="$container"
      run_id="${BASH_REMATCH[1]}"
      attempt="${BASH_REMATCH[2]}"
      resource_kind=mac-boot-smoke
      expected_scope=mac-boot-smoke
    else
      continue
    fi
    if ! metadata="$(bounded_docker 60 inspect --format '{{.Created}}' "$container")" \
      || ! age="$(created_age_seconds "$metadata")" || ! old_enough "$age"; then
      continue
    fi
    if owner_run_is_completed "$run_id"; then
      owner_status=0
    else
      owner_status=$?
    fi
    [ "$owner_status" -eq 0 ] || continue

    if [ "$resource_kind" != buildx ]; then
      if ! labels="$(bounded_docker 60 inspect --format '{{json .Config.Labels}}' "$container")"; then
        echo "WARNING: could not inspect cleanup labels for $container; leaving it untouched" >&2
        continue
      fi
      if GITHUB_REPOSITORY="$GITHUB_REPOSITORY" RUN_ID="$run_id" RUN_ATTEMPT="$attempt" \
        EXPECTED_SCOPE="$expected_scope" \
        python3 -c '
import json, os, sys
try:
    labels = json.load(sys.stdin) or {}
    valid = (
        labels.get("devshot.cleanup.scope") == os.environ["EXPECTED_SCOPE"]
        and labels.get("devshot.github.repository") == os.environ["GITHUB_REPOSITORY"]
        and labels.get("devshot.github.run-id") == os.environ["RUN_ID"]
        and labels.get("devshot.github.run-attempt") == os.environ["RUN_ATTEMPT"]
    )
    raise SystemExit(0 if valid else 1)
except (TypeError, ValueError):
    raise SystemExit(1)
' <<< "$labels"; then
        label_status=0
      else
        label_status=$?
      fi
      if [ "$label_status" -ne 0 ]; then
        echo "WARNING: cleanup labels do not match $container; leaving it untouched" >&2
        continue
      fi
    fi

    echo "Removing completed orphaned scoped container: $container ($owner, ${age}s old)"
    if ! bounded_docker 120 rm -f "$container" >/dev/null; then
      echo "ERROR: failed to remove completed orphaned Buildx container: $container" >&2
      failed=1
    fi
  done <<< "$containers"

  # buildx can leave only its state volume after metadata and the driver
  # container have already disappeared. Reap that exact volume only after the
  # same age floor and completed-owner proof used for other scoped resources.
  if ! volumes="$(bounded_docker 60 volume ls --format '{{.Name}}')"; then
    echo "ERROR: could not list Docker volumes for scoped stale cleanup" >&2
    return 1
  fi
  while IFS= read -r volume; do
    [ -n "$volume" ] || continue
    if [[ "$volume" =~ ^buildx_buildkit_devshot-build-([0-9]+)-([0-9]+)-(dom0|kvm|runtime)[0-9]+_state$ ]]; then
      run_id="${BASH_REMATCH[1]}"
    else
      continue
    fi
    if ! metadata="$(bounded_docker 60 volume inspect --format '{{.CreatedAt}}' "$volume")" \
      || ! age="$(created_age_seconds "$metadata")" || ! old_enough "$age"; then
      continue
    fi
    if owner_run_is_completed "$run_id"; then
      owner_status=0
    else
      owner_status=$?
    fi
    [ "$owner_status" -eq 0 ] || continue
    echo "Removing completed orphaned Buildx state volume: $volume (${age}s old)"
    if ! remove_exact_buildx_volume "$volume"; then
      echo "ERROR: failed to remove completed orphaned Buildx state volume: $volume" >&2
      failed=1
    fi
  done <<< "$volumes"

  # Local validation candidates are intentionally never public. The publisher
  # also creates a run-scoped local alias while pushing its already-validated
  # registry candidate. A hard kill can bypass either exact cleanup, so reap
  # only these run-scoped tags after the same age and completed-owner proof.
  if ! images="$(bounded_docker 60 image ls --format '{{.Repository}}:{{.Tag}}')"; then
    echo "ERROR: could not list Docker images for scoped stale cleanup" >&2
    return 1
  fi
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    if [[ "$image" =~ ^devshot-(amd64|arm64)-candidate:([0-9]+)-([0-9]+)-(dom0|kvm)$ ]]; then
      run_id="${BASH_REMATCH[2]}"
    elif [[ "$image" =~ ^devshot-studio-runtime-test:([0-9]+)-([0-9]+)$ ]]; then
      run_id="${BASH_REMATCH[1]}"
    elif [[ "$image" =~ ^anticipatercom/devshot:validated-(amd64|arm64)(-kvm)?-[0-9a-f]{40}-([0-9]+)-([0-9]+)$ ]]; then
      run_id="${BASH_REMATCH[3]}"
    else
      continue
    fi
    if ! metadata="$(bounded_docker 60 image inspect --format '{{.Created}}' "$image")" \
      || ! age="$(created_age_seconds "$metadata")" || ! old_enough "$age"; then
      continue
    fi
    if owner_run_is_completed "$run_id"; then
      owner_status=0
    else
      owner_status=$?
    fi
    [ "$owner_status" -eq 0 ] || continue
    echo "Removing completed stale validation image: $image (${age}s old)"
    if ! bounded_docker 120 image rm "$image" >/dev/null; then
      echo "ERROR: failed to remove completed stale validation image: $image" >&2
      failed=1
    fi
  done <<< "$images"

  return "$failed"
}

reap_stale_buildx_resources_locked() (
  local runner_temp lock_file lock_status=0
  runner_temp="${RUNNER_TEMP%/}"
  lock_file="$runner_temp/devshot-buildx-reaper.lock"
  umask 077

  # Python's flock is available everywhere this helper already requires
  # Python, including the macOS test host. The parent shell opens fd 9; the
  # lock acquired by the child remains attached to that shared open-file
  # description until this subshell exits. A second prepare therefore sees
  # the state only after the first reaper has finished mutating it.
  exec 9> "$lock_file"
  timeout --foreground --signal=TERM --kill-after=5s 30s \
    python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)' \
    || lock_status=$?
  if [ "$lock_status" -eq 124 ]; then
    echo "WARNING: another self-hosted Buildx reaper is active; skipping this cleanup pass" >&2
    return 0
  fi
  if [ "$lock_status" -ne 0 ]; then
    echo "ERROR: could not acquire the self-hosted Buildx reaper lock" >&2
    return "$lock_status"
  fi

  reap_stale_buildx_resources
)

prepare() {
  local required_kib command workspace_available
  require_run_identity
  required_kib="$(minimum_kib "${1:-}")"

  for command in bash curl docker file git awk df jq python3 timeout; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "ERROR: self-hosted builder is missing required command: $command" >&2
      exit 1
    fi
  done
  if ! timeout --version 2>&1 | head -n 1 | grep -q '^timeout (GNU coreutils) '; then
    echo "ERROR: self-hosted builder requires GNU coreutils timeout" >&2
    exit 1
  fi
  bounded_docker 60 version >/dev/null
  bounded_docker 60 buildx version >/dev/null

  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  [[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "ERROR: invalid GITHUB_REPOSITORY" >&2
    exit 64
  }

  reap_stale_buildx_resources_locked

  if [ ! -d "$GITHUB_WORKSPACE" ] || [ ! -w "$GITHUB_WORKSPACE" ]; then
    echo "ERROR: GitHub workspace is not a writable directory: $GITHUB_WORKSPACE" >&2
    exit 1
  fi
  workspace_available="$(df -Pk "$GITHUB_WORKSPACE" | awk 'NR == 2 { print $4 }')"
  assert_available_kib 'workspace filesystem' "$workspace_available" "$required_kib"

  rm -rf -- "$DOCKER_CONFIG"
  install -d -m 0700 "$DOCKER_CONFIG"
}

verify_docker_storage() {
  local required_kib name docker_available
  require_run_identity
  required_kib="$(minimum_kib "${1:-}")"
  name="$(probe_name)"
  docker rm -f "$name" >/dev/null 2>&1 || true
  cleanup_probe() { docker rm -f "$name" >/dev/null 2>&1 || true; }
  trap cleanup_probe EXIT INT TERM

  timeout --foreground --signal=TERM --kill-after=30s 300s \
    docker pull "$STORAGE_PROBE_IMAGE" >/dev/null
  docker_available="$(
    timeout --foreground --signal=TERM --kill-after=10s 60s \
      docker run --name "$name" --rm "$STORAGE_PROBE_IMAGE" \
        sh -c "df -Pk / | awk 'NR == 2 { print \$4 }'"
  )"
  assert_available_kib 'Docker data filesystem' "$docker_available" "$required_kib"
  trap - EXIT INT TERM
}

cleanup() {
  local exact_image name containers container owner images image failed=0
  require_run_identity
  name="$(probe_name)"

  if ! remove_buildx_builder "$BUILDER_NAME"; then
    echo "ERROR: failed to remove current Buildx builder: $BUILDER_NAME" >&2
    failed=1
  fi

  if ! containers="$(bounded_docker 60 ps -a --format '{{.Names}}')"; then
    echo "ERROR: could not list Docker containers during cleanup" >&2
    failed=1
  else
    while IFS= read -r container; do
      [ -n "$container" ] || continue
      owner=""
      if [[ "$container" =~ ^buildx_buildkit_(devshot-build-[0-9]+-[0-9]+-(dom0|kvm|runtime))[0-9]+$ ]]; then
        owner="${BASH_REMATCH[1]}"
      fi
      if [ "$container" = "$name" ] || [ "$owner" = "$BUILDER_NAME" ]; then
        if ! bounded_docker 120 rm -f "$container" >/dev/null; then
          echo "ERROR: failed to remove scoped Docker container: $container" >&2
          failed=1
        fi
      fi
    done <<< "$containers"
  fi

  if ! bounded_docker 60 logout >/dev/null; then
    echo "ERROR: failed to remove isolated Docker registry credentials" >&2
    failed=1
  fi

  while [ "$#" -gt 0 ]; do
    exact_image="$1"
    shift
    if ! [[ "$exact_image" =~ ^anticipatercom/devshot:(amd64|arm64)(-kvm)?-[0-9a-f]{40}$ ]] \
      && ! [[ "$exact_image" =~ ^anticipatercom/devshot:arm64-mac-[0-9a-f]{40}$ ]] \
      && ! [[ "$exact_image" =~ ^devshot-studio-runtime-test:[0-9]+-[0-9]+$ ]] \
      && ! [[ "$exact_image" =~ ^devshot-(amd64|arm64)-candidate:[0-9]+-[0-9]+-(dom0|kvm)$ ]]; then
      echo "ERROR: refusing unsafe image cleanup target: $exact_image" >&2
      exit 64
    fi
    if ! images="$(bounded_docker 60 image ls --format '{{.Repository}}:{{.Tag}}' "$exact_image")"; then
      echo "ERROR: could not list the exact build image during cleanup: $exact_image" >&2
      failed=1
    else
      while IFS= read -r image; do
        [ "$image" = "$exact_image" ] || continue
        if ! bounded_docker 120 image rm "$exact_image" >/dev/null; then
          echo "ERROR: failed to remove exact build image: $exact_image" >&2
          failed=1
        fi
      done <<< "$images"
    fi
  done

  if [ "$failed" -eq 0 ]; then
    if ! rm -rf -- "$DOCKER_CONFIG"; then
      echo "ERROR: failed to remove isolated Docker configuration: $DOCKER_CONFIG" >&2
      failed=1
    fi
  else
    echo "WARNING: leaving exact isolated Docker configuration for verified stale recovery: $DOCKER_CONFIG" >&2
  fi

  return "$failed"
}

case "${1:-}" in
  initialize)
    shift
    [ "$#" -eq 1 ] || usage
    initialize "$1"
    ;;
  prepare)
    shift
    [ "$#" -eq 1 ] || usage
    prepare "$1"
    ;;
  verify-docker-storage)
    shift
    [ "$#" -eq 1 ] || usage
    verify_docker_storage "$1"
    ;;
  verify-memory)
    shift
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
    verify_memory "$@"
    ;;
  cleanup)
    shift
    cleanup "$@"
    ;;
  *) usage ;;
esac
