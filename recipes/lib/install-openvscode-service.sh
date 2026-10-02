#!/bin/sh
# Install the one openvscode-server OpenRC service every editor image uses
# (blank, expo, cordis, studio, lamp core).
#
# Usage:
#   install-openvscode-service.sh --default-folder <dir>
#                                 [--after "<service...>"]
#                                 [--max-old-space-mb <n>]
#
# The editor listens on 0.0.0.0:8080 because the dom0 forward dials
# vm.IP:<port>, so it must never run without a connection token: start_pre
# (root, every boot) writes 32 random bytes as 64 lowercase hex to
# /run/openvscode-server/connection-token, owned by devshot and mode 0400.
# /run is tmpfs, so no template (not even one baked from a booted VM) ever
# carries a token, and every pool VM is closed from its first boot. The
# console reads the file over vm-exec (as devshot) at claim time; the literal
# `--connection-token-file /run/openvscode-server/connection-token` in the
# generated script is how it tells a tokened image from a legacy one.
#
# DESTDIR (empty in a bake) prefixes every path this script writes.
set -eu

usage_error() {
  echo "ERROR: $*" >&2
  exit 2
}

DEFAULT_FOLDER=""
AFTER=""
MAX_OLD_SPACE_MB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --default-folder|--after|--max-old-space-mb) [ "$#" -ge 2 ] || usage_error "$1 needs a value" ;;
    *) usage_error "unknown argument: $1" ;;
  esac
  case "$1" in
    --default-folder)
      # The folder lands unquoted in command_args: one plain absolute word.
      case "$2" in
        /*) ;;
        *) usage_error "--default-folder must be an absolute path: $2" ;;
      esac
      case "$2" in
        *[!A-Za-z0-9._/-]*) usage_error "--default-folder has unsupported characters: $2" ;;
      esac
      DEFAULT_FOLDER="$2"
      ;;
    --after)
      case "$2" in
        ''|*[!A-Za-z0-9._\ -]*) usage_error "--after takes space-separated OpenRC service names: $2" ;;
      esac
      AFTER="$2"
      ;;
    --max-old-space-mb)
      case "$2" in
        ''|*[!0-9]*|0*) usage_error "--max-old-space-mb must be a positive integer: $2" ;;
      esac
      MAX_OLD_SPACE_MB="$2"
      ;;
  esac
  shift 2
done
[ -n "$DEFAULT_FOLDER" ] || usage_error "--default-folder is required"

INIT_SCRIPT="${DESTDIR:-}/etc/init.d/openvscode-server"
install -d "${DESTDIR:-}/etc/init.d"

# lamp variants overwrite this file per app (_app_lib.sh set_editor_workspace);
# the service reads it on every start.
printf '%s\n' "$DEFAULT_FOLDER" > "${DESTDIR:-}/etc/openvscode-default-folder"

{
  cat <<'HEAD'
#!/sbin/openrc-run
# Written by /usr/local/libexec/devshot/install-openvscode-service.sh.

name="openvscode-server"
description="VSCode in the browser (openvscode-server) — DevShot editor"
HEAD
  if [ -n "$MAX_OLD_SPACE_MB" ]; then
    printf 'export NODE_OPTIONS="--max-old-space-size=%s"\n' "$MAX_OLD_SPACE_MB"
  fi
  cat <<'BODY'
TOKEN_DIR=/run/openvscode-server
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder)"
command="/usr/bin/node"
command_args="/opt/openvscode-server/out/server-main.js \
  --host 0.0.0.0 --port 8080 \
  --connection-token-file /run/openvscode-server/connection-token \
  --disable-telemetry --disable-workspace-trust \
  --user-data-dir /home/devshot/.openvscode-server/data \
  --server-data-dir /home/devshot/.openvscode-server \
  --default-folder $DEFAULT_FOLDER"
command_user="devshot:devshot"
command_background=true
pidfile="/run/openvscode-server.pid"
output_log="/var/log/openvscode-server.log"
error_log="/var/log/openvscode-server.log"

depend() {
	need net
BODY
  printf '\tafter firewall%s\n}\n' "${AFTER:+ $AFTER}"
  cat <<'TOKEN'

connection_token_valid() {
	[ -f "$TOKEN_DIR/connection-token" ] && [ ! -L "$TOKEN_DIR/connection-token" ] || return 1
	token=$(cat "$TOKEN_DIR/connection-token") || return 1
	[ "${#token}" -eq 64 ] || return 1
	case "$token" in
		*[!0-9a-f]*) return 1 ;;
	esac
}

# Keep a valid token for the whole boot; mint one when it is missing, empty or
# malformed. The new token is written in root-owned ${TOKEN_DIR%/*} (devshot
# owns TOKEN_DIR and could otherwise swap the temp path for a symlink), then
# renamed into place, so openvscode never reads a partial file.
#
# openvscode prints its entry URL, token included (`Web UI available at
# http://localhost:8080/?tkn=<token>`), on every start, so its log is as secret
# as the token file: devshot-only. checkpath re-applies the mode each boot, so
# a log left by an older image or a bake boot is closed too.
start_pre() {
	checkpath -f -o devshot:devshot -m 0600 "$output_log" || return 1
	checkpath -d -o devshot:devshot -m 0700 "$TOKEN_DIR" || return 1
	connection_token_valid && return 0
	tmp=$(mktemp "${TOKEN_DIR%/*}/.openvscode-connection-token.XXXXXX") || return 1
	if od -An -vtx1 -N32 /dev/urandom | tr -d ' \n' > "$tmp" \
		&& chmod 0400 "$tmp" \
		&& chown devshot:devshot "$tmp" \
		&& mv -f "$tmp" "$TOKEN_DIR/connection-token" \
		&& connection_token_valid; then
		return 0
	fi
	rm -f "$tmp"
	eerror "openvscode-server: could not write $TOKEN_DIR/connection-token"
	return 1
}
TOKEN
} > "$INIT_SCRIPT"
chmod 0755 "$INIT_SCRIPT"
sh -n "$INIT_SCRIPT"

rc-update add openvscode-server default
