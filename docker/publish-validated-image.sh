#!/usr/bin/env bash
# Publish architecture-specific images only after local runtime validation.
# Immutable SHA tags are pushed first. Rolling tags are promoted as the final
# release transaction after both Dom0 and KVM jobs have validated and cleaned
# their persistent builder state.
set -euo pipefail

readonly REPOSITORY='anticipatercom/devshot'
PROMOTION_AUTH_DIR=''

usage() {
  echo "usage: $0 reuse-immutable <arm64-dom0|arm64-kvm|amd64-dom0|amd64-kvm> <local-candidate> <40-char-sha> | push-immutable <arm64-dom0|arm64-kvm|amd64-dom0|amd64-kvm> <local-candidate> <40-char-sha> | promote-arm64-family <40-char-sha> | promote-amd64-family <40-char-sha>" >&2
  exit 64
}

require_sha() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "ERROR: image source SHA must contain exactly 40 lowercase hex characters" >&2
    exit 64
  }
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $1" >&2
    exit 1
  }
}

bounded_docker() {
  local seconds="$1"
  shift
  timeout --foreground --signal=TERM --kill-after=30s "${seconds}s" \
    env -u DOCKERHUB_TOKEN docker "$@"
}

registry_digest() {
  local reference="$1" manifest digest
  manifest="$(bounded_docker 180 buildx imagetools inspect "$reference" --format '{{json .Manifest}}')"
  digest="$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<< "$manifest")"
  printf '%s\n' "$digest"
}

registry_revision() {
  local reference="$1" image revision
  image="$(bounded_docker 180 buildx imagetools inspect "$reference" --format '{{json .Image}}')"
  revision="$(jq -er '.config.Labels["org.opencontainers.image.revision"] | select(type == "string" and test("^[0-9a-f]{40}$"))' <<< "$image")"
  printf '%s\n' "$revision"
}

registry_digest_or_missing() {
  local reference="$1" output status=0 digest
  output="$(bounded_docker 180 buildx imagetools inspect "$reference" --format '{{json .Manifest}}' 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    digest="$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<< "$output")"
    printf '%s\n' "$digest"
    return 0
  fi
  if grep -Eqi 'not found|manifest unknown|no such manifest' <<< "$output"; then
    printf '%s\n' missing
    return 0
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  echo "ERROR: could not determine whether immutable tag exists: $reference" >&2
  return "$status"
}

create_registry_tag_with_retry() {
  local target="$1" digest="$2" attempt
  for attempt in 1 2; do
    if bounded_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$target" "$REPOSITORY@$digest"; then
      return 0
    fi
    if [ "$attempt" -eq 1 ]; then
      echo "Retrying bounded registry tag creation: $target" >&2
    fi
  done
  echo "ERROR: registry tag creation failed twice: $target" >&2
  return 1
}

ensure_immutable_tag() {
  local reference="$1" expected_digest="$2" existing actual
  existing="$(registry_digest_or_missing "$reference")"
  if [ "$existing" = missing ]; then
    create_registry_tag_with_retry "$reference" "$expected_digest"
  elif [ "$existing" != "$expected_digest" ]; then
    echo "ERROR: immutable tag conflict for $reference: existing=$existing candidate=$expected_digest" >&2
    return 1
  else
    echo "Immutable tag already resolves to the validated digest: $reference"
  fi
  actual="$(registry_digest "$reference")"
  [ "$actual" = "$expected_digest" ] || {
    echo "ERROR: immutable tag verification failed for $reference" >&2
    return 1
  }
}

push_with_retry() {
  local reference="$1" attempt
  for attempt in 1 2; do
    if bounded_docker 1800 push "$reference"; then
      return 0
    fi
    if [ "$attempt" -eq 1 ]; then
      echo "Retrying immutable image push after a bounded failure: $reference" >&2
    fi
  done
  echo "ERROR: immutable image push failed twice: $reference" >&2
  return 1
}

require_candidate_identity() {
  local variant="${1:-}" candidate="${2:-}" run_id run_attempt candidate_arch candidate_variant
  : "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
  : "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
  [[ "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+:[0-9]+$ ]] || {
    echo "ERROR: invalid GitHub Actions run identity" >&2
    exit 64
  }
  if [[ "$candidate" =~ ^devshot-(arm64|amd64)-candidate:([0-9]+)-([0-9]+)-(dom0|kvm)$ ]]; then
    candidate_arch="${BASH_REMATCH[1]}"
    run_id="${BASH_REMATCH[2]}"
    run_attempt="${BASH_REMATCH[3]}"
    candidate_variant="${BASH_REMATCH[4]}"
  else
    echo "ERROR: invalid scoped image candidate: ${candidate:-missing}" >&2
    exit 64
  fi
  [ "$run_id" = "$GITHUB_RUN_ID" ] && [ "$run_attempt" = "$GITHUB_RUN_ATTEMPT" ] \
    && [ "$candidate_arch-$candidate_variant" = "$variant" ] || {
      echo "ERROR: image candidate does not belong to this job identity" >&2
      exit 64
    }
}

immutable_references() {
  local variant="${1:-}" source_sha="${2:-}"
  case "$variant" in
    arm64-dom0)
      printf '%s\n' \
        "$REPOSITORY:arm64-$source_sha" \
        "$REPOSITORY:arm64-mac-$source_sha"
      ;;
    arm64-kvm)
      printf '%s\n' "$REPOSITORY:arm64-kvm-$source_sha"
      ;;
    amd64-dom0)
      printf '%s\n' "$REPOSITORY:amd64-$source_sha"
      ;;
    amd64-kvm)
      printf '%s\n' "$REPOSITORY:amd64-kvm-$source_sha"
      ;;
    *)
      echo "ERROR: invalid image publication variant: $variant" >&2
      exit 64
      ;;
  esac
}

require_local_kvm_revision() {
  local variant="$1" image="$2" source_sha="$3" revision
  case "$variant" in
    arm64-kvm|amd64-kvm) ;;
    *) return 0 ;;
  esac
  revision="$(bounded_docker 60 image inspect \
    --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
    "$image")"
  [ "$revision" = "$source_sha" ] || {
    echo "ERROR: KVM image revision label is ${revision:-missing}, expected $source_sha" >&2
    return 1
  }
}

# A rerun may start after a previously validated immutable image was published
# but before its artifact upload or the next job completed. Reuse only exact
# source-SHA tags in that case; never rebuild and conflict with an immutable
# digest. Exit 3 means that no exact tag exists and a fresh build is required.
reuse_immutable() {
  local variant="${1:-}" candidate="${2:-}" source_sha="${3:-}"
  local reference digest selected_reference='' selected_digest='' architecture expected_arch
  local -a immutable_tags
  require_sha "$source_sha"
  require_candidate_identity "$variant" "$candidate"
  expected_arch="${variant%%-*}"
  while IFS= read -r reference; do
    immutable_tags+=("$reference")
  done < <(immutable_references "$variant" "$source_sha")

  for reference in "${immutable_tags[@]}"; do
    digest="$(registry_digest_or_missing "$reference")"
    if [ "$digest" = missing ]; then
      continue
    fi
    if [ -n "$selected_digest" ]; then
      if [ "$digest" != "$selected_digest" ]; then
        echo "ERROR: exact immutable $variant aliases disagree; refusing retry reuse" >&2
        return 1
      fi
    else
      selected_reference="$reference"
      selected_digest="$digest"
    fi
  done
  if [ -z "$selected_reference" ]; then
    echo "No exact immutable $variant image exists; a fresh build is required"
    return 3
  fi

  bounded_docker 1800 pull "$selected_reference"
  architecture="$(bounded_docker 60 image inspect --format '{{.Architecture}}' "$selected_reference")"
  [ "$architecture" = "$expected_arch" ] || {
    echo "ERROR: refusing to reuse wrong-architecture immutable image: $selected_reference ($architecture, expected $expected_arch)" >&2
    return 1
  }
  require_local_kvm_revision "$variant" "$selected_reference" "$source_sha"
  bounded_docker 60 tag "$selected_reference" "$candidate"
  echo "Reused exact immutable $variant image $selected_reference ($selected_digest)"
}

push_immutable() {
  local variant="${1:-}" candidate="${2:-}" source_sha="${3:-}" architecture
  local immutable candidate_digest registry_candidate expected_arch
  local -a immutable_tags
  require_sha "$source_sha"
  require_candidate_identity "$variant" "$candidate"
  expected_arch="${variant%%-*}"
  while IFS= read -r immutable; do
    immutable_tags+=("$immutable")
  done < <(immutable_references "$variant" "$source_sha")

  case "$variant" in
    arm64-dom0)
      registry_candidate="$REPOSITORY:validated-arm64-$source_sha-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
      ;;
    arm64-kvm)
      registry_candidate="$REPOSITORY:validated-arm64-kvm-$source_sha-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
      ;;
    amd64-dom0)
      registry_candidate="$REPOSITORY:validated-amd64-$source_sha-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
      ;;
    amd64-kvm)
      registry_candidate="$REPOSITORY:validated-amd64-kvm-$source_sha-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
      ;;
    *)
      echo "ERROR: invalid image publication variant: $variant" >&2
      exit 64
      ;;
  esac

  architecture="$(bounded_docker 60 image inspect --format '{{.Architecture}}' "$candidate")"
  [ "$architecture" = "$expected_arch" ] || {
    echo "ERROR: refusing to publish wrong-architecture candidate: $candidate ($architecture, expected $expected_arch)" >&2
    exit 1
  }
  require_local_kvm_revision "$variant" "$candidate" "$source_sha"

  # This run-specific registry candidate is published only after the local
  # runtime validator passed. It lets us resolve the registry manifest digest
  # without ever creating local SHA/rolling tags or mutating an existing SHA.
  bounded_docker 60 tag "$candidate" "$registry_candidate"
  push_with_retry "$registry_candidate"
  candidate_digest="$(registry_digest "$registry_candidate")"
  if [[ "$variant" == *-kvm ]] \
    && [ "$(registry_revision "$registry_candidate")" != "$source_sha" ]; then
    echo "ERROR: published KVM image revision does not match source SHA" >&2
    return 1
  fi
  bounded_docker 120 image rm "$registry_candidate" >/dev/null

  for immutable in "${immutable_tags[@]}"; do
    ensure_immutable_tag "$immutable" "$candidate_digest"
  done
  echo "Published validated immutable $variant image: $candidate_digest"
}

promote_amd64_family() {
  local source_sha="${1:-}" auth_dir dom0_digest kvm_digest
  local old_dom0 old_kvm actual promotion_started=0 promotion_failed=0 rollback_failed=0
  require_sha "$source_sha"
  : "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
  : "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
  : "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
  [[ "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+:[0-9]+$ ]]
  case "$RUNNER_TEMP" in
    /*) ;;
    *) echo "ERROR: RUNNER_TEMP must be absolute" >&2; exit 64 ;;
  esac
  [ "$RUNNER_TEMP" != / ] || { echo "ERROR: RUNNER_TEMP must not be root" >&2; exit 64; }

  auth_dir="${RUNNER_TEMP%/}/devshot-amd64-promotion-auth-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  case "$auth_dir" in
    "${RUNNER_TEMP%/}"/devshot-amd64-promotion-auth-*) ;;
    *) echo "ERROR: unsafe AMD64 promotion authentication directory" >&2; exit 64 ;;
  esac
  rm -rf -- "$auth_dir"
  install -d -m 0700 "$auth_dir"

  auth_docker() {
    local seconds="$1"
    shift
    timeout --foreground --signal=TERM --kill-after=30s "${seconds}s" \
      env -u DOCKERHUB_TOKEN docker --config "$auth_dir" "$@"
  }
  auth_digest() {
    local manifest digest
    manifest="$(auth_docker 180 buildx imagetools inspect "$1" --format '{{json .Manifest}}')"
    digest="$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<< "$manifest")"
    printf '%s\n' "$digest"
  }
  cleanup_auth() {
    local status=$?
    trap - EXIT INT TERM
    rm -rf -- "$auth_dir" || exit 1
    exit "$status"
  }
  restore_previous() {
    rollback_failed=0
    auth_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$REPOSITORY:amd64" "$REPOSITORY@$old_dom0" || rollback_failed=1
    auth_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$REPOSITORY:amd64-kvm" "$REPOSITORY@$old_kvm" || rollback_failed=1
    actual="$(auth_digest "$REPOSITORY:amd64" 2>/dev/null || true)"
    [ "$actual" = "$old_dom0" ] || rollback_failed=1
    actual="$(auth_digest "$REPOSITORY:amd64-kvm" 2>/dev/null || true)"
    [ "$actual" = "$old_kvm" ] || rollback_failed=1
    [ "$rollback_failed" -eq 0 ] || {
      echo "ERROR: AMD64 rolling-tag rollback did not restore the previous family" >&2
      return 1
    }
    echo "Previous AMD64 rolling tags restored"
  }
  handle_signal() {
    local code="$1"
    trap - INT TERM
    if [ "$promotion_started" -eq 1 ]; then
      restore_previous || true
    fi
    exit "$code"
  }
  trap cleanup_auth EXIT

  printf '%s' "$DOCKERHUB_TOKEN" \
    | timeout --foreground --signal=TERM --kill-after=15s 120s \
        env -u DOCKERHUB_TOKEN docker --config "$auth_dir" login \
          --username "$DOCKERHUB_USERNAME" --password-stdin

  dom0_digest="$(auth_digest "$REPOSITORY:amd64-$source_sha")"
  kvm_digest="$(auth_digest "$REPOSITORY:amd64-kvm-$source_sha")"
  [ "$(registry_revision "$REPOSITORY:amd64-kvm-$source_sha")" = "$source_sha" ] || {
    echo "ERROR: AMD64 KVM immutable revision does not match promotion source" >&2
    exit 1
  }
  old_dom0="$(auth_digest "$REPOSITORY:amd64")"
  old_kvm="$(auth_digest "$REPOSITORY:amd64-kvm")"
  trap 'handle_signal 130' INT
  trap 'handle_signal 143' TERM
  promotion_started=1

  if ! auth_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$REPOSITORY:amd64" "$REPOSITORY@$dom0_digest"; then
    promotion_failed=1
  elif ! auth_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$REPOSITORY:amd64-kvm" "$REPOSITORY@$kvm_digest"; then
    promotion_failed=1
  fi
  actual="$(auth_digest "$REPOSITORY:amd64" 2>/dev/null || true)"
  [ "$actual" = "$dom0_digest" ] || promotion_failed=1
  actual="$(auth_digest "$REPOSITORY:amd64-kvm" 2>/dev/null || true)"
  [ "$actual" = "$kvm_digest" ] || promotion_failed=1
  if [ "$promotion_failed" -ne 0 ]; then
    restore_previous || true
    exit 1
  fi
  promotion_started=0
  rm -rf -- "$auth_dir"
  trap - EXIT INT TERM
  echo "Promoted validated AMD64 family: dom0=$dom0_digest kvm=$kvm_digest"
}

promote_arm64_family() {
  local source_sha="${1:-}" auth_dir journal_path journal_lock_path journal_tmp=''
  local promotion_failed=0 rollback_failed=0 promotion_started=0 promotion_superseded=0
  local dom0_digest kvm_digest tag actual
  local -a rolling_tags=(arm64 arm64-mac arm64-kvm)
  local -a previous_digests=()

  require_sha "$source_sha"
  : "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
  : "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  : "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
  : "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
  : "${PROMOTION_STATE_DIR:?PROMOTION_STATE_DIR is required}"
  require_command flock
  [[ "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+:[0-9]+$ ]] || {
    echo "ERROR: invalid GitHub Actions run identity" >&2
    exit 64
  }
  case "$RUNNER_TEMP" in
    /*) ;;
    *) echo "ERROR: RUNNER_TEMP must be absolute" >&2; exit 64 ;;
  esac
  [ "$RUNNER_TEMP" != / ] || { echo "ERROR: RUNNER_TEMP must not be root" >&2; exit 64; }
  case "$PROMOTION_STATE_DIR" in
    /*) ;;
    *) echo "ERROR: PROMOTION_STATE_DIR must be absolute" >&2; exit 64 ;;
  esac
  [ "$PROMOTION_STATE_DIR" != / ] && [ -d "$PROMOTION_STATE_DIR" ] \
    && [ -w "$PROMOTION_STATE_DIR" ] || {
      echo "ERROR: PROMOTION_STATE_DIR must be a writable, pre-created non-root directory" >&2
      exit 64
    }
  if ! python3 - "$PROMOTION_STATE_DIR" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
st = os.lstat(path)
valid = (
    stat.S_ISDIR(st.st_mode)
    and st.st_uid == os.geteuid()
    and stat.S_IMODE(st.st_mode) & 0o077 == 0
)
raise SystemExit(0 if valid else 1)
PY
  then
    echo "ERROR: PROMOTION_STATE_DIR must be owned by this user with mode 0700" >&2
    exit 64
  fi

  journal_path="${PROMOTION_STATE_DIR%/}/arm64-promotion.journal"
  journal_lock_path="${PROMOTION_STATE_DIR%/}/arm64-promotion.lock"
  umask 077
  [ ! -L "$journal_lock_path" ] || {
    echo "ERROR: refusing symlinked ARM64 promotion lock" >&2
    exit 1
  }
  exec 9> "$journal_lock_path"
  chmod 0600 "$journal_lock_path"
  if ! flock --exclusive --nonblock 9; then
    echo "ERROR: another ARM64 rolling-tag promotion owns the persistent journal" >&2
    exit 1
  fi

  auth_dir="${RUNNER_TEMP%/}/devshot-promotion-auth-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  PROMOTION_AUTH_DIR="$auth_dir"
  case "$auth_dir" in
    "${RUNNER_TEMP%/}"/devshot-promotion-auth-*) ;;
    *) echo "ERROR: unsafe promotion authentication directory" >&2; exit 64 ;;
  esac
  rm -rf -- "$auth_dir"
  install -d -m 0700 "$auth_dir"

  remove_promotion_auth() {
    [ -z "$PROMOTION_AUTH_DIR" ] && return 0
    rm -rf -- "$PROMOTION_AUTH_DIR" || return 1
    [ ! -e "$PROMOTION_AUTH_DIR" ] || return 1
    PROMOTION_AUTH_DIR=''
  }
  cleanup_auth() {
    local status=$? cleanup_status=0
    trap - EXIT INT TERM
    if [ -n "$journal_tmp" ]; then
      rm -f -- "$journal_tmp" || cleanup_status=1
      journal_tmp=''
    fi
    remove_promotion_auth || cleanup_status=1
    if [ "$status" -ne 0 ]; then
      exit "$status"
    fi
    exit "$cleanup_status"
  }
  trap cleanup_auth EXIT

  printf '%s' "$DOCKERHUB_TOKEN" \
    | timeout --foreground --signal=TERM --kill-after=15s 120s \
        env -u DOCKERHUB_TOKEN docker --config "$auth_dir" login \
          --username "$DOCKERHUB_USERNAME" --password-stdin

  auth_docker() {
    local seconds="$1"
    shift
    timeout --foreground --signal=TERM --kill-after=30s "${seconds}s" \
      env -u DOCKERHUB_TOKEN docker --config "$auth_dir" "$@"
  }
  auth_digest() {
    local manifest digest
    manifest="$(auth_docker 180 buildx imagetools inspect "$1" --format '{{json .Manifest}}')"
    digest="$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<< "$manifest")"
    printf '%s\n' "$digest"
  }

  restore_previous_tags() {
    local index old_digest rolling rollback_actual
    rollback_failed=0
    echo "Restoring the previous ARM64 rolling-tag set" >&2
    for index in "${!rolling_tags[@]}"; do
      rolling="${rolling_tags[$index]}"
      old_digest="${previous_digests[$index]}"
      if ! auth_docker 600 buildx imagetools create --prefer-index=false \
        --tag "$REPOSITORY:$rolling" "$REPOSITORY@$old_digest"; then
        rollback_failed=1
      fi
    done
    for index in "${!rolling_tags[@]}"; do
      rolling="${rolling_tags[$index]}"
      old_digest="${previous_digests[$index]}"
      rollback_actual="$(auth_digest "$REPOSITORY:$rolling" 2>/dev/null || true)"
      [ "$rollback_actual" = "$old_digest" ] || rollback_failed=1
    done
    if [ "$rollback_failed" -ne 0 ]; then
      echo "ERROR: ARM64 rolling-tag rollback did not restore every previous digest" >&2
      return 1
    fi
    echo "Previous ARM64 rolling tags restored"
  }

  fsync_path() {
    python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
flags = os.O_RDONLY
if os.path.isdir(path) and hasattr(os, "O_DIRECTORY"):
    flags |= os.O_DIRECTORY
fd = os.open(path, flags)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  }

  clear_journal() {
    rm -f -- "$journal_path" || return 1
    [ ! -e "$journal_path" ] || return 1
    fsync_path "$PROMOTION_STATE_DIR"
  }

  verify_superseding_family() {
    local expected_dom0="$1" expected_mac="$2" expected_kvm="$3"
    local helper helper_output verified_dom0 verified_mac verified_kvm
    helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/recover-published-family.sh" || {
      echo "ERROR: could not resolve trusted family verification helper" >&2
      return 1
    }
    [ -f "$helper" ] && [ ! -L "$helper" ] || {
      echo "ERROR: trusted family verification helper is missing" >&2
      return 1
    }
    if ! helper_output="$(bash "$helper" --verify-only arm64)"; then
      echo "ERROR: unrelated ARM64 rolling tags are not a coherent validated family" >&2
      return 1
    fi

    # The helper brackets all rolling reads with the KVM commit marker. Re-read
    # the exact observed triplet before retiring the journal so a tag change
    # between helper completion and this process remains fail-closed.
    verified_dom0="$(auth_digest "$REPOSITORY:arm64")" || return 1
    verified_mac="$(auth_digest "$REPOSITORY:arm64-mac")" || return 1
    verified_kvm="$(auth_digest "$REPOSITORY:arm64-kvm")" || return 1
    if [ "$verified_dom0" != "$expected_dom0" ] \
      || [ "$verified_mac" != "$expected_mac" ] \
      || [ "$verified_kvm" != "$expected_kvm" ]; then
      echo "ERROR: superseding ARM64 rolling family changed before journal retirement" >&2
      return 1
    fi
    printf '%s\n' "$helper_output"
  }

  recover_pending_promotion() {
    local journal_content version journal_repo journal_sha target_dom0 target_kvm
    local old_dom0 old_mac old_kvm old_run old_attempt extra
    local current_dom0 current_mac current_kvm
    local unrelated_digest=0
    local -a target_digests=() current_digests=()
    [ -e "$journal_path" ] || return 0
    [ -f "$journal_path" ] && [ ! -L "$journal_path" ] || {
      echo "ERROR: refusing invalid persistent ARM64 promotion journal" >&2
      return 1
    }
    journal_content="$(< "$journal_path")"
    if [ -z "$journal_content" ] || [[ "$journal_content" == *$'\n'* ]]; then
      echo "ERROR: persistent ARM64 promotion journal is malformed" >&2
      return 1
    fi
    IFS=$'\t' read -r version journal_repo journal_sha target_dom0 target_kvm \
      old_dom0 old_mac old_kvm old_run old_attempt extra <<< "$journal_content" || {
        echo "ERROR: could not read persistent ARM64 promotion journal" >&2
        return 1
      }
    if [ "$version" != v1 ] \
      || [ "$journal_repo" != "$REPOSITORY" ] \
      || ! [[ "$journal_sha" =~ ^[0-9a-f]{40}$ ]] \
      || ! [[ "$target_dom0" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || ! [[ "$target_kvm" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || ! [[ "$old_dom0" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || ! [[ "$old_mac" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || ! [[ "$old_kvm" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || ! [[ "$old_run:$old_attempt" =~ ^[0-9]+:[0-9]+$ ]] \
      || [ -n "${extra:-}" ]; then
      echo "ERROR: persistent ARM64 promotion journal is malformed" >&2
      return 1
    fi
    previous_digests=("$old_dom0" "$old_mac" "$old_kvm")
    target_digests=("$target_dom0" "$target_dom0" "$target_kvm")
    echo "Recovering interrupted ARM64 promotion from run $old_run attempt $old_attempt" >&2
    current_dom0="$(auth_digest "$REPOSITORY:arm64")"
    current_mac="$(auth_digest "$REPOSITORY:arm64-mac")"
    current_kvm="$(auth_digest "$REPOSITORY:arm64-kvm")"
    if [ "$current_dom0" = "$target_dom0" ] \
      && [ "$current_mac" = "$target_dom0" ] \
      && [ "$current_kvm" = "$target_kvm" ]; then
      echo "Interrupted promotion already reached the complete target tag set"
    elif [ "$current_dom0" = "$old_dom0" ] \
      && [ "$current_mac" = "$old_mac" ] \
      && [ "$current_kvm" = "$old_kvm" ]; then
      echo "Interrupted promotion left the complete previous tag set unchanged"
    else
      current_digests=("$current_dom0" "$current_mac" "$current_kvm")
      for index in "${!rolling_tags[@]}"; do
        if [ "${current_digests[$index]}" != "${previous_digests[$index]}" ] \
          && [ "${current_digests[$index]}" != "${target_digests[$index]}" ]; then
          unrelated_digest=1
        fi
      done
      if [ "$unrelated_digest" -eq 1 ]; then
        if [ "$current_dom0" = "$current_mac" ] \
          && verify_superseding_family "$current_dom0" "$current_mac" "$current_kvm"; then
          promotion_superseded=1
          previous_digests=()
          echo "A coherent validated ARM64 family superseded the stale promotion journal"
          return 0
        fi
        echo "ERROR: rolling ARM64 tags contain an unrelated digest; refusing journal recovery because the family is incoherent" >&2
        return 1
      fi
      restore_previous_tags || return 1
    fi
    clear_journal || {
      echo "ERROR: restored tags but could not clear persistent promotion journal" >&2
      return 1
    }
    previous_digests=()
  }

  write_journal() {
    journal_tmp="$(mktemp "${PROMOTION_STATE_DIR%/}/.arm64-promotion.journal.XXXXXX")"
    chmod 0600 "$journal_tmp"
    printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$REPOSITORY" \
      "$source_sha" \
      "$dom0_digest" \
      "$kvm_digest" \
      "${previous_digests[0]}" \
      "${previous_digests[1]}" \
      "${previous_digests[2]}" \
      "$GITHUB_RUN_ID" \
      "$GITHUB_RUN_ATTEMPT" > "$journal_tmp"
    fsync_path "$journal_tmp"
    mv -f -- "$journal_tmp" "$journal_path"
    journal_tmp=''
    fsync_path "$PROMOTION_STATE_DIR"
  }

  recover_pending_promotion

  if [ "$promotion_superseded" -eq 1 ]; then
    if ! remove_promotion_auth; then
      echo "ERROR: failed to remove isolated credentials before retiring a superseded journal" >&2
      exit 1
    fi
    clear_journal || {
      echo "ERROR: could not atomically retire superseded ARM64 promotion journal" >&2
      exit 1
    }
    trap - EXIT INT TERM
    echo "Preserved the coherent superseding ARM64 rolling family; stale promotion skipped"
    return 0
  fi

  dom0_digest="$(auth_digest "$REPOSITORY:arm64-$source_sha")"
  [ "$(auth_digest "$REPOSITORY:arm64-mac-$source_sha")" = "$dom0_digest" ] || {
    echo "ERROR: validated immutable Dom0 aliases do not match" >&2
    exit 1
  }
  kvm_digest="$(auth_digest "$REPOSITORY:arm64-kvm-$source_sha")"
  [ "$(registry_revision "$REPOSITORY:arm64-kvm-$source_sha")" = "$source_sha" ] || {
    echo "ERROR: ARM64 KVM immutable revision does not match promotion source" >&2
    exit 1
  }

  # Snapshot every previous rolling target before the first mutation. A normal
  # registry error or failed post-promotion verification restores this set.
  for tag in "${rolling_tags[@]}"; do
    previous_digests+=("$(auth_digest "$REPOSITORY:$tag")")
  done

  handle_signal() {
    local exit_code="$1"
    trap - INT TERM
    if [ "$promotion_started" -eq 1 ]; then
      if restore_previous_tags; then
        clear_journal || true
      fi
    fi
    exit "$exit_code"
  }

  write_journal
  trap 'handle_signal 130' INT
  trap 'handle_signal 143' TERM
  promotion_started=1

  if ! auth_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$REPOSITORY:arm64" \
      --tag "$REPOSITORY:arm64-mac" \
      "$REPOSITORY@$dom0_digest"; then
    promotion_failed=1
  elif ! auth_docker 600 buildx imagetools create --prefer-index=false \
      --tag "$REPOSITORY:arm64-kvm" \
      "$REPOSITORY@$kvm_digest"; then
    promotion_failed=1
  fi

  if [ "$promotion_failed" -eq 0 ]; then
    for tag in arm64 arm64-mac; do
      actual="$(auth_digest "$REPOSITORY:$tag" 2>/dev/null || true)"
      [ "$actual" = "$dom0_digest" ] || promotion_failed=1
    done
    actual="$(auth_digest "$REPOSITORY:arm64-kvm" 2>/dev/null || true)"
    [ "$actual" = "$kvm_digest" ] || promotion_failed=1
  fi

  if [ "$promotion_failed" -ne 0 ]; then
    if restore_previous_tags; then
      clear_journal || true
    fi
    exit 1
  fi

  # Deleting the isolated Docker config is the actual credential revocation;
  # `docker logout` only edits this same file. Complete it before reporting a
  # successful rolling promotion. If it fails, restore the prior public tags.
  if ! remove_promotion_auth; then
    echo "ERROR: failed to remove isolated rolling-promotion credentials" >&2
    if restore_previous_tags; then
      clear_journal || true
    fi
    exit 1
  fi
  promotion_started=0
  if ! clear_journal; then
    echo "ERROR: promoted tags are consistent, but the persistent promotion journal could not be cleared" >&2
    exit 1
  fi
  trap - EXIT INT TERM

  echo "Promoted validated ARM64 family: dom0=$dom0_digest kvm=$kvm_digest"
}

for command in docker install jq timeout; do
  require_command "$command"
done

case "${1:-}" in
  reuse-immutable)
    [ "$#" -eq 4 ] || usage
    reuse_immutable "$2" "$3" "$4"
    ;;
  push-immutable)
    [ "$#" -eq 4 ] || usage
    push_immutable "$2" "$3" "$4"
    ;;
  promote-arm64-family)
    [ "$#" -eq 2 ] || usage
    promote_arm64_family "$2"
    ;;
  promote-amd64-family)
    [ "$#" -eq 2 ] || usage
    promote_amd64_family "$2"
    ;;
  *) usage ;;
esac
