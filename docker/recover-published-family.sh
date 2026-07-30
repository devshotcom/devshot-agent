#!/usr/bin/env bash
# Repair an interrupted rolling-tag promotion from immutable registry state.
#
# The rolling KVM tag is the family commit marker because promotions publish
# Dom0 aliases first and KVM last. This script never mutates the KVM marker. It
# resolves source-bound KVM images from their OCI revision. During migration of
# legacy unlabeled images, every digest collision is cross-checked against its
# immutable Dom0 family before a source is selected. Only Dom0 rolling aliases
# are repaired; the KVM marker is never mutated.
set -euo pipefail

readonly REPOSITORY='anticipatercom/devshot'
readonly TAGS_API_PREFIX="https://hub.docker.com/v2/repositories/${REPOSITORY}/tags?"
readonly MAX_TAG_PAGES=10
readonly TAG_PAGE_SIZE=100
readonly MAX_RECOVERY_ATTEMPTS=4
readonly MAX_KVM_DIGEST_CANDIDATES=32

verify_only=0
if [ "${1:-}" = --verify-only ]; then
  [ "$#" -eq 2 ] || {
    echo "usage: $0 [--verify-only] <amd64|arm64>" >&2
    exit 64
  }
  verify_only=1
  family="$2"
else
  [ "$#" -eq 1 ] || {
    echo "usage: $0 [--verify-only] <amd64|arm64>" >&2
    exit 64
  }
  family="${1:-}"
fi
case "$family" in
  amd64)
    readonly KVM_ROLLING_TAG='amd64-kvm'
    readonly KVM_IMMUTABLE_PREFIX='amd64-kvm-'
    readonly -a DOM0_IMMUTABLE_PREFIXES=('amd64-')
    readonly -a DOM0_ROLLING_TAGS=('amd64')
    ;;
  arm64)
    readonly KVM_ROLLING_TAG='arm64-kvm'
    readonly KVM_IMMUTABLE_PREFIX='arm64-kvm-'
    readonly -a DOM0_IMMUTABLE_PREFIXES=('arm64-' 'arm64-mac-')
    readonly -a DOM0_ROLLING_TAGS=('arm64' 'arm64-mac')
    ;;
  *)
    echo "usage: $0 [--verify-only] <amd64|arm64>" >&2
    exit 64
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $1" >&2
    exit 1
  }
}

for command_name in curl docker jq mktemp timeout; do
  require_command "$command_name"
done

: "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
: "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
[[ "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+:[0-9]+$ ]] || {
  echo "ERROR: invalid GitHub Actions run identity" >&2
  exit 64
}
case "$RUNNER_TEMP" in
  /*) ;;
  *) echo "ERROR: RUNNER_TEMP must be absolute" >&2; exit 64 ;;
esac
[ "$RUNNER_TEMP" != / ] && [ -d "$RUNNER_TEMP" ] || {
  echo "ERROR: RUNNER_TEMP must be an existing non-root directory" >&2
  exit 64
}

auth_dir="$(mktemp -d "${RUNNER_TEMP%/}/devshot-family-recovery-${family}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.XXXXXX")"
case "$auth_dir" in
  "${RUNNER_TEMP%/}"/devshot-family-recovery-"${family}"-"${GITHUB_RUN_ID}"-"${GITHUB_RUN_ATTEMPT}".*) ;;
  *) echo "ERROR: unsafe family-recovery authentication directory" >&2; exit 64 ;;
esac
chmod 0700 "$auth_dir"
matches_path="$auth_dir/kvm-tags.tsv"
touch "$matches_path"
chmod 0600 "$matches_path"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf -- "$auth_dir" || {
    echo "ERROR: could not remove isolated Docker credentials" >&2
    [ "$status" -ne 0 ] || status=1
  }
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

auth_docker() {
  local seconds="$1"
  shift
  env -u DOCKERHUB_TOKEN DOCKER_CONFIG="$auth_dir" \
    timeout --foreground --signal=TERM --kill-after=30s "${seconds}s" \
      docker --config "$auth_dir" "$@"
}

registry_digest() {
  local reference="$1" manifest digest
  manifest="$(auth_docker 180 buildx imagetools inspect "$reference" --format '{{json .Manifest}}')"
  digest="$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<< "$manifest")"
  printf '%s\n' "$digest"
}

registry_revision_or_legacy() {
  local reference="$1" image revision
  image="$(auth_docker 180 buildx imagetools inspect "$reference" --format '{{json .Image}}')"
  revision="$(jq -er '(.config.Labels // {})["org.opencontainers.image.revision"] // ""' <<< "$image")"
  if [ -z "$revision" ]; then
    printf '%s\n' legacy
  elif [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$revision"
  else
    echo "ERROR: KVM image has an invalid OCI source revision: $reference" >&2
    return 1
  fi
}

bounded_curl() {
  local url="$1"
  case "$url" in
    "$TAGS_API_PREFIX"*) ;;
    *)
      echo "ERROR: Docker Hub pagination escaped the trusted tags endpoint: $url" >&2
      return 1
      ;;
  esac
  [[ "$url" != *$'\n'* && "$url" != *$'\r'* ]] || {
    echo "ERROR: Docker Hub pagination URL contains control characters" >&2
    return 1
  }
  env -u DOCKERHUB_TOKEN timeout --foreground --signal=TERM --kill-after=10s 90s \
    curl --fail --silent --show-error --proto '=https' \
      --connect-timeout 15 --max-time 60 --max-filesize 5242880 \
      --retry 3 --retry-all-errors --retry-delay 2 \
      --header 'Accept: application/json' "$url"
}

find_legacy_committed_source_sha() {
  local committed_digest="$1" page=0 url response next pushed tag selected
  local candidate_count=0 source_sha exact_kvm_digest revision dom_digest alias_digest
  local rolling_dom0 rolling_mac unique_dom_count selected_dom
  local validated_path="$auth_dir/validated-kvm-tags.tsv"
  local tag_pattern="^${KVM_IMMUTABLE_PREFIX}[0-9a-f]{40}$"
  url="${TAGS_API_PREFIX}page_size=${TAG_PAGE_SIZE}&name=${KVM_IMMUTABLE_PREFIX}"
  : > "$matches_path"

  while [ -n "$url" ]; do
    page=$((page + 1))
    if [ "$page" -gt "$MAX_TAG_PAGES" ]; then
      echo "ERROR: Docker Hub tag lookup exceeded ${MAX_TAG_PAGES} bounded pages" >&2
      return 1
    fi
    response="$(bounded_curl "$url")"
    jq -e '
      type == "object"
      and (.results | type == "array")
      and (.next == null or (.next | type == "string"))
    ' >/dev/null <<< "$response" || {
      echo "ERROR: Docker Hub returned an invalid tags response" >&2
      return 1
    }
    jq -e --arg digest "$committed_digest" --arg pattern "$tag_pattern" '
      all(.results[];
        if ((.name | type) == "string"
            and (.digest | type) == "string"
            and .digest == $digest
            and (.name | test($pattern)))
        then ((.tag_last_pushed | type) == "string"
              and (.tag_last_pushed | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z$")))
        else true
        end)
    ' >/dev/null <<< "$response" || {
      echo "ERROR: matching Docker Hub immutable tags have invalid publication metadata" >&2
      return 1
    }
    while IFS=$'\t' read -r pushed tag; do
      [ -n "$pushed" ] && [ -n "$tag" ] || continue
      printf '%s\t%s\n' "$pushed" "$tag" >> "$matches_path"
    done < <(jq -r --arg digest "$committed_digest" --arg pattern "$tag_pattern" '
      .results[]
      | select((.name | type) == "string")
      | select((.digest | type) == "string")
      | select(.digest == $digest)
      | select(.name | test($pattern))
      | [.tag_last_pushed, .name]
      | @tsv
    ' <<< "$response")
    next="$(jq -r '.next // ""' <<< "$response")"
    if [ -n "$next" ]; then
      case "$next" in
        "$TAGS_API_PREFIX"*) ;;
        *)
          echo "ERROR: Docker Hub returned an untrusted pagination URL: $next" >&2
          return 1
          ;;
      esac
    fi
    url="$next"
  done

  [ -s "$matches_path" ] || {
    echo "ERROR: no immutable ${family} KVM tag matches rolling commit digest $committed_digest" >&2
    return 1
  }
  LC_ALL=C sort -t $'\t' -k1,1r -k2,2r -o "$matches_path" "$matches_path"
  : > "$validated_path"
  while IFS=$'\t' read -r pushed tag; do
    [ -n "$pushed" ] && [ -n "$tag" ] || continue
    candidate_count=$((candidate_count + 1))
    if [ "$candidate_count" -gt "$MAX_KVM_DIGEST_CANDIDATES" ]; then
      echo "ERROR: legacy KVM digest maps to more than ${MAX_KVM_DIGEST_CANDIDATES} immutable sources" >&2
      return 1
    fi
    [[ "$tag" =~ ^${KVM_IMMUTABLE_PREFIX}([0-9a-f]{40})$ ]] || {
      echo "ERROR: Docker Hub returned a malformed immutable KVM tag" >&2
      return 1
    }
    source_sha="${BASH_REMATCH[1]}"
    exact_kvm_digest="$(registry_digest "$REPOSITORY:$tag")"
    [ "$exact_kvm_digest" = "$committed_digest" ] || {
      echo "ERROR: immutable KVM tag changed after Docker Hub discovery: $tag" >&2
      return 1
    }
    revision="$(registry_revision_or_legacy "$REPOSITORY:$tag")"
    [ "$revision" = legacy ] || {
      echo "ERROR: labeled KVM candidate unexpectedly shares a legacy rolling digest: $tag" >&2
      return 1
    }

    dom_digest=''
    for prefix in "${DOM0_IMMUTABLE_PREFIXES[@]}"; do
      alias_digest="$(registry_digest "$REPOSITORY:${prefix}${source_sha}")"
      if [ -z "$dom_digest" ]; then
        dom_digest="$alias_digest"
      elif [ "$alias_digest" != "$dom_digest" ]; then
        echo "ERROR: immutable ${family} Dom0 aliases disagree for legacy KVM source $source_sha" >&2
        return 1
      fi
    done
    printf '%s\t%s\t%s\n' "$pushed" "$tag" "$dom_digest" >> "$validated_path"
  done < "$matches_path"

  unique_dom_count="$(cut -f3 "$validated_path" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')"
  if [ "$unique_dom_count" -eq 1 ]; then
    IFS= read -r selected < "$validated_path"
  else
    rolling_dom0="$(registry_digest "$REPOSITORY:${DOM0_ROLLING_TAGS[0]}")"
    if [ "$family" = arm64 ]; then
      rolling_mac="$(registry_digest "$REPOSITORY:${DOM0_ROLLING_TAGS[1]}")"
      [ "$rolling_mac" = "$rolling_dom0" ] || {
        echo "ERROR: ambiguous legacy KVM marker with mixed ARM64 Dom0 rolling aliases" >&2
        return 1
      }
    fi
    selected_dom="$(awk -F '\t' -v digest="$rolling_dom0" '$3 == digest { print; exit }' "$validated_path")"
    [ -n "$selected_dom" ] || {
      echo "ERROR: no legacy KVM source matches the committed rolling Dom0 family" >&2
      return 1
    }
    selected="$selected_dom"
  fi
  tag="${selected#*$'\t'}"
  tag="${tag%%$'\t'*}"
  [[ "$tag" =~ ^${KVM_IMMUTABLE_PREFIX}([0-9a-f]{40})$ ]] || {
    echo "ERROR: selected Docker Hub tag is not an exact immutable KVM tag" >&2
    return 1
  }
  printf '%s\n' "${BASH_REMATCH[1]}"
}

create_dom0_tag() {
  local target="$1" digest="$2" attempt
  for attempt in 1 2; do
    if auth_docker 600 buildx imagetools create --prefer-index=false \
        --tag "$target" "$REPOSITORY@$digest"; then
      return 0
    fi
    [ "$attempt" -eq 2 ] || echo "Retrying bounded rolling-tag repair: $target" >&2
  done
  echo "ERROR: rolling-tag repair failed twice: $target" >&2
  return 1
}

printf '%s' "$DOCKERHUB_TOKEN" \
  | env -u DOCKERHUB_TOKEN DOCKER_CONFIG="$auth_dir" \
      timeout --foreground --signal=TERM --kill-after=15s 120s \
        docker --config "$auth_dir" login \
          --username "$DOCKERHUB_USERNAME" --password-stdin

kvm_rolling_ref="$REPOSITORY:$KVM_ROLLING_TAG"
repaired=0
recovery_complete=0
source_sha=''
dom0_digest=''
kvm_commit_digest=''

# Registry tags do not offer an atomic multi-tag compare-and-swap. Treat a KVM
# marker change as an optimistic-transaction conflict: stop using the stale
# family immediately and resolve every alias again from the new marker. The
# marker is checked before and after every mutable Dom0 operation, then brackets
# a final read of all aliases. This also repairs an ARM64 attempt that updated
# only the first Dom0 alias before a concurrent publisher committed a new KVM.
for ((recovery_attempt = 1; recovery_attempt <= MAX_RECOVERY_ATTEMPTS; recovery_attempt += 1)); do
  marker_changed=0
  kvm_commit_digest="$(registry_digest "$kvm_rolling_ref")"
  kvm_commit_revision="$(registry_revision_or_legacy "$kvm_rolling_ref")"
  if [ "$kvm_commit_revision" = legacy ]; then
    source_sha="$(find_legacy_committed_source_sha "$kvm_commit_digest")"
  else
    source_sha="$kvm_commit_revision"
  fi
  kvm_immutable_ref="$REPOSITORY:${KVM_IMMUTABLE_PREFIX}${source_sha}"
  kvm_immutable_digest="$(registry_digest "$kvm_immutable_ref")"
  [ "$kvm_immutable_digest" = "$kvm_commit_digest" ] || {
    echo "ERROR: immutable KVM tag no longer matches the rolling commit marker" >&2
    exit 1
  }
  kvm_immutable_revision="$(registry_revision_or_legacy "$kvm_immutable_ref")"
  if [ "$kvm_commit_revision" = legacy ]; then
    [ "$kvm_immutable_revision" = legacy ] || {
      echo "ERROR: legacy rolling KVM marker selected a labeled immutable source" >&2
      exit 1
    }
  elif [ "$kvm_immutable_revision" != "$source_sha" ]; then
    echo "ERROR: immutable KVM revision does not match its source tag suffix" >&2
    exit 1
  fi

  dom0_digest=''
  for prefix in "${DOM0_IMMUTABLE_PREFIXES[@]}"; do
    immutable_ref="$REPOSITORY:${prefix}${source_sha}"
    immutable_digest="$(registry_digest "$immutable_ref")"
    if [ -z "$dom0_digest" ]; then
      dom0_digest="$immutable_digest"
    elif [ "$immutable_digest" != "$dom0_digest" ]; then
      echo "ERROR: immutable ${family} Dom0 aliases disagree for committed SHA $source_sha" >&2
      exit 1
    fi
  done

  if [ "$(registry_digest "$kvm_rolling_ref")" != "$kvm_commit_digest" ]; then
    marker_changed=1
  fi

  if [ "$marker_changed" -eq 0 ]; then
    for tag in "${DOM0_ROLLING_TAGS[@]}"; do
      # Do not start or continue a stale-family write after observing a newer
      # KVM commit. A change immediately after a successful first ARM64 alias
      # is caught here before the second alias is touched.
      if [ "$(registry_digest "$kvm_rolling_ref")" != "$kvm_commit_digest" ]; then
        marker_changed=1
        break
      fi
      rolling_ref="$REPOSITORY:$tag"
      rolling_digest="$(registry_digest "$rolling_ref")"
      if [ "$rolling_digest" != "$dom0_digest" ]; then
        if [ "$verify_only" -eq 1 ]; then
          if [ "$(registry_digest "$kvm_rolling_ref")" != "$kvm_commit_digest" ]; then
            marker_changed=1
            break
          fi
          echo "ERROR: ${family} rolling family is not coherent at committed SHA $source_sha" >&2
          exit 1
        else
          create_dom0_tag "$rolling_ref" "$dom0_digest"
          repaired=1
        fi
      fi
      if [ "$(registry_digest "$kvm_rolling_ref")" != "$kvm_commit_digest" ]; then
        marker_changed=1
        break
      fi
    done
  fi

  if [ "$marker_changed" -eq 0 ]; then
    # Stable-snapshot verification: KVM is read before and after every Dom0
    # alias. A concurrent alias writer or marker commit restarts the complete
    # family resolution instead of returning with a mixed rolling family.
    for tag in "${DOM0_ROLLING_TAGS[@]}"; do
      if [ "$(registry_digest "$kvm_rolling_ref")" != "$kvm_commit_digest" ]; then
        marker_changed=1
        break
      fi
      actual="$(registry_digest "$REPOSITORY:$tag")"
      if [ "$actual" != "$dom0_digest" ]; then
        marker_changed=1
        break
      fi
      if [ "$(registry_digest "$kvm_rolling_ref")" != "$kvm_commit_digest" ]; then
        marker_changed=1
        break
      fi
    done
  fi

  if [ "$marker_changed" -eq 0 ] \
      && [ "$(registry_digest "$kvm_rolling_ref")" = "$kvm_commit_digest" ]; then
    recovery_complete=1
    break
  fi

  echo "KVM commit marker changed during ${family} recovery; retrying the complete family (${recovery_attempt}/${MAX_RECOVERY_ATTEMPTS})" >&2
done

[ "$recovery_complete" -eq 1 ] || {
  echo "ERROR: ${family} KVM commit marker did not stabilize after ${MAX_RECOVERY_ATTEMPTS} recovery attempts" >&2
  exit 1
}

if [ "$repaired" -eq 1 ]; then
  echo "Recovered ${family} rolling Dom0 aliases to committed SHA $source_sha (dom0=$dom0_digest kvm=$kvm_commit_digest)"
else
  echo "Verified consistent ${family} rolling family at committed SHA $source_sha (dom0=$dom0_digest kvm=$kvm_commit_digest)"
fi
