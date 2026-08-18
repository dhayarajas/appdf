#!/usr/bin/env bash
# Local smoke test for the device farm scaffold - no phone, emulator, adb or
# Appium required. Run it after cloning, before touching hardware:
#
#   bash device-farm/scripts/local_smoke_test.sh
#   bash device-farm/scripts/local_smoke_test.sh --keep      # keep artifacts/
#   bash device-farm/scripts/local_smoke_test.sh --no-venv   # use the current interpreter
#
# Every check is hardware-free. Exit code 0 means the scaffold is healthy on this
# host; each failure is reported and counted, and the summary lists them all.
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${FARM_DIR}"

KEEP_ARTIFACTS=0
USE_VENV=1
for arg in "$@"; do
  case "${arg}" in
    --keep) KEEP_ARTIFACTS=1 ;;
    --no-venv) USE_VENV=0 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown option: %s (try --help)\n' "${arg}" >&2; exit 2 ;;
  esac
done

RUN_ID="smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
PASSED=0
FAILED=0
FAILURES=()

log()  { printf '\n[smoke] === %s\n' "$*"; }
ok()   { PASSED=$((PASSED + 1)); printf '[smoke] PASS  %s\n' "$*"; }
bad()  { FAILED=$((FAILED + 1)); FAILURES+=("$1"); printf '[smoke] FAIL  %s\n' "$1" >&2; }

# Run a command quietly; report pass/fail against an expected exit code.
check() {
  local name="$1" expected="$2"
  shift 2
  local output rc
  output="$("$@" 2>&1)"
  rc=$?
  if [[ "${rc}" -eq "${expected}" ]]; then
    ok "${name}"
  else
    bad "${name} (expected exit ${expected}, got ${rc})"
    printf '%s\n' "${output}" | tail -20 >&2
  fi
}

# --------------------------------------------------------------- interpreter
log "python environment"
if [[ "${USE_VENV}" -eq 1 ]]; then
  if [[ ! -x "${FARM_DIR}/.venv/bin/python" ]]; then
    printf '[smoke] creating %s/.venv ...\n' "${FARM_DIR}"
    python3 -m venv "${FARM_DIR}/.venv" || { bad "venv creation"; exit 1; }
  fi
  PYTHON="${FARM_DIR}/.venv/bin/python"
  if ! "${PYTHON}" -c 'import pytest, appium, mitmproxy' >/dev/null 2>&1; then
    printf '[smoke] installing dependencies (quiet) ...\n'
    "${PYTHON}" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
    "${PYTHON}" -m pip install -q -e "${FARM_DIR}" || bad "dependency install"
  fi
  # mitmdump lives in .venv/bin, which must be on PATH for shutil.which lookups.
  export PATH="${FARM_DIR}/.venv/bin:${PATH}"
else
  PYTHON="$(command -v python3 || true)"
  [[ -n "${PYTHON}" ]] || { bad "python3 not found"; exit 1; }
fi
printf '[smoke] python: %s (%s)\n' "${PYTHON}" "$("${PYTHON}" --version 2>&1)"

# ------------------------------------------------------------- static checks
log "shell syntax and config"
check "bash -n run_e2e_farm.sh" 0 bash -n "${FARM_DIR}/run_e2e_farm.sh"
check "bash -n scripts/provision_host.sh" 0 bash -n "${FARM_DIR}/scripts/provision_host.sh"
check "bash -n scripts/local_smoke_test.sh" 0 bash -n "${BASH_SOURCE[0]}"
check "appium-device-farm.config.json is valid JSON" 0 \
  "${PYTHON}" -m json.tool "${FARM_DIR}/config/appium-device-farm.config.json"

log "imports and collection (no hardware touched)"
check "framework/proxy/capture import cleanly" 0 \
  "${PYTHON}" -c 'import framework, proxy, capture'
check "pytest --collect-only" 0 "${PYTHON}" -m pytest --collect-only -q

# ------------------------------------------------------------ preflight (soft)
log "preflight (missing tooling is reported, never fatal)"
if bash "${FARM_DIR}/scripts/provision_host.sh" --check >/tmp/smoke-preflight.$$ 2>&1; then
  ok "preflight: host is fully provisioned"
else
  ok "preflight: reported missing components (expected on an unprovisioned host)"
  grep -E 'MISSING|WARN' /tmp/smoke-preflight.$$ | head -10 || true
fi
rm -f /tmp/smoke-preflight.$$

# ------------------------------------------------------------ orchestrated runs
log "zero-device orchestration"
check "dry run exits 0" 0 env \
  DEVICE_FARM_DRY_RUN=1 DEVICE_FARM_TEST_RUN_ID="${RUN_ID}-dry" \
  bash "${FARM_DIR}/run_e2e_farm.sh"
check "non-dry run with zero devices exits 0" 0 env \
  DEVICE_FARM_TEST_RUN_ID="${RUN_ID}-wet" bash "${FARM_DIR}/run_e2e_farm.sh"
check "artifact structure validates" 0 \
  "${PYTHON}" "${FARM_DIR}/scripts/validate_run.py" --run-id "${RUN_ID}-wet"
check "bogus run id is rejected" 1 \
  "${PYTHON}" "${FARM_DIR}/scripts/validate_run.py" --run-id "${RUN_ID}-does-not-exist"
check "non-numeric DEVICE_FARM_MAX_PARALLEL is tolerated" 0 env \
  DEVICE_FARM_MAX_PARALLEL=abc DEVICE_FARM_DRY_RUN=1 \
  DEVICE_FARM_TEST_RUN_ID="${RUN_ID}-badenv" bash "${FARM_DIR}/run_e2e_farm.sh"
check "non-numeric DEVICE_FARM_APPIUM_STARTUP_TIMEOUT is tolerated" 0 env \
  DEVICE_FARM_APPIUM_STARTUP_TIMEOUT=abc DEVICE_FARM_DRY_RUN=1 \
  DEVICE_FARM_TEST_RUN_ID="${RUN_ID}-badtimeout" bash "${FARM_DIR}/run_e2e_farm.sh"

# --------------------------------------------------------- trace pipeline probe
log "trace pipeline (real traffic through mitmdump, still no device)"
if "${PYTHON}" "${FARM_DIR}/scripts/smoke_proxy_probe.py" --run-id "${RUN_ID}-proxy"; then
  ok "proxy/HAR probe"
else
  bad "proxy/HAR probe"
fi

# --------------------------------------------------------------------- summary
log "leak check"
if pgrep -f 'mitmdump.*hardump' >/dev/null 2>&1; then
  bad "mitmdump left running"
else
  ok "no leaked mitmdump processes"
fi

if [[ "${KEEP_ARTIFACTS}" -eq 1 ]]; then
  printf '\n[smoke] artifacts kept under %s/artifacts/%s-*\n' "${FARM_DIR}" "${RUN_ID}"
else
  rm -rf "${FARM_DIR}/artifacts/${RUN_ID}-"*
fi

printf '\n[smoke] ============== local smoke test ==============\n'
printf '[smoke] passed : %s\n' "${PASSED}"
printf '[smoke] failed : %s\n' "${FAILED}"
for failure in ${FAILURES+"${FAILURES[@]}"}; do
  printf '[smoke]   - %s\n' "${failure}"
done
if [[ "${FAILED}" -eq 0 ]]; then
  printf '[smoke] result : OK - the scaffold is healthy on this host (no devices needed)\n'
else
  printf '[smoke] result : PROBLEMS FOUND - see the failures above\n'
fi
printf '[smoke] ==============================================\n'

[[ "${FAILED}" -eq 0 ]]
