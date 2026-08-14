#!/bin/sh
# Wrapper around /opt/devshot/agent. Runs both inside the dom0 container
# and inside pool/domU guests (same rootfs shape). Detects the xenstore
# backend and, on non-Xen guests, mirrors the orchestrator-resolved
# tunnel hostname into /etc/hosts so the agent can reach the tunnel
# without a working DNS server.

apply_tunnel_host_alias() {
    xs_root="$1"
    [ -n "$xs_root" ] || return 0
    [ -r "$xs_root/local__domain__1__data__tunnel-url" ] || return 0
    [ -r "$xs_root/local__domain__1__data__tunnel-host-ip" ] || return 0

    tunnel_url=$(cat "$xs_root/local__domain__1__data__tunnel-url" 2>/dev/null)
    tunnel_ip=$(cat "$xs_root/local__domain__1__data__tunnel-host-ip" 2>/dev/null)
    tunnel_host="${tunnel_url#*://}"
    tunnel_host="${tunnel_host%%/*}"
    tunnel_host="${tunnel_host%%:*}"

    [ -n "$tunnel_host" ] || return 0
    [ -n "$tunnel_ip" ] || return 0

    grep -Fq "$tunnel_ip $tunnel_host" /etc/hosts 2>/dev/null || \
        printf '%s %s\n' "$tunnel_ip" "$tunnel_host" >> /etc/hosts
}

if [ -e /proc/xen/xenbus ]; then
    # Xen DomU: real xenstored talking over xenbus
    export XS_REAL=1
    # A DomU's xenbus connection is rooted at /local/domain/<self>, so a
    # connection-relative read of "domid" returns this guest's own domid.
    # Prefer it: the absolute "/local/domain/self/domid" alias returns ENOENT
    # under cxenstored (the impl on the bare-metal Xen pool hosts), which left
    # DOMID unset → defaulted to "1" → agent read the wrong launch-nonce path →
    # LAUNCH_NOT_AUTHORIZED → guest never connected. Keep the self alias as a
    # fallback for xenstore impls that support it.
    SELF_DOMID="$(xenstore-read domid 2>/dev/null || true)"
    [ -n "$SELF_DOMID" ] || SELF_DOMID="$(xenstore-read /local/domain/self/domid 2>/dev/null || true)"
    [ -n "$SELF_DOMID" ] && export DOMID="$SELF_DOMID"
else
    # Non-Xen: QEMU user-net exposes the parent orchestrator as 10.0.2.2.
    grep -q "^10.0.2.2[[:space:]]\+host.docker.internal" /etc/hosts 2>/dev/null || \
        echo "10.0.2.2 host.docker.internal" >> /etc/hosts

    modprobe 9p 2>/dev/null
    modprobe 9pnet_virtio 2>/dev/null
    mkdir -p /tmp/xenstore

    if mount -t 9p -o trans=virtio,version=9p2000.L,access=any xen_shared /tmp/xenstore 2>/dev/null; then
        # QEMU backend (spec 038): orchestrator populated the 9p share
        # with the FileXenstore tree before launch.
        export XS_REAL=0
        export XS_ROOT=/tmp/xenstore
        export DOMID=1
    elif [ -b /dev/vdb ]; then
        # Firecracker: config disk at /dev/vdb
        mkdir -p /mnt/devshot-config
        mount -o rw /dev/vdb /mnt/devshot-config 2>/dev/null
        export XS_REAL=0
        export XS_ROOT=/mnt/devshot-config/xenstore
        export DOMID=1
    else
        # Fallback: file-based xenstore (standalone / dev mode)
        export XS_REAL=0
        export XS_ROOT=/tmp/xenstore
        export DOMID=1
    fi

    apply_tunnel_host_alias "$XS_ROOT"
fi

# OpenRC owns the Agent service logs. The Agent itself mirrors only its exact
# post-xenstore readiness marker to the serial console for Firecracker's
# fail-closed WaitReady gate, keeping the interactive console unpolluted.
exec /opt/devshot/agent
