#!/usr/bin/env bash
# Trust the mitmproxy CA at the *system* level on a rooted emulator so HTTPS
# from ordinary (unpinned) apps is decrypted into the HAR.
#
# User-store certificates are ignored by apps targeting API 24+, so the CA has
# to land in the system store. On API 30+ that store lives in the Conscrypt
# APEX (/apex/com.android.conscrypt/cacerts), which is read-only even under
# root: the working approach is to bind-mount a writable copy over it inside
# init's mount namespace and restart the framework so zygote-forked apps
# inherit the mount.
#
# Usage:
#   scripts/install_system_ca.sh                     # single attached device
#   scripts/install_system_ca.sh --udid emulator-5554
#   scripts/install_system_ca.sh --check             # report trust state only
#
# Requires: adb, a rooted build (AOSP emulator image, ideally booted with
# -writable-system). Refuses to run against a non-rooted device instead of
# leaving it half-configured. Pinned apps stay opaque regardless (see README).
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFDIR="${DEVICE_FARM_MITM_CONFDIR:-${HOME}/.mitmproxy}"
PEM="${CONFDIR}/mitmproxy-ca-cert.pem"
DEVICE_STORE=/data/local/tmp/cacerts
APEX_STORE=/apex/com.android.conscrypt/cacerts
LEGACY_STORE=/system/etc/security/cacerts

UDID=""
MODE=install
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 ;;
    --check) MODE=check; shift ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf '[ca] ERROR unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

# Stock macOS ships no GNU `timeout`, so bound long-running commands by hand.
# Returns 124 when the deadline is hit, like timeout(1) does.
bounded() {
  local deadline="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= deadline )); then
      kill "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 124
    fi
  done
  wait "${pid}"
}

log() { printf '[ca] %s\n' "$*"; }
warn() { printf '[ca] WARN  %s\n' "$*" >&2; }
die() { printf '[ca] ERROR %s\n' "$*" >&2; exit 1; }

ADB=(adb)
[[ -n "${UDID}" ]] && ADB=(adb -s "${UDID}")

command -v adb >/dev/null 2>&1 || die "adb not found; install platform-tools (see README)"
"${ADB[@]}" get-state >/dev/null 2>&1 || die "no device reachable via ${ADB[*]}"

if [[ ! -f "${PEM}" ]]; then
  if command -v mitmdump >/dev/null 2>&1; then
    log "generating the mitmproxy CA in ${CONFDIR} ..."
    bounded 8 mitmdump --set "confdir=${CONFDIR}" -q >/dev/null 2>&1
  fi
  [[ -f "${PEM}" ]] || die "no CA at ${PEM}; run mitmdump once or pip install mitmproxy"
fi

command -v openssl >/dev/null 2>&1 || die "openssl is required to hash the CA subject"
HASH="$("$(command -v openssl)" x509 -inform PEM -subject_hash_old -in "${PEM}" -noout)" \
  || die "could not compute the CA subject hash"
CERT_NAME="${HASH}.0"
log "ca      : ${PEM} -> ${CERT_NAME}"

trusted() {
  "${ADB[@]}" shell "ls ${APEX_STORE}/${CERT_NAME} ${LEGACY_STORE}/${CERT_NAME} 2>/dev/null" \
    | grep -q "${CERT_NAME}"
}

if [[ "${MODE}" == "check" ]]; then
  if trusted; then
    log "status  : ${CERT_NAME} is present in the system store"
    exit 0
  fi
  warn "status  : ${CERT_NAME} is NOT in the system store; HTTPS bodies will not decrypt"
  exit 1
fi

"${ADB[@]}" root >/dev/null 2>&1
sleep 3
if [[ "$("${ADB[@]}" shell id -u | tr -d '\r')" != "0" ]]; then
  die "adbd is not running as root; use an AOSP ('default' tag) emulator image, not google_apis"
fi

# Android's hashed-cert format: PEM followed by the human-readable dump.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp "${PEM}" "${STAGE}/${CERT_NAME}"
openssl x509 -inform PEM -text -fingerprint -noout -in "${PEM}" >> "${STAGE}/${CERT_NAME}"
"${ADB[@]}" push "${STAGE}/${CERT_NAME}" "/data/local/tmp/${CERT_NAME}" >/dev/null \
  || die "could not push the certificate"

"${ADB[@]}" remount >/dev/null 2>&1 || warn "adb remount failed; continuing with the APEX overlay"

# The copy is mounted over a system path, so it must carry system labels and
# ownership - without 'chcon u:object_r:system_file:s0' system_server cannot
# read the directory and crash-loops on boot (SystemCertificateSource NPE).
"${ADB[@]}" shell "set -e
  mkdir -p ${DEVICE_STORE}
  cp ${APEX_STORE}/* ${DEVICE_STORE}/ 2>/dev/null || cp ${LEGACY_STORE}/* ${DEVICE_STORE}/
  cp /data/local/tmp/${CERT_NAME} ${DEVICE_STORE}/
  chown root:root ${DEVICE_STORE} ${DEVICE_STORE}/*
  chmod 755 ${DEVICE_STORE}; chmod 644 ${DEVICE_STORE}/*
  chcon u:object_r:system_file:s0 ${DEVICE_STORE} ${DEVICE_STORE}/*
  cp /data/local/tmp/${CERT_NAME} ${LEGACY_STORE}/ 2>/dev/null || true" \
  || die "could not stage the certificate bundle on the device"

if "${ADB[@]}" shell "[ -d ${APEX_STORE} ]"; then
  "${ADB[@]}" shell "nsenter --mount=/proc/1/ns/mnt -- mount --bind ${DEVICE_STORE} ${APEX_STORE}" \
    || die "bind mount into init's namespace failed (needs a rooted, -writable-system boot)"
  log "mounted : ${DEVICE_STORE} over ${APEX_STORE} (init namespace)"
  log "restarting the framework so apps inherit the mount ..."
  "${ADB[@]}" shell 'stop; start' >/dev/null 2>&1
  sleep 5
  waited=0
  until [[ "$("${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    sleep 3
    waited=$((waited + 3))
    (( waited >= 240 )) \
      && die "the framework did not come back up; check 'adb logcat -b crash'"
  done
fi

if trusted; then
  log "done    : mitmproxy CA trusted system-wide (bind mount is lost on reboot; re-run then)"
  log "next    : DEVICE_FARM_ENABLE_PROXY=1 DEVICE_FARM_ENABLE_DEVICE_PROXY=1 ./run_e2e_farm.sh"
  exit 0
fi
die "the certificate is still not visible in the system store"
