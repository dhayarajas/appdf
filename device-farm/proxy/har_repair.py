"""Make a mitmproxy-written HAR loadable by strict HAR consumers.

Chrome DevTools parses a HAR field by field and rejects the *whole* file on the
first problem, most often with "Casting to number results in NaN": every number
it needs must be present and finite, and every optional number it merely looks
at must be a number if the key exists at all. mitmproxy emits ``"content": {}``
for flows that never got a response (client aborts, connection errors, CONNECT
tunnels) and ``postData.text: null`` for bodies it could not decode, so one
aborted request is enough to make a whole capture import as nothing.

This fills the required fields with HAR's "unknown" sentinels, drops optional
keys whose values are unusable, and leaves valid entries alone.

    python3 proxy/har_repair.py run.har            # repair in place
    python3 proxy/har_repair.py run.har --check    # report problems, change nothing
    python3 proxy/har_repair.py run.har --slim     # repair and drop response bodies

The field rules mirror devtools-frontend's ``models/har/HARFormat.ts``.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime
from typing import Any

# Required numbers, with the value to use when one is missing or unusable. -1 is
# the spec's "not available"; genuinely absent sizes are 0 so totals stay sane.
_ENTRY_NUMBERS = {"time": -1}
_MESSAGE_NUMBERS = {"headersSize": -1, "bodySize": -1}
_RESPONSE_NUMBERS = {"status": 0}
_CONTENT_NUMBERS = {"size": 0}
_TIMING_NUMBERS = {"send": 0, "wait": 0, "receive": 0}

# Optional numbers: DevTools still casts them when the key is present, so an
# unusable value has to be removed rather than defaulted.
_MESSAGE_OPTIONAL = ("_transferSize", "_serviceWorkerRouterRuleIdMatched")
_CONTENT_OPTIONAL = ("compression",)
_TIMING_OPTIONAL = (
    "blocked",
    "dns",
    "connect",
    "ssl",
    "_blocked_queueing",
    "_blocked_proxy",
    "_workerStart",
    "_workerReady",
    "_workerFetchStart",
    "_workerRespondWithSettled",
    "_workerRouterEvaluationStart",
    "_workerCacheLookupStart",
)
_MESSAGE_OPTIONAL_NUMBERS = ("time", "opcode")

_EPOCH = "1970-01-01T00:00:00+00:00"


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _is_date(value: Any) -> bool:
    """Approximate ``new Date(value)`` for the shapes a HAR can hold."""
    if _is_number(value):
        return True
    if not isinstance(value, str) or not value.strip():
        return False
    # Every writer we care about emits ISO-8601; anything else is a guess in JS
    # too, so accept only what Python can parse.
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


class _Fixer:
    """Walks a HAR, reporting problems and optionally fixing them in place."""

    def __init__(self, fix: bool) -> None:
        self.fix = fix
        self.problems: list[str] = []

    def _report(self, where: str, what: str) -> None:
        self.problems.append(f"{where}: {what}")

    def required_numbers(self, obj: dict[str, Any], defaults: dict[str, int], where: str) -> None:
        for key, fallback in defaults.items():
            if not _is_number(obj.get(key)):
                self._report(f"{where}.{key}", f"{obj.get(key)!r} is not a number")
                if self.fix:
                    obj[key] = fallback

    def optional_numbers(self, obj: dict[str, Any], keys: tuple[str, ...], where: str) -> None:
        for key in keys:
            if key in obj and not _is_number(obj[key]):
                self._report(f"{where}.{key}", f"{obj[key]!r} is not a number")
                if self.fix:
                    del obj[key]

    def name_value_lists(self, obj: dict[str, Any], keys: tuple[str, ...], where: str) -> None:
        for key in keys:
            items = obj.get(key)
            if items is None:
                continue
            if not isinstance(items, list):
                self._report(f"{where}.{key}", "not a list")
                if self.fix:
                    obj[key] = []
                continue
            kept = [item for item in items if isinstance(item, dict)]
            if len(kept) != len(items):
                self._report(f"{where}.{key}", "contains non-object items")
                if self.fix:
                    obj[key] = kept
            for index, cookie in enumerate(kept):
                if key != "cookies":
                    continue
                expires = cookie.get("expires")
                if expires and not _is_date(expires):
                    self._report(f"{where}.cookies[{index}].expires", f"{expires!r} is not a date")
                    if self.fix:
                        del cookie["expires"]

    def message(self, entry: dict[str, Any], side: str, where: str, slim: bool) -> bool:
        message = entry.get(side)
        if not isinstance(message, dict):
            self._report(f"{where}.{side}", "missing or not an object")
            if not self.fix:
                return False
            if side == "request":
                return False
            message = entry[side] = {
                "status": 0,
                "statusText": "",
                "httpVersion": "",
                "headers": [],
                "cookies": [],
                "content": {},
                "redirectURL": "",
                "headersSize": -1,
                "bodySize": -1,
            }

        self.required_numbers(message, _MESSAGE_NUMBERS, f"{where}.{side}")
        self.optional_numbers(message, _MESSAGE_OPTIONAL, f"{where}.{side}")
        self.name_value_lists(message, ("headers", "cookies", "queryString"), f"{where}.{side}")

        if side == "response":
            self.required_numbers(message, _RESPONSE_NUMBERS, f"{where}.response")
            content = message.get("content")
            if not isinstance(content, dict):
                self._report(f"{where}.response.content", "missing or not an object")
                if not self.fix:
                    return True
                content = message["content"] = {}
            self.required_numbers(content, _CONTENT_NUMBERS, f"{where}.response.content")
            self.optional_numbers(content, _CONTENT_OPTIONAL, f"{where}.response.content")
            if not isinstance(content.get("mimeType"), str):
                self._report(f"{where}.response.content.mimeType", "missing")
                if self.fix:
                    content["mimeType"] = ""
            if slim and self.fix:
                content.pop("text", None)
                content.pop("encoding", None)

        post = message.get("postData")
        if isinstance(post, dict):
            if not isinstance(post.get("text"), str):
                self._report(f"{where}.{side}.postData.text", f"{post.get('text')!r} is not text")
                if self.fix:
                    post["text"] = ""
            if not isinstance(post.get("mimeType"), str):
                if self.fix:
                    post["mimeType"] = ""
            self.name_value_lists(post, ("params",), f"{where}.{side}.postData")
        return True

    def entry(self, entry: Any, where: str, slim: bool) -> bool:
        if not isinstance(entry, dict):
            self._report(where, "not an object")
            return False

        started = entry.get("startedDateTime")
        if not _is_date(started):
            self._report(f"{where}.startedDateTime", f"{started!r} is not a date")
            if self.fix:
                entry["startedDateTime"] = _EPOCH

        self.required_numbers(entry, _ENTRY_NUMBERS, where)

        timings = entry.get("timings")
        if not isinstance(timings, dict):
            self._report(f"{where}.timings", "missing or not an object")
            if not self.fix:
                return True
            timings = entry["timings"] = {}
        self.required_numbers(timings, _TIMING_NUMBERS, f"{where}.timings")
        self.optional_numbers(timings, _TIMING_OPTIONAL, f"{where}.timings")

        for messages_key in ("_webSocketMessages", "_eventSourceMessages"):
            messages = entry.get(messages_key)
            if messages is None:
                continue
            if not isinstance(messages, list) or any(not isinstance(m, dict) for m in messages):
                self._report(f"{where}.{messages_key}", "not a list of objects")
                if self.fix:
                    del entry[messages_key]
                continue
            for index, msg in enumerate(messages):
                self.optional_numbers(
                    msg, _MESSAGE_OPTIONAL_NUMBERS, f"{where}.{messages_key}[{index}]"
                )

        initiator = entry.get("_initiator")
        if isinstance(initiator, dict):
            self.optional_numbers(initiator, ("lineNumber",), f"{where}._initiator")

        if not self.message(entry, "request", where, slim):
            return False
        self.message(entry, "response", where, slim)
        return True

    def log(self, har: Any, slim: bool) -> None:
        if not isinstance(har, dict) or not isinstance(har.get("log"), dict):
            raise ValueError("not a HAR file: no 'log' object")
        log = har["log"]
        if self.fix:
            log.setdefault("version", "1.2")
            if not isinstance(log.get("pages"), list):
                log["pages"] = []
        for index, page in enumerate(list(log.get("pages") or [])):
            if not isinstance(page, dict) or not _is_date(page.get("startedDateTime")):
                self._report(f"log.pages[{index}]", "unusable page")
                if self.fix:
                    log["pages"] = [p for p in log["pages"] if p is not page]
                continue
            timings = page.get("pageTimings")
            if isinstance(timings, dict):
                self.optional_numbers(
                    timings, ("onContentLoad", "onLoad"), f"log.pages[{index}].pageTimings"
                )

        entries = log.get("entries")
        if not isinstance(entries, list):
            self._report("log.entries", "missing or not a list")
            if self.fix:
                log["entries"] = []
            return

        kept = []
        for index, entry in enumerate(entries):
            if self.entry(entry, f"log.entries[{index}]", slim):
                kept.append(entry)
        if len(kept) != len(entries) and self.fix:
            log["entries"] = kept


def check(har: dict[str, Any]) -> list[str]:
    """Return everything a strict reader such as Chrome DevTools would reject."""
    fixer = _Fixer(fix=False)
    fixer.log(har, slim=False)
    return fixer.problems


def repair(har: dict[str, Any], slim: bool = False) -> int:
    """Repair ``har`` in place and return the number of problems fixed."""
    fixer = _Fixer(fix=True)
    fixer.log(har, slim=slim)
    return len(fixer.problems)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("har", help="HAR file to repair in place")
    parser.add_argument(
        "--check",
        action="store_true",
        help="report what a strict reader would reject and exit, changing nothing",
    )
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
        if args.check:
            problems = check(har)
        else:
            problems = []
            fixed = repair(har, slim=args.slim)
            with open(args.har, "w", encoding="utf-8") as handle:
                json.dump(har, handle)
    except (OSError, ValueError) as exc:
        print(f"[har] WARN  could not read {args.har}: {exc}", file=sys.stderr)
        return 1

    if args.check:
        entries = len(har.get("log", {}).get("entries", []))
        if not problems:
            print(f"[har] {args.har}: {entries} entries, no problems a strict reader rejects")
            return 0
        print(f"[har] {args.har}: {len(problems)} problem(s) in {entries} entries")
        for problem in problems[:20]:
            print(f"[har]   {problem}")
        if len(problems) > 20:
            print(f"[har]   ... {len(problems) - 20} more")
        return 1

    if fixed and not args.quiet:
        print(f"[har] repaired    : {fixed} field(s) strict HAR readers reject")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
