"""Hardware-free unit tests for the HAR repair pass."""

from __future__ import annotations

import json
from pathlib import Path

from proxy.har_repair import main, repair

FULL_TIMINGS = {
    "connect": 1,
    "ssl": -1,
    "send": 1,
    "receive": 1,
    "wait": 1,
    "blocked": 0,
    "dns": 0,
}

# What mitmproxy writes for a flow that never got a response: no content size,
# no timings the reader can use, and a null postData body.
RESPONSELESS_ENTRY = {
    "startedDateTime": "2026-08-30T17:26:28+00:00",
    "request": {
        "method": "POST",
        "url": "https://api.example/v1",
        "headersSize": 120,
        "bodySize": 4,
        "postData": {"text": None},
    },
    "response": {
        "status": 0,
        "content": {},
        "headersSize": -1,
        "bodySize": -1,
    },
    "timings": {"connect": -1, "send": 0},
}


def _har(*entries: dict) -> dict:
    return {"log": {"entries": [json.loads(json.dumps(e)) for e in entries]}}


def test_repair_fills_the_fields_strict_readers_cast_to_number() -> None:
    har = _har(RESPONSELESS_ENTRY)

    assert repair(har) > 0

    entry = har["log"]["entries"][0]
    assert entry["time"] == -1
    assert entry["response"]["content"]["size"] == 0
    assert entry["response"]["content"]["compression"] == 0
    assert entry["request"]["postData"]["text"] == ""
    assert all(isinstance(v, (int, float)) for v in entry["timings"].values())
    assert har["log"]["version"] == "1.2"


def test_repair_leaves_valid_entries_untouched() -> None:
    valid = {
        "time": 27.6,
        "request": {"method": "GET", "url": "http://example/", "headersSize": 1, "bodySize": 0},
        "response": {
            "status": 200,
            "headersSize": 2,
            "bodySize": 3,
            "content": {"size": 3, "compression": 0, "mimeType": "text/html", "text": "abc"},
        },
        "timings": dict(FULL_TIMINGS),
    }
    har = _har(valid)

    assert repair(har) == 0
    assert har["log"]["entries"][0] == valid


def test_slim_drops_response_bodies() -> None:
    har = _har(
        {
            "time": 1,
            "request": {"headersSize": 1, "bodySize": 0},
            "response": {
                "headersSize": 1,
                "bodySize": 3,
                "content": {"size": 3, "compression": 0, "text": "abc", "encoding": "base64"},
            },
            "timings": dict(FULL_TIMINGS),
        }
    )

    repair(har, slim=True)

    content = har["log"]["entries"][0]["response"]["content"]
    assert "text" not in content and "encoding" not in content
    assert content["size"] == 3  # sizes stay, so the summary is still accurate


def test_main_rewrites_the_file_and_reports_bad_input(tmp_path: Path) -> None:
    path = tmp_path / "run.har"
    path.write_text(json.dumps(_har(RESPONSELESS_ENTRY)))

    assert main([str(path)]) == 0
    assert json.loads(path.read_text())["log"]["entries"][0]["response"]["content"]["size"] == 0

    not_a_har = tmp_path / "other.json"
    not_a_har.write_text("{}")
    assert main([str(not_a_har)]) == 1
    assert main([str(tmp_path / "missing.har")]) == 1
