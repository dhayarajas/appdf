#!/usr/bin/env bash
# Boot a simulator/emulator for hardware-free runs of the farm.
#
# iOS simulators are handled here with simctl; Android emulators are delegated
# to emulator_up.sh, so a single entrypoint covers both families.
#
# Usage:
#   scripts/simulator_up.sh                       # boot the default iOS simulator
#   scripts/simulator_up.sh --platform android    # delegate to emulator_up.sh
#   scripts/simulator_up.sh --list                # available simulators/runtimes
#   scripts/simulator_up.sh --device "iPhone 16" --app ~/build/MyApp.app
#   scripts/simulator_up.sh --trust-ca            # trust the mitmproxy CA
#   scripts/simulator_up.sh --set-proxy           # route the host through mitmproxy
#   scripts/simulator_up.sh --unset-proxy
#   scripts/simulator_up.sh --check               # report readiness only
#   scripts/simulator_up.sh --stop
#
# Options:
#   --platform auto|ios|android   simulator family (default: auto)
#   --device <name>               simulator name, e.g. "iPhone 16"
#   --runtime <id>                runtime for --device creation, e.g. iOS-18-2
#   --app <path>                  install this .app (simulator builds only)
#   --launch <bundle-id>          launch this bundle after installing
#   --proxy-port <n>              mitmproxy port used by --set-proxy (default: 8080)
#
# An iOS simulator has no network stack of its own: it uses the host's, so
# there is no per-device proxy setting the way there is on Android. Traffic is
# intercepted by pointing macOS itself at mitmproxy (--set-proxy), which is why
# debug_traffic.sh has no simulator branch. A simulator also runs a simulator
# build (.app) - a device .ipa cannot be installed into it.
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_OS="$(uname -s)"

PLATFORM=auto
SIM_NAME="${DEVICE_FARM_SIM_NAME:-iPhone 16}"
SIM_RUNTIME="${DEVICE_FARM_SIM_RUNTIME:-}"
APP_PATH="${DEVICE_FARM_APP_PATH:-}"
LAUNCH_BUNDLE=""
PROXY_PORT="${DEVICE_FARM_PROXY_PORT:-8080}"
BOOT_TIMEOUT="${DEVICE_FARM_SIM_BOOT_TIMEOUT:-180}"
CA_FILE="${DEVICE_FARM_CA_FILE:-${HOME}/.mitmproxy/mitmproxy-ca-cert.pem}"
MODE=up

log() { printf '[simulator] %s\n' "$*"; }
warn() { printf '[simulator] WARN  %s\n' "$*" >&2; }
die() { printf '[simulator] ERROR %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_value() {
  # $1 is the flag, $2 the remaining argument count including the flag itself.
  (( $2 >= 2 )) || die "$1 requires a value (try --help)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) need_value "$1" $#; PLATFORM="$2"; shift 2 ;;
    --device) need_value "$1" $#; SIM_NAME="$2"; shift 2 ;;
    --runtime) need_value "$1" $#; SIM_RUNTIME="$2"; shift 2 ;;
    --app) need_value "$1" $#; APP_PATH="$2"; shift 2 ;;
    --launch) need_value "$1" $#; LAUNCH_BUNDLE="$2"; shift 2 ;;
    --proxy-port) need_value "$1" $#; PROXY_PORT="$2"; shift 2 ;;
    --list) MODE=list; shift ;;
    --check) MODE=check; shift ;;
    --stop) MODE=stop; shift ;;
    --trust-ca) MODE=trust-ca; shift ;;
    --set-proxy) MODE=set-proxy; shift ;;
    --unset-proxy) MODE=unset-proxy; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "${PLATFORM}" in
  auto|ios|android) ;;
  *) die "--platform must be auto, ios or android" ;;
esac

# Android emulators are already fully scripted; forward the equivalent flags
# rather than reimplementing AVD management here.
delegate_android() {
  case "${MODE}" in
    up) exec bash "${FARM_DIR}/scripts/emulator_up.sh" ;;
    check) exec bash "${FARM_DIR}/scripts/emulator_up.sh" --check ;;
    stop) exec bash "${FARM_DIR}/scripts/emulator_up.sh" --stop ;;
    list)
      # avdmanager lives in the SDK rather than on PATH for most installs.
      local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/android-sdk}}"
      PATH="${sdk_root}/cmdline-tools/latest/bin:${PATH}"
      have avdmanager || die "avdmanager not found under ${sdk_root}; run scripts/provision_host.sh"
      exec avdmanager list avd
      ;;
    trust-ca) exec bash "${FARM_DIR}/scripts/install_system_ca.sh" ;;
    set-proxy|unset-proxy)
      die "an Android emulator takes its proxy from adb: use scripts/debug_traffic.sh --platform android" ;;
  esac
}

if [[ "${PLATFORM}" == "android" ]]; then
  delegate_android
elif [[ "${PLATFORM}" == "auto" && "${HOST_OS}" != "Darwin" ]]; then
  log "host is ${HOST_OS}; iOS simulators need macOS - using the Android emulator"
  delegate_android
fi

# ------------------------------------------------------------------- iOS
[[ "${HOST_OS}" == "Darwin" ]] || die "iOS simulators require macOS (host is ${HOST_OS})"
have xcrun || die "xcrun not found; install Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

simctl() { xcrun simctl "$@"; }

# `simctl list` prints one device per line as: "    <name> (<udid>) (<state>)".
# Parsed with sed rather than jq so no extra dependency is needed.
sim_line() {
  local scope="$1" name="$2"
  simctl list devices "${scope}" 2>/dev/null \
    | sed -n "s/^[[:space:]]*${name} (\([-0-9A-F]*\)) (\(.*\))$/\1 \2/p" | head -1
}
sim_udid() { sim_line "$1" "$2" | awk '{print $1}'; }
booted_udid() { simctl list devices booted 2>/dev/null | sed -n 's/.*(\([-0-9A-F]\{36\}\)).*/\1/p' | head -1; }

if [[ "${MODE}" == "list" ]]; then
  log "runtimes:"
  simctl list runtimes | sed 's/^/[simulator]   /'
  log "available devices:"
  simctl list devices available | sed 's/^/[simulator]   /'
  exit 0
fi

xcode_ready() {
  # CoreSimulator is missing until Xcode's first-launch install has run, which
  # is the usual reason simctl reports no runtimes at all.
  simctl list runtimes 2>/dev/null | grep -q '^iOS'
}

if [[ "${MODE}" == "check" ]]; then
  log "host        : ${HOST_OS}"
  log "xcode       : $(xcodebuild -version 2>/dev/null | head -1 || printf 'not found')"
  if xcode_ready; then
    log "runtimes    : $(simctl list runtimes | grep -c '^iOS') iOS runtime(s)"
  else
    warn "no iOS runtimes; run: sudo xcodebuild -runFirstLaunch"
  fi
  UDID="$(sim_udid available "${SIM_NAME}")"
  [[ -n "${UDID}" ]] && log "device      : ${SIM_NAME} (${UDID})" \
    || warn "no simulator named '${SIM_NAME}'; --list shows what exists (it will be created on boot)"
  BOOTED="$(booted_udid)"
  [[ -n "${BOOTED}" ]] && log "booted      : ${BOOTED}" || log "booted      : none"
  [[ -f "${CA_FILE}" ]] && log "ca          : ${CA_FILE}" \
    || warn "no mitmproxy CA at ${CA_FILE}; it is generated on the first mitmproxy run"
  xcode_ready || exit 1
  log "status      : READY"
  exit 0
fi

if [[ "${MODE}" == "stop" ]]; then
  UDID="$(booted_udid)"
  if [[ -n "${UDID}" ]]; then
    simctl shutdown "${UDID}" >/dev/null 2>&1 && log "shut down ${UDID}" || warn "could not shut down ${UDID}"
  else
    log "no booted simulator"
  fi
  exit 0
fi

# The simulator shares the host keychain-less trust store per device, so the CA
# has to be added to each simulator rather than to macOS.
if [[ "${MODE}" == "trust-ca" ]]; then
  [[ -f "${CA_FILE}" ]] || die "no CA at ${CA_FILE}; start mitmproxy once to generate it"
  UDID="$(booted_udid)"
  [[ -n "${UDID}" ]] || die "no booted simulator; run this script without --trust-ca first"
  simctl keychain "${UDID}" add-root-cert "${CA_FILE}" \
    && log "trusted ${CA_FILE} on ${UDID}" \
    || die "simctl keychain failed; check the CA path and that the simulator is booted"
  exit 0
fi

# macOS itself is the simulator's network stack, so the proxy is a host setting.
# networksetup needs admin rights, hence sudo.
active_service() {
  networksetup -listnetworkserviceorder 2>/dev/null \
    | sed -n 's/^([0-9]*) \(.*\)$/\1/p' | head -1
}

if [[ "${MODE}" == "set-proxy" || "${MODE}" == "unset-proxy" ]]; then
  have networksetup || die "networksetup not found"
  SERVICE="${DEVICE_FARM_NETWORK_SERVICE:-$(active_service)}"
  [[ -n "${SERVICE}" ]] || die "could not determine the network service; pass DEVICE_FARM_NETWORK_SERVICE='Wi-Fi'"
  if [[ "${MODE}" == "set-proxy" ]]; then
    log "pointing '${SERVICE}' at 127.0.0.1:${PROXY_PORT} (sudo required) ..."
    sudo networksetup -setwebproxy "${SERVICE}" 127.0.0.1 "${PROXY_PORT}" \
      && sudo networksetup -setsecurewebproxy "${SERVICE}" 127.0.0.1 "${PROXY_PORT}" \
      && log "host proxy on; undo with: $0 --unset-proxy" \
      || die "networksetup failed"
  else
    sudo networksetup -setwebproxystate "${SERVICE}" off
    sudo networksetup -setsecurewebproxystate "${SERVICE}" off
    log "host proxy off for '${SERVICE}'"
  fi
  exit 0
fi

# ------------------------------------------------------------------- boot
xcode_ready || die "no iOS runtimes are installed; run: sudo xcodebuild -runFirstLaunch"

UDID="$(sim_udid available "${SIM_NAME}")"
if [[ -z "${UDID}" ]]; then
  DEVICE_TYPE="$(simctl list devicetypes 2>/dev/null \
    | sed -n "s/^${SIM_NAME} (\(.*\))$/\1/p" | head -1)"
  [[ -n "${DEVICE_TYPE}" ]] || die "unknown device '${SIM_NAME}'; see --list"
  RUNTIME="${SIM_RUNTIME}"
  [[ -n "${RUNTIME}" ]] || RUNTIME="$(simctl list runtimes 2>/dev/null \
    | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.[^ ]*\).*/\1/p' | tail -1)"
  [[ -n "${RUNTIME}" ]] || die "no iOS runtime found; see --list"
  log "creating '${SIM_NAME}' (${RUNTIME}) ..."
  UDID="$(simctl create "${SIM_NAME}" "${DEVICE_TYPE}" "${RUNTIME}" 2>/dev/null)" \
    || die "simctl create failed for '${SIM_NAME}'"
fi
log "device      : ${SIM_NAME} (${UDID})"

STATE="$(sim_line available "${SIM_NAME}" | awk '{print $2}')"
if [[ "${STATE}" == "Booted" ]]; then
  log "already booted"
else
  log "booting (timeout ${BOOT_TIMEOUT}s) ..."
  # bootstatus boots the device when needed and blocks until it is usable, so
  # no polling loop is required.
  simctl bootstatus "${UDID}" -b >/dev/null 2>&1 || die "boot failed; see 'xcrun simctl bootstatus ${UDID} -b'"
  log "booted"
fi

open -a Simulator >/dev/null 2>&1 || warn "could not open Simulator.app; the device is still usable headlessly"

if [[ -n "${APP_PATH}" ]]; then
  if [[ ! -e "${APP_PATH}" ]]; then
    warn "app not found: ${APP_PATH}"
  elif [[ "${APP_PATH}" == *.ipa ]]; then
    warn "a simulator cannot install an .ipa (device build); pass the .app from a simulator build"
  else
    log "installing ${APP_PATH} ..."
    simctl install "${UDID}" "${APP_PATH}" \
      && log "installed" \
      || warn "simctl install failed; confirm the .app was built for the simulator (arm64-simulator/x86_64)"
  fi
fi

if [[ -n "${LAUNCH_BUNDLE}" ]]; then
  simctl launch "${UDID}" "${LAUNCH_BUNDLE}" >/dev/null 2>&1 \
    && log "launched ${LAUNCH_BUNDLE}" \
    || warn "could not launch ${LAUNCH_BUNDLE}"
fi

cat <<EOF

[simulator] ================= next steps =================
[simulator] udid        : ${UDID}
[simulator] farm run    : DEVICE_FARM_PLATFORM=iOS DEVICE_FARM_UDID=${UDID} \\
[simulator]                 DEVICE_FARM_APP_PATH=${APP_PATH:-/path/to/MyApp.app} \\
[simulator]                 bash run_e2e_farm.sh
[simulator] traffic     : start mitmweb, then route the host through it -
[simulator]                 .venv/bin/mitmweb --listen-port ${PROXY_PORT} --web-port 8081
[simulator]                 scripts/simulator_up.sh --set-proxy --proxy-port ${PROXY_PORT}
[simulator]                 scripts/simulator_up.sh --trust-ca
[simulator]               a simulator has no proxy setting of its own: it uses
[simulator]               the host's network stack, so the proxy is set on macOS
[simulator]               and cleared again with --unset-proxy.
[simulator] stop        : scripts/simulator_up.sh --stop
[simulator] ==============================================

EOF
