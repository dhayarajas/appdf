#!/usr/bin/env python3
"""Validate the artifact structure produced by a device farm run.

Checks that ``artifacts/<test_run_id>/`` exists with ``reports/``, ``logs/`` and
``traces/`` subdirectories, that a test report is present, and reports (without
failing) on device logs and HAR/PCAP traces — those are legitimately absent on a
host with no devices or no capture privileges.

Exit codes:
    0  structure is valid (warnings may have been printed)
    1  structure is invalid (missing run dir, subdirectory, or test report)
    2  bad usage (e.g. no runs found)

Usage:
    python scripts/validate_run.py --latest
    python scripts/validate_run.py --run-id 20250817T132500Z-ab12cd
    python scripts/validate_run.py --latest --require-traces
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

FARM_DIR = Path(__file__).resolve().parent.parent
DEFAULT_ARTIFACTS_ROOT = FARM_DIR / "artifacts"
REQUIRED_SUBDIRS = ("reports", "logs", "traces")
REPORT_PATTERNS = ("junit.xml", "*.xml", "pytest.log", "*.json")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--run-id", help="test run id (directory name under the artifacts root)")
    target.add_argument(
        "--latest", action="store_true", help="validate the most recently modified run"
    )
    parser.add_argument(
        "--artifacts-root",
        type=Path,
        default=DEFAULT_ARTIFACTS_ROOT,
        help=f"artifacts root (default: {DEFAULT_ARTIFACTS_ROOT})",
    )
    parser.add_argument(
        "--require-traces",
        action="store_true",
        help="fail when no HAR/PCAP traces were captured (only meaningful with hardware)",
    )
    parser.add_argument(
        "--require-device-logs",
        action="store_true",
        help="fail when no device logs were collected (only meaningful with hardware)",
    )
    return parser.parse_args(argv)


def resolve_run_dir(root: Path, run_id: str | None, latest: bool) -> Path | None:
    if run_id:
        return root / run_id
    if not root.is_dir():
        return None
    candidates = [path for path in root.iterdir() if path.is_dir()]
    if not candidates:
        return None
    if not latest:
        print("no --run-id given; falling back to the most recent run")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def validate(run_dir: Path, *, require_traces: bool, require_device_logs: bool) -> int:
    errors: list[str] = []
    warnings: list[str] = []

    print(f"validating {run_dir}")
    if not run_dir.is_dir():
        print(f"  MISSING run directory: {run_dir}")
        print("FAIL")
        return 1

    for name in REQUIRED_SUBDIRS:
        directory = run_dir / name
        if directory.is_dir():
            count = sum(1 for path in directory.iterdir() if path.is_file())
            print(f"  OK   {name}/ ({count} file(s))")
        else:
            errors.append(f"missing subdirectory: {name}/")

    reports = run_dir / "reports"
    report_files = (
        sorted(
            {
                path
                for pattern in REPORT_PATTERNS
                for path in reports.glob(pattern)
                if path.is_file()
            }
        )
        if reports.is_dir()
        else []
    )
    if report_files:
        print(f"  OK   test report(s): {', '.join(path.name for path in report_files)}")
    else:
        errors.append("no test report found under reports/ (expected junit.xml or pytest.log)")

    logs = run_dir / "logs"
    device_logs = (
        sorted(logs.glob("*logcat*")) + sorted(logs.glob("*syslog*")) if logs.is_dir() else []
    )
    if device_logs:
        print(f"  OK   device log(s): {len(device_logs)}")
    elif require_device_logs:
        errors.append("no device logs (logcat/syslog) collected under logs/")
    else:
        warnings.append("no device logs collected - expected when no device is attached")

    traces = run_dir / "traces"
    hars = sorted(traces.glob("*.har")) if traces.is_dir() else []
    pcaps = sorted(traces.glob("*.pcap")) if traces.is_dir() else []
    if hars or pcaps:
        print(f"  OK   traces: {len(hars)} HAR, {len(pcaps)} PCAP")
    elif require_traces:
        errors.append("no HAR/PCAP traces found under traces/")
    else:
        warnings.append(
            "no HAR/PCAP traces - expected without a device, mitmdump, or capture privileges"
        )

    for message in warnings:
        print(f"  WARN {message}")
    for message in errors:
        print(f"  FAIL {message}")

    print(f"summary: {len(errors)} error(s), {len(warnings)} warning(s)")
    print("FAIL" if errors else "PASS")
    return 1 if errors else 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.artifacts_root.expanduser()
    run_dir = resolve_run_dir(root, args.run_id, args.latest)
    if run_dir is None:
        print(f"no runs found under {root}; run ./run_e2e_farm.sh first", file=sys.stderr)
        return 2
    return validate(
        run_dir, require_traces=args.require_traces, require_device_logs=args.require_device_logs
    )


if __name__ == "__main__":
    raise SystemExit(main())
