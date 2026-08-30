"""Make a mitmproxy-written HAR loadable by strict HAR consumers.

mitmproxy emits ``"content": {}`` for flows that never got a response (client
aborts, connection errors, CONNECT tunnels) and leaves ``postData.text`` as
``null``. Chrome DevTools' importer casts the missing numbers and fails the
whole file with "Casting to number results in NaN", so a capture with a single
aborted request imports as nothing at all.

This fills the required numeric fields with HAR's "unknown" sentinels without
touching anything that is already valid.

    python3 proxy/har_repair.py run.har            # repair in place
    python3 proxy/har_repair.py run.har --slim     # ... and drop response bodies
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

# HAR 1.2 numeric fields, with the value to use when one is missing or not a
# number. -1 is the spec's "not available"; sizes that are genuinely absent are
# reported as 0 so totals stay meaningful.
_ENTRY_NUMBERS = {"time": -1}
_MESSAGE_NUMBERS = {"headersSize": -1, "bodySize": -1}
_CONTENT_NUMBERS = {"size": 0, "compression": 0}
_TIMINGS = {"blocked": -1, "dns": -1, "connect": -1, "send": 0, "wait": 0, "receive": 0, "ssl": -1}


def _coerce(obj: dict[str, Any], defaults: dict[str, int]) -> int:
    fixed = 0
    for key, fallback in defaults.items():
        value = obj.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            obj[key] = fallback
            fixed += 1
    return fixed


def repair(har: dict[str, Any], slim: bool = False) -> int:
    """Repair ``har`` in place and return the number of fields touched."""
    fixed = 0
    log = har.get("log")
    if not isinstance(log, dict):
        raise ValueError("not a HAR file: no 'log' object")
    log.setdefault("version", "1.2")
    log.setdefault("pages", [])

    for entry in log.get("entries", []):
        fixed += _coerce(entry, _ENTRY_NUMBERS)

        timings = entry.get("timings")
        if not isinstance(timings, dict):
            timings = entry["timings"] = {}
        fixed += _coerce(timings, _TIMINGS)

        for side in ("request", "response"):
            message = entry.get(side)
            if not isinstance(message, dict):
                continue
            fixed += _coerce(message, _MESSAGE_NUMBERS)

            content = message.get("content")
            if side == "response":
                if not isinstance(content, dict):
                    content = message["content"] = {}
                content.setdefault("mimeType", "")
                fixed += _coerce(content, _CONTENT_NUMBERS)
                if slim:
                    content.pop("text", None)
                    content.pop("encoding", None)

            post = message.get("postData")
            if isinstance(post, dict):
                if post.get("text") is None:
                    post["text"] = ""
                    fixed += 1
                post.setdefault("mimeType", "")

    return fixed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("har", help="HAR file to repair in place")
    parser.add_argument(
        "--slim",
        action="store_true",
        help="drop response bodies, which is what makes large HARs unusable in DevTools",
    )
    parser.add_argument("--quiet", action="store_true", help="only report failures")
    args = parser.parse_args(argv)

    try:
        with open(args.har, encoding="utf-8") as handle:
            har = json.load(handle)
        fixed = repair(har, slim=args.slim)
        with open(args.har, "w", encoding="utf-8") as handle:
            json.dump(har, handle)
    except (OSError, ValueError) as exc:
        print(f"[har] WARN  could not repair {args.har}: {exc}", file=sys.stderr)
        return 1

    if fixed and not args.quiet:
        print(f"[har] repaired    : {fixed} field(s) strict HAR readers reject")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
