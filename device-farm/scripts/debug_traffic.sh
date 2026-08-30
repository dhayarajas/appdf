#!/usr/bin/env bash
# Interactive traffic debugging for an attached Android or iOS device.
#
# This is the manual counterpart to run_e2e_farm.sh: instead of driving the app
# with pytest, it wires the device's traffic through mitmweb so the app can be
# used by hand while every request streams into a browser UI. On exit the live
# flows are converted to a HAR under artifacts/<run-id>/traces/.
#
# Usage:
#   scripts/debug_traffic.sh                      # auto-detect the platform
#   scripts/debug_traffic.sh --platform ios
#   scripts/debug_traffic.sh --app ~/build/app.apk
#   scripts/debug_traffic.sh --app ~/build/app.ipa --udid 00008150-0011...
#   scripts/debug_traffic.sh --check              # report tooling/devices only
#   scripts/debug_traffic.sh --stop               # clear a device proxy left behind
#
# Options:
#   --platform auto|android|ios   device family (default: auto)
#   --udid <id>                   target a specific device
#   --app <path>                  install this .apk/.ipa before debugging
#   --proxy-port <n>              mitmproxy listen port (default: 8080)
#   --web-port <n>                mitmweb UI port (default: 8081)
#   --no-proxy-setup              never touch the device's proxy settings
#   --check                       preflight only, never start anything
#   --stop                        clear the Android proxy setting and exit
#
# Android proxy configuration is automatic via adb; iOS has no adb equivalent,
# so the script prints the exact Settings path and waits. HTTPS bodies stay
# encrypted until the mitmproxy CA is trusted on the device, and apps with
# certificate pinning refuse to connect through a proxy at all - both are
# expected, not bugs.
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_OS="$(uname -s)"

PLATFORM=auto
UDID=""
APP_PATH="${DEVICE_FARM_APP_PATH:-}"
PROXY_PORT="${DEVICE_FARM_PROXY_PORT:-8080}"
WEB_PORT="${DEVICE_FARM_WEB_PORT:-8081}"
MODE=run
SETUP_PROXY=1
RUN_ID="${DEVICE_FARM_TEST_RUN_ID:-manual-$(date -u +%Y%m%dT%H%M%SZ)}"

log() { printf '[debug] %s\n' "$*"; }
warn() { printf '[debug] WARN  %s\n' "$*" >&2; }
die() { printf '[debug] ERROR %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# `shift 2` is a no-op when only the flag itself is left, which would spin the
# parsing loop forever, so a missing value is rejected up front.
need_value() { (( $2 >= 2 )) || die "$1 requires a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) need_value "$1" $#; PLATFORM="$2"; shift 2 ;;
    --udid) need_value "$1" $#; UDID="$2"; shift 2 ;;
    --app) need_value "$1" $#; APP_PATH="$2"; shift 2 ;;
    --proxy-port) need_value "$1" $#; PROXY_PORT="$2"; shift 2 ;;
    --web-port) need_value "$1" $#; WEB_PORT="$2"; shift 2 ;;
    --no-proxy-setup) SETUP_PROXY=0; shift ;;
    --check) MODE=check; shift ;;
    --stop) MODE=stop; shift ;;
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "${PLATFORM}" in
  auto|android|ios) ;;
  *) die "--platform must be auto, android or ios" ;;
esac

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

# --------------------------------------------------------------- host address
# The device must reach this host over the LAN; localhost is meaningless there.
host_lan_ip() {
  local ip=""
  if [[ "${HOST_OS}" == "Darwin" ]]; then
    local iface
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

# ---------------------------------------------------------- device discovery
android_devices() {
  have adb || return 0
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'
}

ios_devices() {
  if have idevice_id; then
    idevice_id -l 2>/dev/null | awk 'NF'
  elif have xcrun; then
    # devicectl is the modern Xcode path; xcdevice is broken on some installs,
    # so a failure here is not fatal - libimobiledevice remains the fallback.
    xcrun devicectl list devices 2>/dev/null \
      | awk '/available|connected/ {print $(NF-1)}' | awk 'NF'
  fi
}

detect_platform() {
  local android ios
  android="$(android_devices)"
  ios="$(ios_devices)"
  if [[ -n "${android}" && -n "${ios}" ]]; then
    warn "both Android and iOS devices are attached; defaulting to android (use --platform ios)"
    printf 'android'
  elif [[ -n "${android}" ]]; then
    printf 'android'
  elif [[ -n "${ios}" ]]; then
    printf 'ios'
  else
    printf ''
  fi
}

# An emulator reaches the host through the QEMU alias, never through the LAN IP.
device_proxy_host() {
  case "${DEVICE_SERIAL}" in
    emulator-*) printf '10.0.2.2' ;;
    *) printf '%s' "${HOST_IP}" ;;
  esac
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
    warn "adb not found; nothing to clear"
  fi
  log "iOS proxies are set by hand: Settings > Wi-Fi > (i) > Configure Proxy > Off"
  exit 0
fi

# ---------------------------------------------------------------- preflight
log "host        : ${HOST_OS} (lan ip: ${HOST_IP:-unknown})"
[[ -n "${MITMWEB}" ]] && log "mitmweb     : ${MITMWEB}" || warn "mitmweb not found; install with: .venv/bin/python -m pip install -e '${FARM_DIR}'"
[[ -n "${HOST_IP}" ]] || warn "could not determine this host's LAN IP; pass DEVICE_FARM_HOST_IP=<ip>"

if [[ "${PLATFORM}" == "auto" ]]; then
  DETECTED="$(detect_platform)"
  if [[ -z "${DETECTED}" ]]; then
    warn "no Android or iOS device detected"
    [[ "${MODE}" == "check" ]] || warn "starting mitmweb anyway; attach a device and re-run to wire it up"
    PLATFORM=none
  else
    PLATFORM="${DETECTED}"
    log "platform    : ${PLATFORM} (auto-detected)"
  fi
fi

DEVICE_SERIAL="${UDID}"
if [[ "${PLATFORM}" == "android" ]]; then
  have adb || warn "adb not found; install Android platform-tools (see scripts/provision_host.sh)"
  [[ -n "${DEVICE_SERIAL}" ]] || DEVICE_SERIAL="$(android_devices | head -1)"
  [[ -n "${DEVICE_SERIAL}" ]] && log "device      : ${DEVICE_SERIAL}" \
    || warn "no Android device in 'adb devices' (check USB debugging and the authorisation prompt)"
elif [[ "${PLATFORM}" == "ios" ]]; then
  have idevice_id || warn "idevice_id not found; install with: brew install libimobiledevice"
  [[ -n "${DEVICE_SERIAL}" ]] || DEVICE_SERIAL="$(ios_devices | head -1)"
  [[ -n "${DEVICE_SERIAL}" ]] && log "device      : ${DEVICE_SERIAL}" \
    || warn "no iOS device detected (unlock the phone and tap 'Trust This Computer')"
fi
: "${DEVICE_SERIAL:=}"

if [[ -n "${APP_PATH}" ]]; then
  [[ -f "${APP_PATH}" ]] && log "app         : ${APP_PATH}" || warn "app not found: ${APP_PATH}"
  case "${APP_PATH}" in
    *.ipa) have ios-deploy || warn "ios-deploy not found; install with: brew install ios-deploy" ;;
  esac
fi

if [[ "${MODE}" == "check" ]]; then
  log "check mode: nothing was started"
  [[ -n "${MITMWEB}" && -n "${DEVICE_SERIAL}" ]] && { log "status      : READY"; exit 0; }
  log "status      : INCOMPLETE (see the warnings above)"
  exit 1
fi

[[ -n "${MITMWEB}" ]] || die "mitmweb is required; install the package into ${FARM_DIR}/.venv"

# ------------------------------------------------------------- app install
install_app() {
  [[ -n "${APP_PATH}" && -f "${APP_PATH}" && -n "${DEVICE_SERIAL}" ]] || return 0
  case "${APP_PATH}" in
    *.apk)
      have adb || { warn "adb missing; skipping install"; return 0; }
      log "installing ${APP_PATH} on ${DEVICE_SERIAL} ..."
      adb -s "${DEVICE_SERIAL}" install -r -g "${APP_PATH}" \
        || warn "adb install failed; install the app by hand and continue"
      ;;
    *.ipa)
      have ios-deploy || { warn "ios-deploy missing; install the .ipa by hand (Xcode/Apple Configurator)"; return 0; }
      log "installing ${APP_PATH} on ${DEVICE_SERIAL} ..."
      ios-deploy --id "${DEVICE_SERIAL}" --bundle "${APP_PATH}" --no-wifi \
        || warn "ios-deploy failed - the .ipa must be signed with a profile that includes UDID ${DEVICE_SERIAL}"
      ;;
    *) warn "unrecognised app type: ${APP_PATH} (expected .apk or .ipa)" ;;
  esac
}

# ------------------------------------------------------------ proxy wiring
set_device_proxy() {
  [[ "${SETUP_PROXY}" == "1" ]] || return 0
  local endpoint
  if [[ "${PLATFORM}" == "android" && -n "${DEVICE_SERIAL}" ]] && have adb; then
    endpoint="$(device_proxy_host):${PROXY_PORT}"
    if adb -s "${DEVICE_SERIAL}" shell settings put global http_proxy "${endpoint}" >/dev/null 2>&1; then
      log "device proxy: ${DEVICE_SERIAL} -> ${endpoint}"
    else
      warn "could not set the proxy via adb; configure it in Settings > Wi-Fi by hand"
    fi
  elif [[ "${PLATFORM}" == "ios" ]]; then
    cat <<EOF
[debug] iOS has no adb equivalent - configure the proxy on the phone:
[debug]   Settings > Wi-Fi > (i) next to your network > Configure Proxy > Manual
[debug]   Server: ${HOST_IP:-<the LAN ip of this host>}    Port: ${PROXY_PORT}
EOF
  fi
}

clear_device_proxy() {
  [[ "${SETUP_PROXY}" == "1" ]] || return 0
  if [[ "${PLATFORM}" == "android" && -n "${DEVICE_SERIAL}" ]] && have adb; then
    adb -s "${DEVICE_SERIAL}" shell settings put global http_proxy :0 >/dev/null 2>&1 \
      && log "device proxy cleared on ${DEVICE_SERIAL}" \
      || warn "could not clear the proxy on ${DEVICE_SERIAL}; run --stop"
  elif [[ "${PLATFORM}" == "ios" ]]; then
    log "remember to set Configure Proxy back to Off on the phone"
  fi
}

# ------------------------------------------------------------------- run
TRACE_DIR="${FARM_DIR}/artifacts/${RUN_ID}/traces"
mkdir -p "${TRACE_DIR}"
FLOW_FILE="${TRACE_DIR}/${PLATFORM}-${RUN_ID}.flows"
HAR_FILE="${TRACE_DIR}/${PLATFORM}-${RUN_ID}.har"
MITM_LOG="${FARM_DIR}/artifacts/${RUN_ID}/mitmweb.log"
MITM_PID=""

export_har() {
  [[ -s "${FLOW_FILE}" && -n "${MITMDUMP}" ]] || return 0
  log "exporting HAR ..."
  # Delegated so the HAR gets the same repair pass as `make export-har`.
  bash "${FARM_DIR}/scripts/export_har.sh" --run "${FLOW_FILE}" --out "${HAR_FILE}" \
    || warn "HAR export failed; the raw flows are still at ${FLOW_FILE}"
}

cleanup() {
  trap - EXIT INT TERM
  printf '\n'
  log "shutting down ..."
  clear_device_proxy
  if [[ -n "${MITM_PID}" ]] && kill -0 "${MITM_PID}" 2>/dev/null; then
    kill "${MITM_PID}" 2>/dev/null
    wait "${MITM_PID}" 2>/dev/null
  fi
  export_har
  log "artifacts   : ${FARM_DIR}/artifacts/${RUN_ID}"
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
  kill -0 "${MITM_PID}" 2>/dev/null || { warn "mitmweb exited early; see ${MITM_LOG}"; exit 1; }
  sleep 1
  waited=$((waited + 1))
  (( waited >= 30 )) && { warn "mitmweb did not answer on :${WEB_PORT} in 30s; see ${MITM_LOG}"; break; }
done

install_app
set_device_proxy

cat <<EOF

[debug] ================= live traffic =================
[debug] ui          : http://127.0.0.1:${WEB_PORT}
[debug] proxy       : ${HOST_IP:-<host>}:${PROXY_PORT}
[debug] platform    : ${PLATFORM}${DEVICE_SERIAL:+ (${DEVICE_SERIAL})}
[debug] flows       : ${FLOW_FILE}
[debug] har on exit : ${HAR_FILE}
[debug] ------------------------------------------------
[debug] HTTPS bodies stay encrypted until the mitmproxy CA is trusted:
[debug]   android : http://mitm.it on the device > Android > Settings >
[debug]             Security > Install a certificate > CA
[debug]             (system-level trust on a rooted device/emulator:
[debug]              scripts/install_system_ca.sh)
[debug]   ios     : http://mitm.it on the device > install profile >
[debug]             Settings > General > VPN & Device Management > install >
[debug]             then General > About > Certificate Trust Settings >
[debug]             enable full trust for mitmproxy
[debug] Apps that pin their certificates will refuse to connect at all.
[debug] ------------------------------------------------
[debug] Use the app by hand; press Ctrl-C when done to clear the proxy and
[debug] write the HAR.
[debug] ================================================

EOF

wait "${MITM_PID}"
