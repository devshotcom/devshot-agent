#!/bin/sh
# Recipe: Expo — universal React Native development in DevShot Studio.
#
# The guest runs Expo SDK 57 / Metro Web on :8081 and OpenVSCode on :8080.
# Studio renders :8081 in its existing Chromium surface with switchable exact
# iPhone (390x844) and Android (412x915) viewports. Keeping Chromium out of the
# guest's steady-state boot path avoids a second browser, X server and VNC
# stack, which is the difference between a
# reliable low-memory workspace and routine OOM kills.
#
# These are mobile-shaped Chromium WEB simulators. They validate responsive
# layout, routing, touch-sized controls and universal React Native code. UIKit, WebKit,
# device hardware and custom native modules still require Expo Go, a development
# build/EAS, or Xcode on macOS; the UI never represents this as Xcode Simulator.
#
# Run via: devshot-agent bake run --recipe=apps/agent/recipes/expo.sh --name=expo
# devshot:exposed_ports=[{"port":8081,"name":"app","proto":"http"},{"port":8080,"name":"editor","proto":"http"}]
# devshot:memory_mb=1536
set -eux

apk update
apk add --no-cache \
  bash ca-certificates chromium chromium-swiftshader git gcompat nodejs npm \
  sudo tar ttf-freefont wget

install -d -m 0750 /etc/sudoers.d
printf 'devshot ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/devshot
chmod 0440 /etc/sudoers.d/devshot
visudo -cf /etc/sudoers

/usr/local/libexec/devshot/install-grok-speckit.sh

# The verification agent drives the apk Chromium only when it needs evidence.
# puppeteer-core carries no bundled browser, so this adds no duplicate runtime.
install -d /opt/devshot-e2e
(
  cd /opt/devshot-e2e
  npm init -y >/dev/null 2>&1
  PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --omit=dev puppeteer-core
)

# Bake the official current Expo starter. Pinning the SDK makes the image
# reproducible while create-expo-app itself can keep receiving installer fixes.
install -d -o devshot -g devshot /var/www
cat > /tmp/devshot-build-expo.sh <<'BUILD_EXPO'
#!/bin/sh
set -eux
export CI=1
export EXPO_NO_TELEMETRY=1
export npm_config_audit=false
export npm_config_fund=false
export npm_config_fetch_retries=5
export npm_config_fetch_retry_mintimeout=20000
export npm_config_fetch_retry_maxtimeout=120000
export npm_config_maxsockets=6
# create-expo-app stages the downloaded template through os.tmpdir(), and this
# script runs as the unprivileged workload user: the bake's /tmp is not
# world-writable, so it died with "EACCES: permission denied, mkdir
# '/tmp/.create-expo-app'" (agent run 33800980629). Node honours TMPDIR, so
# give it one inside the user's own home.
export TMPDIR="$HOME/.tmp"
mkdir -p "$TMPDIR"
cd /var/www
npx --yes create-expo-app@latest devshot-expo --template default@sdk-57 --yes
mv /var/www/devshot-expo /var/www/expo
cd /var/www/expo

# create-expo-app currently leaves the scaffold behind and exits successfully
# when its inner npm install times out. Never bake that partial state: validate
# the top-level dependency tree and retry the install within a fixed bound.
if ! npm ls --depth=0 >/dev/null 2>&1; then
  install_attempt=1
  while ! npm install --prefer-offline --no-audit --no-fund; do
    if [ "$install_attempt" -ge 3 ]; then
      echo "Expo dependency installation failed after $install_attempt attempts" >&2
      exit 1
    fi
    install_attempt=$((install_attempt + 1))
    sleep 5
  done
fi

# A quiet, neutral first screen gives the agent a clean starting point and
# confirms that the native React primitives render in the web simulator.
cat > src/app/index.tsx <<'APP'
import { StyleSheet, Text, View } from 'react-native';

export default function HomeScreen() {
  return (
    <View style={styles.screen}>
      <Text style={styles.eyebrow}>EXPO · IOS + ANDROID + WEB</Text>
      <Text style={styles.title}>Your native app is ready</Text>
      <Text style={styles.body}>Describe a change in the chat to start building.</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: {
    alignItems: 'center',
    backgroundColor: '#0b1020',
    flex: 1,
    gap: 14,
    justifyContent: 'center',
    padding: 32,
  },
  eyebrow: {
    color: '#67e8f9',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.4,
  },
  title: {
    color: '#f8fafc',
    fontSize: 30,
    fontWeight: '700',
    textAlign: 'center',
  },
  body: {
    color: '#94a3b8',
    fontSize: 16,
    lineHeight: 24,
    maxWidth: 300,
    textAlign: 'center',
  },
});
APP

printf '\n# DevShot verification harness\n.devshot/\ndist/\n' >> .gitignore
test -x node_modules/.bin/expo
npm ls --depth=0 >/dev/null
BUILD_EXPO
chmod 0755 /tmp/devshot-build-expo.sh
su -l -s /bin/sh devshot -c /tmp/devshot-build-expo.sh
rm -f /tmp/devshot-build-expo.sh

cat > /usr/local/bin/start-expo <<'START_EXPO'
#!/bin/sh
set -eu
export CI=1
export BROWSER=none
export EXPO_NO_TELEMETRY=1
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=384}"
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-2}"
cd /var/www/expo
LOG="${LOG:-/tmp/studio-dev.log}"

boot_ts() { awk '{printf "%.1f", $1}' /proc/uptime 2>/dev/null || printf '?'; }
echo "[boot +$(boot_ts)s] start-expo: launching Metro Web on port 8081" >> "$LOG"

if [ ! -x node_modules/.bin/expo ]; then
  echo "[boot +$(boot_ts)s] Expo dependencies missing from baked image" >> "$LOG"
  exit 1
fi

# --lan binds beyond loopback so the VM proxy can reach Metro. --offline avoids
# version/network probes on a claimed VM, and two workers cap peak memory.
exec ./node_modules/.bin/expo start --web --lan --offline --max-workers 2
START_EXPO
chmod 0755 /usr/local/bin/start-expo

cat > /etc/init.d/devshot-expo <<'EXPO_SERVICE'
#!/sbin/openrc-run
name="devshot-expo"
description="DevShot Expo SDK 57 Metro Web runtime"
supervisor=supervise-daemon
command="/usr/local/bin/start-expo"
command_user="devshot:devshot"
pidfile="/run/devshot-expo.pid"
output_log="/tmp/studio-dev.log"
error_log="/tmp/studio-dev.log"
respawn_delay=3
respawn_max=0

depend() {
  need net
  after networking firewall devshot-perms
}
EXPO_SERVICE
chmod 0755 /etc/init.d/devshot-expo
rc-update add devshot-expo default

# Restore operations can change ownership. Repair only drifted entries before
# Metro and the editor start; do not recursively rewrite a clean node_modules.
cat > /etc/init.d/devshot-perms <<'PERMS'
#!/sbin/openrc-run
name="devshot-perms"
description="Keep the Expo workspace writable by devshot"
depend() {
  after localmount
  before devshot-expo openvscode-server
}
start() {
  ebegin "Normalizing /var/www/expo ownership"
  find /var/www/expo -xdev \! -user devshot -exec chown devshot:devshot {} + 2>/dev/null
  find /var/www/expo -xdev \! -group devshot -exec chgrp devshot {} + 2>/dev/null
  find /var/www/expo -xdev -type d \! -perm -u+w -exec chmod u+rwX {} + 2>/dev/null
  find /var/www/expo -xdev -type f \! -perm -u+w -exec chmod u+rw {} + 2>/dev/null
  eend 0
}
PERMS
chmod 0755 /etc/init.d/devshot-perms
rc-update add devshot-perms default

# OpenVSCode is intentionally the same fixed system-Node distribution used by
# the other Studio images. Its bundled optional glibc modules are not required.
OPENVSCODE_VERSION="${OPENVSCODE_VERSION:-1.95.2}"
case "$(uname -m)" in
  x86_64) OV_ARCH=x64 ;;
  aarch64) OV_ARCH=arm64 ;;
  *) echo "ERROR: unsupported architecture for openvscode-server" >&2; exit 1 ;;
esac
install -d /opt/openvscode-server
wget -q -O /tmp/openvscode.tar.gz \
  "https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${OPENVSCODE_VERSION}/openvscode-server-v${OPENVSCODE_VERSION}-linux-${OV_ARCH}.tar.gz"
tar -xzf /tmp/openvscode.tar.gz -C /opt/openvscode-server --strip-components=1
rm -f /tmp/openvscode.tar.gz
node /opt/openvscode-server/out/server-main.js --version | head -1

install -d -o devshot -g devshot \
  /home/devshot/.openvscode-server/data/User \
  /home/devshot/.openvscode-server/data/Machine \
  /var/www/expo/.vscode
cat > /home/devshot/.openvscode-server/data/User/settings.json <<'SETTINGS'
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.startupEditor": "none",
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.startupPrompt": "never",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 800,
  "editor.fontSize": 13,
  "explorer.confirmDelete": false,
  "explorer.confirmDragAndDrop": false
}
SETTINGS
chown -R devshot:devshot /home/devshot/.openvscode-server /var/www/expo/.vscode
echo /var/www/expo > /etc/openvscode-default-folder
install -o devshot -g devshot -m 0644 /dev/null /var/log/openvscode-server.log

cat > /etc/init.d/openvscode-server <<'VSCODE_SERVICE'
#!/sbin/openrc-run
name="openvscode-server"
description="VSCode in the browser — DevShot Expo editor"
DEFAULT_FOLDER="$(cat /etc/openvscode-default-folder 2>/dev/null || echo /var/www/expo)"
command="/usr/bin/node"
command_args="/opt/openvscode-server/out/server-main.js \
  --host 0.0.0.0 --port 8080 \
  --without-connection-token \
  --disable-telemetry \
  --disable-workspace-trust \
  --user-data-dir /home/devshot/.openvscode-server/data \
  --server-data-dir /home/devshot/.openvscode-server \
  --default-folder $DEFAULT_FOLDER"
command_user="devshot:devshot"
command_background=true
pidfile="/run/openvscode-server.pid"
output_log="/var/log/openvscode-server.log"
error_log="/var/log/openvscode-server.log"

depend() {
  need net
  after firewall devshot-perms
}
VSCODE_SERVICE
chmod 0755 /etc/init.d/openvscode-server
rc-update add openvscode-server default

rm -rf /home/devshot/.npm /home/devshot/.cache /root/.npm /var/cache/apk/*

echo "=== Expo recipe complete ==="
node --version
npm --version
du -sh /var/www/expo
test -x /usr/local/bin/start-expo
test -x /etc/init.d/devshot-expo
test -d /opt/devshot-e2e/node_modules/puppeteer-core
su -s /bin/sh devshot -c 'sudo -n true'
sync
