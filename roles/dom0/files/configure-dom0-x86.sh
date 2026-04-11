#!/bin/bash
# Configure Dom0 rootfs (x86_64): networking, Xen services, NAT, agent auto-start
# No SSH -- agent starts via systemd, env vars shared via 9p /xen/agent.env
set -euo pipefail

ROOTFS="${1:-/rootfs}"
HOSTNAME="${2:-xen-dom0}"

# System identity
echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
echo "127.0.0.1 localhost $HOSTNAME" > "$ROOTFS/etc/hosts"
echo "nameserver 10.0.2.3" > "$ROOTFS/etc/resolv.conf"

# Network interfaces
mkdir -p "$ROOTFS/etc/network/interfaces.d"
cat > "$ROOTFS/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cat > "$ROOTFS/etc/network/interfaces.d/xenbr0" <<EOF
auto xenbr0
iface xenbr0 inet static
    bridge_ports none
    address 10.10.0.1
    netmask 255.255.0.0
EOF

# IP forwarding
echo "net.ipv4.ip_forward=1" > "$ROOTFS/etc/sysctl.d/99-xen.conf"

# Use iptables-legacy
chroot "$ROOTFS" bash -c 'update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true'

# Xen toolstack
echo "TOOLSTACK=xl" > "$ROOTFS/etc/default/xen"
chroot "$ROOTFS" bash -c 'systemctl enable xencommons 2>/dev/null || true'

# NAT + bridge setup script
mkdir -p "$ROOTFS/usr/local/bin"
cat > "$ROOTFS/usr/local/bin/xen-nat.sh" <<'NAT'
#!/bin/bash
depmod -a 2>/dev/null || true
modprobe bridge 2>/dev/null || true

if ! ip link show xenbr0 >/dev/null 2>&1; then
    ip link add xenbr0 type bridge
    ip addr add 10.10.0.1/16 dev xenbr0
    ip link set xenbr0 up
fi

iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -C FORWARD -i xenbr0 -o eth0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i xenbr0 -o eth0 -j ACCEPT
iptables -C FORWARD -i eth0 -o xenbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i eth0 -o xenbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
NAT
chmod +x "$ROOTFS/usr/local/bin/xen-nat.sh"

# xen-nat systemd service
cat > "$ROOTFS/etc/systemd/system/xen-nat.service" <<UNIT
[Unit]
Description=Xen NAT for DomU internet access
After=network.target xencommons.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xen-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
chroot "$ROOTFS" bash -c 'systemctl enable xen-nat 2>/dev/null || true'

# Unprivileged user for command execution
chroot "$ROOTFS" bash -c 'useradd -m -s /bin/bash -d /home/devshot devshot 2>/dev/null || true'
mkdir -p "$ROOTFS/home/devshot/workspace"
chroot "$ROOTFS" bash -c 'chown -R devshot:devshot /home/devshot'
# Random, unknown password — unlocks the account (so sudo NOPASSWD works)
# without leaving an empty password that would allow passwordless console login.
RANDPW=$(head -c 32 /dev/urandom | base64 | tr -d '/+= \n')
echo "devshot:${RANDPW}" | chroot "$ROOTFS" chpasswd
unset RANDPW

# Passwordless sudo
chroot "$ROOTFS" bash -c 'apt-get install -y --no-install-recommends sudo tmux >/dev/null 2>&1 || true'
mkdir -p "$ROOTFS/etc/sudoers.d"
echo "devshot ALL=(ALL) NOPASSWD: ALL" > "$ROOTFS/etc/sudoers.d/devshot"
chmod 440 "$ROOTFS/etc/sudoers.d/devshot"

# DevShot agent systemd service
cat > "$ROOTFS/etc/systemd/system/devshot-agent.service" <<UNIT
[Unit]
Description=DevShot Agent (Dom0 orchestrator)
After=xen-nat.service
Requires=xen-nat.service

[Service]
EnvironmentFile=/xen/agent.env
Environment=XS_REAL=1
ExecStart=/opt/devshot/agent
Restart=always
RestartSec=5
StandardOutput=append:/xen/orchestrator.log
StandardError=append:/xen/orchestrator.log

[Install]
WantedBy=multi-user.target
UNIT
chroot "$ROOTFS" bash -c 'systemctl enable devshot-agent 2>/dev/null || true'

# Xen device model symlinks (x86_64 — Xen looks for qemu-system-i386)
mkdir -p "$ROOTFS/usr/libexec" "$ROOTFS/usr/lib/xen/bin"
ln -sf /usr/bin/qemu-system-x86_64 "$ROOTFS/usr/libexec/xen-qemu-system-i386"
ln -sf /usr/bin/qemu-system-x86_64 "$ROOTFS/usr/lib/xen/bin/qemu-system-i386"

# 9p mounts in fstab
echo "xen_shared /xen 9p trans=virtio,version=9p2000.L,nofail 0 0" >> "$ROOTFS/etc/fstab"
echo "orchestrator /opt/devshot 9p trans=virtio,version=9p2000.L,nofail 0 0" >> "$ROOTFS/etc/fstab"

# Ensure mount points exist
mkdir -p "$ROOTFS/opt/devshot" "$ROOTFS/xen/guests" "$ROOTFS/etc/xen/guests" "$ROOTFS/etc/xen/auto" "$ROOTFS/xen/boot" "$ROOTFS/xen/configs"

# Disable SSH
chroot "$ROOTFS" bash -c 'systemctl disable ssh 2>/dev/null || true'

# ── QEMU Guest Agent ───────────────────────────────────────────────────────
chroot "$ROOTFS" bash -c 'apt-get install -y --no-install-recommends qemu-guest-agent >/dev/null 2>&1 || true'
chroot "$ROOTFS" bash -c 'systemctl enable qemu-guest-agent 2>/dev/null || true'

echo "=== Dom0 (x86_64) configured (no SSH) ==="
