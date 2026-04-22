#!/bin/bash
# DevShot Orchestrator Installer — Mac (Colima), Linux (Docker + KVM), Windows (WSL2)
# Detects platform, installs dependencies, pulls/builds the right Docker image, and starts the orchestrator.
#
# Usage:
#   curl -fsSL https://devshot.com/install.sh | bash
#   # or
#   make install
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
fatal() { err "$*"; exit 1; }

# ── Detect platform ─────────────────────────────────────────────────────────

detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Darwin)
      PLATFORM="mac"
      if [ "$ARCH" = "arm64" ]; then
        DOCKER_ARCH="arm64"
        IMAGE_TAG="arm64-mac"
      else
        DOCKER_ARCH="amd64"
        IMAGE_TAG="amd64"
      fi
      ;;
    Linux)
      PLATFORM="linux"
      if grep -qi microsoft /proc/version 2>/dev/null; then
        PLATFORM="wsl"
      fi
      if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
        DOCKER_ARCH="amd64"
        IMAGE_TAG="amd64-kvm"
      elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        DOCKER_ARCH="arm64"
        IMAGE_TAG="arm64-kvm"
      else
        fatal "Unsupported architecture: $ARCH"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      PLATFORM="windows"
      DOCKER_ARCH="amd64"
      IMAGE_TAG="amd64-kvm"
      ;;
    *)
      fatal "Unsupported OS: $OS"
      ;;
  esac

  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  DevShot Orchestrator Installer"
  echo "════════════════════════════════════════════════════════"
  echo "  Platform:     $PLATFORM ($ARCH)"
  echo "  Docker arch:  $DOCKER_ARCH"
  echo "  Image:        anticipatercom/devshot:$IMAGE_TAG"
  echo "════════════════════════════════════════════════════════"
  echo ""
}

# ── Mac: install via Colima ──────────────────────────────────────────────────

install_mac() {
  info "Mac detected — using Colima for Docker runtime"

  # Check Homebrew
  if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  ok "Homebrew installed"

  # Install Docker CLI + Colima
  if ! command -v docker &>/dev/null; then
    info "Installing Docker CLI..."
    brew install docker
  fi
  ok "Docker CLI installed"

  if ! command -v colima &>/dev/null; then
    info "Installing Colima..."
    brew install colima
  fi
  ok "Colima installed"

  # Start Colima with x86_64 (Rosetta) for KVM-ready x86 Xen.
  # Note: Colima runs an x86_64 Linux VM — even on Apple Silicon — so we
  # always pull the :amd64 tag here. (The console paste path uses Docker
  # Desktop on Apple Silicon instead, which pulls :arm64-mac.)
  if ! colima status &>/dev/null; then
    info "Starting Colima (x86_64 via Rosetta)..."
    if [ "$ARCH" = "arm64" ]; then
      # Apple Silicon: use x86_64 with Rosetta for x86 Xen image
      colima start \
        --arch x86_64 \
        --vm-type vz \
        --vz-rosetta \
        --mount-type virtiofs \
        --cpu 4 \
        --memory 8 \
        --disk 60
    else
      # Intel Mac
      colima start \
        --cpu 4 \
        --memory 8 \
        --disk 60
    fi
  fi
  IMAGE_TAG="amd64"
  ok "Colima running"

  # Check KVM inside Colima
  if docker run --rm --privileged alpine sh -c '[ -w /dev/kvm ]' 2>/dev/null; then
    ok "KVM available inside Colima"
    KVM_FLAG="--device /dev/kvm"
  else
    warn "No KVM inside Colima — the Xen image will not boot reliably"
    KVM_FLAG=""
  fi
}

# ── Linux: native Docker + KVM ──────────────────────────────────────────────

install_linux() {
  info "Linux detected — using native Docker + KVM"

  # Install Docker if missing
  if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group — you may need to log out and back in"
  fi
  ok "Docker installed"

  # Check KVM
  if [ -w /dev/kvm ] || sudo test -w /dev/kvm 2>/dev/null; then
    ok "KVM available — hardware acceleration enabled"
    KVM_FLAG="--device /dev/kvm"

    # Ensure current user can access /dev/kvm
    if [ ! -w /dev/kvm ]; then
      info "Adding $USER to kvm group..."
      sudo usermod -aG kvm "$USER"
      warn "You may need to log out and back in for kvm group access"
    fi
  else
    warn "No KVM — loading kvm module..."
    sudo modprobe kvm 2>/dev/null || true
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

    if [ -e /dev/kvm ]; then
      ok "KVM module loaded"
      KVM_FLAG="--device /dev/kvm"
    else
      warn "KVM not available — will use the direct QEMU backend under TCG (slower)"
      warn "For hardware acceleration, ensure your CPU supports VT-x/AMD-V"
      KVM_FLAG=""
    fi
  fi
}

# ── Windows (WSL2) ──────────────────────────────────────────────────────────

install_wsl() {
  info "WSL2 detected — using Docker inside WSL"

  # Check if Docker Desktop is providing the daemon
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    ok "Docker available (via Docker Desktop or WSL2 daemon)"
  else
    info "Installing Docker inside WSL2..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    sudo service docker start
  fi
  ok "Docker ready"

  # WSL2 with Hyper-V can expose /dev/kvm
  if [ -w /dev/kvm ]; then
    ok "KVM available in WSL2"
    KVM_FLAG="--device /dev/kvm"
  else
    # Try loading KVM modules (works on some WSL2 kernel builds)
    sudo modprobe kvm 2>/dev/null || true
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

    if [ -e /dev/kvm ]; then
      ok "KVM module loaded"
      KVM_FLAG="--device /dev/kvm"
    else
      warn "No KVM in WSL2 — will use the direct QEMU backend under TCG (slower)"
      warn "For KVM in WSL2, you need a custom kernel with CONFIG_KVM=y"
      KVM_FLAG=""
    fi
  fi

  IMAGE_TAG="amd64-kvm"
}

# ── Windows (native) ────────────────────────────────────────────────────────

install_windows() {
  info "Windows detected"
  echo ""
  echo "  DevShot requires WSL2 on Windows."
  echo ""
  echo "  Install steps:"
  echo "    1. Open PowerShell as Administrator"
  echo "    2. Run: wsl --install -d Ubuntu"
  echo "    3. Reboot"
  echo "    4. Open Ubuntu from Start menu"
  echo "    5. Run this installer again inside WSL2"
  echo ""
  fatal "Please install WSL2 first, then run this script inside WSL."
}

# ── Pull or build image ─────────────────────────────────────────────────────

pull_image() {
  local image="anticipatercom/devshot:${IMAGE_TAG}"

  info "Pulling Docker image: ${image}..."
  if docker pull "$image" 2>/dev/null; then
    ok "Image pulled: ${image}"
  else
    warn "Could not pull image — building locally..."
    info "This will take a while (compiling Xen + kernel)..."

    if [ -f "$(dirname "$0")/build.yml" ]; then
      cd "$(dirname "$0")/.."
      make build
    else
      fatal "Cannot build locally — no source tree found. Please pull the image manually."
    fi
  fi
}

# ── Configure and start orchestrator ────────────────────────────────────────────────

configure_orchestrator() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "  Configure your DevShot Orchestrator"
  echo "════════════════════════════════════════════════════════"
  echo ""

  if [ -z "${DEVSHOT_SERVER_ID:-}" ]; then
    read -rp "  Server ID (from console.devshot.com):  " DEVSHOT_SERVER_ID
  fi
  if [ -z "${DEVSHOT_HMAC_SECRET:-}" ]; then
    read -rp "  HMAC Secret (from console.devshot.com): " DEVSHOT_HMAC_SECRET
  fi
  DEVSHOT_TUNNEL_URL="${DEVSHOT_TUNNEL_URL:-wss://console.devshot.com}"

  if [ -z "$DEVSHOT_SERVER_ID" ] || [ -z "$DEVSHOT_HMAC_SECRET" ]; then
    fatal "Server ID and HMAC Secret are required. Get them from console.devshot.com"
  fi
}

start_orchestrator() {
  local image="anticipatercom/devshot:${IMAGE_TAG}"
  local container_name="devshot-orchestrator"

  # Stop existing container
  docker rm -f "$container_name" 2>/dev/null || true

  info "Starting DevShot Orchestrator..."
  docker run -d \
    --name "$container_name" \
    --privileged $KVM_FLAG \
    --restart=unless-stopped \
    -e DEVSHOT_SERVER_ID="$DEVSHOT_SERVER_ID" \
    -e DEVSHOT_HMAC_SECRET="$DEVSHOT_HMAC_SECRET" \
    -e DEVSHOT_TUNNEL_URL="$DEVSHOT_TUNNEL_URL" \
    "$image"

  echo ""
  echo "════════════════════════════════════════════════════════"
  ok "DevShot Orchestrator is running!"
  echo ""
  echo "  Container:  $container_name"
  echo "  Image:      $image"
  echo "  Server ID:  $DEVSHOT_SERVER_ID"
  echo "  KVM:        $([ -n '$KVM_FLAG' ] && echo 'enabled' || echo 'disabled (TCG)')"
  echo ""
  echo "  Commands:"
  echo "    docker logs -f $container_name    # View logs"
  echo "    docker stop $container_name       # Stop orchestrator"
  echo "    docker start $container_name      # Start orchestrator"
  echo "    docker rm -f $container_name      # Remove orchestrator"
  echo "════════════════════════════════════════════════════════"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  KVM_FLAG=""

  detect_platform

  case "$PLATFORM" in
    mac)      install_mac ;;
    linux)    install_linux ;;
    wsl)      install_wsl ;;
    windows)  install_windows ;;
  esac

  pull_image
  configure_orchestrator
  start_orchestrator
}

main "$@"
