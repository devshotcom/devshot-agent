#!/bin/sh
# Recipe: VNC desktop — Openbox + tint2 + Xvnc.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/desktop.sh --name=desktop
#
# Output template: devshot-guest-desktop.qcow2. Every VM spawned from
# it boots straight into a working desktop on TCP:5900 (raw RFB). The
# DevShot console's /console/desktop tab dials :5900 directly over
# WebRTC DataChannel — no websockify / no in-VM HTTP bridge.
#
# We deliberately do NOT install websockify + novnc:
#   - The console's WebRTC path bypasses websockify entirely (browser
#     speaks RFB through a DataChannel, agent dials :5900 inside the
#     VM, no /vnc.html involved).
#   - websockify pulls in the full python3 stdlib, which adds ~50 MB
#     to the image and trips the bundled YARA rules on legitimate
#     stdlib helpers (pdb.py / doctest.py contain `exec(compile(`,
#     which the Python_Webshell rule reads as a webshell signature).
#     Stripping the dependency removes the alarms at the source — the
#     scanner correctly flagged unused code, not buggy detection.
#
# This is the bake-VM equivalent of apps/agent/docker/Dockerfile.domU-desktop:
# same package set, same theme + dock + wallpaper, same launcher style.
# Re-implemented as a recipe so the bakery can stamp a flavored qcow2
# ready for `pool-set-base-image desktop` selection in the console.
#
# Spec 050 — declared listen ports auto-populate the per-VM forward
# allowlist (and surface as Open buttons in the Servers tab):
# devshot:exposed_ports=[{"port":5900,"name":"vnc","proto":"tcp"}]
#
# Memory floor: Xvnc + openbox + tint2 + picom + the agent (~104MB RSS)
# does not fit in the default 256MB pool VM. Desktop Studio now also bakes
# Chromium for browser and research workflows; 1GB leaves room for a normal
# page without evicting the desktop or agent. createVM honours
# this and overrides the per-pool default when spawning from a template
# that declares it.
# devshot:memory_mb=1024
# devshot:disk_gb=6
set -eux

# ── 1. Packages ─────────────────────────────────────────────────────────
# Openbox + tint2 keep memory/disk small (~80 MB total) — the user can
# install heavier desktops on top after claiming. picom adds compositor
# eye-candy. tigervnc bundles Xvnc (X server + VNC export in one).
#
# Some bake hosts route IPv6 unreliably to Fastly (the dl-cdn.alpinelinux.org
# CDN front), so apk-tools' TLS handshake fails with "TLS: unspecified
# error". Force IPv4 by disabling IPv6 and pinning the resolver to IPv4-only
# so apk falls back to the IPv4 A record. Retry once if the index is still
# half-fetched.
#
# Spec 044: this recipe also runs inside a Docker build stage (the dom0
# image bakes a desktop template at CI time). Buildkit mounts
# /etc/resolv.conf read-only there, so the append-fallback `|| true`s
# below are required — the tweaks are only useful in live-VM bakes
# anyway, and Docker's own DNS is already configured by the daemon.
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
echo 'options single-request-reopen' >> /etc/resolv.conf 2>/dev/null || true
echo 'nameserver 1.1.1.1'              >> /etc/resolv.conf 2>/dev/null || true
apk update || (sleep 5 && apk update)
apk add --no-cache \
    ca-certificates wget git sudo \
    tigervnc \
    openbox tint2 picom \
    pcmanfm xterm \
    dbus dbus-x11 \
    xdotool scrot xclip \
    chromium chromium-swiftshader \
    greybird-themes-gtk3 \
    adwaita-icon-theme papirus-icon-theme \
    font-noto font-noto-emoji \
    feh \
    ripgrep file nodejs npm

# GTK3 theme Arc-Dark (matches the Arc-Dark-OSX Openbox theme below). Alpine
# ships it only in edge/testing; it is theme data without dependencies, so the
# one package comes from there without adding the repo for anything else. If
# edge/testing drops or breaks it, the desktop keeps Greybird-dark instead of
# failing the bake.
GTK3_THEME=Greybird-dark
if apk add --no-cache \
     --repository https://dl-cdn.alpinelinux.org/alpine/edge/testing \
     arc-dark-gtk3 \
   && [ -f /usr/share/themes/Arc-Dark/gtk-3.0/gtk.css ]; then
  GTK3_THEME=Arc-Dark
else
  echo "WARN: arc-dark-gtk3 from edge/testing unavailable, GTK stays Greybird-dark" >&2
fi

# Replace Alpine's lagging nodejs with the current LTS release
# from nodejs.org (see recipes/lib/install-node.sh).
/usr/local/libexec/devshot/install-node.sh

# Spec 451 — the project MCP's screenshot tool drives the apk Chromium through
# puppeteer-core at this fixed path (as studio.sh / lamp / blank / expo do), so
# Desktop reports console errors and broken images too. puppeteer-core ships
# no browser of its own.
install -d /opt/devshot-e2e
( cd /opt/devshot-e2e && npm init -y >/dev/null 2>&1 && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --omit=dev puppeteer-core )

# Desktop tools and Studio onboarding run as the unprivileged devshot user.
# Keep the qcow2 recipe's privilege contract identical to the standalone
# desktop container: maintenance commands must never block on an interactive
# password prompt inside an ephemeral VM.
install -d -m 0750 /etc/sudoers.d
printf 'devshot ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/devshot
chmod 0440 /etc/sudoers.d/devshot
visudo -cf /etc/sudoers

# xdotool + scrot + xclip back the typed AI-desktop-control surface.
# Chromium is part of the desktop image (like git and Grok), so browser and
# research scenarios never depend on an interactive runtime install:
#   /api/vms/:vm/desktop/screenshot (scrot via vm-exec)
#   /api/vms/:vm/desktop/action     (xdotool key/type/click via vm-exec)
#   /api/vms/:vm/browser/action     (chromium URL bar via xdotool + scrot)
# Without these baked in, screenshot endpoints return 503 and browser
# actions error out with "sh: xdotool: not found".

# ── 2. Grok Build + official GitHub Spec Kit ────────────────────────────
/usr/local/libexec/devshot/install-grok-speckit.sh

# ── 3. Per-user desktop config ─────────────────────────────────────────
# The universal base already created the `devshot` user with a hidden
# random password (project_vm_user_auth memory). We just need to drop
# config + wallpaper into its $HOME. mkdir -p is idempotent, so this
# recipe is safe to re-run on a respun bake VM.
DEVSHOT_HOME=/home/devshot
mkdir -p "$DEVSHOT_HOME/.config/openbox" \
         "$DEVSHOT_HOME/.config/tint2" \
         "$DEVSHOT_HOME/.config/gtk-3.0" \
         "$DEVSHOT_HOME/.vnc"

# GTK3 — Arc-Dark (or the Greybird-dark fallback, see section 1), Papirus
# icons, Noto sans
cat > "$DEVSHOT_HOME/.config/gtk-3.0/settings.ini" <<GTK3
[Settings]
gtk-theme-name=$GTK3_THEME
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Noto Sans 10
gtk-decoration-layout=close,minimize,maximize:
gtk-application-prefer-dark-theme=true
GTK3

# GTK2 fallback (some legacy apps still read this; Alpine's Arc has no GTK2)
cat > "$DEVSHOT_HOME/.gtkrc-2.0" <<'GTK2'
gtk-theme-name="Greybird-dark"
gtk-icon-theme-name="Papirus-Dark"
gtk-font-name="Noto Sans 10"
GTK2

# Openbox theme Arc-Dark-OSX — Arc-Dark colours with macOS traffic-light
# buttons. Not packaged by Alpine, so the four files are written here:
# github.com/Dr-Noob/Arc-Dark-OSX @ 3b5d1f21 (GPL-3.0, from dglava's Arc
# Openbox theme). Two fixes against upstream: its close colour key had a
# double dot ("button..close"), so the close button never turned red; and
# inactive buttons had no colour (Openbox drew them white), now macOS grey.
ARC_OB=/usr/share/themes/Arc-Dark-OSX/openbox-3
mkdir -p "$ARC_OB"
cat > "$ARC_OB/themerc" <<'ARCTHEMERC'
# Arc Openbox theme
# Copyright (C) 2015 Dino Duratović <dinomol at mail dot com>
#
# Inspired by and made for horst3180's Arc GTK theme
# https://github.com/horst3180/Arc-theme
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

### WINDOW
border.width: 1

window.client.padding.width: 0
window.client.padding.height: 0
window.handle.width: 0

padding.width: 4
padding.height: 4

window.active.border.color: #2d3036
window.inactive.border.color: #2d3036
window.active.title.separator.color: #2f343f
window.inactive.title.separator.color: #2f343f
window.active.client.color: #2d3036
window.inactive.client.color: #2d3036

window.active.label.text.color: #D3DAE3
window.inactive.label.text.color: #7F8388

window.active.button.unpressed.image.color: #D3DAE3
window.active.button.pressed.image.color: #5294E2
window.active.button.disabled.image.color: #dbdfe3
window.active.button.iconify.unpressed.image.color: #f9bc2d
window.active.button.max.unpressed.image.color: #2bcc46
window.active.button.close.unpressed.image.color: #f95f57
window.active.button.iconify.hover.image.color: #df9e07
window.active.button.max.hover.image.color: #24a83a
window.active.button.close.hover.image.color: #dd1308
window.active.button.toggled.unpressed.image.color: #24a83a

window.inactive.button.unpressed.image.color: #5c616c
window.inactive.button.pressed.image.color: #5294E2
window.inactive.button.disabled.image.color: #dddee2
window.inactive.button.hover.image.color: #afb8c5
window.inactive.button.toggled.unpressed.image.color: #dddee2
window.inactive.button.toggled.pressed.image.color: #5294E2
window.inactive.button.toggled.hover.image.color: #afb8c5

window.active.title.bg: flat solid
window.active.title.bg.color: #2f343f
window.active.label.bg: flat solid
window.active.label.bg.color: #2f343f
#window.active.handle.bg: texture
#window.active.grip.bg: texture
window.inactive.title.bg: flat solid
window.inactive.title.bg.color: #2f343f
window.inactive.label.bg: flat solid
window.inactive.label.bg.color: #2f343f
#window.inactive.handle.bg: texture
#window.inactive.grip.bg: texture

window.active.button.unpressed.bg: parentrelative
window.active.button.pressed.bg: parentrelative
window.active.button.hover.bg: parentrelative
window.active.button.disabled.bg: parentrelative
window.active.button.toggled.unpressed.bg: parentrelative
window.active.button.toggled.pressed.bg: parentrelative
window.active.button.toggled.hover.bg: parentrelative
window.inactive.button.unpressed.bg: parentrelative
window.inactive.button.pressed.bg: parentrelative
window.inactive.button.hover.bg: parentrelative
window.inactive.button.disabled.bg: parentrelative
window.inactive.button.toggled.unpressed.bg: parentrelative
window.inactive.button.toggled.pressed.bg: parentrelative
window.inactive.button.toggled.hover.bg: parentrelative

window.label.text.justify: center

#window.active.label.text.font: text shadow
#window.inactive.label.text.font: text shadow

### MENU
menu.border.width: 0
menu.separator.width: 1
menu.separator.padding.width: 10
menu.separator.padding.height: 2

menu.overlap.x: 0
menu.overlap.y: 0

menu.border.color: #aeb0b6
menu.separator.color: #a8adb5

menu.title.text.color: #D3DAE3
menu.items.text.color: #a8adb5
menu.items.disabled.text.color: #76797F
menu.items.active.text.color: #ffffff
menu.items.active.disabled.text.color: #aeb0b6

menu.items.bg: flat solid
menu.items.bg.color: #454a54
menu.items.active.bg: flat solid
menu.items.active.bg.color: #5294E2
menu.title.bg: flat solid
menu.title.bg.color: #2d3036

menu.title.text.justify: center

#menu.items.font: text shadow
#menu.title.text.font: text shadow

### OSD
osd.border.width: 1

osd.border.color: #2d3036

osd.label.text.color: #D3DAE3

osd.bg: flat solid
osd.bg.color: #2f343f
osd.label.bg: flat solid
osd.label.bg.color: #2f343f
osd.hilight.bg: flat solid
osd.hilight.bg.color: #5294E2
osd.unhilight.bg: flat solid
osd.unhilight.bg.color: #000000

#osd.label.text.font: text shadow
ARCTHEMERC
# close / iconify / max share one 10x10 filled circle; the theme colours them.
for button in close iconify max; do
  cat > "$ARC_OB/$button.xbm" <<ARCXBM
#define ${button}_width 10
#define ${button}_height 10
static unsigned char ${button}_bits[] = {
   0x7c, 0x00, 0xfe, 0x00, 0xff, 0x01, 0xff, 0x01, 0xff, 0x01, 0xff, 0x01,
   0xff, 0x01, 0xfe, 0x00, 0x7c, 0x00, 0x00, 0x00 };
ARCXBM
done

# Openbox window manager — Arc-Dark-OSX decorations, CIML title layout
# (close/min/max on the LEFT like macOS), 8 px corner radius, smart
# placement, alt-drag to move, alt-right to resize.
cat > "$DEVSHOT_HOME/.config/openbox/rc.xml" <<'OPENBOXRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <name>Arc-Dark-OSX</name>
    <titleLayout>CIML</titleLayout>
    <cornerRadius>8</cornerRadius>
    <font place="ActiveWindow"><name>Noto Sans</name><size>10</size><weight>Bold</weight></font>
    <font place="InactiveWindow"><name>Noto Sans</name><size>9</size><weight>Normal</weight></font>
    <font place="MenuHeader"><name>Noto Sans</name><size>10</size><weight>Bold</weight></font>
    <font place="MenuItem"><name>Noto Sans</name><size>10</size><weight>Normal</weight></font>
  </theme>
  <!-- Operator 2026-10-31: one desktop by default; the agent adds more when the work needs them. -->
  <desktops><number>1</number><names><name>Desktop</name></names></desktops>
  <resize><drawContents>yes</drawContents></resize>
  <placement><policy>Smart</policy><center>yes</center></placement>
  <mouse>
    <context name="Titlebar">
      <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
      <mousebind button="Left" action="DoubleClick"><action name="ToggleMaximize"/></mousebind>
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>client-menu</menu></action></mousebind>
    </context>
    <context name="Top"><mousebind button="Left" action="Drag"><action name="Resize"><edge>top</edge></action></mousebind></context>
    <context name="Bottom"><mousebind button="Left" action="Drag"><action name="Resize"><edge>bottom</edge></action></mousebind></context>
    <context name="Left"><mousebind button="Left" action="Drag"><action name="Resize"><edge>left</edge></action></mousebind></context>
    <context name="Right"><mousebind button="Left" action="Drag"><action name="Resize"><edge>right</edge></action></mousebind></context>
    <context name="Frame">
      <mousebind button="A-Left"  action="Drag"><action name="Move"/></mousebind>
      <mousebind button="A-Right" action="Drag"><action name="Resize"/></mousebind>
    </context>
    <context name="Root">
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind>
    </context>
    <context name="Close"><mousebind button="Left" action="Click"><action name="Close"/></mousebind></context>
    <context name="Maximize"><mousebind button="Left" action="Click"><action name="ToggleMaximize"/></mousebind></context>
    <context name="Iconify"><mousebind button="Left" action="Click"><action name="Iconify"/></mousebind></context>
  </mouse>
</openbox_config>
OPENBOXRC

# Right-click root menu — Terminal + File Manager + Apps submenu
cat > "$DEVSHOT_HOME/.config/openbox/menu.xml" <<'OBMENU'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.5/menu">
  <menu id="root-menu" label="DevShot">
    <item label="Browser"><action name="Execute"><execute>/usr/local/bin/devshot-browser</execute></action></item>
    <item label="Terminal"><action name="Execute"><execute>xterm -fa "Noto Sans Mono" -fs 11 -bg "#1c1c1e" -fg "#e5e5e7"</execute></action></item>
    <item label="File Manager"><action name="Execute"><execute>pcmanfm</execute></action></item>
    <separator />
    <menu id="apps" label="Applications">
      <item label="XTerm"><action name="Execute"><execute>xterm</execute></action></item>
      <item label="PCManFM"><action name="Execute"><execute>pcmanfm</execute></action></item>
    </menu>
    <separator />
    <item label="Reconfigure"><action name="Reconfigure" /></item>
  </menu>
</openbox_menu>
OBMENU

# tint2 dock panel — bottom dock, dark, macOS-inspired
cat > "$DEVSHOT_HOME/.config/tint2/tint2rc" <<'TINT2RC'
rounded = 0
border_width = 1
border_sides = T
background_color = #1c1c1e 85
border_color = #3a3a3c 50

rounded = 6
border_width = 0
background_color = #ffffff 15
border_color = #000000 0

rounded = 4
border_width = 0
background_color = #2c2c2e 95
border_color = #000000 0

panel_items = LTSC
panel_size = 100% 38
panel_margin = 0 0
panel_padding = 6 0 6
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all

launcher_padding = 4 2 4
launcher_background_id = 0
launcher_icon_size = 24
launcher_item_app = /usr/share/applications/chromium.desktop
launcher_item_app = /usr/share/applications/xterm.desktop
launcher_item_app = /usr/share/applications/pcmanfm.desktop

taskbar_mode = single_desktop
taskbar_padding = 2 0 4
taskbar_background_id = 0
taskbar_active_background_id = 0
taskbar_name = 0

task_text = 1
task_icon = 1
task_centered = 1
task_maximum_size = 180 30
task_padding = 6 2 4
task_font = Noto Sans 9
task_font_color = #c7c7cc 80
task_active_font_color = #ffffff 100
task_icon_asb = 100 0 0
task_active_icon_asb = 100 0 0
task_background_id = 0
task_active_background_id = 2
task_urgent_background_id = 0
task_iconified_font_color = #8e8e93 60

separator = new
separator_background_id = 0
separator_color = #48484a 40
separator_style = line
separator_size = 1
separator_padding = 4 4

systray_padding = 4 2 4
systray_background_id = 0
systray_icon_size = 20
systray_icon_asb = 100 0 0

time1_format = %H:%M
time1_font = Noto Sans Bold 10
time2_format = %a %d %b
time2_font = Noto Sans 8
clock_font_color = #e5e5e7 90
clock_padding = 8 0
clock_background_id = 0

tooltip_show_timeout = 0.3
tooltip_padding = 6 4
tooltip_background_id = 3
tooltip_font = Noto Sans 9
tooltip_font_color = #e5e5e7 100

mouse_left = toggle_iconify
mouse_middle = close
mouse_right = maximize_restore
mouse_scroll_up = toggle
mouse_scroll_down = iconify
TINT2RC

# Wallpaper — dark gradient with subtle blue + purple accents.
# imagemagick is added briefly, used once, then removed to keep the
# template lean (saves ~40 MB).
apk add --no-cache imagemagick
convert -size 1280x800 \
    -define gradient:angle=135 \
    'gradient:#0d1117-#161b22' \
    -fill 'rgba(56,139,253,0.08)' -draw 'circle 900,200 900,500' \
    -fill 'rgba(139,92,246,0.05)' -draw 'circle 300,600 300,900' \
    "$DEVSHOT_HOME/.wallpaper.png"
apk del imagemagick

# Openbox autostart — compositor, wallpaper, dock panel
cat > "$DEVSHOT_HOME/.config/openbox/autostart" <<'AUTOSTART'
#!/bin/sh
# picom: compositor — shadows, transparency, smooth rendering
picom --backend xrender --shadow --shadow-radius=12 --shadow-opacity=0.4 \
  --shadow-offset-x=-8 --shadow-offset-y=-8 --no-fading-openclose \
  --inactive-opacity=0.95 -b 2>/dev/null &
# Wallpaper (the system copy: a Workspace's private home has none, see 3b)
feh --bg-fill /usr/share/devshot/wallpaper.png &
# tint2 dock panel — DevShot's dock, not a stock tint2rc tint2 once copied
# into the home
tint2 -c /etc/xdg/tint2/tint2rc &
AUTOSTART
chmod +x "$DEVSHOT_HOME/.config/openbox/autostart"

chown -R devshot:devshot "$DEVSHOT_HOME"

# ── 3b. The same desktop for every home ───────────────────────────────
# A Workspace runs the desktop as uid 1000 in its private domain, where
# /home/devshot is the workspace's own home, not this image's
# (go/desktop_start.go privateDesktopStartCommand). Openbox, its autostart,
# tint2 and GTK fall back to /etc/xdg, /etc/gtk-3.0 and /etc/gtk-2.0 when the
# home has no config of its own, so the look lives there too (2026-10-30: a
# Workspace desktop showed stock Openbox — four "desktop N" desktops, no
# Arc-Dark-OSX, a grey tint2 bar). studio-desktop.sh edits both copies.
install -d -m 0755 /etc/xdg/openbox /etc/xdg/tint2 /etc/gtk-3.0 /etc/gtk-2.0 /usr/share/devshot
install -m 0644 "$DEVSHOT_HOME/.config/openbox/rc.xml" /etc/xdg/openbox/rc.xml
install -m 0644 "$DEVSHOT_HOME/.config/openbox/menu.xml" /etc/xdg/openbox/menu.xml
install -m 0755 "$DEVSHOT_HOME/.config/openbox/autostart" /etc/xdg/openbox/autostart
install -m 0644 "$DEVSHOT_HOME/.config/tint2/tint2rc" /etc/xdg/tint2/tint2rc
install -m 0644 "$DEVSHOT_HOME/.config/gtk-3.0/settings.ini" /etc/gtk-3.0/settings.ini
install -m 0644 "$DEVSHOT_HOME/.gtkrc-2.0" /etc/gtk-2.0/gtkrc
install -m 0644 "$DEVSHOT_HOME/.wallpaper.png" /usr/share/devshot/wallpaper.png

# ── 4. /usr/local/bin launchers ────────────────────────────────────────
# start-desktop  → bring up Xvnc :0 + openbox (foreground or -d).
# stop-desktop   → kill the lot.
# Same UX shape as start-n8n / start-flowise so muscle memory carries.
cat > /usr/local/bin/start-desktop <<'LAUNCHER'
#!/bin/sh
# Start the VNC desktop. Pass -d to run detached.
# Listens on :5900 (raw RFB). The /console/desktop tab dials :5900
# directly over WebRTC DataChannel — no in-VM HTTP/websockify bridge.
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi

VNC_GEOMETRY="${VNC_GEOMETRY:-1280x800}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5900}"

# Anything still bound from a prior run blocks Xvnc — wipe stale state.
pkill -f 'Xvnc :0' 2>/dev/null || true
pkill -f 'openbox' 2>/dev/null || true
rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# Xvnc: X server with VNC export. -SecurityTypes None opens the wire to
# whatever firewalled in front of it — for DevShot that's the spec-050
# forward channel which already gates the connection on the user's
# fingerprint allowlist. Keep Xvnc's own blacklist enabled; repeated bad
# handshakes must not weaken the VNC server's security posture. -localhost
# no lets the forwarder dial 10.10.0.X:5900.
#
# Use \`su -s /bin/sh devshot -c\` instead of \`runuser\` — runuser
# ships with util-linux, which Alpine's busybox base does NOT include
# by default. Falling through to \`runuser: not found\` left Xvnc
# never starting and the desktop tab cycling through reconnect loops
# forever. \`su\` works the same way and is always available on
# Alpine. Mirrors apps/agent/docker/entrypoint-domU-desktop.sh which
# already uses su for the same reason.
su -s /bin/sh devshot -c "Xvnc :0 \
  -geometry $VNC_GEOMETRY -depth $VNC_DEPTH \
  -rfbport $VNC_PORT -SecurityTypes None -AlwaysShared \
  -AcceptSetDesktopSize -pn -localhost=0 -UseBlacklist=0 \
  >/tmp/xvnc.log 2>&1 &"

# Wait for the X server to ACCEPT connections before launching openbox. The
# socket file appears before Xvnc answers on it; on a 2 GB pool VM that gap
# outlived the old 2 s wait, openbox-session died with "Failed to open the
# display" and the person got a VNC frame of a bare black root window
# (spec 459, measured 2026-10-24 on the studio-desktop template). xdotool is
# part of this image; a query that succeeds means the display is open.
_x_ready=0
for _ in $(seq 1 150); do
  if [ -S /tmp/.X11-unix/X0 ] \
    && su -s /bin/sh devshot -c "DISPLAY=:0 xdotool getdisplaygeometry" >/dev/null 2>&1; then
    _x_ready=1
    break
  fi
  sleep 0.2
done
[ "$_x_ready" = "1" ] || echo "start-desktop: X display :0 not answering after 30s — starting openbox anyway" >&2

# Openbox window manager + autostart (compositor + wallpaper + dock).
su -s /bin/sh devshot -c "DISPLAY=:0 HOME=/home/devshot openbox-session \
  >/tmp/openbox.log 2>&1 &"

if [ "$detached" = "1" ]; then
  echo "Desktop started — VNC :$VNC_PORT"
  echo "  raw VNC:  forward :$VNC_PORT and connect with any VNC client"
  echo "  browser:  open /console/desktop/<server>/<vm> for WebRTC noVNC"
  exit 0
fi

# Foreground mode — wait on Xvnc.
wait
LAUNCHER
chmod 0755 /usr/local/bin/start-desktop

cat > /usr/local/bin/stop-desktop <<'STOP'
#!/bin/sh
pkill -f 'Xvnc :0' 2>/dev/null || true
pkill -f 'openbox-session' 2>/dev/null || true
pkill -f 'openbox' 2>/dev/null || true
pkill -f 'tint2' 2>/dev/null || true
pkill -f 'picom' 2>/dev/null || true
echo "Desktop stopped."
STOP
chmod 0755 /usr/local/bin/stop-desktop

# Raise a running browser or start the baked Chromium on the shared X display.
# This mirrors docker/devshot-browser.sh for qcow2 recipe images.
cat > /usr/local/bin/devshot-browser <<'BROWSER'
#!/bin/sh
set -eu
export DISPLAY=:0
PROFILE="${HOME:-/home/devshot}/.config/chromium"

# Spec 459 — on a Studio Desktop the desktop's one browser is the agent's
# (go/studio_browser_desktop.go): it opens the URL in the tab the person and
# the agent share, or shows that browser. Only when no agent answers (exit
# 75) does this launcher start a Chromium of its own.
if [ -S /run/devshot-desktop-browser.sock ] && [ -x /opt/devshot/agent ]; then
  status=0
  /opt/devshot/agent browser-open "$@" || status=$?
  [ "$status" -eq 75 ] || exit "$status"
fi

# Is a Chromium already using this profile? Chromium's own lock names the
# process that holds it (SingletonLock -> <host>-<pid>); a stale lock from a
# hard stop names a dead pid. `pgrep chromium` alone missed the Alpine
# launcher (chromium-launcher.sh) in its first second, so two instances
# started 50 s apart and the profile lock ended one of them ("chromium is
# always closing", spec 459, 2026-10-25).
browser_running() {
  lock="$(readlink "$PROFILE/SingletonLock" 2>/dev/null || true)"
  pid="${lock##*-}"
  if [ -n "$pid" ] && [ "$pid" != "$lock" ] && [ -d "/proc/$pid" ]; then return 0; fi
  pgrep -f '/usr/lib/chromium/chromium|chromium-launcher|^chromium' >/dev/null 2>&1
}

if browser_running; then
  xdotool search --onlyvisible --class chromium windowactivate --sync >/dev/null 2>&1 || true
  exit 0
fi

# Nobody holds the profile: a lock left by a hard stop would make the new
# instance hand its URL to a ghost and exit.
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie" 2>/dev/null || true

# --disable-gpu: Xvnc has no GPU; without the flag Chromium logs a failed
# GpuControl.CreateCommandBuffer on every start before it falls back.
# The package's launcher by its full path: `chromium` on PATH may be the
# Studio Desktop's wrapper, which comes back here.
nohup /usr/bin/chromium-browser \
  --no-sandbox \
  --disable-gpu \
  --disable-features=Translate \
  --disable-dev-shm-usage \
  --start-maximized \
  >/tmp/chromium.log 2>&1 &
BROWSER
chmod 0755 /usr/local/bin/devshot-browser

# ── 5. OpenRC service: auto-start on boot ──────────────────────────────
# Operators who want a "claim a desktop, point browser at it" flow get
# this for free — the desktop is up by the time the spec-050 forward
# channel can reach :5900/:6080. To opt out post-claim:
#   rc-update del devshot-desktop default && rc-service devshot-desktop stop
cat > /etc/init.d/devshot-desktop <<'INITD'
#!/sbin/openrc-run

description="DevShot VNC desktop (Xvnc + Openbox)"

depend() {
    need net
    after networking
}

start() {
    ebegin "Starting DevShot desktop"
    /usr/local/bin/start-desktop -d
    eend $?
}

stop() {
    ebegin "Stopping DevShot desktop"
    /usr/local/bin/stop-desktop
    eend $?
}

status() {
    if pgrep -f 'Xvnc :0' >/dev/null 2>&1; then
        einfo "running (Xvnc :0 alive)"
        return 0
    fi
    einfo "stopped"
    return 3
}
INITD
chmod +x /etc/init.d/devshot-desktop
# Spec 451 — room for installed software and files in the home directory: the template disk is disk_gb above.
# build-templates.sh bakes it at that size; the Go baker only grows the qcow2,
# so this one-shot service grows the filesystem at boot before any workspace
# service starts (idempotent; the cordis.sh pattern).
apk add --no-cache e2fsprogs-extra
cat > /etc/init.d/devshot-grow-root <<'GROWROOT'
#!/sbin/openrc-run
name="devshot-grow-root"
description="Grow the Desktop root filesystem to the template disk size"
depend() {
  need localmount
  before devshot-desktop
}
start() {
  ebegin "Growing Desktop root filesystem"
  # The root device is /dev/vda under QEMU and /dev/xvda under Xen; /proc/mounts
  # may only say /dev/root. A template baked at full size has nothing to grow,
  # and a failed grow is never a boot failure (spec 452 follow-up).
  dev=$(awk '$2 == "/" { print $1 }' /proc/mounts | tail -n 1)
  case "$dev" in /dev/vd*|/dev/xvd*|/dev/sd*|/dev/nvme*) ;; *) dev=""; for d in /dev/vda /dev/xvda /dev/sda; do [ -b "$d" ] && dev="$d" && break; done ;; esac
  [ -n "$dev" ] && /usr/sbin/resize2fs "$dev" >/dev/null 2>&1
  eend 0
}
GROWROOT
chmod +x /etc/init.d/devshot-grow-root
rc-update add devshot-grow-root default

rc-update add devshot-desktop default

echo "=== desktop recipe complete ==="
ls /usr/local/bin/start-desktop /usr/local/bin/stop-desktop /usr/local/bin/devshot-browser
ls /etc/init.d/devshot-desktop
for binary in Xvnc openbox tint2 picom pcmanfm xterm xdotool scrot xclip chromium git grok; do
  command -v "$binary" >/dev/null 2>&1 || {
    echo "ERROR: Desktop runtime is missing $binary" >&2
    exit 1
  }
done
su -s /bin/sh devshot -c 'sudo -n true'
test -x /usr/local/bin/devshot-browser
echo "Desktop runtime prerequisites verified"
