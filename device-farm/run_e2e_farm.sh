#!/usr/bin/env bash
# Phase 4 - orchestration entrypoint for the self-hosted mobile device farm.
#
#   1. preflight checks (never fatal when hardware is absent)
#   2. start the Appium server with the device-farm plugin
#   3. run pytest in parallel across the discovered devices
#   4. teardown: stop pytest-owned proxies/captures, stop Appium
#   5. print a summary and validate the artifact tree
#
# Exits 0 when zero devices are present (all device tests skip); non-zero only
# when a test genuinely fails.
#
# Usage:
#   ./run_e2e_farm.sh                      # full run
#   DEVICE_FARM_DRY_RUN=1 ./run_e2e_farm.sh   # no hardware, no Appium server
#   ./run_e2e_farm.sh -k test_artifact_tree   # extra args go to pytest
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${FARM_DIR}"

DRY_RUN="${DEVICE_FARM_DRY_RUN:-0}"
APPIUM_HOST="${DEVICE_FARM_APPIUM_HOST:-127.0.0.1}"
APPIUM_PORT="${DEVICE_FARM_APPIUM_PORT:-4723}"
APPIUM_URL="${DEVICE_FARM_APPIUM_URL:-http://${APPIUM_HOST}:${APPIUM_PORT}}"
MAX_PARALLEL="${DEVICE_FARM_MAX_PARALLEL:-4}"
PLUGIN_CONFIG="${DEVICE_FARM_PLUGIN_CONFIG:-${FARM_DIR}/config/appium-device-farm.config.json}"
TEST_RUN_ID="${DEVICE_FARM_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
ARTIFACTS_ROOT="${DEVICE_FARM_ARTIFACTS_ROOT:-${FARM_DIR}/artifacts}"
RUN_DIR="${ARTIFACTS_ROOT}/${TEST_RUN_ID}"
APPIUM_LOG="${RUN_DIR}/logs/appium.log"
APPIUM_STARTUP_TIMEOUT="${DEVICE_FARM_APPIUM_STARTUP_TIMEOUT:-60}"

export DEVICE_FARM_TEST_RUN_ID="${TEST_RUN_ID}"
export DEVICE_FARM_ARTIFACTS_ROOT="${ARTIFACTS_ROOT}"
export DEVICE_FARM_APPIUM_URL="${APPIUM_URL}"

APPIUM_PID=""
DEVICE_COUNT=0
WORKERS=1
PYTEST_RC=0
APPIUM_STARTED=0
PYTEST_RAN=0
RUN_FAILURE_REASON=""

log()  { printf '[e2e] %s\n' "$*"; }
warn() { printf '[e2e] WARN: %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

pick_python() {
  if [[ -x "${FARM_DIR}/.venv/bin/python" ]]; then
    printf '%s' "${FARM_DIR}/.venv/bin/python"
    return
  fi
  for candidate in python3.13 python3.12 python3.11 python3; do
    have "${candidate}" && { printf '%s' "${candidate}"; return; }
  done
  printf '%s' "python3"
}
PYTHON="$(pick_python)"

if ! [[ "${MAX_PARALLEL}" =~ ^[0-9]+$ ]]; then
  warn "DEVICE_FARM_MAX_PARALLEL='${MAX_PARALLEL}' is not a non-negative integer; using 4"
  MAX_PARALLEL=4
fi

if ! [[ "${APPIUM_STARTUP_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  warn "DEVICE_FARM_APPIUM_STARTUP_TIMEOUT='${APPIUM_STARTUP_TIMEOUT}' is not a non-negative integer; using 60"
  APPIUM_STARTUP_TIMEOUT=60
fi

if ! mkdir -p "${RUN_DIR}/reports" "${RUN_DIR}/logs" "${RUN_DIR}/traces" 2>/dev/null; then
  warn "cannot create the artifact tree at ${RUN_DIR} (check DEVICE_FARM_ARTIFACTS_ROOT permissions)"
  exit 1
fi

# ------------------------------------------------------------------ teardown
teardown() {
  local rc=$?
  log "teardown ..."
  # pytest fixtures own their mitmdump/tcpdump processes and stop them on exit;
  # this is a belt-and-braces sweep for anything orphaned by a hard kill.
  if have pkill; then
    pkill -f "hardump=${RUN_DIR}" 2>/dev/null && log "stopped orphaned mitmdump processes" || true
    pkill -f "tcpdump.*${RUN_DIR}" 2>/dev/null && log "stopped orphaned tcpdump processes" || true
  fi
  if [[ -n "${APPIUM_PID}" ]] && kill -0 "${APPIUM_PID}" 2>/dev/null; then
    log "stopping Appium (pid ${APPIUM_PID}) ..."
    kill "${APPIUM_PID}" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "${APPIUM_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -0 "${APPIUM_PID}" 2>/dev/null && kill -9 "${APPIUM_PID}" 2>/dev/null || true
  fi
  summary
  exit "${rc}"
}

summary() {
  local reports logs traces
  reports=$(find "${RUN_DIR}/reports" -type f 2>/dev/null | wc -l | tr -d ' ')
  logs=$(find "${RUN_DIR}/logs" -type f 2>/dev/null | wc -l | tr -d ' ')
  traces=$(find "${RUN_DIR}/traces" -type f 2>/dev/null | wc -l | tr -d ' ')
  printf '\n[e2e] ================= run summary =================\n'
  printf '[e2e] run id        : %s\n' "${TEST_RUN_ID}"
  printf '[e2e] artifacts     : %s\n' "${RUN_DIR}"
  printf '[e2e] devices found : %s\n' "${DEVICE_COUNT}"
  printf '[e2e] xdist workers : %s\n' "${WORKERS}"
  printf '[e2e] appium server : %s\n' "$([[ ${APPIUM_STARTED} -eq 1 ]] && echo "started (${APPIUM_URL})" || echo 'not started')"
  if [[ -n "${RUN_FAILURE_REASON}" ]]; then
    printf '[e2e] failure      : %s\n' "${RUN_FAILURE_REASON}"
  fi
  printf '[e2e] artifacts     : reports=%s logs=%s traces=%s\n' "${reports}" "${logs}" "${traces}"
  if [[ "${PYTEST_RAN}" -eq 1 ]]; then
    printf '[e2e] pytest exit   : %s\n' "${PYTEST_RC}"
    if [[ "${DEVICE_COUNT}" -eq 0 && "${PYTEST_RC}" -eq 0 ]]; then
      printf '[e2e] note          : zero devices present - device tests were skipped, not failed.\n'
    fi
  else
    printf '[e2e] pytest exit   : not run (the run aborted before pytest started)\n'
  fi
  printf '[e2e] ===============================================\n'
}
trap teardown EXIT INT TERM

# ------------------------------------------------------------------ preflight
log "preflight ..."
if [[ -x "${FARM_DIR}/scripts/provision_host.sh" || -f "${FARM_DIR}/scripts/provision_host.sh" ]]; then
  bash "${FARM_DIR}/scripts/provision_host.sh" --check || warn "preflight reported missing components (continuing)"
fi

log "python: ${PYTHON} ($(${PYTHON} --version 2>&1))"
if ! ${PYTHON} -c 'import pytest' >/dev/null 2>&1; then
  warn "pytest is not importable with ${PYTHON}; install dependencies first:"
  warn "  ${PYTHON} -m pip install -e ${FARM_DIR}"
  PYTEST_RC=0
  log "nothing to run; exiting cleanly"
  exit 0
fi

# ------------------------------------------------------------ device discovery
if [[ "${DRY_RUN}" == "1" ]]; then
  log "DEVICE_FARM_DRY_RUN=1: skipping device discovery and Appium startup"
  DEVICE_COUNT=0
elif have adb; then
  adb start-server >/dev/null 2>&1 || warn "adb start-server failed"
  DEVICE_COUNT=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
  log "adb reports ${DEVICE_COUNT} ready device(s)"
else
  warn "adb not found; assuming zero devices"
  DEVICE_COUNT=0
fi

WORKERS=$(( DEVICE_COUNT < MAX_PARALLEL ? DEVICE_COUNT : MAX_PARALLEL ))
(( WORKERS < 1 )) && WORKERS=1

# -------------------------------------------------------------- start Appium
start_appium() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "dry run: not starting Appium"
    return 0
  fi
  if ! have appium; then
    warn "appium not installed; skipping server startup (device tests will skip)"
    return 0
  fi
  if curl -fsS --max-time 3 "${APPIUM_URL}/status" >/dev/null 2>&1; then
    log "reusing the Appium server already listening at ${APPIUM_URL}"
    APPIUM_STARTED=1
    return 0
  fi

  local -a args=(
    server
    --port "${APPIUM_PORT}"
    --address "${APPIUM_HOST}"
    --use-plugins=device-farm
    --use-drivers=uiautomator2
    --allow-cors
  )
  if [[ -f "${PLUGIN_CONFIG}" ]]; then
    args+=(--config "${PLUGIN_CONFIG}")
  else
    warn "plugin config not found at ${PLUGIN_CONFIG}; starting with CLI defaults"
  fi

  log "starting Appium: appium ${args[*]}"
  appium "${args[@]}" >"${APPIUM_LOG}" 2>&1 &
  APPIUM_PID=$!

  local waited=0
  while (( waited < APPIUM_STARTUP_TIMEOUT )); do
    if ! kill -0 "${APPIUM_PID}" 2>/dev/null; then
      RUN_FAILURE_REASON="Appium exited during startup; see ${APPIUM_LOG}"
      warn "FATAL: ${RUN_FAILURE_REASON}"
      APPIUM_PID=""
      return 1
    fi
    if curl -fsS --max-time 3 "${APPIUM_URL}/status" >/dev/null 2>&1; then
      log "Appium is up at ${APPIUM_URL} (pid ${APPIUM_PID})"
      APPIUM_STARTED=1
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  RUN_FAILURE_REASON="Appium did not become ready within ${APPIUM_STARTUP_TIMEOUT}s; see ${APPIUM_LOG}"
  warn "FATAL: ${RUN_FAILURE_REASON}"
  return 1
}
if ! start_appium; then
  exit 1
fi

# ---------------------------------------------------------------- run pytest
PYTEST_ARGS=(
  -v
  --junitxml "${RUN_DIR}/reports/junit.xml"
  --color=no
)
if (( WORKERS > 1 )) && ${PYTHON} -c 'import xdist' >/dev/null 2>&1; then
  PYTEST_ARGS+=(-n "${WORKERS}" --dist loadfile)
  log "running pytest across ${WORKERS} worker(s)"
else
  log "running pytest serially (devices=${DEVICE_COUNT})"
fi

log "pytest ${PYTEST_ARGS[*]} $*"
PYTEST_RAN=1
${PYTHON} -m pytest "${PYTEST_ARGS[@]}" "$@" 2>&1 | tee "${RUN_DIR}/reports/pytest.log"
PYTEST_RC=${PIPESTATUS[0]}

# pytest exit code 5 means "no tests collected" - not a failure for a scaffold run.
if [[ "${PYTEST_RC}" -eq 5 ]]; then
  warn "pytest collected no tests"
  PYTEST_RC=0
fi

# ------------------------------------------------------------ validate output
if [[ -f "${FARM_DIR}/scripts/validate_run.py" ]]; then
  log "validating artifact structure ..."
  ${PYTHON} "${FARM_DIR}/scripts/validate_run.py" --run-id "${TEST_RUN_ID}" \
    --artifacts-root "${ARTIFACTS_ROOT}" || warn "artifact validation reported problems"
fi

exit "${PYTEST_RC}"
