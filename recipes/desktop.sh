#!/bin/sh
# Recipe: VNC desktop — Openbox + tint2 + Xvnc + noVNC.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/desktop.sh --name=desktop
#
# Output template: devshot-guest-desktop.qcow2. Every VM spawned from
# it boots straight into a working desktop on TCP:5900 (raw RFB) and
# :6080 (websockify+noVNC). The DevShot console's spec-050 forward
# allowlist auto-populates with both ports thanks to the magic-comment
# header below, so an operator can `Open` the desktop in a browser
# tab without any manual setup.
#
# This is the bake-VM equivalent of apps/agent/docker/Dockerfile.domU-desktop:
# same package set, same theme + dock + wallpaper, same launcher style.
# Re-implemented as a recipe so the bakery can stamp a flavored qcow2
# ready for `pool-set-base-image desktop` selection in the console.
#
# Spec 050 — declared listen ports auto-populate the per-VM forward
# allowlist (and surface as Open buttons in the Servers tab):
# devshot:exposed_ports=[{"port":5900,"name":"vnc","proto":"tcp"},{"port":6080,"name":"novnc","proto":"http"}]
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
    tigervnc \
    websockify novnc \
    openbox tint2 picom \
    pcmanfm xterm \
    dbus dbus-x11 \
    greybird-themes-gtk2 greybird-themes-gtk3 numix-themes-openbox \
    adwaita-icon-theme papirus-icon-theme \
    font-noto font-noto-emoji \
    feh

# ── 2. Per-user desktop config ─────────────────────────────────────────
# The universal base already created the `devshot` user with a hidden
# random password (project_vm_user_auth memory). We just need to drop
# config + wallpaper into its $HOME. mkdir -p is idempotent, so this
# recipe is safe to re-run on a respun bake VM.
DEVSHOT_HOME=/home/devshot
mkdir -p "$DEVSHOT_HOME/.config/openbox" \
         "$DEVSHOT_HOME/.config/tint2" \
         "$DEVSHOT_HOME/.config/gtk-3.0" \
         "$DEVSHOT_HOME/.vnc"

# GTK3 — dark Greybird theme, Papirus icons, Noto sans
cat > "$DEVSHOT_HOME/.config/gtk-3.0/settings.ini" <<'GTK3'
[Settings]
gtk-theme-name=Greybird-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Noto Sans 10
gtk-decoration-layout=close,minimize,maximize:
gtk-application-prefer-dark-theme=true
GTK3

# GTK2 fallback (some legacy apps still read this)
cat > "$DEVSHOT_HOME/.gtkrc-2.0" <<'GTK2'
gtk-theme-name="Greybird-dark"
gtk-icon-theme-name="Papirus-Dark"
gtk-font-name="Noto Sans 10"
GTK2

# Openbox window manager — clean window decorations, CLIMD title layout
# (close/max/min on the LEFT like macOS), 8 px corner radius, smart
# placement, alt-drag to move, alt-right to resize.
cat > "$DEVSHOT_HOME/.config/openbox/rc.xml" <<'OPENBOXRC'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <theme>
    <name>Numix</name>
    <titleLayout>CLIMD</titleLayout>
    <cornerRadius>8</cornerRadius>
    <font place="ActiveWindow"><name>Noto Sans</name><size>10</size><weight>Bold</weight></font>
    <font place="InactiveWindow"><name>Noto Sans</name><size>9</size><weight>Normal</weight></font>
    <font place="MenuHeader"><name>Noto Sans</name><size>10</size><weight>Bold</weight></font>
    <font place="MenuItem"><name>Noto Sans</name><size>10</size><weight>Normal</weight></font>
  </theme>
  <desktops><number>2</number><names><name>Desktop</name><name>Work</name></names></desktops>
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
# Wallpaper
feh --bg-fill /home/devshot/.wallpaper.png &
# tint2 dock panel
tint2 &
AUTOSTART
chmod +x "$DEVSHOT_HOME/.config/openbox/autostart"

chown -R devshot:devshot "$DEVSHOT_HOME"

# ── 3. /usr/local/bin launchers ────────────────────────────────────────
# start-desktop  → bring up Xvnc :0, openbox, websockify (foreground or -d)
# stop-desktop   → kill the lot
# Same UX shape as start-n8n / start-flowise so muscle memory carries.
cat > /usr/local/bin/start-desktop <<'LAUNCHER'
#!/bin/sh
# Start the VNC desktop. Pass -d to run detached.
# Listens on :5900 (raw RFB) and :6080 (noVNC over websockify).
detached=0
if [ "${1-}" = "-d" ]; then detached=1; fi

VNC_GEOMETRY="${VNC_GEOMETRY:-1280x800}"
VNC_DEPTH="${VNC_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"

# Anything still bound from a prior run blocks Xvnc — wipe stale state.
pkill -f 'Xvnc :0' 2>/dev/null || true
pkill -f 'openbox' 2>/dev/null || true
pkill -f 'websockify' 2>/dev/null || true
rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# Xvnc: X server with VNC export. -SecurityTypes None opens the wire to
# whatever firewalled in front of it — for DevShot that's the spec-050
# forward channel which already gates the connection on the user's
# fingerprint allowlist. -localhost no lets dom0 dial 10.10.0.X:5900.
runuser -u devshot -- Xvnc :0 \
  -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" \
  -rfbport "$VNC_PORT" -SecurityTypes None -AlwaysShared \
  -AcceptSetDesktopSize -pn -localhost=0 \
  >/tmp/xvnc.log 2>&1 &

# Wait briefly for the X socket to appear before launching openbox.
for _ in $(seq 1 20); do
  [ -S /tmp/.X11-unix/X0 ] && break
  sleep 0.1
done

# Openbox window manager + autostart (compositor + wallpaper + dock).
runuser -u devshot -- env DISPLAY=:0 HOME=/home/devshot openbox-session \
  >/tmp/openbox.log 2>&1 &

# websockify: WebSocket → TCP bridge so noVNC's HTML client (served on
# the same port) can render the RFB stream.
websockify --web /usr/share/novnc "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" \
  >/tmp/websockify.log 2>&1 &

if [ "$detached" = "1" ]; then
  echo "Desktop started — VNC :$VNC_PORT, noVNC :$NOVNC_PORT"
  echo "  raw VNC:  forward :$VNC_PORT and connect with any VNC client"
  echo "  browser:  forward :$NOVNC_PORT and open /vnc.html"
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
pkill -f 'websockify' 2>/dev/null || true
pkill -f 'tint2' 2>/dev/null || true
pkill -f 'picom' 2>/dev/null || true
echo "Desktop stopped."
STOP
chmod 0755 /usr/local/bin/stop-desktop

# ── 4. OpenRC service: auto-start on boot ──────────────────────────────
# Operators who want a "claim a desktop, point browser at it" flow get
# this for free — the desktop is up by the time the spec-050 forward
# channel can reach :5900/:6080. To opt out post-claim:
#   rc-update del devshot-desktop default && rc-service devshot-desktop stop
cat > /etc/init.d/devshot-desktop <<'INITD'
#!/sbin/openrc-run

description="DevShot VNC desktop (Xvnc + Openbox + websockify)"

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
rc-update add devshot-desktop default

echo "=== desktop recipe complete ==="
ls /usr/local/bin/start-desktop /usr/local/bin/stop-desktop
ls /etc/init.d/devshot-desktop
which Xvnc openbox tint2 picom websockify
