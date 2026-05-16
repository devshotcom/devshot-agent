#!/bin/sh
# Recipe: Headless Chromium browser — Xvnc + Openbox + Chromium kiosk.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/browser.sh --name=browser
#
# Output template: devshot-guest-browser.qcow2. Every VM spawned from
# it boots straight into a fullscreen Chromium window on TCP:5900
# (raw RFB). The DevShot console's /console/browser tab dials :5900
# directly over WebRTC DataChannel — same transport as Desktop / Phone.
#
# Differences vs the desktop recipe:
#   - No tint2 / picom / file manager / GTK theming. Browser-only kiosk.
#   - Chromium auto-launches fullscreen as `devshot` after Xvnc binds
#     :5900. tab/menu hidden via --kiosk + --start-fullscreen.
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

# ── 1. Network hardening (mirrors desktop.sh) ──────────────────────────
# Inside Docker BUILD this is a no-op (the daemon already configured
# DNS); inside a live bake VM it forces IPv4 to dodge IPv6-flaky
# Alpine mirrors. Either path keeps the apk cycle reliable.
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
echo 'options single-request-reopen' >> /etc/resolv.conf 2>/dev/null || true
echo 'nameserver 1.1.1.1'              >> /etc/resolv.conf 2>/dev/null || true
apk update || (sleep 5 && apk update)

# ── 2. Packages ────────────────────────────────────────────────────────
# tigervnc:        Xvnc binary — same VNC server desktop uses.
# openbox:         Tiny window manager Chromium runs under (Chromium
#                  refuses to start without one — even in --kiosk it
#                  asks the WM for a fullscreen frame).
# chromium:        The actual browser. Alpine ships an aarch64/amd64
#                  build under chromium and chromium-swiftshader.
# ttf-dejavu / ttf-liberation / font-noto-emoji: enough fallback fonts
#                  that most websites render legibly out of the box.
# dbus / dbus-x11: Chromium's account/cookie helpers and Openbox both
#                  poke dbus on startup; without it Chromium spends
#                  ~3 s timing out per launch.
# xset:            One-line trick to disable screen blanking; the
#                  desktop recipe doesn't need it because tint2's idle
#                  inhibits work, but kiosk-mode Chromium has no panel.
apk add --no-cache \
    tigervnc \
    openbox \
    chromium \
    dbus dbus-x11 \
    ttf-dejavu ttf-liberation font-noto-emoji \
    xset

# ── 3. Per-user kiosk config ───────────────────────────────────────────
# The universal base already created the `devshot` user. We just need
# to drop a tiny Openbox config and a fresh Chromium profile.
DEVSHOT_HOME=/home/devshot
mkdir -p "$DEVSHOT_HOME/.config/openbox" "$DEVSHOT_HOME/.vnc" "$DEVSHOT_HOME/.config/chromium-data"

# Openbox config — strip every key/title bar/menu/dock binding so the
# user can't accidentally close the browser or open a context menu they
# can't get out of. Only Alt+F4 (close window) and Super+Tab (cycle)
# survive — operators sometimes need those for diagnostics.
cat > "$DEVSHOT_HOME/.config/openbox/rc.xml" <<'OBRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme><name>Clearlooks</name><titleLayout></titleLayout></theme>
  <desktops><number>1</number></desktops>
  <applications>
    <application name="*">
      <decor>no</decor>
      <fullscreen>yes</fullscreen>
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
#   --kiosk + --start-fullscreen: borderless, no tabs, no menus.
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
#       password-leak nag that pops up in kiosk mode.
#   --homepage / start URL: about:blank lets the user / API drive.
cat > "$DEVSHOT_HOME/.config/openbox/autostart" <<'AUTOSTART'
#!/bin/sh
xset s off -dpms &
xset s noblank &
exec chromium-browser \
  --kiosk --start-fullscreen \
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

description="DevShot kiosk Chromium (Xvnc + Openbox)"

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
