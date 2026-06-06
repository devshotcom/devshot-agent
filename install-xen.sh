#!/bin/sh
# DevShot native Xen installer.
#
#   curl -fsSL https://console.devshot.com/install-xen.sh | sh
#
# Docker-free entry point for bare-metal Linux x86_64 hosts. It installs the
# same `devshot` CLI as install.sh, but deliberately does not install or require
# Docker. The native Xen setup happens in:
#
#   sudo devshot up --auth-key=ds_<key> --target=linux-amd64-xen-baremetal

set -eu

DEVSHOT_BIN_DIR="${DEVSHOT_BIN_DIR:-/usr/local/bin}"
DEVSHOT_API_BASE="${DEVSHOT_API_BASE:-https://console.devshot.com}"

if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
  C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_NC=''
fi
info()  { printf "${C_CYAN}info${C_NC}  %s\n" "$*"; }
ok()    { printf "${C_GREEN}ok${C_NC}    %s\n" "$*"; }
warn()  { printf "${C_YELLOW}warn${C_NC}  %s\n" "$*"; }
fatal() { printf "${C_RED}error${C_NC} %s\n" "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -eq 0 ]; then SUDO=""; return; fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    sudo -v || fatal "sudo is required to install the devshot CLI"
    return
  fi
  fatal "must run as root or with sudo available"
}

detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  [ "$OS" = "Linux" ] || fatal "native Xen install requires Linux (got $OS)"
  case "$ARCH" in
    x86_64|amd64) ;;
    *) fatal "native Xen install currently supports x86_64/amd64 only (got $ARCH)" ;;
  esac
  if ! command -v systemctl >/dev/null 2>&1; then
    fatal "native Xen install requires systemd/systemctl"
  fi
}

install_cli() {
  [ -d "$DEVSHOT_BIN_DIR" ] || $SUDO mkdir -p "$DEVSHOT_BIN_DIR"
  CLI_PATH="$DEVSHOT_BIN_DIR/devshot"
  TMP_CLI="$(mktemp)"
  src_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  if [ -n "$src_dir" ] && [ -f "$src_dir/devshot.sh" ]; then
    cp "$src_dir/devshot.sh" "$TMP_CLI"
  else
    cli_url="${DEVSHOT_CLI_URL:-${DEVSHOT_API_BASE%/}/devshot.sh}"
    info "Downloading CLI from $cli_url"
    curl -fsSL "$cli_url" -o "$TMP_CLI" || fatal "failed to fetch CLI from $cli_url"
  fi
  $SUDO install -m 0755 "$TMP_CLI" "$CLI_PATH"
  rm -f "$TMP_CLI"
  ok "Installed: $CLI_PATH"
}

print_next_steps() {
  cat <<EOF

${C_BOLD}DevShot native Xen CLI installed.${C_NC}

Register and configure this bare-metal host:

    ${C_CYAN}sudo devshot up --auth-key=ds_<your-orchestrator-api-key> --target=linux-amd64-xen-baremetal${C_NC}

This path installs Xen packages, extracts DevShot artifacts without Docker,
creates systemd services, and starts the agent after the host is booted into Xen.

EOF
}

main() {
  detect_platform
  need_root
  warn "This installer intentionally does not install Docker."
  install_cli
  print_next_steps
}

main "$@"
