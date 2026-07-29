#!/usr/bin/env bash
# Fail-closed lifecycle helpers for the persistent self-hosted image builder.
# Every cleanup target is scoped to the current Actions run. Never add a
# system-wide Docker prune or delete host toolchains from this script.
set -euo pipefail

readonly STORAGE_PROBE_IMAGE='alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40'

usage() {
  echo "usage: $0 initialize <dom0|kvm> | prepare <minimum-gib> | verify-docker-storage <minimum-gib> | cleanup [exact-image]" >&2
  exit 64
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
    dom0|kvm) ;;
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
  require_numeric_run_identity
  : "${GITHUB_JOB:?GITHUB_JOB is required}"
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${DOCKER_CONFIG:?DOCKER_CONFIG is required}"
  : "${BUILDER_NAME:?BUILDER_NAME is required}"

  case "$DOCKER_CONFIG" in
    "$RUNNER_TEMP"/devshot-docker-config-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-*) ;;
    *)
      echo "ERROR: refusing unsafe DOCKER_CONFIG path: $DOCKER_CONFIG" >&2
      exit 64
      ;;
  esac

  case "$BUILDER_NAME" in
    devshot-build-"$GITHUB_RUN_ID"-"$GITHUB_RUN_ATTEMPT"-*) ;;
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

prepare() {
  local required_kib command workspace_available
  require_run_identity
  required_kib="$(minimum_kib "${1:-}")"

  for command in bash docker git awk df python3 timeout; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "ERROR: self-hosted builder is missing required command: $command" >&2
      exit 1
    fi
  done
  if ! timeout --version 2>&1 | head -n 1 | grep -q '^timeout (GNU coreutils) '; then
    echo "ERROR: self-hosted builder requires GNU coreutils timeout" >&2
    exit 1
  fi
  docker version >/dev/null
  docker buildx version >/dev/null

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
  local exact_image="${1:-}" name
  require_run_identity
  name="$(probe_name)"

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker buildx rm --force "$BUILDER_NAME" >/dev/null 2>&1 || true
  docker logout >/dev/null 2>&1 || true

  if [ -n "$exact_image" ]; then
    case "$exact_image" in
      anticipatercom/devshot:amd64-????????????????????????????????????????) ;;
      *)
        echo "ERROR: refusing unsafe image cleanup target: $exact_image" >&2
        exit 64
        ;;
    esac
    docker image rm "$exact_image" >/dev/null 2>&1 || true
  fi

  rm -rf -- "$DOCKER_CONFIG"
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
  cleanup)
    shift
    [ "$#" -le 1 ] || usage
    cleanup "${1:-}"
    ;;
  *) usage ;;
esac
