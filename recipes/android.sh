#!/bin/sh
# Recipe: Android-x86 in QEMU — spec 057 bakery side.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/android.sh --name=android
#
# Output template: devshot-guest-android.qcow2. Every VM spawned from
# it boots Alpine, then auto-starts qemu-system-x86_64 hosting an
# Android-x86 guest with VNC on :5900 and ADB on :5555. The DevShot
# console's /console/android tab dials :5900 directly over WebRTC
# DataChannel — same transport as the Desktop / Browser scenarios.
#
# This is the bake-VM equivalent of apps/agent/docker/Dockerfile.domU-android:
# same package set (qemu + android-tools), same QEMU command, same adb
# pre-connect loop. Re-implemented as a recipe so the bakery can stamp a
# flavored qcow2 ready for `pool-set-base-image android` selection in
# the console (matching how desktop / public-session-desktop are baked).
#
# Spec 050 — declared listen ports auto-populate the per-VM forward
# allowlist (and surface as Open buttons in the Servers tab):
#   :5900 — QEMU's built-in VNC server (raw RFB)
#   :6080 — websockify-fronted noVNC for browser fallback / public demos
#   :5555 — ADB over the QEMU hostfwd, for `adb connect` from the action API
#
# devshot:exposed_ports=[{"port":5900,"name":"vnc","proto":"tcp"},{"port":6080,"name":"novnc","proto":"http"},{"port":5555,"name":"adb","proto":"tcp"}]
#
# Memory floor: the Android-x86 guest itself wants 2 GiB minimum,
# QEMU has ~150 MB process overhead, Alpine + the agent another ~80 MB.
# 2560 MB (2.5 GiB) leaves headroom for adb-server, websockify, and
# brief spikes during app installs. The orchestrator's createVM honours
# this and overrides the per-pool default when spawning from this
# template.
# devshot:memory_mb=2560

set -eux

# ── 1. Packages ─────────────────────────────────────────────────────────
# qemu-system-x86_64: hosts the Android-x86 guest. Always x86_64 because
#   Android-x86 ships only x86 images; on arm64 hosts QEMU falls back to
#   TCG emulation (slow but boots).
# android-tools: provides `adb` for the action API's input-injection
#   pipeline (apps/console/lib/android-control.js).
# websockify + novnc: browser fallback. The WebRTC path still works on
#   :5900 directly, but the public-proxy variant uses websockify the
#   same way the public-session-desktop template does.
# curl: downloads the Android-x86 ISO during the bake (see step 2).
#
# DNS hardening mirrors desktop.sh: some bake hosts route IPv6
# unreliably to Fastly (Alpine's CDN front), so force IPv4.
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
echo 'options single-request-reopen' >> /etc/resolv.conf 2>/dev/null || true
echo 'nameserver 1.1.1.1'              >> /etc/resolv.conf 2>/dev/null || true
apk update || (sleep 5 && apk update)
apk add --no-cache \
    qemu-system-x86_64 qemu-img \
    android-tools \
    websockify novnc \
    curl coreutils \
    p7zip

# ── 2. Bake the Android-x86 ISO into the template ──────────────────────
# Pin to android-x86 9.0-r2 — the long-stable GA release. SourceForge's
# master.dl mirror is the canonical direct URL (no interstitial). Every
# template build pulls this 830 MB ISO once; the resulting qcow2 ships
# ~1.1 GB on top of the base. That's deliberate — the operator goal is
# "claim a phone, it boots Android straight away," not "claim a phone,
# wait 90 s for a first-boot download."
#
# To pin a different release per-deploy: pass ANDROID_X86_URL +
# ANDROID_X86_SHA256 to the bake (build-templates.sh forwards env into
# the chroot). The defaults below match the recipe-time sha256.
ANDROID_X86_URL="${ANDROID_X86_URL:-https://master.dl.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso}"
# Optional integrity check — sha256 of the upstream ISO. Empty = skip.
# When set, mismatch aborts the bake so a corrupted mirror can't silently
# poison every template.
ANDROID_X86_SHA256="${ANDROID_X86_SHA256:-}"

mkdir -p /opt/devshot/images
chmod 755 /opt/devshot/images

echo "Downloading Android-x86 from $ANDROID_X86_URL ..."
curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 \
  -o /opt/devshot/images/android-x86.iso \
  "$ANDROID_X86_URL"

if [ -n "$ANDROID_X86_SHA256" ]; then
  echo "Verifying SHA256 ..."
  actual=$(sha256sum /opt/devshot/images/android-x86.iso | awk '{print $1}')
  if [ "$actual" != "$ANDROID_X86_SHA256" ]; then
    echo "ERROR: SHA256 mismatch" >&2
    echo "  expected: $ANDROID_X86_SHA256" >&2
    echo "  actual:   $actual"            >&2
    rm -f /opt/devshot/images/android-x86.iso
    exit 1
  fi
  echo "  ok ($actual)"
fi

# Sanity-check the artifact. Android-x86 9.0-r2 is ~830 MB; anything
# below 200 MB is almost certainly a captive-portal HTML page or a
# truncated download (curl's --fail catches non-2xx but not partial
# streams behind a 200).
iso_size=$(stat -c%s /opt/devshot/images/android-x86.iso 2>/dev/null || stat -f%z /opt/devshot/images/android-x86.iso)
if [ "$iso_size" -lt 209715200 ]; then
  echo "ERROR: ISO is suspiciously small (${iso_size} bytes)" >&2
  exit 1
fi
echo "  baked: ${iso_size} bytes"
chmod 0644 /opt/devshot/images/android-x86.iso

# ── 2b. Extract kernel + initrd from the ISO ───────────────────────────
# Booting Android-x86 via `-cdrom + -boot d` lands at the ISO's GRUB
# menu and on headless QEMU there is no way to advance from it. The
# canonical headless boot is to hand the kernel + initrd straight to
# QEMU via -kernel/-initrd, with the ISO mounted as a CDROM only so
# the kernel can find /system.sfs by SRC= path. That bypasses GRUB
# entirely and gives us deterministic boot args.
#
# 7z is the simplest cross-environment way to extract specific files
# from an ISO9660 image (works in Alpine + Debian chroots without
# needing loop-mount privileges, which Dockerfile builds don't have).
#
# Android-x86 9.0-r2's ISO layout has the boot media at ISO root:
#   /kernel
#   /initrd.img
#   /ramdisk.img
#   /system.sfs
# The kernel cmdline points at SRC= (empty) so init scans the root of
# the boot device — see ANDROID_SRC env in the launcher below.
echo "Extracting kernel + initrd from ISO ..."
7z -y e /opt/devshot/images/android-x86.iso \
  'kernel' \
  'initrd.img' \
  -o/opt/devshot/images/ >/dev/null
mv /opt/devshot/images/kernel     /opt/devshot/images/android-kernel
mv /opt/devshot/images/initrd.img /opt/devshot/images/android-initrd.img
chmod 0644 /opt/devshot/images/android-kernel /opt/devshot/images/android-initrd.img
echo "  kernel: $(stat -c%s /opt/devshot/images/android-kernel 2>/dev/null || stat -f%z /opt/devshot/images/android-kernel) bytes"
echo "  initrd: $(stat -c%s /opt/devshot/images/android-initrd.img 2>/dev/null || stat -f%z /opt/devshot/images/android-initrd.img) bytes"

# Pre-allocate a 4 GB writable qcow2 for /data so Android-x86's live
# boot has somewhere persistent to put app installs / accounts. qcow2
# is sparse — the file occupies only what the guest actually writes.
# Spawned VMs that want a clean slate just delete this and let the
# launcher recreate it.
if [ ! -f /opt/devshot/images/android-data.qcow2 ]; then
  qemu-img create -f qcow2 /opt/devshot/images/android-data.qcow2 4G
  chmod 0644 /opt/devshot/images/android-data.qcow2
fi

# ── 3. ADB-server stub user dir ────────────────────────────────────────
# adb-server runs as `devshot` so the user's $HOME/.android/ owns the
# ADB key pair. Without an established ADB key, every adb invocation
# would generate one in /tmp and the action API's `adb connect` would
# log "waiting for device" because the key changed mid-session.
DEVSHOT_HOME=/home/devshot
mkdir -p "$DEVSHOT_HOME/.android"
chown -R devshot:devshot "$DEVSHOT_HOME/.android"

# ── 4. Launcher script ─────────────────────────────────────────────────
# start-android boots QEMU + Android-x86 + adb + (optional) websockify.
# Idempotent: re-running while QEMU is already up is a no-op.
#
# Boot model: live ISO (CDROM) + persistent /data on a writable qcow2.
# The ISO ships baked into the template (step 2 above) so first boot
# is offline-clean. The data disk is initialized once on first boot
# (qemu-img create) and survives VM restarts; destroying it gives a
# fresh phone.
#
# Environment overrides (set per-VM via env, e.g. in the orchestrator's
# launch command or in dom0 xenstore):
#   ANDROID_ISO       — path to baked ISO (default: /opt/devshot/images/android-x86.iso)
#   ANDROID_DATA      — path to writable qcow2 (default: /opt/devshot/images/android-data.qcow2)
#   ANDROID_DATA_GB   — data disk size if created on first boot (default: 4)
#   ANDROID_RAM       — guest RAM in MiB (default: 2048)
#   ANDROID_VCPUS     — guest vCPUs (default: 2)
#   VNC_PORT          — host port for the Android guest's RFB (default: 5900)
#   ADB_PORT          — host port forwarded to the guest's adbd (default: 5555)
#   NOVNC_PORT        — websockify port for the browser fallback (default: 6080)
cat > /usr/local/bin/start-android <<'LAUNCHER'
#!/bin/sh
# Start the Android-x86 emulator. Pass -d to run detached.
set -eu

detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi

ANDROID_ISO="${ANDROID_ISO:-/opt/devshot/images/android-x86.iso}"
ANDROID_KERNEL="${ANDROID_KERNEL:-/opt/devshot/images/android-kernel}"
ANDROID_INITRD="${ANDROID_INITRD:-/opt/devshot/images/android-initrd.img}"
ANDROID_DATA="${ANDROID_DATA:-/opt/devshot/images/android-data.qcow2}"
ANDROID_DATA_GB="${ANDROID_DATA_GB:-4}"
ANDROID_RAM="${ANDROID_RAM:-2048}"
ANDROID_VCPUS="${ANDROID_VCPUS:-2}"
ANDROID_SRC="${ANDROID_SRC:-}"
VNC_PORT="${VNC_PORT:-5900}"
ADB_PORT="${ADB_PORT:-5555}"
NOVNC_PORT="${NOVNC_PORT:-6080}"

# ── Sanity-check the baked artefacts ─────────────────────────────────
# The recipe step bakes the ISO + extracts kernel/initrd at template
# build time. If any are gone (operator wiped them, mount went stale)
# abort loudly rather than silently boot a blank QEMU.
for f in "$ANDROID_ISO" "$ANDROID_KERNEL" "$ANDROID_INITRD"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f missing — re-bake the android template" >&2
    exit 1
  fi
done

# ── Ensure the persistent /data disk exists ──────────────────────────
if [ ! -f "$ANDROID_DATA" ]; then
  echo "Creating writable data disk ($ANDROID_DATA, ${ANDROID_DATA_GB} GB) ..."
  qemu-img create -f qcow2 "$ANDROID_DATA" "${ANDROID_DATA_GB}G" >/dev/null
fi

# ── Detect KVM acceleration + pick a CPU model that actually boots ───
# `-cpu max` is great under KVM (passes through every feature the host
# advertises) but trips QEMU on TCG with "unrecognized CPU feature" for
# anything not implemented in software. Default to host-under-KVM,
# qemu64-under-TCG so the same launcher works on Linux orchestrators
# (KVM available) and Mac dev (TCG only).
ACCEL_FLAG=""
CPU_FLAG="-cpu qemu64,+ssse3,+sse4.1,+sse4.2"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ACCEL_FLAG="-enable-kvm"
  CPU_FLAG="-cpu host"
fi

# ── Already running? ─────────────────────────────────────────────────
if pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
  echo "QEMU already running."
else
  echo "Starting Android-x86 QEMU (vnc :$VNC_PORT, adb :$ADB_PORT) ..."
  # Direct kernel boot — bypasses the ISO's GRUB menu (which sits at a
  # 5 s timeout on headless QEMU with no way to advance). The kernel
  # finds /system.sfs by SRC=… on the CDROM. nomodeset + xforcevesa
  # force a software framebuffer that VNC can capture without GPU.
  # androidboot.selinux=permissive matches the upstream Live-CD entry.
  # video= sets a deterministic resolution so the data API's coordinate
  # space is stable across boots.
  # Console order matters — Linux makes the LAST `console=` /dev/console,
  # so /init's stdout reaches the serial log file while kernel printk
  # still goes to both tty0 (VNC framebuffer) and ttyS0 (log). -vga std
  # advertises the VESA modes Android-x86's `nomodeset xforcevesa` needs.
  KERNEL_APPEND="root=/dev/ram0 androidboot.selinux=permissive \
androidboot.hardware=android_x86_64 SRC=${ANDROID_SRC} \
video=1280x720 nomodeset xforcevesa \
console=tty0 console=ttyS0,115200"
  # -drive media=cdrom is more portable than -cdrom (some QEMU builds
  # silently ignore -boot order=d with -cdrom). The data disk is
  # virtio for speed; Android sees it but won't auto-format until we
  # pass DATA= (phase 2).
  nohup qemu-system-x86_64 \
    -m "$ANDROID_RAM" \
    -smp "$ANDROID_VCPUS" \
    $ACCEL_FLAG \
    $CPU_FLAG \
    -kernel "$ANDROID_KERNEL" \
    -initrd "$ANDROID_INITRD" \
    -append "$KERNEL_APPEND" \
    -drive "file=$ANDROID_ISO,media=cdrom" \
    -drive "file=$ANDROID_DATA,format=qcow2,if=virtio,cache=writeback" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ADB_PORT}-:5555" \
    -device virtio-net-pci,netdev=net0 \
    -device virtio-tablet-pci \
    -vga std \
    -display none \
    -vnc ":0,websocket=${NOVNC_PORT}" \
    -serial file:/tmp/qemu-serial.log \
    -monitor "telnet:127.0.0.1:4444,server,nowait" \
    >/tmp/qemu-android.log 2>&1 &
  # Give QEMU a moment to bind ports. If it dies during early boot
  # (missing kernel feature, invalid append) the log catches it.
  for _ in $(seq 1 24); do
    if (echo > /dev/tcp/127.0.0.1/"$VNC_PORT") 2>/dev/null; then
      break
    fi
    if ! pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
      echo "ERROR: QEMU exited during boot. Last log lines:" >&2
      tail -n 20 /tmp/qemu-android.log >&2 || true
      exit 1
    fi
    sleep 0.5
  done
fi

# ── adb pre-connect ──────────────────────────────────────────────────
# Backgrounded retry loop. Android's adbd takes ~30-60 s after boot;
# the action API would otherwise see "device not found" until the user
# manually `adb connect`'d. Runs as the devshot user so the key pair
# lives under /home/devshot/.android/.
(
  for i in $(seq 1 60); do
    sleep 2
    if su -s /bin/sh devshot -c "adb connect 127.0.0.1:${ADB_PORT}" 2>/dev/null | grep -q 'connected'; then
      echo "adb connected on :${ADB_PORT}"
      break
    fi
  done
) >/tmp/adb-bootstrap.log 2>&1 &

# ── websockify (browser fallback) ─────────────────────────────────────
# Same pattern as public-session-desktop: stand up a noVNC HTTP front
# on :6080 so the public-proxy / non-WebRTC clients still work. The
# authenticated WebRTC path doesn't need this — it dials :5900 directly.
if ! pgrep -x websockify >/dev/null 2>&1; then
  nohup websockify --web /usr/share/novnc "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" \
    >/tmp/websockify-android.log 2>&1 &
fi

if [ "$detached" = "1" ]; then
  echo "Android started — VNC :$VNC_PORT, ADB :$ADB_PORT, noVNC :$NOVNC_PORT"
  exit 0
fi

# Foreground mode — wait on QEMU.
wait
LAUNCHER
chmod 0755 /usr/local/bin/start-android

cat > /usr/local/bin/stop-android <<'STOP'
#!/bin/sh
pkill -x qemu-system-x86_64 2>/dev/null || true
pkill -x websockify 2>/dev/null || true
adb kill-server 2>/dev/null || true
echo "Android stopped."
STOP
chmod 0755 /usr/local/bin/stop-android

# ── 5. OpenRC service: auto-start on boot ──────────────────────────────
# Operators who want "claim a phone, point browser at it" get this for
# free — the emulator is up by the time the spec-050 forward channel
# can reach :5900/:5555. To opt out post-claim:
#   rc-update del devshot-android default && rc-service devshot-android stop
cat > /etc/init.d/devshot-android <<'INITD'
#!/sbin/openrc-run

description="DevShot Android-x86 emulator (QEMU + adb)"

depend() {
    need net
    after networking
}

start() {
    ebegin "Starting DevShot Android"
    /usr/local/bin/start-android -d
    eend $?
}

stop() {
    ebegin "Stopping DevShot Android"
    /usr/local/bin/stop-android
    eend $?
}

status() {
    if pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
        einfo "running (qemu-system-x86_64 alive)"
        return 0
    fi
    einfo "stopped"
    return 3
}
INITD
chmod +x /etc/init.d/devshot-android
rc-update add devshot-android default

echo "=== android recipe complete ==="
ls /usr/local/bin/start-android /usr/local/bin/stop-android
ls /etc/init.d/devshot-android
