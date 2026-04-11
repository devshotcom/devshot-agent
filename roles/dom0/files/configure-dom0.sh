#!/bin/bash
# Configure Dom0 rootfs: networking, Xen services, NAT, agent auto-start
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

# Grow the root filesystem to fill the underlying block device.
# Pairs with `qemu-img resize` performed by the orchestrator entrypoint when
# the user passes -e DOM0_DISK=16G. Online resize2fs handles a mounted ext4
# root since e2fsprogs >= 1.42, and is idempotent: a no-op when /dev/vda is
# already at full size, so safe to run on every boot.
cat > "$ROOTFS/etc/systemd/system/dom0-resize-rootfs.service" <<UNIT
[Unit]
Description=Grow Dom0 root filesystem to underlying block device size
DefaultDependencies=no
After=local-fs.target
Before=basic.target sysinit.target
ConditionPathExists=/dev/vda

[Service]
Type=oneshot
ExecStart=/sbin/resize2fs /dev/vda
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=sysinit.target
UNIT
chroot "$ROOTFS" bash -c 'systemctl enable dom0-resize-rootfs 2>/dev/null || true'

# Unprivileged user for command execution (same as DomU)
chroot "$ROOTFS" bash -c 'useradd -m -s /bin/bash -d /home/devshot devshot 2>/dev/null || true'
mkdir -p "$ROOTFS/home/devshot/workspace"
chroot "$ROOTFS" bash -c 'chown -R devshot:devshot /home/devshot'

# Random, unknown password — unlocks the account (so sudo NOPASSWD works)
# without leaving an empty password that would allow passwordless console login.
# Plaintext is generated and thrown away; no one knows it. A human can set a
# real password later if interactive access is ever needed.
RANDPW=$(head -c 32 /dev/urandom | base64 | tr -d '/+= \n')
echo "devshot:${RANDPW}" | chroot "$ROOTFS" chpasswd
unset RANDPW

# Passwordless sudo + tmux for devshot user (sandbox — disposable VM)
chroot "$ROOTFS" bash -c 'apt-get install -y --no-install-recommends sudo tmux >/dev/null 2>&1 || true'
mkdir -p "$ROOTFS/etc/sudoers.d"
echo "devshot ALL=(ALL) NOPASSWD: ALL" > "$ROOTFS/etc/sudoers.d/devshot"
chmod 440 "$ROOTFS/etc/sudoers.d/devshot"

# DevShot agent systemd service (the Go binary, auto-detects dom0)
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

# Xen device model symlinks (ARM64 HVM -- Xen looks for both paths)
mkdir -p "$ROOTFS/usr/libexec" "$ROOTFS/usr/lib/xen/bin"
ln -sf /usr/bin/qemu-system-aarch64 "$ROOTFS/usr/libexec/xen-qemu-system-i386"
ln -sf /usr/bin/qemu-system-aarch64 "$ROOTFS/usr/lib/xen/bin/qemu-system-i386"

# 9p mounts in fstab (both xen_shared and orchestrator)
echo "xen_shared /xen 9p trans=virtio,version=9p2000.L,nofail 0 0" >> "$ROOTFS/etc/fstab"
echo "orchestrator /opt/devshot 9p trans=virtio,version=9p2000.L,nofail 0 0" >> "$ROOTFS/etc/fstab"

# Ensure mount points exist
mkdir -p "$ROOTFS/opt/devshot" "$ROOTFS/xen/guests" "$ROOTFS/etc/xen/guests" "$ROOTFS/etc/xen/auto" "$ROOTFS/xen/boot" "$ROOTFS/xen/configs"

# Disable SSH (not needed -- agent managed via systemd)
chroot "$ROOTFS" bash -c 'systemctl disable ssh 2>/dev/null || true'

# ── QEMU Guest Agent ───────────────────────────────────────────────────────
# Enables guest-exec from the container level for recovery/health checks.
chroot "$ROOTFS" bash -c 'apt-get install -y --no-install-recommends qemu-guest-agent >/dev/null 2>&1 || true'
chroot "$ROOTFS" bash -c 'systemctl enable qemu-guest-agent 2>/dev/null || true'

# ── ClamAV: configure clamd and enable first-boot signature update ────────
# Uncomment Example line so clamd actually starts
if [ -f "$ROOTFS/etc/clamav/clamd.conf" ]; then
  sed -i 's/^Example/#Example/' "$ROOTFS/etc/clamav/clamd.conf"
fi

# Enable clamd daemon
chroot "$ROOTFS" bash -c 'systemctl enable clamav-daemon 2>/dev/null || true'

# First-boot freshclam service — downloads sigs once, then disables itself
cat > "$ROOTFS/etc/systemd/system/clamav-freshclam-boot.service" <<'UNIT'
[Unit]
Description=ClamAV first-boot signature download
After=network-online.target
Wants=network-online.target
Before=clamav-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ ! -f /var/lib/clamav/main.cvd ]; then freshclam --stdout; fi'
ExecStartPost=/bin/systemctl disable clamav-freshclam-boot.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
chroot "$ROOTFS" bash -c 'systemctl enable clamav-freshclam-boot.service 2>/dev/null || true'

echo "=== Dom0 configured (no SSH) ==="
