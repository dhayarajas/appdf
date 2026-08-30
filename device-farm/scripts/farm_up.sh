#!/usr/bin/env bash
# Bring up the whole farm: dashboard + shared interception proxy.
#
# One command starts the Appium device-farm dashboard with every driver that is
# installed (so Android devices, Android emulators, real iPhones and iOS
# simulators all show up in a single page) and a single mitmweb instance that
# every one of those targets is routed through, so network tracing is on by
# default rather than something to wire up per device.
#
# Usage:
#   scripts/farm_up.sh                 # dashboard + proxy, wire up everything found
#   scripts/farm_up.sh --check         # report tooling and inventory only
#   scripts/farm_up.sh --stop          # clear proxies left behind by a killed run
#   scripts/farm_up.sh --no-proxy-setup
#
# Options:
#   --proxy-port <n>    mitmproxy listen port (default: 8080)
#   --web-port <n>      mitmweb UI port (default: 8081)
#   --appium-port <n>   Appium/dashboard port (default: 4723)
#   --appium-host <ip>  Appium bind address (default: 0.0.0.0, i.e. LAN-wide)
#   --no-proxy-setup    start both UIs but never touch device/host proxies
#   --no-appium         proxy only (dashboard already running elsewhere)
#   --check             preflight only, never start anything
#   --stop              undo proxy settings and exit
#
# Android proxies are set over adb (emulators get the QEMU host alias). iOS
# simulators share the Mac's network stack, so they are covered by the macOS
# system proxy. A real iPhone has no scriptable proxy: the exact Settings path
# is printed instead. HTTPS bodies stay encrypted until the mitmproxy CA is
# trusted, and pinned apps refuse a proxy outright - both expected, not bugs.
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_OS="$(uname -s)"

PROXY_PORT="${DEVICE_FARM_PROXY_PORT:-8080}"
WEB_PORT="${DEVICE_FARM_WEB_PORT:-8081}"
APPIUM_PORT="${DEVICE_FARM_APPIUM_PORT:-4723}"
APPIUM_HOST="${DEVICE_FARM_APPIUM_HOST:-0.0.0.0}"
SETUP_PROXY=1
START_APPIUM=1
MODE=run
RUN_ID="${DEVICE_FARM_TEST_RUN_ID:-farm-$(date -u +%Y%m%dT%H%M%SZ)}"

log() { printf '[farm] %s\n' "$*"; }
warn() { printf '[farm] WARN  %s\n' "$*" >&2; }
die() { printf '[farm] ERROR %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# `shift 2` is a no-op when only the flag itself is left, which would spin the
# parsing loop forever, so a missing value is rejected up front.
need_value() { (( $2 >= 2 )) || die "$1 requires a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-port) need_value "$1" $#; PROXY_PORT="$2"; shift 2 ;;
    --web-port) need_value "$1" $#; WEB_PORT="$2"; shift 2 ;;
    --appium-port) need_value "$1" $#; APPIUM_PORT="$2"; shift 2 ;;
    --appium-host) need_value "$1" $#; APPIUM_HOST="$2"; shift 2 ;;
    --no-proxy-setup) SETUP_PROXY=0; shift ;;
    --no-appium) START_APPIUM=0; shift ;;
    --check) MODE=check; shift ;;
    --stop) MODE=stop; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- tool lookup
# mitmproxy is a dependency of this package, so prefer the venv-local binaries
# over PATH: that way the script works without activating the virtualenv.
VENV_BIN="${FARM_DIR}/.venv/bin"
find_tool() {
  local name="$1"
  if [[ -x "${VENV_BIN}/${name}" ]]; then
    printf '%s' "${VENV_BIN}/${name}"
  elif have "${name}"; then
    command -v "${name}"
  fi
}
MITMWEB="$(find_tool mitmweb)"
MITMDUMP="$(find_tool mitmdump)"

# The device-farm plugin refuses to start without an SDK root exported, so it is
# resolved here rather than left to the caller's shell profile.
SDK_ROOT=""
for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
    "${HOME}/Library/Android/sdk" "${HOME}/android-sdk" "${HOME}/Android/Sdk"; do
  if [[ -n "${candidate}" && -d "${candidate}/platform-tools" ]]; then
    SDK_ROOT="${candidate}"
    export ANDROID_HOME="${SDK_ROOT}" ANDROID_SDK_ROOT="${SDK_ROOT}"
    break
  fi
done
unset candidate

# --------------------------------------------------------------- host address
# Physical devices must reach this host over the LAN; localhost is meaningless
# there.
host_lan_ip() {
  local ip="" iface
  if [[ "${HOST_OS}" == "Darwin" ]]; then
    for iface in $(route -n get default 2>/dev/null | awk '/interface:/{print $2}') en0 en1; do
      ip="$(ipconfig getifaddr "${iface}" 2>/dev/null)"
      [[ -n "${ip}" ]] && break
    done
  else
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
    [[ -n "${ip}" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${ip}"
}
HOST_IP="${DEVICE_FARM_HOST_IP:-$(host_lan_ip)}"

# ----------------------------------------------------------- device discovery
android_devices() {
  have adb || return 0
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'
}

ios_devices() {
  if have idevice_id; then
    idevice_id -l 2>/dev/null | awk 'NF'
  elif have xcrun; then
    xcrun devicectl list devices 2>/dev/null \
      | awk '/available|connected/ {print $(NF-1)}' | awk 'NF'
  fi
}

booted_simulators() {
  [[ "${HOST_OS}" == "Darwin" ]] || return 0
  have xcrun || return 0
  xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/^[[:space:]]*\(.*\) (\([-0-9A-F]\{36\}\)) (Booted)$/\2 \1/p'
}

# An emulator reaches the host through the QEMU alias, never through the LAN IP.
proxy_host_for() {
  case "$1" in
    emulator-*) printf '10.0.2.2' ;;
    *) printf '%s' "${HOST_IP}" ;;
  esac
}

# ------------------------------------------------------------ macOS host proxy
# A simulator has no proxy setting of its own: it uses the Mac's network stack,
# so the system proxy is what routes it into mitmproxy.
active_service() {
  networksetup -listnetworkserviceorder 2>/dev/null \
    | sed -n 's/^([0-9]*) \(.*\)$/\1/p' | head -1
}

host_proxy() {
  local state="$1" service
  [[ "${HOST_OS}" == "Darwin" ]] || return 0
  have networksetup || { warn "networksetup not found; set the macOS proxy by hand"; return 0; }
  service="${DEVICE_FARM_NETWORK_SERVICE:-$(active_service)}"
  [[ -n "${service}" ]] || {
    warn "could not determine the network service; pass DEVICE_FARM_NETWORK_SERVICE='Wi-Fi'"
    return 0
  }
  if [[ "${state}" == "on" ]]; then
    log "macOS proxy : '${service}' -> 127.0.0.1:${PROXY_PORT} (sudo may prompt)"
    sudo networksetup -setwebproxy "${service}" 127.0.0.1 "${PROXY_PORT}" \
      && sudo networksetup -setsecurewebproxy "${service}" 127.0.0.1 "${PROXY_PORT}" \
      || warn "networksetup failed; simulator traffic will bypass the proxy"
  else
    sudo networksetup -setwebproxystate "${service}" off >/dev/null 2>&1
    sudo networksetup -setsecurewebproxystate "${service}" off >/dev/null 2>&1
    log "macOS proxy : off for '${service}'"
  fi
}

# ------------------------------------------------------------------- --stop
if [[ "${MODE}" == "stop" ]]; then
  if have adb; then
    for serial in $(android_devices); do
      adb -s "${serial}" shell settings put global http_proxy :0 >/dev/null 2>&1 \
        && log "cleared proxy on ${serial}" \
        || warn "could not clear the proxy on ${serial}"
    done
  else
    warn "adb not found; no Android proxies to clear"
  fi
  host_proxy off
  log "a real iPhone keeps its proxy until you clear it by hand:"
  log "  Settings > Wi-Fi > (i) > Configure Proxy > Off"
  exit 0
fi

# ---------------------------------------------------------------- inventory
ANDROID_LIST="$(android_devices)"
IOS_LIST="$(ios_devices)"
SIM_LIST="$(booted_simulators)"

count() { [[ -z "$1" ]] && printf '0' || printf '%s' "$(printf '%s\n' "$1" | wc -l | tr -d ' ')"; }

log "host        : ${HOST_OS} (lan ip: ${HOST_IP:-unknown})"
[[ -n "${HOST_IP}" ]] || warn "could not determine this host's LAN IP; pass DEVICE_FARM_HOST_IP=<ip>"
[[ -n "${MITMWEB}" ]] && log "mitmweb     : ${MITMWEB}" \
  || warn "mitmweb not found; install with: .venv/bin/python -m pip install -e '${FARM_DIR}'"
have appium && log "appium      : $(appium --version 2>/dev/null)" \
  || warn "appium not found; install with: npm i -g appium (see scripts/provision_host.sh)"
[[ -n "${SDK_ROOT}" ]] && log "android sdk : ${SDK_ROOT}" \
  || warn "no Android SDK found; the device-farm plugin will refuse to start - see scripts/provision_host.sh"

# The plugin scans for iOS unconditionally when told `platform=both` and dies on
# a host without xcrun/usbmuxd, so iOS discovery is only requested on a Mac.
DRIVERS="uiautomator2"
PLUGIN_PLATFORM=android
if [[ "${HOST_OS}" == "Darwin" ]] && have xcrun; then
  PLUGIN_PLATFORM=both
fi
if have appium; then
  INSTALLED_DRIVERS="$(appium driver list --installed 2>&1)"
  grep -q uiautomator2 <<<"${INSTALLED_DRIVERS}" || warn "driver uiautomator2 missing: appium driver install uiautomator2"
  if grep -q xcuitest <<<"${INSTALLED_DRIVERS}" && [[ "${PLUGIN_PLATFORM}" == "both" ]]; then
    DRIVERS="uiautomator2,xcuitest"
  elif [[ "${HOST_OS}" == "Darwin" ]]; then
    warn "driver xcuitest missing: appium driver install xcuitest (no iOS in the dashboard without it)"
  fi
fi

log "android     : $(count "${ANDROID_LIST}") device(s)${ANDROID_LIST:+ [$(echo ${ANDROID_LIST} | tr '\n' ' ')]}"
log "ios devices : $(count "${IOS_LIST}")${IOS_LIST:+ [$(echo ${IOS_LIST} | tr '\n' ' ')]}"
log "ios sims    : $(count "${SIM_LIST}") booted"
if [[ "${HOST_OS}" == "Darwin" && -z "${SIM_LIST}" ]]; then
  if have xcrun && xcrun simctl list runtimes 2>/dev/null | grep -q '^iOS'; then
    log "            boot one so it appears in the dashboard: scripts/simulator_up.sh"
  else
    warn "no iOS runtime installed, so no simulator can appear in the dashboard:"
    warn "  sudo xcodebuild -runFirstLaunch && xcodebuild -downloadPlatform iOS"
  fi
fi

if [[ "${MODE}" == "check" ]]; then
  log "check mode: nothing was started"
  [[ -n "${MITMWEB}" ]] || { log "status      : INCOMPLETE (see the warnings above)"; exit 1; }
  if [[ -z "${ANDROID_LIST}${IOS_LIST}${SIM_LIST}" ]]; then
    log "status      : NO TARGETS (the dashboard will start but stay empty)"
    exit 1
  fi
  log "status      : READY"
  exit 0
fi

[[ -n "${MITMWEB}" ]] || die "mitmweb is required; install the package into ${FARM_DIR}/.venv"

# ------------------------------------------------------------- proxy wiring
wire_proxies() {
  [[ "${SETUP_PROXY}" == "1" ]] || { log "proxy setup skipped (--no-proxy-setup)"; return 0; }
  local serial endpoint
  for serial in ${ANDROID_LIST}; do
    endpoint="$(proxy_host_for "${serial}"):${PROXY_PORT}"
    adb -s "${serial}" shell settings put global http_proxy "${endpoint}" >/dev/null 2>&1 \
      && log "proxy       : ${serial} -> ${endpoint}" \
      || warn "could not set the proxy on ${serial}; do it in Settings > Wi-Fi"
  done
  [[ -n "${SIM_LIST}" ]] && host_proxy on
  if [[ -n "${IOS_LIST}" ]]; then
    cat <<EOF
[farm] a real iPhone has no scriptable proxy - set it once per device:
[farm]   Settings > Wi-Fi > (i) next to your network > Configure Proxy > Manual
[farm]   Server: ${HOST_IP:-<the LAN ip of this host>}    Port: ${PROXY_PORT}
EOF
  fi
}

unwire_proxies() {
  [[ "${SETUP_PROXY}" == "1" ]] || return 0
  local serial
  for serial in ${ANDROID_LIST}; do
    adb -s "${serial}" shell settings put global http_proxy :0 >/dev/null 2>&1 \
      && log "proxy       : cleared on ${serial}" \
      || warn "could not clear the proxy on ${serial}; run --stop"
  done
  [[ -n "${SIM_LIST}" ]] && host_proxy off
  [[ -n "${IOS_LIST}" ]] && log "set Configure Proxy back to Off on the iPhone"
  return 0
}

# ------------------------------------------------------------------- run
RUN_DIR="${FARM_DIR}/artifacts/${RUN_ID}"
TRACE_DIR="${RUN_DIR}/traces"
mkdir -p "${TRACE_DIR}"
FLOW_FILE="${TRACE_DIR}/farm-${RUN_ID}.flows"
HAR_FILE="${TRACE_DIR}/farm-${RUN_ID}.har"
MITM_LOG="${RUN_DIR}/mitmweb.log"
APPIUM_LOG="${RUN_DIR}/appium.log"
MITM_PID=""
APPIUM_PID=""

export_har() {
  [[ -n "${MITMDUMP}" ]] || return 0
  [[ -s "${FLOW_FILE}" ]] || {
    log "no flows captured, so no HAR: nothing reached the proxy on :${PROXY_PORT}"
    log "  check the device really points at ${HOST_IP:-<host>}:${PROXY_PORT}"
    return 0
  }
  log "exporting HAR ..."
  # Delegated so the HAR gets the same repair pass as `make export-har`.
  bash "${FARM_DIR}/scripts/export_har.sh" --run "${FLOW_FILE}" --out "${HAR_FILE}" \
    || warn "HAR export failed; the raw flows are still at ${FLOW_FILE}"
}

stop_pid() {
  local pid="$1"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null || return 0
  kill "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null
  return 0
}

cleanup() {
  trap - EXIT INT TERM
  printf '\n'
  log "shutting down ..."
  unwire_proxies
  stop_pid "${APPIUM_PID}"
  stop_pid "${MITM_PID}"
  export_har
  log "artifacts   : ${RUN_DIR}"
}
trap cleanup EXIT INT TERM

log "starting mitmweb (proxy :${PROXY_PORT}, ui :${WEB_PORT}) ..."
"${MITMWEB}" \
  --listen-host 0.0.0.0 --listen-port "${PROXY_PORT}" \
  --web-host 127.0.0.1 --web-port "${WEB_PORT}" --no-web-open-browser \
  --save-stream-file "${FLOW_FILE}" \
  >"${MITM_LOG}" 2>&1 &
MITM_PID=$!

# mitmweb block-buffers its log when stdout is not a tty, so readiness is taken
# from the UI port rather than from the log text.
waited=0
until curl -fsS --max-time 2 "http://127.0.0.1:${WEB_PORT}/" >/dev/null 2>&1; do
  kill -0 "${MITM_PID}" 2>/dev/null || die "mitmweb exited early; see ${MITM_LOG}"
  sleep 1
  waited=$((waited + 1))
  (( waited >= 30 )) && { warn "mitmweb did not answer on :${WEB_PORT} in 30s; see ${MITM_LOG}"; break; }
done

if [[ "${START_APPIUM}" == "1" ]] && have appium; then
  if curl -fsS --max-time 3 "http://127.0.0.1:${APPIUM_PORT}/status" >/dev/null 2>&1; then
    warn "something already listens on :${APPIUM_PORT} - reusing it; if the dashboard"
    warn "  is missing devices it is an older server: kill it and re-run"
  else
    # The plugin options are passed as flags rather than via the config file so a
    # stale config can never narrow discovery back down to one platform.
    log "starting appium (drivers: ${DRIVERS}, pool: ${PLUGIN_PLATFORM}) ..."
    appium server --port "${APPIUM_PORT}" --address "${APPIUM_HOST}" --allow-cors \
      --use-drivers="${DRIVERS}" --use-plugins=device-farm \
      --plugin-device-farm-platform="${PLUGIN_PLATFORM}" \
      --plugin-device-farm-ios-device-type=both \
      >"${APPIUM_LOG}" 2>&1 &
    APPIUM_PID=$!
    waited=0
    until curl -fsS --max-time 2 "http://127.0.0.1:${APPIUM_PORT}/status" >/dev/null 2>&1; do
      kill -0 "${APPIUM_PID}" 2>/dev/null || die "appium exited during startup; see ${APPIUM_LOG}"
      sleep 1
      waited=$((waited + 1))
      (( waited >= 60 )) && { warn "appium not ready after 60s; see ${APPIUM_LOG}"; break; }
    done
  fi
fi

wire_proxies

cat <<EOF

[farm] =================== farm up ====================
[farm] dashboard   : http://127.0.0.1:${APPIUM_PORT}/device-farm/
[farm] traffic ui  : http://127.0.0.1:${WEB_PORT}
[farm] proxy       : ${HOST_IP:-<host>}:${PROXY_PORT} (all wired targets)
[farm] pool api    : curl -s http://127.0.0.1:${APPIUM_PORT}/device-farm/api/device
[farm] flows       : ${FLOW_FILE}
[farm] har on exit : ${HAR_FILE}
[farm] appium log  : ${APPIUM_LOG}
[farm] ------------------------------------------------
[farm] HTTPS bodies stay encrypted until the mitmproxy CA is trusted:
[farm]   android device   : http://mitm.it > Android > install as CA
[farm]   android emulator : scripts/install_system_ca.sh (system store)
[farm]   ios device       : http://mitm.it > install profile > Settings >
[farm]                      General > VPN & Device Management > install, then
[farm]                      About > Certificate Trust Settings > full trust
[farm]   ios simulator    : scripts/simulator_up.sh --trust-ca
[farm] Live view / remote control of a real iPhone additionally needs a signed
[farm] WebDriverAgent; Android streams without extra setup.
[farm] ------------------------------------------------
[farm] Press Ctrl-C to clear every proxy, stop both servers and write the HAR.
[farm] Killed the run instead? scripts/export_har.sh converts the newest flows.
[farm] ================================================

EOF

wait "${MITM_PID}"
