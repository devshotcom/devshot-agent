#!/bin/sh
# Recipe: Headless Chromium browser — Xvnc + Openbox + maximized Chromium.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/browser.sh --name=browser
#
# Output template: devshot-guest-browser.qcow2. Every VM spawned from
# it boots straight into a fullscreen Chromium window on TCP:5900
# (raw RFB). The DevShot console's /console/browser tab dials :5900
# directly over WebRTC DataChannel — same transport as Desktop / Phone.
#
# Differences vs the desktop recipe:
#   - No tint2 / picom / file manager / GTK theming. Browser-only image.
#   - Chromium auto-launches maximized as `devshot` after Xvnc binds
#     :5900. Its own URL bar + tabs stay visible — Openbox just strips
#     the window-manager decoration so Chromium's chrome is the only
#     chrome the user sees.
#   - Chrome DevTools opens on :9222 so the agent's
#     detectBrowserCapability() probe lights up `caps:['browser']` and
#     the console's /console/browser route picks this image specifically
#     (vs a vanilla desktop with `caps:['vnc']`).
#
# Spec 056 — declared listen ports auto-populate the per-VM forward
# allowlist (and surface as Open buttons in the Servers tab):
#   :5900 — Xvnc (raw RFB, the framebuffer the user sees)
#   :9222 — Chrome DevTools (programmatic browser control + cap probe)
#
# devshot:exposed_ports=[{"port":5900,"name":"vnc","proto":"tcp"},{"port":9222,"name":"devtools","proto":"http"}]
# devshot:memory_mb=2048

set -eux

# ── 1. Network hardening ──────────────────────────────────────────────
# Three execution contexts:
#   - Docker BUILD: DNS is wired by the daemon, /etc/resolv.conf is a
#     read-only bind-mount, eth0 already has a routable address.
#   - build-templates.sh chroot: outer script populated /etc/resolv.conf
#     with public DNS, eth0 inherits the Docker bridge.
#   - Live bake VM: QGA recipe fires ~1s after kernel boot, well before
#     busybox-init finishes networking. eth0 is down; no resolv.conf.
#
# Probe first: if apk update already works, networking is fine and we
# must NOT touch eth0 — udhcpc's deconfig hook on lease-failure poisons
# DNS in the chroot/docker contexts (no DHCP server, lease fails, the
# default-script wipes the routing state). Only run the manual bring-up
# in the live VM, which is the only context where the probe will fail.
echo 'options single-request-reopen' >> /etc/resolv.conf 2>/dev/null || true
echo 'nameserver 1.1.1.1'              >> /etc/resolv.conf 2>/dev/null || true
if ! apk update 2>&1 | grep -q 'OK:'; then
  echo "[recipe] apk update failed cold — assuming live bake VM, bringing eth0 up"
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
  ip link set eth0 up 2>/dev/null || ifconfig eth0 up 2>/dev/null || true
  udhcpc -i eth0 -t 5 -n -q 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if apk update 2>&1 | grep -q 'OK:'; then
      echo "[recipe] apk update succeeded on iteration $i"
      break
    fi
    echo "[recipe] apk update attempt $i failed, retrying..."
    sleep 2
  done
fi

# ── 2. Packages ────────────────────────────────────────────────────────
# tigervnc:        Xvnc binary — same VNC server desktop uses.
# openbox:         Tiny window manager Chromium runs under (Chromium
#                  refuses to start without one — it asks the WM for a
#                  frame even when launched maximized).
# chromium:        The actual browser. Alpine ships an aarch64/amd64
#                  build under chromium and chromium-swiftshader.
# ttf-dejavu / ttf-liberation / font-noto-emoji: enough fallback fonts
#                  that most websites render legibly out of the box.
# dbus / dbus-x11: Chromium's account/cookie helpers and Openbox both
#                  poke dbus on startup; without it Chromium spends
#                  ~3 s timing out per launch.
# xset:            One-line trick to disable screen blanking; the
#                  desktop recipe doesn't need it because tint2's idle
#                  inhibits work, but this image has no panel.
# xdotool / scrot: Spec-055 desktop/browser-control endpoints
#                  (/api/vms/:vm/desktop/{action,screenshot} and
#                  /api/vms/:vm/browser/action) call these binaries
#                  through vm-exec to synthesize input + capture frames.
#                  Without them the screenshot endpoint returns 503 and
#                  the type/key actions error with "sh: xdotool: not
#                  found". The desktop recipe already pulls them in for
#                  the same reason.
# chromium-swiftshader: Software GL/Vulkan when no GPU is exposed to
#                  the VM (Mac TCG, headless Linux dom0). Without this,
#                  Chromium falls back to llvmpipe and many sites hang
#                  on getContext("webgl") for 3-5 s per page.
# nodejs / npm:    Trainer-browser automation runs Playwright scripts
#                  inside the guest. Baking node + npm avoids a
#                  per-claim `apk add` over the bake-VM's flaky slirp.
# xclip:           Clipboard get/set. Lets the AI driver paste long
#                  strings via clipboard (much faster than xdotool's
#                  per-char type loop) and read out drag-drop content.
# xrandr:          Screen geometry control — change resolution from a
#                  scripted automation pass (resize for screenshots,
#                  emulate mobile viewports) without restarting Xvnc.
# playwright-core: Pre-installed at /opt/pw so automation scripts get
#                  `import { chromium } from 'playwright-core'` for
#                  CDP control of the system Chromium. `--no-audit
#                  --no-fund` shaves seconds off npm's noise; we use
#                  -core (no bundled browser) because Alpine's chromium
#                  is already on PATH.
# wmctrl is NOT installed — not packaged for Alpine v3.23 (community
# repo lacks it). xdotool's `search`/`getactivewindow`/`windowactivate`
# cover the same surface for our automation needs.
apk add --no-cache \
    tigervnc \
    openbox \
    chromium chromium-swiftshader \
    dbus dbus-x11 \
    ttf-dejavu ttf-liberation font-noto-emoji \
    xset xrandr \
    xdotool scrot xclip \
    nodejs npm

# Playwright-core install. Pinned location so spec-056's automation
# layer always finds it at the same path regardless of who started
# Chromium. Using `playwright-core` (not full `playwright`) skips the
# ~200 MB bundled browser download — we drive Alpine's system chromium
# via CDP instead.
mkdir -p /opt/pw
cd /opt/pw
printf '{"type":"module"}\n' > package.json
npm install --no-audit --no-fund playwright-core@latest
chown -R devshot:devshot /opt/pw
cd /

# ── 3. Per-user browser config ─────────────────────────────────────────
# The universal base already created the `devshot` user. We just need
# to drop a tiny Openbox config and a fresh Chromium profile.
DEVSHOT_HOME=/home/devshot
mkdir -p "$DEVSHOT_HOME/.config/openbox" "$DEVSHOT_HOME/.vnc" "$DEVSHOT_HOME/.config/chromium-data"

# Openbox config — every window opens maximized with no WM decoration.
# We deliberately do NOT force <fullscreen>yes</fullscreen>: that flag
# tells the app "you own the whole screen, hide your own chrome", which
# Chromium honours by hiding its URL bar + tabs — leaving the user
# staring at a blank about:blank with no way to navigate. <maximized>
# fills the framebuffer without triggering that signal, so Chromium's
# own chrome stays visible while still using every pixel of the VNC
# canvas. <decor>no</decor> drops the WM title bar (Chromium provides
# its own window controls in maximized mode).
cat > "$DEVSHOT_HOME/.config/openbox/rc.xml" <<'OBRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme><name>Clearlooks</name><titleLayout></titleLayout></theme>
  <desktops><number>1</number></desktops>
  <applications>
    <application name="*">
      <decor>no</decor>
      <maximized>true</maximized>
      <focus>yes</focus>
    </application>
  </applications>
</openbox_config>
OBRC

# Openbox autostart — no panel, no compositor, just Chromium + a
# screen-blank inhibitor. xset s off / dpms 0 0 0 keep the
# framebuffer alive so an idle session doesn't drop to a black screen
# the user can't wake up from over VNC.
#
# Chromium flags:
#   --start-maximized: window fills the Xvnc geometry. Combined with
#       Openbox's <maximized>true</maximized> + <decor>no</decor>, the
#       result is Chromium edge-to-edge with its own URL bar + tabs as
#       the only visible chrome. We deliberately avoid --kiosk and
#       --start-fullscreen here: both flags hide Chromium's URL bar,
#       which leaves the user looking at a blank about:blank canvas
#       with no way to navigate (the console doesn't render its own
#       URL bar overlay).
#   --no-sandbox: the universal base runs `devshot` as a regular user,
#       but Chromium's namespace sandbox needs setuid bits the busybox
#       coreutils don't ship with. --no-sandbox is fine here because the
#       VM itself IS the sandbox — the operator has full guest access.
#   --user-data-dir=...: keep the profile under $HOME so storage-save
#       picks it up and the next boot resumes tabs/cookies.
#   --remote-debugging-port=9222: opens DevTools on a TCP socket that
#       the agent's detectBrowserCapability() probes. Bind to 0.0.0.0
#       so `socat -L 0.0.0.0:9222 ...` from the agent can reach it.
#   --remote-allow-origins=*: required since Chrome 111 — DevTools
#       refuses cross-origin WebSocket upgrades without the allowlist.
#   --disable-features=...: kill the first-run nag screens and the
#       password-leak nag.
#   --homepage / start URL: about:blank lets the user / API drive.
cat > "$DEVSHOT_HOME/.config/openbox/autostart" <<'AUTOSTART'
#!/bin/sh
xset s off -dpms &
xset s noblank &
exec chromium-browser \
  --start-maximized \
  --no-sandbox \
  --user-data-dir=/home/devshot/.config/chromium-data \
  --remote-debugging-port=9222 \
  --remote-debugging-address=0.0.0.0 \
  --remote-allow-origins=* \
  --disable-features=ChromeWhatsNewUI,PasswordLeakDetection,SafeBrowsingEnhancedProtection \
  --disable-translate \
  --noerrdialogs \
  --no-first-run \
  --homepage=about:blank \
  about:blank
AUTOSTART
chmod +x "$DEVSHOT_HOME/.config/openbox/autostart"

chown -R devshot:devshot "$DEVSHOT_HOME"

# ── 4. /usr/local/bin launchers ────────────────────────────────────────
# Same start-* / stop-* shape as desktop.sh so muscle memory carries.
# Default geometry tracks Chrome's default test window (1280x800) — the
# agent's screenshot/recording paths assume that resolution unless the
# operator overrides VNC_GEOMETRY.
cat > /usr/local/bin/start-browser <<'LAUNCHER'
#!/bin/sh
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi

VNC_GEOMETRY="${VNC_GEOMETRY:-1280x800}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5900}"

# Wipe stale Xvnc state — same dance as the desktop launcher.
pkill -f 'Xvnc :0' 2>/dev/null || true
pkill -f 'openbox' 2>/dev/null || true
pkill -f 'chromium' 2>/dev/null || true
rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# Start Xvnc as `devshot` so Chromium's profile dir is owned by the
# right user. -SecurityTypes None opens the wire — the spec-050 forward
# allowlist gates network-side access, the VM itself trusts whoever
# reaches :5900.
sudo -u devshot env DISPLAY=:0 \
  Xvnc :0 \
  -SecurityTypes None \
  -geometry "$VNC_GEOMETRY" \
  -depth "$VNC_DEPTH" \
  -rfbport "$VNC_PORT" \
  -rfbauth /dev/null \
  -localhost no \
  -UseBlacklist=0 \
  &> /tmp/Xvnc.log &
XVNC_PID=$!

# Wait for Xvnc to bind before launching Openbox — otherwise Openbox
# races the X server and exits with "cannot connect to display".
for _ in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/$VNC_PORT) 2>/dev/null; then break; fi
  sleep 0.2
done

# Start dbus session so Chromium doesn't spin on missing-bus warnings,
# then Openbox (which autostarts Chromium per the autostart script).
sudo -u devshot env DISPLAY=:0 dbus-launch openbox-session &> /tmp/openbox.log &
OPENBOX_PID=$!

if [ "$detached" = "1" ]; then
  echo "Browser started — VNC :$VNC_PORT, DevTools :9222 (xvnc=$XVNC_PID openbox=$OPENBOX_PID)"
  exit 0
fi

wait "$OPENBOX_PID"
LAUNCHER
chmod 0755 /usr/local/bin/start-browser

cat > /usr/local/bin/stop-browser <<'STOP'
#!/bin/sh
pkill -f 'chromium' 2>/dev/null || true
pkill -f 'openbox' 2>/dev/null || true
pkill -f 'Xvnc :0' 2>/dev/null || true
echo "Browser stopped."
STOP
chmod 0755 /usr/local/bin/stop-browser

# ── 5. OpenRC service: auto-start on boot ──────────────────────────────
# Same shape as devshot-desktop / devshot-android so operators can
# disable with a one-liner: rc-update del devshot-browser default
cat > /etc/init.d/devshot-browser <<'INITD'
#!/sbin/openrc-run

description="DevShot Chromium browser (Xvnc + Openbox)"

depend() {
    need net
    after networking
}

start() {
    ebegin "Starting DevShot browser"
    /usr/local/bin/start-browser -d
    eend $?
}

stop() {
    ebegin "Stopping DevShot browser"
    /usr/local/bin/stop-browser
    eend $?
}

status() {
    if pgrep -f 'chromium' >/dev/null 2>&1; then
        einfo "running (chromium alive)"
        return 0
    fi
    einfo "stopped"
    return 3
}
INITD
chmod +x /etc/init.d/devshot-browser
rc-update add devshot-browser default

echo "=== browser recipe complete ==="
ls /usr/local/bin/start-browser /usr/local/bin/stop-browser
ls /etc/init.d/devshot-browser
which Xvnc openbox chromium-browser
