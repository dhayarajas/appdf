#!/usr/bin/env bash
# Turn a captured run into a HAR without having to know its run id.
#
# `farm_up.sh`/`debug_traffic.sh` write raw mitmproxy flows per run; this picks
# the newest run that actually captured something and converts it, so the usual
# case is a bare `scripts/export_har.sh`.
#
# Usage:
#   scripts/export_har.sh                        # newest run with flows -> HAR beside it
#   scripts/export_har.sh --out ~/Desktop/x.har  # write somewhere else
#   scripts/export_har.sh --run farm-20260830T101853Z
#   scripts/export_har.sh --host verizon.com     # only flows for matching hosts
#   scripts/export_har.sh --list                 # what is available to export
#   scripts/export_har.sh --all                  # convert every run that has flows
#   scripts/export_har.sh --check ~/Desktop/x.har   # why DevTools refuses a HAR
#
# Options:
#   --run <id>       run id (or a path to a run dir / .flows file)
#   --out <path>     HAR destination (default: next to the flows)
#   --host <substr>  keep only flows whose host matches
#   --filter <expr>  raw mitmproxy filter expression (overrides --host)
#   --slim           drop response bodies (a big HAR will not open in DevTools)
#   --check <har>    report what a strict reader (DevTools) rejects, fix nothing
#   --all            export every run that has flows
#   --list           list runs with flow sizes and exit
#   --open           reveal the HAR in Finder/xdg-open when done
set -uo pipefail

FARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_ROOT="${DEVICE_FARM_ARTIFACTS_ROOT:-${FARM_DIR}/artifacts}"

RUN=""
OUT=""
FILTER=""
CHECK=""
MODE=one
OPEN_AFTER=0
SLIM=0

log() { printf '[har] %s\n' "$*"; }
warn() { printf '[har] WARN  %s\n' "$*" >&2; }
die() { printf '[har] ERROR %s\n' "$*" >&2; exit 1; }

# `shift 2` is a no-op when only the flag itself is left, which would spin the
# parsing loop forever, so a missing value is rejected up front.
need_value() { (( $2 >= 2 )) || die "$1 requires a value (try --help)"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) need_value "$1" $#; RUN="$2"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    --host) need_value "$1" $#; FILTER="~d $2"; shift 2 ;;
    --filter) need_value "$1" $#; FILTER="$2"; shift 2 ;;
    --slim) SLIM=1; shift ;;
    --check) need_value "$1" $#; CHECK="$2"; MODE=check; shift 2 ;;
    --all) MODE=all; shift ;;
    --list) MODE=list; shift ;;
    --open) OPEN_AFTER=1; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

MITMDUMP=""
if [[ -x "${FARM_DIR}/.venv/bin/mitmdump" ]]; then
  MITMDUMP="${FARM_DIR}/.venv/bin/mitmdump"
elif command -v mitmdump >/dev/null 2>&1; then
  MITMDUMP="$(command -v mitmdump)"
fi
# --check reads an existing HAR, so it needs neither mitmdump nor a run.
if [[ "${MODE}" != check ]]; then
  [[ -n "${MITMDUMP}" ]] || die "mitmdump not found; run 'make install' or 'pip install mitmproxy'"
fi

if [[ -x "${FARM_DIR}/.venv/bin/python" ]]; then
  PYTHON="${FARM_DIR}/.venv/bin/python"
else
  PYTHON="$(command -v python3 || true)"
fi
HAR_REPAIR="${FARM_DIR}/proxy/har_repair.py"

if [[ "${MODE}" != check ]]; then
  [[ -d "${ARTIFACTS_ROOT}" ]] || die "no artifacts directory at ${ARTIFACTS_ROOT}"
fi

# Non-empty flow files, newest first. Empty ones are runs where nothing ever
# crossed the proxy - listing them as exportable would only mislead.
flow_files() {
  find "${ARTIFACTS_ROOT}" -name '*.flows' -size +0 2>/dev/null \
    | while read -r f; do printf '%s\t%s\n' "$(stat_mtime "$f")" "$f"; done \
    | sort -rn | cut -f2-
}

stat_mtime() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

human_size() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %z "$1"
  else
    stat -c %s "$1"
  fi
}

# Accepts a run id, a run directory or a .flows path and resolves the flows.
resolve_flows() {
  local want="$1" candidate
  for candidate in "${want}" "${ARTIFACTS_ROOT}/${want}"; do
    [[ -f "${candidate}" ]] && { printf '%s' "${candidate}"; return 0; }
    if [[ -d "${candidate}" ]]; then
      candidate="$(find "${candidate}" -name '*.flows' -size +0 2>/dev/null | head -1)"
      [[ -n "${candidate}" ]] && { printf '%s' "${candidate}"; return 0; }
      return 1
    fi
  done
  return 1
}

# mitmproxy leaves fields unset for flows without a response, which makes strict
# readers (Chrome DevTools) reject the whole file, so every HAR is repaired here.
repair() {
  local args=("$1")
  [[ -n "${PYTHON}" && -f "${HAR_REPAIR}" ]] || return 0
  (( SLIM )) && args+=(--slim)
  "${PYTHON}" "${HAR_REPAIR}" "${args[@]}" || true
}

# The export is worth nothing if DevTools still refuses it, so say so here
# rather than leaving the user to discover it in the browser.
verify() {
  [[ -n "${PYTHON}" && -f "${HAR_REPAIR}" ]] || return 0
  "${PYTHON}" "${HAR_REPAIR}" "$1" --check >/dev/null 2>&1 \
    || warn "this HAR still has fields strict readers reject: run --check \"$1\""
}

summarize() {
  local har="$1"
  "${PYTHON:-python3}" - "$har" <<'PY' 2>/dev/null || true
import collections, json, sys
try:
    entries = json.load(open(sys.argv[1]))["log"]["entries"]
except Exception:
    sys.exit(0)
hosts = collections.Counter()
for e in entries:
    url = e["request"]["url"]
    hosts[url.split("/")[2] if "//" in url else url] += 1
print(f"[har] entries     : {len(entries)}")
for host, n in hosts.most_common(8):
    print(f"[har]   {n:>5}  {host}")
if len(hosts) > 8:
    print(f"[har]   ... {len(hosts) - 8} more host(s)")
PY
}

export_one() {
  local flows="$1" out="$2"
  [[ -n "${out}" ]] || out="${flows%.flows}.har"
  mkdir -p "$(dirname "${out}")" 2>/dev/null
  log "flows       : ${flows} ($(human_size "${flows}") bytes)"
  [[ -n "${FILTER}" ]] && log "filter      : ${FILTER}"
  if [[ -n "${FILTER}" ]]; then
    "${MITMDUMP}" -q -nr "${flows}" --set "hardump=${out}" "${FILTER}" >/dev/null 2>&1
  else
    "${MITMDUMP}" -q -nr "${flows}" --set "hardump=${out}" >/dev/null 2>&1
  fi
  [[ -s "${out}" ]] || {
    warn "no HAR written from ${flows} (nothing matched the filter?)"
    return 1
  }
  repair "${out}"
  log "har         : ${out} ($(human_size "${out}") bytes)"
  verify "${out}"
  summarize "${out}"
  if (( OPEN_AFTER )); then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      open -R "${out}" >/dev/null 2>&1 || true
    else
      xdg-open "$(dirname "${out}")" >/dev/null 2>&1 || true
    fi
  fi
}

case "${MODE}" in
  check)
    [[ -f "${CHECK}" ]] || die "no such HAR: ${CHECK}"
    [[ -n "${PYTHON}" ]] || die "python3 not found"
    "${PYTHON}" "${HAR_REPAIR}" "${CHECK}" --check
    ;;
  list)
    found=0
    while read -r flows; do
      [[ -n "${flows}" ]] || continue
      found=1
      printf '[har] %-46s %10s bytes  %s\n' \
        "$(basename "$(dirname "$(dirname "${flows}")")")" \
        "$(human_size "${flows}")" "${flows}"
    done < <(flow_files)
    (( found )) || log "no run has captured flows yet under ${ARTIFACTS_ROOT}"
    ;;
  all)
    exported=0
    while read -r flows; do
      [[ -n "${flows}" ]] || continue
      export_one "${flows}" "" && exported=$((exported + 1))
    done < <(flow_files)
    (( exported )) || die "nothing to export under ${ARTIFACTS_ROOT} (no run captured traffic)"
    log "exported ${exported} run(s)"
    ;;
  one)
    if [[ -n "${RUN}" ]]; then
      FLOWS="$(resolve_flows "${RUN}")" \
        || die "no non-empty .flows for '${RUN}'; try --list"
    else
      FLOWS="$(flow_files | head -1)"
      [[ -n "${FLOWS}" ]] || die "no run has captured traffic yet - check the device proxy, then --list"
      log "run         : $(basename "$(dirname "$(dirname "${FLOWS}")")") (newest with traffic)"
    fi
    export_one "${FLOWS}" "${OUT}"
    ;;
esac
