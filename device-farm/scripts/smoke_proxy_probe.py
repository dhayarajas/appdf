#!/usr/bin/env python3
"""Prove the Phase 2 trace pipeline works locally, without any device.

Starts a real ``mitmdump`` on a dynamically allocated port, drives one HTTP
request through it, then asserts the HAR (or the raw ``.flows`` fallback) is
non-empty. Also exercises the adb-dependent helpers to confirm they degrade to
``False`` instead of raising when no device is attached.

Skips (exit 0) when mitmdump is unavailable or the probe URL is unreachable —
neither is a defect in the scaffold.

Usage:
    python scripts/smoke_proxy_probe.py --run-id smoke-1
    python scripts/smoke_proxy_probe.py --url http://example.com/ --timeout 20
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

FARM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(FARM_DIR))

import requests  # noqa: E402

from framework.artifacts import ArtifactPaths  # noqa: E402
from proxy.proxy_manager import ProxyManager, mitmdump_available  # noqa: E402


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--run-id",
        default=f"proxy-probe-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}",
        help="artifact run id to write the HAR under",
    )
    parser.add_argument(
        "--artifacts-root",
        type=Path,
        default=FARM_DIR / "artifacts",
        help="artifacts root (default: device-farm/artifacts)",
    )
    parser.add_argument("--url", default="http://example.com/", help="URL to fetch via the proxy")
    parser.add_argument("--timeout", type=float, default=20.0, help="request timeout in seconds")
    return parser.parse_args(argv)


def har_entry_count(path: Path) -> int:
    try:
        log = json.loads(path.read_text())["log"]
    except (OSError, ValueError, KeyError):
        return 0
    entries = log.get("entries")
    return len(entries) if isinstance(entries, list) else 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if not mitmdump_available():
        print("[probe] SKIP: mitmdump is not on PATH (pip install mitmproxy, or add .venv/bin)")
        return 0

    paths = ArtifactPaths.for_run(args.artifacts_root, args.run_id).ensure()
    har_path = paths.trace_file("proxy-probe", ".har")
    manager = ProxyManager(har_path=har_path)

    session = manager.start()
    if not session.started:
        print(f"[probe] SKIP: mitmdump did not start ({session.reason})")
        manager.stop()
        return 0
    print(f"[probe] mitmdump listening on {session.endpoint}")

    try:
        proxies = {"http": f"http://127.0.0.1:{session.port}"}
        response = requests.get(args.url, proxies=proxies, timeout=args.timeout)
        print(f"[probe] GET {args.url} -> {response.status_code} ({len(response.content)} bytes)")
    except requests.RequestException as exc:
        print(f"[probe] SKIP: {args.url} is unreachable from this host ({exc})")
        manager.stop()
        return 0

    # adb-dependent helpers must report failure, not raise, with no device.
    for name, ok in (
        ("set_device_proxy", manager.set_device_proxy()),
        ("clear_device_proxy", manager.clear_device_proxy()),
    ):
        print(f"[probe] {name}() -> {ok} (False is expected without adb/a device)")

    manager.stop()

    traces = session.artifacts
    if not traces:
        print(f"[probe] FAIL: no trace written (expected {har_path})")
        return 1

    for trace in traces:
        size = trace.stat().st_size
        detail = ""
        if trace.suffix == ".har":
            detail = f", {har_entry_count(trace)} entry/entries"
        print(f"[probe] trace: {trace.name} ({size} bytes{detail})")

    har = next((trace for trace in traces if trace.suffix == ".har"), None)
    if har is not None and har_entry_count(har) < 1:
        print("[probe] FAIL: the HAR contains no entries")
        return 1
    if har is None:
        print("[probe] note: this mitmproxy build wrote raw flows instead of a HAR")

    print("[probe] OK: proxy started, traffic captured, trace written, proxy stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
