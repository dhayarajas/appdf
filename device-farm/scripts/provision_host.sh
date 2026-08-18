#!/usr/bin/env bash
# Phase 1 - idempotent host provisioning for the self-hosted mobile device farm.
#
# Safe to re-run: every step checks first and only installs what is missing.
# When a dependency cannot be installed non-interactively the script prints
# copy-pasteable guidance instead of failing. A missing device is a warning,
# never an error.
#
# Usage:
#   bash scripts/provision_host.sh            # install what is possible, verify the rest
#   bash scripts/provision_host.sh --check    # verify only, install nothing
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FARM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CHECK_ONLY=0
[[ "${1:-}" == "--check" || "${1:-}" == "-c" ]] && CHECK_ONLY=1

WARNINGS=0
ERRORS=0

log()  { printf '[provision] %s\n' "$*"; }
ok()   { printf '[provision]   OK      %s\n' "$*"; }
warn() { printf '[provision]   WARN    %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
err()  { printf '[provision]   MISSING %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }
hint() { printf '[provision]           -> %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

OS_NAME="$(uname -s)"
IS_DARWIN=0
[[ "${OS_NAME}" == "Darwin" ]] && IS_DARWIN=1

# Package manager detection (best effort; only used for optional installs).
PKG=""
if [[ ${IS_DARWIN} -eq 1 ]] && have brew; then
  PKG="brew"
elif have apt-get; then
  PKG="apt"
elif have dnf; then
  PKG="dnf"
elif have pacman; then
  PKG="pacman"
fi

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo; then
  SUDO="sudo"
fi

pkg_install() {
  # pkg_install <apt-name> <brew-name> <dnf-name> <pacman-name>
  local apt_pkg="$1" brew_pkg="$2" dnf_pkg="$3" pacman_pkg="$4"
  if [[ ${CHECK_ONLY} -eq 1 ]]; then
    return 1
  fi
  case "${PKG}" in
    apt)    ${SUDO} apt-get update -qq && ${SUDO} apt-get install -y "${apt_pkg}" ;;
    brew)   brew install "${brew_pkg}" ;;
    dnf)    ${SUDO} dnf install -y "${dnf_pkg}" ;;
    pacman) ${SUDO} pacman -Sy --noconfirm "${pacman_pkg}" ;;
    *)      return 1 ;;
  esac
}

version_ge() {
  # version_ge <have> <want> -> 0 when have >= want
  [[ "$1" == "$2" ]] && return 0
  local lowest
  lowest="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [[ "${lowest}" == "$2" ]]
}

log "host: ${OS_NAME} $(uname -m); package manager: ${PKG:-none detected}"
[[ ${CHECK_ONLY} -eq 1 ]] && log "running in --check mode: nothing will be installed"

# ---------------------------------------------------------------- Node.js LTS
check_node() {
  log "Node.js (LTS) ..."
  if have node; then
    local v major
    v="$(node --version 2>/dev/null | sed 's/^v//')"
    major="${v%%.*}"
    if [[ -n "${major}" ]] && (( major >= 18 )); then
      ok "node ${v}"
    else
      warn "node ${v} is older than the supported LTS lines (18/20/22)"
      hint "install via nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && nvm install --lts"
    fi
    have npm && ok "npm $(npm --version 2>/dev/null)" || err "npm not found alongside node"
    return
  fi
  err "node"
  if pkg_install nodejs node nodejs nodejs; then
    ok "node $(node --version 2>/dev/null)"
    ERRORS=$((ERRORS - 1))
  else
    hint "install Node.js LTS: https://nodejs.org/en/download or 'nvm install --lts'"
  fi
}

# ---------------------------------------------------------------- OpenJDK 17+
check_java() {
  log "OpenJDK 17+ ..."
  if have java; then
    local raw major
    raw="$(java -version 2>&1 | head -n1 | sed -E 's/.*version "([0-9._]+).*/\1/')"
    major="${raw%%.*}"
    [[ "${major}" == "1" ]] && major="$(printf '%s' "${raw}" | cut -d. -f2)"
    if [[ -n "${major}" ]] && (( major >= 17 )); then
      ok "java ${raw}"
    else
      err "java ${raw} (need 17+)"
      hint "apt: sudo apt-get install -y openjdk-17-jdk | brew: brew install openjdk@17"
    fi
  else
    err "java"
    if pkg_install openjdk-17-jdk openjdk@17 java-17-openjdk-devel jdk17-openjdk; then
      ok "java $(java -version 2>&1 | head -n1)"
      ERRORS=$((ERRORS - 1))
    else
      hint "install OpenJDK 17+: https://adoptium.net/temurin/releases/?version=17"
    fi
  fi
}

# --------------------------------------------------------------- Python 3.11+
check_python() {
  log "Python 3.11+ ..."
  local py=""
  for candidate in python3.13 python3.12 python3.11 python3; do
    have "${candidate}" || continue
    local v
    v="$("${candidate}" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || continue
    if version_ge "${v}" "3.11"; then
      py="${candidate}"
      ok "${candidate} ${v}"
      break
    fi
  done
  if [[ -z "${py}" ]]; then
    err "python 3.11+"
    hint "apt: sudo apt-get install -y python3.11 python3.11-venv | brew: brew install python@3.11"
    return
  fi
  if [[ ${CHECK_ONLY} -eq 0 ]]; then
    log "installing Python test dependencies into ${FARM_DIR}/.venv ..."
    if "${py}" -m venv "${FARM_DIR}/.venv" 2>/dev/null; then
      # shellcheck disable=SC1091
      "${FARM_DIR}/.venv/bin/python" -m pip install --quiet --upgrade pip \
        && "${FARM_DIR}/.venv/bin/python" -m pip install --quiet -e "${FARM_DIR}" \
        && ok "virtualenv ready: ${FARM_DIR}/.venv" \
        || warn "dependency install failed; run: ${FARM_DIR}/.venv/bin/pip install -e ${FARM_DIR}"
    else
      warn "could not create ${FARM_DIR}/.venv (missing venv module?)"
      hint "apt: sudo apt-get install -y python3-venv"
    fi
  fi
}

# ------------------------------------------------- Android SDK platform-tools
check_android() {
  log "Android SDK platform-tools ..."
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "${sdk}" ]]; then
    for candidate in "${HOME}/Android/Sdk" "${HOME}/Library/Android/sdk" /usr/lib/android-sdk /opt/android-sdk; do
      [[ -d "${candidate}" ]] && sdk="${candidate}" && break
    done
  fi
  if [[ -n "${sdk}" && -d "${sdk}" ]]; then
    ok "Android SDK at ${sdk}"
  else
    err "Android SDK (ANDROID_HOME / ANDROID_SDK_ROOT unset and no SDK found)"
    hint "install command line tools: https://developer.android.com/studio#command-line-tools-only"
    hint "then: sdkmanager --install 'platform-tools' && export ANDROID_HOME=<sdk-dir>"
  fi

  if have adb; then
    ok "adb $(adb version 2>/dev/null | head -n1)"
  elif [[ -n "${sdk}" && -x "${sdk}/platform-tools/adb" ]]; then
    warn "adb found at ${sdk}/platform-tools/adb but not on PATH"
    hint "export PATH=\"${sdk}/platform-tools:\$PATH\""
  else
    err "adb"
    if pkg_install android-sdk-platform-tools android-platform-tools android-tools android-tools; then
      ok "adb $(adb version 2>/dev/null | head -n1)"
      ERRORS=$((ERRORS - 1))
    else
      hint "sdkmanager --install 'platform-tools' (or apt-get install android-sdk-platform-tools)"
    fi
  fi
}

# ------------------------------------------------------------- Env var checks
check_env() {
  log "environment variables ..."
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    ok "ANDROID_HOME=${ANDROID_HOME}"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    warn "ANDROID_HOME unset (ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT} will be used as fallback)"
  else
    warn "ANDROID_HOME unset"
    hint "export ANDROID_HOME=\"\$HOME/Android/Sdk\""
  fi

  if [[ -n "${JAVA_HOME:-}" ]]; then
    ok "JAVA_HOME=${JAVA_HOME}"
  else
    warn "JAVA_HOME unset"
    if have java; then
      local guess
      guess="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
      hint "export JAVA_HOME=\"${guess}\""
    else
      hint "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
    fi
  fi

  case ":${PATH}:" in
    *:*platform-tools:*) ok "PATH contains platform-tools" ;;
    *) warn "PATH does not contain Android platform-tools"
       hint "export PATH=\"\${ANDROID_HOME}/platform-tools:\$PATH\"" ;;
  esac
}

# ------------------------------------------------------ Appium 2.x + drivers
# Current uiautomator2 / xcuitest / device-farm releases require an Appium 3.x
# server and refuse to install on 2.x, so a compatible version is pinned when
# the installed server reports major 2.
extension_spec() {
  local package="$1" major
  major="$(appium --version 2>/dev/null)"
  major="${major%%.*}"
  if [[ "${major}" == "2" ]]; then
    case "${package}" in
      appium-uiautomator2-driver)
        printf '%s' "${UIAUTOMATOR2_SPEC:-appium-uiautomator2-driver@4.2.9}"
        return ;;
      appium-xcuitest-driver)
        printf '%s' "${XCUITEST_SPEC:-appium-xcuitest-driver@7.26.4}"
        return ;;
      appium-device-farm)
        printf '%s' "${DEVICE_FARM_PLUGIN_SPEC:-appium-device-farm@9.8.8}"
        return ;;
    esac
  fi
  printf '%s' "${package}"
}

install_extension() {
  # install_extension <driver|plugin> <npm-spec> <extension-name>
  local kind="$1" spec="$2" name="$3"
  log "  appium ${kind} install --source=npm ${spec}"
  if appium "${kind}" install --source=npm "${spec}"; then
    ok "${kind} ${name} installed (${spec})"
    return 0
  fi
  hint "on a version conflict, pin a compatible release, e.g. UIAUTOMATOR2_SPEC=appium-uiautomator2-driver@<version>"
  return 1
}

check_appium() {
  log "Appium 2.x ..."
  if ! have appium; then
    err "appium"
    if have npm && [[ ${CHECK_ONLY} -eq 0 ]]; then
      log "installing appium globally via npm ..."
      if npm install -g appium; then
        ok "appium $(appium --version 2>/dev/null)"
        ERRORS=$((ERRORS - 1))
      else
        hint "npm install -g appium (may need sudo, or set a user-writable npm prefix)"
        return
      fi
    else
      hint "npm install -g appium"
      return
    fi
  else
    local av
    av="$(appium --version 2>/dev/null)"
    if [[ "${av%%.*}" -ge 2 ]] 2>/dev/null; then
      ok "appium ${av}"
    else
      warn "appium ${av} detected; this scaffold targets Appium 2.x"
      hint "npm install -g appium@latest"
    fi
  fi

  local installed_drivers installed_plugins
  installed_drivers="$(appium driver list --installed 2>&1 || true)"
  installed_plugins="$(appium plugin list --installed 2>&1 || true)"

  if printf '%s' "${installed_drivers}" | grep -q 'uiautomator2'; then
    ok "driver uiautomator2 installed"
  elif [[ ${CHECK_ONLY} -eq 1 ]]; then
    warn "driver uiautomator2 not installed (appium driver install uiautomator2)"
  else
    log "installing driver uiautomator2 ..."
    install_extension driver "$(extension_spec appium-uiautomator2-driver)" uiautomator2 \
      || warn "driver uiautomator2 install failed; re-run manually"
  fi

  if [[ ${IS_DARWIN} -eq 1 ]]; then
    if printf '%s' "${installed_drivers}" | grep -q 'xcuitest'; then
      ok "driver xcuitest installed"
    elif [[ ${CHECK_ONLY} -eq 1 ]]; then
      warn "driver xcuitest not installed (appium driver install xcuitest)"
    else
      log "installing driver xcuitest (Darwin host) ..."
      install_extension driver "$(extension_spec appium-xcuitest-driver)" xcuitest \
        || warn "driver xcuitest install failed; Xcode + command line tools are required"
    fi
  else
    log "  skipping xcuitest driver: host is ${OS_NAME}, not Darwin"
  fi

  if printf '%s' "${installed_plugins}" | grep -q 'device-farm'; then
    ok "plugin device-farm installed"
  elif [[ ${CHECK_ONLY} -eq 1 ]]; then
    warn "plugin device-farm not installed (appium plugin install --source=npm appium-device-farm)"
  else
    log "installing plugin appium-device-farm ..."
    install_extension plugin "$(extension_spec appium-device-farm)" device-farm \
      || warn "plugin device-farm install failed; re-run manually"
  fi
}

# ------------------------------------------------------- Trace pipeline tools
check_trace_tools() {
  log "trace pipeline tooling ..."
  if have mitmdump; then
    ok "mitmdump $(mitmdump --version 2>/dev/null | head -n1)"
  else
    warn "mitmdump not found; HAR capture will be disabled"
    hint "pip install mitmproxy  (or brew install mitmproxy)"
  fi

  if have tcpdump; then
    ok "tcpdump $(tcpdump --version 2>&1 | head -n1)"
    if [[ ${EUID:-$(id -u)} -ne 0 ]] && ! tcpdump -D >/dev/null 2>&1; then
      warn "tcpdump present but not usable unprivileged; PCAP capture needs root"
      hint "sudo setcap cap_net_raw,cap_net_admin=eip \$(command -v tcpdump)"
    fi
  else
    warn "tcpdump not found; PCAP capture will be disabled"
    hint "apt: sudo apt-get install -y tcpdump | brew: brew install tcpdump"
  fi
}

# -------------------------------------------------------- Device preflight
check_devices() {
  log "connected devices (informational) ..."
  if ! have adb; then
    warn "adb unavailable, cannot enumerate devices"
    return
  fi
  adb start-server >/dev/null 2>&1 || warn "adb start-server failed"
  local devices
  devices="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')"
  if [[ -z "${devices}" ]]; then
    warn "no Android devices attached - this is expected in CI and is NOT an error"
    hint "on Linux see docs/udev-rules.md; verify USB debugging and 'adb devices'"
  else
    while read -r serial; do
      [[ -z "${serial}" ]] && continue
      ok "device ${serial} ($(adb -s "${serial}" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r'))"
    done <<< "${devices}"
  fi
}

main() {
  check_node
  check_java
  check_python
  check_android
  check_env
  check_appium
  check_trace_tools
  check_devices

  printf '\n[provision] ---------------- summary ----------------\n'
  printf '[provision] missing required components: %d\n' "${ERRORS}"
  printf '[provision] warnings:                    %d\n' "${WARNINGS}"
  if (( ERRORS > 0 )); then
    printf '[provision] status: INCOMPLETE - address the MISSING items above, then re-run.\n'
    printf '[provision] launch Appium once complete:\n'
    printf '[provision]   appium server --use-plugins=device-farm --config %s/config/appium-device-farm.config.json\n' "${FARM_DIR}"
    return 1
  fi
  printf '[provision] status: READY\n'
  printf '[provision] launch Appium with the device-farm plugin:\n'
  printf '[provision]   appium server --use-plugins=device-farm --config %s/config/appium-device-farm.config.json\n' "${FARM_DIR}"
  return 0
}

main "$@"
