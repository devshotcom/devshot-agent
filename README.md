# DevShot Agent

Pre-built orchestrator images and Go agent binaries for DevShot.

This repo is **auto-generated** on every push to
[devshotcom/devshot](https://github.com/devshotcom/devshot)'s `main`
branch. Do not edit files here directly — they will be overwritten.
The Docker images published to Docker Hub (`anticipatercom/devshot:*`)
are built from this repo by `.github/workflows/build-images.yml`
on Docker Build Cloud.

Release policy: create `v*` tags from `main` only. CI rejects
release tags whose commit is not reachable from `origin/main`.

## Quick Install

```bash
curl -fsSL https://devshot.com/install.sh | bash
```

Or grab a copy-paste `docker run` from
[console.devshot.com](https://console.devshot.com) → **Servers** →
**Add Server** — it selects the right image for your host.

## Docker Images

Published to Docker Hub by `.github/workflows/build-images.yml` on every push.

### Dom0 orchestrator (multi-VM, full Xen hypervisor)

Single privileged container that runs Xen and spawns guest VMs
on demand. Use this for `server_type: 'multi'` servers.

| Tag | Platform | KVM | Source Dockerfile |
|---|---|---|---|
| `anticipatercom/devshot:amd64` | Linux x86_64 Xen orchestrator (legacy) | required (`--device /dev/kvm`) | `docker/Dockerfile.dom0-x86` |
| `anticipatercom/devshot:arm64` | Linux ARM64 Xen orchestrator (legacy) | required (`--device /dev/kvm`) | `docker/Dockerfile.dom0-arm` |
| `anticipatercom/devshot:arm64-mac` | Apple Silicon via Docker Desktop | not used (TCG software emulation) | `docker/Dockerfile.dom0-arm` |
| `anticipatercom/devshot:amd64-kvm` | Linux x86_64 direct QEMU backend | optional (`/dev/kvm` enables acceleration) | `docker/Dockerfile.vmm-qemu-x86` |
| `anticipatercom/devshot:arm64-kvm` | Linux ARM64 direct QEMU backend | optional (`/dev/kvm` enables acceleration) | `docker/Dockerfile.vmm-qemu-arm` |

### DomU standalone (single-VM, no Xen)

Lightweight container running just the Go DomU agent. Use this
for `server_type: 'single'` servers — one VM, direct tunnel,
no hypervisor. Both images ship as a single multi-arch manifest
covering `linux/amd64` and `linux/arm64`.

| Tag | Contents | Source Dockerfile |
|---|---|---|
| `anticipatercom/devshot_domu:latest` | Alpine + Go agent, terminal only | `docker/Dockerfile.domU` |
| `anticipatercom/devshot_desktop:latest` | Alpine + Go agent + Openbox + tigervnc + noVNC (port 6080) | `docker/Dockerfile.domU-desktop` |

Every build also publishes an immutable `<tag>-<sha>` tag
(e.g. `amd64-1a2b3c4d` for dom0, or `<sha>` on the domU repos)
so you can pin a specific commit.

### Pull

```bash
# Dom0 orchestrator
docker pull anticipatercom/devshot:amd64      # Linux x86_64 Xen (legacy)
docker pull anticipatercom/devshot:arm64      # Linux ARM64 Xen (legacy)
docker pull anticipatercom/devshot:arm64-mac  # Apple Silicon Docker Desktop
docker pull anticipatercom/devshot:amd64-kvm  # Linux x86_64 direct QEMU
docker pull anticipatercom/devshot:arm64-kvm  # Linux ARM64 direct QEMU

# DomU standalone
docker pull anticipatercom/devshot_domu:latest     # terminal only
docker pull anticipatercom/devshot_desktop:latest  # + VNC desktop
```

### Build locally

```bash
# Dom0 orchestrator (one per target arch — cross-compiles Xen + kernel)
docker build -t anticipatercom/devshot:amd64 -f docker/Dockerfile.dom0-x86 .
docker build -t anticipatercom/devshot:arm64 -f docker/Dockerfile.dom0-arm .
docker build -t anticipatercom/devshot:amd64-kvm -f docker/Dockerfile.vmm-qemu-x86 .
docker build -t anticipatercom/devshot:arm64-kvm -f docker/Dockerfile.vmm-qemu-arm .

# DomU standalone (multi-arch from a single Dockerfile)
docker buildx build --platform linux/amd64,linux/arm64 \
  -t anticipatercom/devshot_domu:latest -f docker/Dockerfile.domU .
docker buildx build --platform linux/amd64,linux/arm64 \
  -t anticipatercom/devshot_desktop:latest -f docker/Dockerfile.domU-desktop .
```

The dom0 Dockerfiles cross-compile Xen + the Linux kernel from
upstream source, then copy the pre-built Go agent from `bin/`.
The final stage is pinned to its target platform so the manifest
is correct even when the build runs on a different host arch.
The domU Dockerfiles are plain `alpine + bin/devshot-agent-linux-$TARGETARCH`.

## Run

### Linux (x86_64 or ARM64) — hardware virtualization

```bash
docker run -d \
  --name devshot-orchestrator \
  --privileged --device /dev/kvm --network=host \
  --restart=unless-stopped \
  -e DEVSHOT_SERVER_ID=<your-server-id> \
  -e DEVSHOT_HMAC_SECRET=<your-hmac-secret> \
  -e DEVSHOT_TUNNEL_URL=wss://console.devshot.com \
  anticipatercom/devshot:amd64-kvm   # or :arm64-kvm on Pi / Graviton
```

If `/dev/kvm` is present, keep `--device /dev/kvm` for acceleration.
If it is absent, remove just that flag and the direct QEMU image still boots under TCG.

### macOS (Apple Silicon) — Docker Desktop, TCG

```bash
docker run -d \
  --name devshot-orchestrator \
  --privileged --network=host \
  --restart=unless-stopped \
  -e DEVSHOT_SERVER_ID=<your-server-id> \
  -e DEVSHOT_HMAC_SECRET=<your-hmac-secret> \
  -e DEVSHOT_TUNNEL_URL=wss://console.devshot.com \
  anticipatercom/devshot:arm64-mac
```

No `/dev/kvm` (Docker Desktop doesn't expose it). Xen and guest
VMs run under QEMU TCG software emulation — slower than a real
Linux host but fine for local testing.

### Windows (WSL2)

Run from **inside WSL2** (not PowerShell). Requires Windows 11
with nested virtualization enabled:

```powershell
# Host PowerShell, as admin, once:
Set-VMProcessor -VMName WSL -ExposeVirtualizationExtensions \$true
wsl --shutdown
```

Then inside WSL2:

```bash
ls /dev/kvm   # must exist
docker run -d \
  --name devshot-orchestrator \
  --privileged --device /dev/kvm --network=host \
  --restart=unless-stopped \
  -e DEVSHOT_SERVER_ID=<your-server-id> \
  -e DEVSHOT_HMAC_SECRET=<your-hmac-secret> \
  -e DEVSHOT_TUNNEL_URL=wss://console.devshot.com \
  anticipatercom/devshot:amd64
```

### DomU standalone (`server_type: 'single'`)

No Xen, no `/dev/kvm`, no `--network=host`. Just a container
with the Go agent talking directly to the tunnel:

```bash
docker run -d \
  --name devshot-domu \
  --restart=unless-stopped \
  -e DEVSHOT_SERVER_ID=<your-server-id> \
  -e DEVSHOT_HMAC_SECRET=<your-hmac-secret> \
  -e DEVSHOT_TUNNEL_URL=wss://console.devshot.com \
  anticipatercom/devshot_domu:latest
```

### DomU desktop (browser VNC on port 6080)

Same as `devshot_domu` plus Openbox + tigervnc + noVNC. Open
`http://localhost:6080/vnc.html` after starting:

```bash
docker run -d \
  --name devshot-desktop \
  --restart=unless-stopped \
  -p 6080:6080 \
  -e DEVSHOT_SERVER_ID=<your-server-id> \
  -e DEVSHOT_HMAC_SECRET=<your-hmac-secret> \
  -e DEVSHOT_TUNNEL_URL=wss://console.devshot.com \
  anticipatercom/devshot_desktop:latest
```

Omit the `DEVSHOT_*` env vars to run as a purely local desktop
with no tunnel.

## Standalone Go Agent Binaries

If you want the Go agent without the Xen orchestrator layer
(e.g. running directly on a Linux host you already provision):

| File | Platform |
|---|---|
| `bin/devshot-agent-linux-amd64` | Linux x86_64 |
| `bin/devshot-agent-linux-arm64` | Linux ARM64 |

Stripped (`-ldflags="-s -w"`), statically linked (`CGO_ENABLED=0`).

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `DEVSHOT_SERVER_ID` | yes | Server UUID from console.devshot.com |
| `DEVSHOT_HMAC_SECRET` | yes | HMAC key from console.devshot.com |
| `DEVSHOT_TUNNEL_URL` | yes | Control-plane WebSocket URL (prod: `wss://console.devshot.com`) |
| `POOL_SIZE` | no | Concurrent DomUs (default: `2`) |
| `VM_MEM` | no | Per-DomU memory in MB (default: `1024`) |
| `XEN_MEM` | no | Hypervisor memory in MB (default: `auto — host RAM minus 1 GB`) |
| `XEN_CPUS` | no | Hypervisor CPUs (default: `auto — all host cores`) |
| `DOM0_MEM` | no | Dom0 memory in MB (default: `auto — 80% of XEN_MEM, floor 1536`) |
| `DOM0_DISK` | no | Dom0 root disk size, e.g. `16G` (default: baked-in 4 GB). qemu-img resize + in-VM resize2fs on boot. |

## Build Info

Auto-deployed by CI from [devshotcom/devshot@af573f64f4aee0210234b2a2329eabae70700da8](https://github.com/devshotcom/devshot/commit/af573f64f4aee0210234b2a2329eabae70700da8).

Last built: 2026-05-18T13:03:52Z
