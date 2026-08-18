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
# Acceleration is required so the boot never falls back to a software-rendered
# emulator: /dev/kvm on Linux, Apple Hypervisor.framework on macOS. Without it
# the script reports the exact reason and exits 1 instead of hanging.
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

if [[ "${HOST_OS}" == "Darwin" ]]; then
  DEFAULT_SDK_ROOT="${HOME}/Library/Android/sdk"
else
  DEFAULT_SDK_ROOT="${HOME}/android-sdk"
fi

# Apple Silicon only ships arm64-v8a system images; everything else stays x86_64.
if [[ "${HOST_OS}" == "Darwin" && "${HOST_ARCH}" == "arm64" ]]; then
  DEFAULT_AVD_ABI=arm64-v8a
else
  DEFAULT_AVD_ABI=x86_64
fi

AVD_NAME="${DEVICE_FARM_AVD_NAME:-farm34}"
AVD_API="${DEVICE_FARM_AVD_API:-34}"
AVD_ABI="${DEVICE_FARM_AVD_ABI:-${DEFAULT_AVD_ABI}}"
AVD_TAG="${DEVICE_FARM_AVD_TAG:-default}"  # 'default' = AOSP, keeps adb root working
AVD_DEVICE="${DEVICE_FARM_AVD_DEVICE:-pixel_5}"
AVD_MEMORY="${DEVICE_FARM_AVD_MEMORY:-3072}"
AVD_PORT="${DEVICE_FARM_AVD_PORT:-5554}"
BOOT_TIMEOUT="${DEVICE_FARM_AVD_BOOT_TIMEOUT:-300}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-${DEFAULT_SDK_ROOT}}}"
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
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: ${arg} (try --help)" ;;
  esac
done

export ANDROID_SDK_ROOT="${SDK_ROOT}" ANDROID_HOME="${SDK_ROOT}"
export PATH="${SDK_ROOT}/platform-tools:${SDK_ROOT}/emulator:${SDK_ROOT}/cmdline-tools/latest/bin:${PATH}"

# Acceleration state, normalised across hosts:
#   ready     - accelerated, nothing to launch through a helper group (macOS)
#   writable  - /dev/kvm usable by this process
#   needs-sg  - kvm group membership exists but is not active in this process
#   absent    - no accelerator on this host
#   unwritable- /dev/kvm exists but this user cannot use it
accel_state() {
  if [[ "${HOST_OS}" == "Darwin" ]]; then
    # macOS emulators use Apple Hypervisor.framework, which needs no user setup.
    # -accel-check is authoritative when the emulator package is installed.
    local accel_check="${SDK_ROOT}/emulator/emulator"
    if [[ -x "${accel_check}" ]]; then
      if "${accel_check}" -accel-check >/dev/null 2>&1; then
        printf 'ready'
      else
        printf 'unwritable'
      fi
    else
      printf 'writable'
    fi
    return
  fi
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
# There is no kvm group on macOS, so the wrapper is a plain eval there.
with_kvm() {
  if [[ "${HOST_OS}" != "Darwin" && "$(accel_state)" == "needs-sg" ]]; then
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
ACCEL="$(accel_state)"
if [[ "${HOST_OS}" == "Darwin" ]]; then
  ACCEL_LABEL="hypervisor.framework"
else
  ACCEL_LABEL="kvm"
fi
log "sdk root : ${SDK_ROOT}"
log "host     : ${HOST_OS}/${HOST_ARCH}"
log "avd      : ${AVD_NAME} (api ${AVD_API}, ${AVD_TAG}/${AVD_ABI})"
log "accel    : ${ACCEL_LABEL} ${ACCEL}"
[[ "${ACCEL}" == "absent" || "${ACCEL}" == "unwritable" ]] && MISSING=1

if [[ "${MODE}" == "check" ]]; then
  if emulator_running; then
    log "status   : ${SERIAL} already booted"
    exit 0
  fi
  [[ "${MISSING}" -eq 0 ]] && { log "status   : ready to boot"; exit 0; }
  warn "not ready: address the items above"
  if [[ "${HOST_OS}" == "Darwin" ]]; then
    case "${ACCEL}" in
      unwritable) warn "emulator -accel-check failed; update the SDK emulator package (sdkmanager --install emulator) and confirm macOS 12+" ;;
    esac
  else
    case "${ACCEL}" in
      absent) warn "this host has no /dev/kvm; an emulator cannot be booted here" ;;
      unwritable) warn "grant KVM access: sudo usermod -aG kvm \$USER && sudo chmod 660 /dev/kvm" ;;
    esac
  fi
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
# ${#arr[@]} on an empty array is an unbound-variable error under `set -u` in
# bash 3.2, which is what stock macOS ships.
if [[ -n "${MISSING_PACKAGES[*]:-}" ]]; then
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

# Polled from the host rather than with `timeout`, which stock macOS does not
# ship, and with the loop outside adb so a dropped shell cannot wedge the wait.
log "waiting for sys.boot_completed ..."
waited=0
until [[ "$(adb -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 2
  waited=$((waited + 2))
  if (( waited >= BOOT_TIMEOUT )); then
    warn "boot did not complete within ${BOOT_TIMEOUT}s; see ${LOG_FILE}"
    exit 1
  fi
done

log "booted: ${SERIAL} (android $(adb -s "${SERIAL}" shell getprop ro.build.version.release | tr -d '\r'))"
log "next   : scripts/install_system_ca.sh --udid ${SERIAL}"
