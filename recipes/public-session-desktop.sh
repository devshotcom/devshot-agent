#!/bin/sh
# Recipe: noVNC + websockify on top of devshot-guest-desktop.qcow2.
#
# Run via:
#   devshot-agent bake run \
#     --base=devshot-guest-desktop.qcow2 \
#     --recipe=apps/agent/recipes/public-session-desktop.sh \
#     --name=public-session-desktop
#
# Output template: devshot-guest-public-session-desktop.qcow2.
#
# Why a separate template?
#   * The plain desktop image (recipes/desktop.sh) intentionally does
#     NOT include websockify. The authenticated console uses WebRTC
#     DataChannels straight to :5900 — no in-VM HTTP bridge — and
#     websockify pulls in the full python3 stdlib (+~50 MB; trips YARA
#     scanners on legitimate stdlib code). For the AUTHENTICATED path
#     those bytes are pure overhead and the YARA noise is real harm.
#   * The PUBLIC marketing-site demo is different: anonymous visitors
#     can't run the WebRTC handshake (signaling is auth'd), so the
#     console's /api/public/p/<vm>/6080/* proxy fronts noVNC's plain
#     WebSocket transport. That requires noVNC + websockify INSIDE the
#     VM, listening on :6080.
#
# This recipe stacks on top of the desktop template, adding the noVNC
# web client + websockify daemon, exposing :6080, and updating the
# start-desktop launcher to bring websockify up alongside Xvnc.
#
# Spec 050 — both VNC and noVNC ports are pre-populated into the per-
# VM forward allowlist via the magic-comment header below. The
# anonymous proxy in tunnel-server.js looks up `expose_public=true`
# in pool_claims (set by lib/session.js on every demo claim) AND
# the agent enforces this allowlist — defense in depth.
#
# devshot:exposed_ports=[{"port":5900,"name":"vnc","proto":"tcp"},{"port":6080,"name":"novnc","proto":"http"}]
set -eux

# ── 1. Packages ─────────────────────────────────────────────────────────
# novnc — bundles the HTML/JS client at /usr/share/novnc/. Alpine
#   community repo carries it as `novnc`. The bundle includes
#   vnc.html / vnc_lite.html and the core/ JS modules noVNC needs.
# websockify — Python WS-to-TCP proxy. Listens on :6080, upgrades
#   visitor's WebSocket and pumps bytes to/from 127.0.0.1:5900. Also
#   serves the noVNC files from --web=/usr/share/novnc.
#
# Both pulled from the community repo (enabled below if not already).
# `--no-cache` keeps the template lean.
if ! grep -q '^http.*community' /etc/apk/repositories; then
    # Mirror the alpine-version line already present so the community
    # branch tracks the same release as main.
    main_line=$(grep -m1 '^http.*main$' /etc/apk/repositories || true)
    if [ -n "$main_line" ]; then
        community_line=$(echo "$main_line" | sed 's|/main$|/community|')
        echo "$community_line" >> /etc/apk/repositories
    fi
fi
apk update || (sleep 5 && apk update)
apk add --no-cache novnc websockify

# ── 2. Locate the noVNC web root ───────────────────────────────────────
# Alpine's novnc package installs to /usr/share/novnc (vnc.html lives
# at the top level there). We hard-code the path in the launcher
# below; this echo is just a sanity check for the bake log.
test -f /usr/share/novnc/vnc.html || {
    echo "ERROR: /usr/share/novnc/vnc.html missing — novnc package layout changed?" >&2
    exit 1
}

# ── 3. Drop a start-novnc launcher ─────────────────────────────────────
# Runs the websockify proxy under the `devshot` user so it doesn't have
# extra privileges to anything Xvnc didn't already grant. --web serves
# the noVNC HTML; the WebSocket on the same port proxies to :5900.
cat > /usr/local/bin/start-novnc <<'LAUNCHER'
#!/bin/sh
# Start websockify on :6080, proxying WebSocket frames to local :5900
# (where Xvnc is listening, started by start-desktop). Also serves the
# bundled noVNC HTML/JS from /usr/share/novnc.
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi

# Make sure Xvnc is up first — websockify will refuse to start if
# :5900 isn't listening. start-desktop is the conventional way to
# bring Xvnc up; if it isn't running we kick it.
if ! ss -ltn 2>/dev/null | grep -q ':5900 '; then
    /usr/local/bin/start-desktop -d >/dev/null 2>&1 || true
    # Wait briefly for Xvnc to come up.
    for _ in $(seq 1 30); do
        ss -ltn 2>/dev/null | grep -q ':5900 ' && break
        sleep 0.2
    done
fi

# Kill any stale websockify on :6080 from a previous run.
pkill -f 'websockify.*:6080' 2>/dev/null || true
sleep 0.2

NOVNC_WEB=/usr/share/novnc

if [ "$detached" = "1" ]; then
    nohup su -s /bin/sh devshot -c "websockify --web=${NOVNC_WEB} 6080 127.0.0.1:5900 \
        >/tmp/novnc.log 2>&1" &
    echo "noVNC started — http://<vm>:6080/vnc.html"
    exit 0
fi
exec su -s /bin/sh devshot -c "websockify --web=${NOVNC_WEB} 6080 127.0.0.1:5900"
LAUNCHER
chmod 0755 /usr/local/bin/start-novnc

# ── 4. OpenRC service: auto-start at boot ──────────────────────────────
# Operators who pool-set-base-image to this template get the public
# demo experience for free — every claimed VM boots with both Xvnc
# (from the inherited devshot-desktop service) and websockify (this
# one) listening. Order: after net + after devshot-desktop so :5900 is
# alive before :6080 tries to dial it.
cat > /etc/init.d/devshot-novnc <<'INITD'
#!/sbin/openrc-run

description="DevShot noVNC bridge (websockify :6080 → :5900)"

depend() {
    need net
    after networking
    after devshot-desktop
}

start() {
    ebegin "Starting DevShot noVNC bridge"
    /usr/local/bin/start-novnc -d
    eend $?
}

stop() {
    ebegin "Stopping DevShot noVNC bridge"
    pkill -f 'websockify.*:6080' 2>/dev/null || true
    eend 0
}

status() {
    if pgrep -f 'websockify.*:6080' >/dev/null 2>&1; then
        einfo "running (websockify :6080 alive)"
        return 0
    fi
    einfo "stopped"
    return 3
}
INITD
chmod +x /etc/init.d/devshot-novnc
rc-update add devshot-novnc default

# ── 5. Sanity log ──────────────────────────────────────────────────────
echo "=== public-session-desktop recipe complete ==="
ls /usr/local/bin/start-novnc /etc/init.d/devshot-novnc
ls /usr/share/novnc/vnc.html
which websockify
