#!/usr/bin/env bash
# Boot a headless, root-capable Android emulator for hardware-free E2E runs.
#
# Installs the required SDK packages if they are missing, creates the AVD once,
# then boots it with -writable-system so the mitmproxy CA can be trusted at the
# system level (see install_system_ca.sh).
#
# Usage:
#   scripts/emulator_up.sh                 # create if needed, boot, wait for boot_completed
#   scripts/emulator_up.sh --check         # report readiness only, never boot
#   scripts/emulator_up.sh --stop          # shut the emulator down
#   DEVICE_FARM_AVD_NAME=farm34 DEVICE_FARM_AVD_API=34 scripts/emulator_up.sh
#
# Requires KVM (/dev/kvm writable). Without it the script reports the exact
# reason and exits 1 instead of hanging on a software-rendered boot.
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AVD_NAME="${DEVICE_FARM_AVD_NAME:-farm34}"
AVD_API="${DEVICE_FARM_AVD_API:-34}"
AVD_ABI="${DEVICE_FARM_AVD_ABI:-x86_64}"
AVD_TAG="${DEVICE_FARM_AVD_TAG:-default}"  # 'default' = AOSP, keeps adb root working
AVD_DEVICE="${DEVICE_FARM_AVD_DEVICE:-pixel_5}"
AVD_MEMORY="${DEVICE_FARM_AVD_MEMORY:-3072}"
AVD_PORT="${DEVICE_FARM_AVD_PORT:-5554}"
BOOT_TIMEOUT="${DEVICE_FARM_AVD_BOOT_TIMEOUT:-300}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${HOME}/android-sdk}}"
IMAGE="system-images;android-${AVD_API};${AVD_TAG};${AVD_ABI}"
BUILD_TOOLS_VERSION="${DEVICE_FARM_BUILD_TOOLS:-${AVD_API}.0.0}"
SERIAL="emulator-${AVD_PORT}"
LOG_FILE="${DEVICE_FARM_AVD_LOG:-${FARM_DIR}/artifacts/emulator-${AVD_NAME}.log}"

log() { printf '[emulator] %s\n' "$*"; }
warn() { printf '[emulator] WARN  %s\n' "$*" >&2; }
die() { printf '[emulator] ERROR %s\n' "$*" >&2; exit 1; }

MODE=up
for arg in "$@"; do
  case "${arg}" in
    --check) MODE=check ;;
    --stop) MODE=stop ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: ${arg} (try --help)" ;;
  esac
done

export ANDROID_SDK_ROOT="${SDK_ROOT}" ANDROID_HOME="${SDK_ROOT}"
export PATH="${SDK_ROOT}/platform-tools:${SDK_ROOT}/emulator:${SDK_ROOT}/cmdline-tools/latest/bin:${PATH}"

kvm_state() {
  if [[ ! -e /dev/kvm ]]; then
    printf 'absent'
  elif [[ -w /dev/kvm ]]; then
    printf 'writable'
  elif id -nG | tr ' ' '\n' | grep -qx kvm \
    || getent group kvm 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$(id -un)"; then
    # Membership exists on the host but is not active in this process yet, so
    # the emulator has to be launched through `sg kvm`.
    printf 'needs-sg'
  else
    printf 'unwritable'
  fi
}

# Run a command with the kvm group applied when the current process lacks it.
with_kvm() {
  if [[ "$(kvm_state)" == "needs-sg" ]]; then
    sg kvm -c "$*"
  else
    eval "$*"
  fi
}

emulator_running() {
  adb devices 2>/dev/null | grep -q "^${SERIAL}[[:space:]]*device"
}

if [[ "${MODE}" == "stop" ]]; then
  if emulator_running; then
    adb -s "${SERIAL}" emu kill >/dev/null 2>&1 || pkill -f "emulator.*-avd ${AVD_NAME}" || true
    log "stopped ${SERIAL}"
  else
    log "${SERIAL} is not running"
  fi
  exit 0
fi

MISSING=0
for tool in java; do
  command -v "${tool}" >/dev/null 2>&1 || { warn "${tool} not found"; MISSING=1; }
done
[[ -x "${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ]] \
  || { warn "sdkmanager not found under ${SDK_ROOT}/cmdline-tools/latest"; MISSING=1; }
KVM="$(kvm_state)"
log "sdk root : ${SDK_ROOT}"
log "avd      : ${AVD_NAME} (api ${AVD_API}, ${AVD_TAG}/${AVD_ABI})"
log "kvm      : ${KVM}"
[[ "${KVM}" == "absent" || "${KVM}" == "unwritable" ]] && MISSING=1

if [[ "${MODE}" == "check" ]]; then
  if emulator_running; then
    log "status   : ${SERIAL} already booted"
    exit 0
  fi
  [[ "${MISSING}" -eq 0 ]] && { log "status   : ready to boot"; exit 0; }
  warn "not ready: address the items above"
  case "${KVM}" in
    absent) warn "this host has no /dev/kvm; an emulator cannot be booted here" ;;
    unwritable) warn "grant KVM access: sudo usermod -aG kvm \$USER && sudo chmod 660 /dev/kvm" ;;
  esac
  exit 1
fi

[[ "${MISSING}" -eq 0 ]] || die "preflight failed; re-run with --check for details"

if emulator_running; then
  log "${SERIAL} is already booted; nothing to do"
  exit 0
fi

# build-tools ships apksigner, which the Appium uiautomator2 driver needs to
# verify an .apk before installing it.
REQUIRED_PACKAGES=(
  "platform-tools"
  "emulator"
  "platforms;android-${AVD_API}"
  "build-tools;${BUILD_TOOLS_VERSION}"
  "${IMAGE}"
)
INSTALLED="$(sdkmanager --list_installed 2>/dev/null)"
MISSING_PACKAGES=()
for package in "${REQUIRED_PACKAGES[@]}"; do
  grep -qF " ${package} " <<<"${INSTALLED}" || MISSING_PACKAGES+=("${package}")
done
if (( ${#MISSING_PACKAGES[@]} > 0 )); then
  log "installing SDK packages: ${MISSING_PACKAGES[*]} ..."
  yes 2>/dev/null | sdkmanager --licenses >/dev/null 2>&1
  sdkmanager --install "${MISSING_PACKAGES[@]}" >/dev/null \
    || die "sdkmanager could not install: ${MISSING_PACKAGES[*]}"
fi

if ! avdmanager list avd -c 2>/dev/null | grep -qx "${AVD_NAME}"; then
  log "creating avd ${AVD_NAME} ..."
  echo no | avdmanager create avd -n "${AVD_NAME}" -k "${IMAGE}" -d "${AVD_DEVICE}" >/dev/null \
    || die "could not create the avd ${AVD_NAME}"
fi

mkdir -p "$(dirname "${LOG_FILE}")"
log "booting headless (log: ${LOG_FILE}) ..."
with_kvm "nohup ${SDK_ROOT}/emulator/emulator -avd ${AVD_NAME} -no-window -no-audio \
  -no-boot-anim -gpu swiftshader_indirect -writable-system -no-snapshot \
  -memory ${AVD_MEMORY} -port ${AVD_PORT} > '${LOG_FILE}' 2>&1 &"

waited=0
until emulator_running; do
  sleep 3
  waited=$((waited + 3))
  if (( waited >= BOOT_TIMEOUT )); then
    warn "no adb connection after ${BOOT_TIMEOUT}s; see ${LOG_FILE}"
    exit 1
  fi
done

log "waiting for sys.boot_completed ..."
if ! timeout "${BOOT_TIMEOUT}" adb -s "${SERIAL}" shell \
  'while [[ -z $(getprop sys.boot_completed) ]]; do sleep 2; done' >/dev/null 2>&1; then
  warn "boot did not complete within ${BOOT_TIMEOUT}s; see ${LOG_FILE}"
  exit 1
fi

log "booted: ${SERIAL} (android $(adb -s "${SERIAL}" shell getprop ro.build.version.release | tr -d '\r'))"
log "next   : scripts/install_system_ca.sh --udid ${SERIAL}"
