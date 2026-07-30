#!/bin/bash
# Shared bounded Docker operations for template bakes.
#
# GNU timeout bounds the client process. A Docker-owned CID file gives cleanup
# an exact daemon-side container identity even when the client is terminated.
# Call bounded_docker_cleanup from the caller's EXIT trap.

if [ "${DEVSHOT_BOUNDED_DOCKER_RUN_LOADED:-}" = "1" ]; then
  return 0
fi
DEVSHOT_BOUNDED_DOCKER_RUN_LOADED=1

BOUNDED_DOCKER_INITIALIZED=0
BOUNDED_DOCKER_TIMEOUT_BIN=""
BOUNDED_DOCKER_CID_DIR=""
BOUNDED_DOCKER_ACTIVE_CID_FILE=""
BOUNDED_DOCKER_ACTIVE_STAGING_DIR=""
BOUNDED_DOCKER_SEQUENCE=0

bounded_docker_init() {
  if [ "$BOUNDED_DOCKER_INITIALIZED" = "1" ]; then
    return 0
  fi

  BAKE_TIMEOUT_SECONDS="${BAKE_TIMEOUT_SECONDS:-3600}"
  case "$BAKE_TIMEOUT_SECONDS" in
    ''|*[!0-9]*)
      echo "ERROR: BAKE_TIMEOUT_SECONDS must be an integer from 1 to 14400" >&2
      return 1
      ;;
  esac
  if [ "$BAKE_TIMEOUT_SECONDS" -lt 1 ] || [ "$BAKE_TIMEOUT_SECONDS" -gt 14400 ]; then
    echo "ERROR: BAKE_TIMEOUT_SECONDS must be an integer from 1 to 14400" >&2
    return 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    BOUNDED_DOCKER_TIMEOUT_BIN="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    BOUNDED_DOCKER_TIMEOUT_BIN="$(command -v gtimeout)"
  else
    echo "ERROR: GNU timeout (timeout or gtimeout) is required for Docker bakes" >&2
    return 1
  fi
  if ! "$BOUNDED_DOCKER_TIMEOUT_BIN" --help 2>&1 | grep -q -- '--foreground'; then
    echo "ERROR: $BOUNDED_DOCKER_TIMEOUT_BIN is not GNU timeout" >&2
    return 1
  fi

  BOUNDED_DOCKER_CID_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devshot-docker-cids.XXXXXX")"
  BOUNDED_DOCKER_INITIALIZED=1
}

bounded_docker_cleanup_cid_file() {
  local cid_file="${1:-}"
  local cid=""

  [ -n "$cid_file" ] || return 0
  if [ -f "$cid_file" ]; then
    cid="$(tr -d '\r\n' < "$cid_file")"
    if [[ "$cid" =~ ^[0-9a-f]{64}$ ]]; then
      "$BOUNDED_DOCKER_TIMEOUT_BIN" --foreground --signal=TERM --kill-after=5s 30s \
        docker rm -f "$cid" >/dev/null 2>&1 || true
    elif [ -n "$cid" ]; then
      echo "WARN: refusing Docker cleanup for invalid CID in $cid_file" >&2
    fi
  fi
  rm -f -- "$cid_file"
}

bounded_docker_cleanup_active() {
  local cid_file="$BOUNDED_DOCKER_ACTIVE_CID_FILE"
  local staging_dir="$BOUNDED_DOCKER_ACTIVE_STAGING_DIR"
  BOUNDED_DOCKER_ACTIVE_CID_FILE=""
  BOUNDED_DOCKER_ACTIVE_STAGING_DIR=""
  bounded_docker_cleanup_cid_file "$cid_file"
  if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
    rm -rf -- "$staging_dir"
  fi
}

bounded_docker_cleanup() {
  bounded_docker_cleanup_active
  if [ -n "$BOUNDED_DOCKER_CID_DIR" ] && [ -d "$BOUNDED_DOCKER_CID_DIR" ]; then
    rm -rf -- "$BOUNDED_DOCKER_CID_DIR"
  fi
  BOUNDED_DOCKER_CID_DIR=""
  BOUNDED_DOCKER_INITIALIZED=0
}

bounded_docker_run() {
  local label="${1:?bounded_docker_run requires a label}"
  shift
  local safe_label cid_file rc

  bounded_docker_init
  safe_label="$(printf '%s' "$label" | tr -c '[:alnum:]_.-' '-')"
  BOUNDED_DOCKER_SEQUENCE=$((BOUNDED_DOCKER_SEQUENCE + 1))
  cid_file="$BOUNDED_DOCKER_CID_DIR/${BOUNDED_DOCKER_SEQUENCE}-${safe_label}.cid"
  rm -f -- "$cid_file"
  BOUNDED_DOCKER_ACTIVE_CID_FILE="$cid_file"

  if "$BOUNDED_DOCKER_TIMEOUT_BIN" \
      --foreground --signal=TERM --kill-after=30s "${BAKE_TIMEOUT_SECONDS}s" \
      docker run --cidfile "$cid_file" --rm "$@"; then
    rc=0
  else
    rc=$?
  fi

  bounded_docker_cleanup_active
  return "$rc"
}

bounded_docker_extract_present_file() {
  local image="${1:?bounded_docker_extract_file requires an image}"
  local container_path="${2:?bounded_docker_extract_file requires a container path}"
  local destination="${3:?bounded_docker_extract_file requires a destination}"
  local destination_dir destination_name cid_file cid staging_file rc

  bounded_docker_init
  destination_dir="$(cd "$(dirname "$destination")" && pwd)"
  destination_name="$(basename "$destination")"

  BOUNDED_DOCKER_SEQUENCE=$((BOUNDED_DOCKER_SEQUENCE + 1))
  cid_file="$BOUNDED_DOCKER_CID_DIR/${BOUNDED_DOCKER_SEQUENCE}-extract.cid"
  rm -f -- "$cid_file"
  BOUNDED_DOCKER_ACTIVE_CID_FILE="$cid_file"
  BOUNDED_DOCKER_ACTIVE_STAGING_DIR="$(mktemp -d "$destination_dir/.${destination_name}.extract.XXXXXX")"
  staging_file="$BOUNDED_DOCKER_ACTIVE_STAGING_DIR/$destination_name"

  if "$BOUNDED_DOCKER_TIMEOUT_BIN" \
      --foreground --signal=TERM --kill-after=30s 60s \
      docker create --cidfile "$cid_file" "$image" >/dev/null; then
    :
  else
    rc=$?
    bounded_docker_cleanup_active
    return "$rc"
  fi

  cid="$(tr -d '\r\n' < "$cid_file")"
  if ! [[ "$cid" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: Docker create returned an invalid container ID" >&2
    bounded_docker_cleanup_active
    return 1
  fi

  if "$BOUNDED_DOCKER_TIMEOUT_BIN" \
      --foreground --signal=TERM --kill-after=30s 1800s \
      docker cp "$cid:$container_path" "$staging_file"; then
    if [ ! -f "$staging_file" ]; then
      echo "ERROR: Docker copy produced no regular file for $container_path" >&2
      rc=1
    elif mv -f -- "$staging_file" "$destination"; then
      rc=0
    else
      rc=$?
    fi
  else
    rc=$?
  fi

  bounded_docker_cleanup_active
  return "$rc"
}

bounded_docker_extract_file() {
  local image="${1:?bounded_docker_extract_file requires an image}"
  local container_path="${2:?bounded_docker_extract_file requires a container path}"
  local destination="${3:?bounded_docker_extract_file requires a destination}"

  bounded_docker_init
  if "$BOUNDED_DOCKER_TIMEOUT_BIN" \
      --foreground --signal=TERM --kill-after=30s 3600s \
      docker pull "$image"; then
    :
  else
    return $?
  fi
  bounded_docker_extract_present_file "$image" "$container_path" "$destination"
}

bounded_docker_extract_local_file() {
  local image="${1:?bounded_docker_extract_local_file requires an image}"
  local container_path="${2:?bounded_docker_extract_local_file requires a container path}"
  local destination="${3:?bounded_docker_extract_local_file requires a destination}"

  bounded_docker_init
  if ! "$BOUNDED_DOCKER_TIMEOUT_BIN" \
      --foreground --signal=TERM --kill-after=30s 60s \
      docker image inspect "$image" >/dev/null; then
    echo "ERROR: required local Docker image is unavailable: $image" >&2
    return 1
  fi
  bounded_docker_extract_present_file "$image" "$container_path" "$destination"
}
