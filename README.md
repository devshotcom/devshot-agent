# DevShot Agent

Pre-built agents and orchestrator binaries for DevShot.

## Quick Install

```bash
curl -fsSL https://devshot.com/install.sh | bash
```

## Binaries

| File | Platform |
|---|---|
| `bin/devshot-agent-linux-amd64` | Linux x86_64 |
| `bin/devshot-agent-linux-arm64` | Linux ARM64 |

## Docker Images

```bash
docker pull devshotcom/devshot-orchestrator:x86
docker pull devshotcom/devshot-orchestrator:arm64
```

Or build locally:

```bash
docker build -t devshot-orchestrator:x86 -f docker/Dockerfile.dom0-x86 .
docker build -t devshot-orchestrator:arm64 -f docker/Dockerfile.dom0-arm .
```

## Run

```bash
docker run -d \
  --name devshot-orchestrator \
  --privileged --device /dev/kvm \
  --restart=unless-stopped \
  -e DEVSHOT_SERVER_ID=<your-server-id> \
  -e DEVSHOT_HMAC_SECRET=<your-hmac-secret> \
  -e DEVSHOT_TUNNEL_URL=wss://console.devshot.com \
  devshotcom/devshot-orchestrator:x86
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `DEVSHOT_SERVER_ID` | Yes | Server UUID from console |
| `DEVSHOT_HMAC_SECRET` | Yes | HMAC key from console |
| `DEVSHOT_TUNNEL_URL` | Yes | WebSocket tunnel URL |
| `POOL_SIZE` | No | Concurrent VMs (default: 1) |
| `VM_MEM` | No | Per-VM memory in MB (default: 256) |
| `XEN_MEM` | No | Hypervisor memory in MB (default: 4096) |
| `XEN_CPUS` | No | Hypervisor CPUs (default: 4) |

## Build Info

Auto-deployed by CI. Last built: 2026-04-11T01:38:52Z
