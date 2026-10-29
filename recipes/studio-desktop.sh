#!/bin/sh
# Recipe: Studio Desktop — one machine, and Grok builds in it (spec 459).
#
# Runs ON TOP of the desktop payload (recipes/desktop.sh): Alpine, Xvnc :5900,
# Openbox + tint2, Chromium, xdotool/scrot/xclip, Grok + Spec Kit. This layer
# adds what turns that desktop into the Studio's one central machine:
#
#   - no app stack is baked in: the guest agent's Grok installs WordPress,
#     Next.js or whatever the request needs, in the open, with internet on
#     (the console's desktop stack declares it);
#   - the agent's terminal is one menu click away on the desktop: every
#     studio-exec appends to /var/log/devshot/agent-terminal.log
#     (studio_actions.go) and "Agent terminal" opens an xterm that tails it;
#   - the agent's governed Chromium opens on :0 instead of headless
#     (studio_browser.go studioBrowserDisplay), so the person watching the
#     VNC desktop sees the page the agent reads;
#   - the few tools an agent needs to fetch and unpack things itself;
#   - round three: /usr/local/bin/devshot-desktop, the agent's own way to see
#     and drive the screen (go/desktop_actions.go), the same implementation
#     the console's computer_use runs over studio-exec.
#
# In the dom0 image this is stage 4e of Dockerfile.dom0-x86 (FROM
# desktop-rootfs). As a bake VM recipe it needs the desktop recipe first:
#   devshot-agent bake run --recipe=apps/agent/recipes/desktop.sh --name=desktop
#   devshot-agent bake run --recipe=apps/agent/recipes/studio-desktop.sh --name=studio-desktop
#
# Spec 050 — declared listen ports auto-populate the per-VM forward allowlist:
# devshot:exposed_ports=[{"port":5900,"name":"vnc","proto":"tcp"}]
# Shared Workspace: host-admitted growth for the desktop and independent
# project cgroups. Two projects request 4096 MB in this same VM.
# devshot:memory_mb=8192
# Operator 2026-10-27: it boots with only what the machine needs; the agent
# asks for 1024 MB when Grok runs and 2048 MB for the desktop (go/vm_memory.go):
# devshot:boot_memory_mb=512
# Space for verified OS activation, immutable staging and sparse project disks.
# devshot:disk_gb=64
set -eux
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ── 0. The desktop payload must already be here ───────────────────────────
for binary in Xvnc openbox tint2 xterm xdotool scrot xclip chromium git grok node npm; do
  command -v "$binary" >/dev/null 2>&1 || {
    echo "ERROR: studio-desktop needs the desktop payload first (missing $binary)" >&2
    exit 1
  }
done
[ -x /usr/local/bin/start-desktop ] || { echo "ERROR: start-desktop missing — run recipes/desktop.sh first" >&2; exit 1; }

# ── 1. What an agent that installs its own stack reaches for ─────────────
# curl/jq/unzip/rsync for downloads and archives, bash for the scripts most
# READMEs assume, build-base + python3 so native npm modules and apk packages
# with post-install hooks work. PHP, MariaDB, nginx and friends stay OUT: the
# agent chooses and installs them per project (`apk add`, with sudo).
apk update || (sleep 5 && apk update)
apk add --no-cache \
    curl jq unzip rsync bash \
    build-base python3 \
    openssh-client \
    mandoc less \
    bubblewrap slirp4netns nftables e2fsprogs e2fsprogs-extra util-linux-misc

# Workspace projects share this VM but receive private mount/PID/network/user
# namespaces and cgroup-v2 resource controls. The marker is a versioned restore
# ABI; the agent advertises workspace-v1 only on this prepared image.
mkdir -p /etc/devshot /workspace/projects /workspace/shared
printf '%s\n' studio-desktop-workspace-v1 > /etc/devshot/workspace-base
chmod 0711 /workspace/projects
chmod 0700 /workspace/shared
# A single unified hierarchy is required by clone3/cgroup.freeze/cgroup.kill.
printf '\nrc_cgroup_mode="unified"\n' >> /etc/rc.conf
rc-update add cgroups boot

for binary in bwrap slirp4netns nft mkfs.ext4 mount umount; do
    command -v "$binary" >/dev/null
done

# ── 2. The workspace: /home/devshot is the project ─────────────────────────
# The console's desktop stack names /home/devshot as the project directory
# (stack-config.js) and the guest agent lists it among its Studio roots
# (studio_actions.go). Spec Kit is initialised per project at first turn
# (ensure-grok-speckit.sh), so only git's view of the tree is prepared here.
DEVSHOT_HOME=/home/devshot
mkdir -p "$DEVSHOT_HOME/workspace"
su -s /bin/sh devshot -c "git config --global init.defaultBranch main && \
  git config --global user.name 'DevShot Studio' && \
  git config --global user.email 'studio@devshot.com' && \
  git config --global --add safe.directory '*'"

# ── 3. The agent's terminal, on demand on the desktop ─────────────────────
# studio_actions.go appends every studio-exec (command, then the head of its
# output) to this log when the directory exists. The agent runs as root and
# the desktop session as devshot, so the file is group-writable and the
# directory setgid: whoever creates it, the devshot user can read it.
install -d -m 2775 -o root -g devshot /var/log/devshot
install -m 0664 -o devshot -g devshot /dev/null /var/log/devshot/agent-terminal.log
printf '# DevShot Studio — the agent'"'"'s terminal. Every command the agent runs lands here.\n' \
  > /var/log/devshot/agent-terminal.log

# The log is always available, but its window opens only on explicit request.
# Chat shows execution output; an idle desktop needs no agent taskbar entry.
cat > /usr/local/bin/devshot-agent-terminal <<'TERMINAL'
#!/bin/sh
# Keep the agent log in the background. Only --show opens it for the user.
export DISPLAY=:0
LOG=/var/log/devshot/agent-terminal.log
background=1
case "${1-}" in
  ""|--background) ;;
  --show) background=0 ;;
  *) printf 'usage: devshot-agent-terminal [--background|--show]\n' >&2; exit 2 ;;
esac
if xdotool search --name '^DevShot Agent$' >/dev/null 2>&1; then
  if [ "$background" = "1" ]; then
    xdotool search --name '^DevShot Agent$' windowminimize >/dev/null 2>&1
    exit $?
  fi
  xdotool search --name '^DevShot Agent$' windowactivate --sync >/dev/null 2>&1 || true
  exit 0
fi
[ "$background" = "1" ] && exit 0
exec xterm -T 'DevShot Agent' -fa 'Noto Sans Mono' -fs 10 \
  -bg '#101114' -fg '#d7d8dc' -geometry 158x20+0-0 \
  -e sh -c "tail -n 60 -F $LOG"
TERMINAL
chmod 0755 /usr/local/bin/devshot-agent-terminal

# Remove the old background terminal from existing desktop configurations.
AUTOSTART="$DEVSHOT_HOME/.config/openbox/autostart"
if [ -f "$AUTOSTART" ]; then
  sed -i '/the agent.s terminal/d; /devshot-agent-terminal/d' "$AUTOSTART"
fi

# Openbox menu entry next to the desktop's own Terminal item.
RCXML="$DEVSHOT_HOME/.config/openbox/rc.xml"
if [ -f "$RCXML" ]; then
  sed -i 's|devshot-agent-terminal</execute>|devshot-agent-terminal --show</execute>|g' "$RCXML"
fi
if [ -f "$RCXML" ] && ! grep -q devshot-agent-terminal "$RCXML"; then
  sed -i 's|<item label="Terminal">|<item label="Agent terminal"><action name="Execute"><execute>/usr/local/bin/devshot-agent-terminal --show</execute></action></item>\n    <item label="Terminal">|' "$RCXML"
fi

# ── 3b. The desktop CLI: devshot-desktop (spec 459, round three) ──────────
# `devshot-agent desktop <action>` (go/desktop_actions.go) performs the typed
# computer-use actions on :0 as one process — xdotool, scrot, xclip with an
# argv, no shell — and answers one JSON line plus the PNG. It is the ONE
# implementation: the console's computer_use runs it over studio-exec with
# --png=inline, and the Grok in this VM runs it at its own shell, reading the
# PNG it writes under /tmp/devshot-desktop (one local process instead of a
# ~3 s round trip through the console). Each action also leaves one line in
# the agent's terminal log above. The binary is the guest agent already in
# this image, so nothing is copied: the wrapper only names the subcommand.
test -x /opt/devshot/agent || { echo "ERROR: studio-desktop needs the guest agent at /opt/devshot/agent" >&2; exit 1; }
# The guest image locks /opt/devshot to root (0700, Dockerfile.dom0-*), so
# the workspace user — Grok at its shell, the person at the desktop — got
# "Permission denied" from every wrapper below that execs the agent
# (devshot-desktop since round three, devshot-browser's browser-open). 0711
# lets them run the agent's CLI and nothing more: they still cannot list or
# write the directory, and the agent binary was 0755 already.
chmod 0711 /opt/devshot
cat > /usr/local/bin/devshot-desktop <<'DESKTOP'
#!/bin/sh
# See and drive the desktop on :0 — `devshot-desktop help` lists the actions.
# Same implementation as the Studio's computer_use (spec 459, round three).
[ -d /tmp/devshot-desktop ] || mkdir -m 1777 -p /tmp/devshot-desktop 2>/dev/null || true
exec /opt/devshot/agent desktop "$@"
DESKTOP
chmod 0755 /usr/local/bin/devshot-desktop
# Where the CLI leaves its screenshots: world-writable with the sticky bit,
# so whoever runs the CLI first (the agent as devshot, an operator as root)
# does not lock the other out.
install -d -m 1777 /tmp/devshot-desktop

# ── 4. The agent's browser on this display ────────────────────────────────
# studio_browser.go opens Chromium on :0 when /tmp/.X11-unix/X0 exists at
# launch (studioBrowserDisplay), and that browser is the desktop's ONE
# browser (go/studio_browser_desktop.go): the agent listens on
# /run/devshot-desktop-browser.sock and `devshot-browser` hands every launch
# to it. Here every other way to start Chromium on this desktop is routed
# through `devshot-browser` too — Grok's own `chromium <url>` at its shell
# (PATH has /usr/local/bin first), the tint2 dock icon and xdg-open (a
# chromium.desktop in /usr/local/share shadows the package's). Before
# (2026-10-25) each started its own instance on its own profile beside the
# agent's, and the agent never knew a window was already open.
# Headless and scripted runs (screenshots, --dump-dom, a debugging port, an
# explicit profile) are not a window anyone shares: they keep the real binary.
for name in chromium chromium-browser; do
  cat > "/usr/local/bin/$name" <<'CHROMIUM'
#!/bin/sh
# Spec 459 — Chromium on the desktop machine is the agent's one browser.
for arg in "$@"; do
  case "$arg" in
    --headless*|--dump-dom|--screenshot*|--print-to-pdf*|--remote-debugging-*|--user-data-dir*|--version|--help|-h)
      exec /usr/bin/chromium-browser "$@" ;;
  esac
done
exec /usr/local/bin/devshot-browser "$@"
CHROMIUM
  chmod 0755 "/usr/local/bin/$name"
done
install -d -m 0755 /usr/local/share/applications
sed -e 's|^Exec=/usr/bin/chromium-browser --incognito.*|Exec=/usr/local/bin/devshot-browser|' \
    -e 's|^Exec=/usr/bin/chromium-browser|Exec=/usr/local/bin/devshot-browser|' \
    /usr/share/applications/chromium.desktop > /usr/local/share/applications/chromium.desktop
TINT2RC="$DEVSHOT_HOME/.config/tint2/tint2rc"
if [ -f "$TINT2RC" ]; then
  sed -i 's|^launcher_item_app = /usr/share/applications/chromium.desktop|launcher_item_app = /usr/local/share/applications/chromium.desktop|' "$TINT2RC"
fi

# ── 4b. The desktop starts on demand ─────────────────────────────────────
# Operator 2026-10-25: the machine does not boot into a desktop. Until the
# agent needs a screen (a desktop app, computer_use, a look at the page in a
# real window) the terminal and the app's port are enough, and a website
# build never pays for Xvnc, Openbox and a compositor. desktop.sh enabled the
# service for the public desktop demo; this image takes it out of the
# runlevel. Every devshot-desktop action starts it first when it is off
# (go/desktop_start.go), and the agent's shell can run `devshot-desktop
# start`. The agent runs as devshot, and the claim drops its general sudo
# rule on other stacks, so exactly this one command gets its own rule.
rc-update del devshot-desktop default 2>/dev/null || true
cat > /etc/sudoers.d/devshot-desktop-start <<'SUDOERS'
devshot ALL=(root) NOPASSWD: /usr/local/bin/start-desktop -d
SUDOERS
chmod 0440 /etc/sudoers.d/devshot-desktop-start
# The desktop needs 2048 MB: start-desktop (root through the rule above) asks
# dom0 for it before Xvnc starts, so the RAM is there first. On a host that
# does not resize this returns at once.
if ! grep -q 'devshot-agent-memory' /usr/local/bin/start-desktop; then
  sed -i '1a /opt/devshot/agent memory request 2048 desktop >/dev/null 2>\&1 || true # devshot-agent-memory' /usr/local/bin/start-desktop
fi

# ── 4c. A machine that boots with 512 MB ─────────────────────────────────
# The chat phase runs only the machine itself (operator 2026-10-27). A zram
# swap (lz4, half of the boot RAM) absorbs the restore and backup peaks until
# the agent has asked for more; swappiness 100 and page-cluster 0 are the
# usual settings for swap that lives in RAM. rc.log records each service's
# start so the boot can be measured on a real VM.
cat > /etc/init.d/devshot-zram <<'ZRAM'
#!/sbin/openrc-run
description="zram swap for the 512 MB chat phase"

depend() {
    after localmount
}

start() {
    # The image may not run the sysctl service at boot.
    sysctl -q -p /etc/sysctl.d/90-devshot-low-memory.conf 2>/dev/null || true
    [ -e /sys/block/zram0 ] || modprobe zram 2>/dev/null || true
    if [ ! -e /sys/block/zram0 ]; then
        ewarn "this kernel has no zram; no swap"
        return 0
    fi
    grep -q '^/dev/zram0 ' /proc/swaps && return 0
    size_mb=$(awk '/^MemTotal:/ { print int($2 / 2048) }' /proc/meminfo)
    ebegin "Starting zram swap (${size_mb} MB, lz4)"
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "${size_mb}M" > /sys/block/zram0/disksize &&
        mkswap /dev/zram0 >/dev/null &&
        swapon -p 100 /dev/zram0
    eend $?
}

stop() {
    grep -q '^/dev/zram0 ' /proc/swaps || return 0
    swapoff /dev/zram0
    echo 1 > /sys/block/zram0/reset
}
ZRAM
chmod 0755 /etc/init.d/devshot-zram
rc-update add devshot-zram boot
cat > /etc/sysctl.d/90-devshot-low-memory.conf <<'SYSCTL'
vm.swappiness = 100
vm.page-cluster = 0
SYSCTL
sed -i 's/^#\?rc_logger=.*/rc_logger="YES"/' /etc/rc.conf
grep -q '^rc_logger="YES"' /etc/rc.conf || echo 'rc_logger="YES"' >> /etc/rc.conf

# ── 5. Verify ─────────────────────────────────────────────────────────────
for binary in curl jq unzip rsync bash python3 gcc; do
  command -v "$binary" >/dev/null 2>&1 || { echo "ERROR: studio-desktop is missing $binary" >&2; exit 1; }
done
test -x /usr/local/bin/devshot-agent-terminal
# The desktop is off at boot and starts on demand.
if rc-update show default 2>/dev/null | grep -q devshot-desktop; then
  echo "ERROR: the desktop still starts at boot" >&2; exit 1
fi
visudo -c -f /etc/sudoers.d/devshot-desktop-start >/dev/null
grep -q 'memory request 2048 desktop' /usr/local/bin/start-desktop
rc-update show boot 2>/dev/null | grep -q devshot-zram
/usr/local/bin/devshot-desktop help | grep -q 'start the desktop if it is off'
# Every launcher ends at the agent's browser: no Exec of the package binary
# left in the shadowing entry, the dock pointing at it, `chromium` the wrapper.
if grep -q '^Exec=/usr/bin/chromium' /usr/local/share/applications/chromium.desktop; then
  echo "ERROR: the desktop entry still starts Chromium beside the agent's browser" >&2; exit 1
fi
grep -q '^Exec=/usr/local/bin/devshot-browser' /usr/local/share/applications/chromium.desktop
grep -q 'launcher_item_app = /usr/local/share/applications/chromium.desktop' "$TINT2RC"
su -s /bin/sh devshot -c 'command -v chromium' | grep -qx /usr/local/bin/chromium
grep -q 'browser-open' /usr/local/bin/devshot-browser
# The guest agent must know browser-open (an older one would start the
# role-based agent): with no socket it answers 75, the launcher's fallback.
browser_open_status=0
/opt/devshot/agent browser-open --socket=/nonexistent/devshot-desktop-browser.sock 2>/dev/null || browser_open_status=$?
test "$browser_open_status" -eq 75
# The agent terminal starts with the desktop, minimized — never in front.
grep -q 'devshot-agent-terminal --background' "$AUTOSTART"
if grep devshot-agent-terminal "$AUTOSTART" | grep -qv -- '--background'; then
  echo "ERROR: the agent terminal opens in front at login" >&2; exit 1
fi
grep -q -- '-iconic' /usr/local/bin/devshot-agent-terminal
# The guest agent in this image must know the subcommand: an older binary
# would start the role-based agent instead of answering, so the bake fails
# here rather than shipping a wrapper that misbehaves.
test -x /usr/local/bin/devshot-desktop
/usr/local/bin/devshot-desktop actions | grep -q '"left_click"'
su -s /bin/sh devshot -c '/usr/local/bin/devshot-desktop actions' | grep -q '"left_click"'
/usr/local/bin/devshot-desktop help | grep -q 'until two frames'
su -s /bin/sh devshot -c 'test -w /tmp/devshot-desktop'
# A screenshot cannot run at bake time (no X server yet): the CLI refuses a
# bad action with its JSON line and exit 1, which proves the dispatch.
if /usr/local/bin/devshot-desktop launch_nuke --quiet >/tmp/devshot-desktop-probe.json 2>/dev/null; then
  echo "ERROR: devshot-desktop accepted an unknown action" >&2; exit 1
fi
grep -q '"unknown action: launch_nuke"' /tmp/devshot-desktop-probe.json
rm -f /tmp/devshot-desktop-probe.json
test -w /var/log/devshot/agent-terminal.log
su -s /bin/sh devshot -c 'test -w /var/log/devshot/agent-terminal.log'
su -s /bin/sh devshot -c 'git config --global --get init.defaultBranch' | grep -qx main
echo "=== studio-desktop recipe complete ==="
