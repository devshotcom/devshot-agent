#!/bin/bash
# Boot Xen hypervisor inside DDEV web container (for local dev)
# This is the DDEV web-entrypoint.d script, NOT the Docker cell entrypoint.
set -e

echo "=== DevShot Xen Boot (DDEV) ==="

# Check for required artifacts
for f in /xen/xen /xen/Image /xen/dom0-rootfs.qcow2; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found. Run 'make build' in apps/agent/ first."
        exit 1
    fi
done

# CoW overlay so base rootfs stays clean
if [ ! -f /xen/dom0-rootfs-work.qcow2 ]; then
    qemu-img create -f qcow2 -b /xen/dom0-rootfs.qcow2 -F qcow2 /xen/dom0-rootfs-work.qcow2
fi

# Boot QEMU with Xen hypervisor
qemu-system-aarch64 \
  -accel tcg,thread=multi \
  -machine virt,gic-version=3,virtualization=true \
  -cpu max \
  -smp "${XEN_CPUS:-2}" \
  -m "${XEN_MEM:-4096}" \
  -display none \
  -daemonize \
  -kernel /xen/xen \
  -append "dom0_mem=1024M,max:1024M loglvl=all guest_loglvl=all console=dtuart" \
  -device guest-loader,addr=0x49000000,kernel=/xen/Image,bootargs="console=hvc0 root=/dev/vda rw earlyprintk=xenboot" \
  -drive file=/xen/dom0-rootfs-work.qcow2,format=qcow2,if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -fsdev local,id=xen_fs,path=/xen,security_model=none \
  -device virtio-9p-device,fsdev=xen_fs,mount_tag=xen_shared \
  -fsdev local,id=orch_fs,path=/opt/devshot,security_model=none \
  -device virtio-9p-device,fsdev=orch_fs,mount_tag=orchestrator \
  -monitor unix:/tmp/qemu-monitor.sock,server,nowait \
  -serial unix:/tmp/qemu-console.sock,server,nowait \
  -pidfile /tmp/qemu.pid

echo "QEMU started (pid=$(cat /tmp/qemu.pid 2>/dev/null || echo unknown))"
echo "Dom0 will auto-start agent via systemd"
echo "Console: socat - UNIX-CONNECT:/tmp/qemu-console.sock"

echo "Container ready. Use 'ddev ssh' to access web container."
tail -f /dev/null
