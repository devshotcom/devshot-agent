#!/bin/sh
# DevShot Orchestrator Installer.
#
#   curl -fsSL https://devshot.com/install.sh | sh
#
# This is the Tailscale-style entry point: it makes Docker available,
# drops a `devshot` CLI into /usr/local/bin, and exits. It does NOT
# register the host with the control plane — that's a separate step:
#
#   sudo devshot up --auth-key=ds_<your-orchestrator-key>
#
# The auth key is an orchestrator-mode API key (Settings → API Keys
# in console.devshot.com). `devshot up` POSTs it to /api/install/bootstrap,
# receives a fresh per-server HMAC secret, and starts the container.
#
# Re-running this script is idempotent: it only installs what's missing.
# Re-running `devshot up` registers a brand-new server (so don't do that
# unless you mean it). Use `devshot down` / `devshot logs` for routine
# operations.
#
# Env overrides (all optional):
#   DEVSHOT_BIN_DIR       Where to install the CLI (default: /usr/local/bin)
#   DEVSHOT_API_BASE      Override the console URL the CLI bootstraps
#                         against (default: https://console.devshot.com)

set -eu

DEVSHOT_BIN_DIR="${DEVSHOT_BIN_DIR:-/usr/local/bin}"
DEVSHOT_API_BASE="${DEVSHOT_API_BASE:-https://console.devshot.com}"
DEVSHOT_VERSION="${DEVSHOT_VERSION:-latest}"

# ── Output helpers (no colors when stdout isn't a TTY) ──────────────────
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

# ── Need-root: every step the installer takes (apt-get / chown of
#    /usr/local/bin / docker daemon install) needs root. We ask once
#    upfront and re-use cached sudo for the rest of the run.
need_root() {
  if [ "$(id -u)" -eq 0 ]; then SUDO=""; return; fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    sudo -v || fatal "sudo is required to install Docker and the devshot CLI"
    return
  fi
  fatal "must run as root or with sudo available"
}

# ── Detect platform ─────────────────────────────────────────────────────
detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  case "$OS" in
    Linux)
      PLATFORM="linux"
      if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM="wsl"; fi
      ;;
    Darwin)   PLATFORM="mac" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *) fatal "unsupported OS: $OS" ;;
  esac
  case "$ARCH" in
    x86_64|amd64) ARCH_NORM="amd64" ;;
    aarch64|arm64) ARCH_NORM="arm64" ;;
    *) fatal "unsupported architecture: $ARCH" ;;
  esac
}

# ── Install Docker (Linux + WSL only — Mac users handle Docker
#    themselves via Docker Desktop or Colima; we just verify presence).
ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker present ($(docker --version 2>/dev/null | head -1))"
    return
  fi
  case "$PLATFORM" in
    linux|wsl)
      info "Installing Docker via the official get.docker.com script…"
      # Download-then-run rather than piping curl straight into a root shell
      # (audit #18): this lets us reject a truncated transfer or a captive-
      # portal HTML page before executing anything as root.
      docker_script="$(mktemp)"
      if ! curl -fsSL https://get.docker.com -o "$docker_script"; then
        rm -f "$docker_script"; fatal "failed to download the Docker install script"
      fi
      if [ ! -s "$docker_script" ] || ! head -c2 "$docker_script" | grep -q '#!'; then
        rm -f "$docker_script"; fatal "Docker install script looks invalid (empty or not a script) — aborting"
      fi
      $SUDO sh "$docker_script"
      rm -f "$docker_script"
      if ! id -nG "$(id -un)" 2>/dev/null | grep -qw docker; then
        $SUDO usermod -aG docker "$(id -un)" || true
        warn "Added $(id -un) to docker group — log out and back in, or run 'newgrp docker'"
      fi
      ;;
    mac)
      fatal "Docker not found. Install Docker Desktop or Colima first: https://www.docker.com/products/docker-desktop"
      ;;
    windows)
      cat >&2 <<EOF
DevShot on Windows requires WSL2:
  1. Open PowerShell as Administrator
  2. wsl --install -d Ubuntu
  3. Reboot, then re-run this script inside WSL2
EOF
      exit 1
      ;;
  esac
}

# ── Check /dev/kvm so we can warn early if the host can't run KVM
#    images. We still install the CLI either way — a TCG-only host can
#    still run, just slower.
check_kvm() {
  if [ "$PLATFORM" = "linux" ] || [ "$PLATFORM" = "wsl" ]; then
    if [ -e /dev/kvm ]; then
      ok "/dev/kvm available — hardware acceleration enabled"
    else
      warn "/dev/kvm not present — VMs will run under TCG (slower)"
      warn "  ensure your CPU supports VT-x / AMD-V and the kvm kernel module is loaded"
    fi
  fi
}

# ── Install the devshot CLI to $DEVSHOT_BIN_DIR ────────────────────────
install_cli() {
  if [ ! -d "$DEVSHOT_BIN_DIR" ]; then
    $SUDO mkdir -p "$DEVSHOT_BIN_DIR"
  fi
  CLI_PATH="$DEVSHOT_BIN_DIR/devshot"
  info "Installing CLI to $CLI_PATH"

  # The CLI is a small POSIX shell script. We embed it inline rather
  # than fetching a separate file so the curl|sh flow is one network
  # round-trip and won't half-install on a flaky link.
  TMP_CLI="$(mktemp)"
  fetch_cli "$TMP_CLI"
  $SUDO install -m 0755 "$TMP_CLI" "$CLI_PATH"
  rm -f "$TMP_CLI"
  ok "Installed: $CLI_PATH"
}

# ── Compute the sha256 of a file, portably (sha256sum or shasum -a 256).
#    Prints the hex digest, or empty if no tool is available.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf ''
  fi
}

# ── Verify the integrity of a freshly-downloaded CLI before we install and
#    run it as root (audit #18). The trust model is otherwise TLS-only, so a
#    compromised origin / on-path proxy could ship a malicious script. Two
#    ways to verify, strongest first:
#      1. DEVSHOT_CLI_SHA256=<hex>  — pin from the install docs (hard fail).
#      2. <cli_url>.sha256 sidecar  — published next to the CLI (hard fail).
#    If neither is available we warn and proceed (TLS-only) so existing
#    installs keep working until the sidecar is published.
verify_cli_integrity() {
  file="$1"; url="$2"
  actual="$(sha256_of "$file")"
  if [ -z "$actual" ]; then
    warn "no sha256 tool (sha256sum/shasum) found — cannot verify CLI integrity"
    return 0
  fi
  if [ -n "${DEVSHOT_CLI_SHA256:-}" ]; then
    if [ "$actual" != "$DEVSHOT_CLI_SHA256" ]; then
      fatal "CLI integrity check FAILED — expected $DEVSHOT_CLI_SHA256, got $actual. Refusing to install."
    fi
    ok "CLI integrity verified against pinned DEVSHOT_CLI_SHA256"
    return 0
  fi
  expected="$(curl -fsSL "${url}.sha256" 2>/dev/null | awk '{print $1; exit}')"
  if [ -n "$expected" ]; then
    if [ "$actual" != "$expected" ]; then
      fatal "CLI integrity check FAILED against ${url}.sha256 — expected $expected, got $actual. Refusing to install."
    fi
    ok "CLI integrity verified against published sha256 sidecar"
    return 0
  fi
  warn "CLI integrity: no pin or .sha256 sidecar available — proceeding on TLS trust only."
  warn "  To enforce, re-run with DEVSHOT_CLI_SHA256=<sha256-from-docs>."
}

# ── Fetch the CLI script. If we're being run via curl|sh, the same
#    domain serves /devshot. Local invocation falls back to the sibling
#    devshot.sh in this repo.
fetch_cli() {
  out="$1"
  # 1. Local development: prefer the on-disk copy if present.
  src_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
  if [ -n "$src_dir" ] && [ -f "$src_dir/devshot.sh" ]; then
    cp "$src_dir/devshot.sh" "$out"
    return
  fi
  # 2. Production: pull from the same origin that served install.sh.
  cli_url="${DEVSHOT_CLI_URL:-${DEVSHOT_API_BASE%/}/devshot.sh}"
  info "Downloading CLI from $cli_url"
  if ! curl -fsSL "$cli_url" -o "$out"; then
    fatal "failed to fetch CLI from $cli_url"
  fi
  # Verify BEFORE the caller installs it 0755 and root-runs it.
  verify_cli_integrity "$out" "$cli_url"
}

# ── Print the next-steps banner ─────────────────────────────────────────
print_next_steps() {
  cat <<EOF

${C_BOLD}DevShot orchestrator installed.${C_NC}

Register this host with your account:

    ${C_CYAN}sudo devshot up --auth-key=ds_<your-orchestrator-api-key>${C_NC}

Get a key from ${C_BOLD}${DEVSHOT_API_BASE}${C_NC} → Settings → API Keys
(use mode "orchestrator").

Other commands:
    devshot status        show daemon status
    devshot logs -f       tail orchestrator logs
    devshot down          stop the orchestrator
    devshot update        pull the latest image
    devshot version       print versions

EOF
}

main() {
  detect_platform
  need_root
  ensure_docker
  check_kvm
  install_cli
  print_next_steps
}

main "$@"
