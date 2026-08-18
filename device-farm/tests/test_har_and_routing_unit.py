"""Hardware-free unit tests for HAR parsing and proxy-host routing."""

from __future__ import annotations

import json
from pathlib import Path

from framework.devices import EMULATOR_HOST_ALIAS, proxy_host_for_device
from framework.har import HarEntry, load_har_entries, summarize


def _har(*entries: dict) -> dict:
    return {"log": {"version": "1.2", "entries": list(entries)}}


def _entry(url: str, status: int = 200, size: int = 12) -> dict:
    return {
        "request": {"method": "GET", "url": url},
        "response": {"status": status, "content": {"mimeType": "application/json", "size": size}},
    }


def test_load_har_entries_parses_requests(tmp_path: Path) -> None:
    path = tmp_path / "run.har"
    path.write_text(json.dumps(_har(_entry("https://f-droid.org/repo/index-v1.jar", size=999))))

    entries = load_har_entries(path)

    assert entries == [
        HarEntry(
            method="GET",
            url="https://f-droid.org/repo/index-v1.jar",
            status=200,
            mime_type="application/json",
            response_bytes=999,
        )
    ]
    assert entries[0].host == "f-droid.org"
    assert entries[0].is_tls and entries[0].decrypted


def test_tls_without_a_response_is_not_decrypted(tmp_path: Path) -> None:
    """A pinned app's failed handshake must never read as decrypted traffic."""
    path = tmp_path / "pinned.har"
    path.write_text(json.dumps(_har(_entry("https://pinned.example/api", status=0))))

    (entry,) = load_har_entries(path)

    assert entry.is_tls
    assert not entry.decrypted


def test_plain_http_is_never_reported_as_decrypted_tls(tmp_path: Path) -> None:
    path = tmp_path / "http.har"
    path.write_text(json.dumps(_har(_entry("http://example.com/x"))))

    (entry,) = load_har_entries(path)

    assert not entry.is_tls
    assert not entry.decrypted


def test_missing_and_malformed_har_files_yield_no_entries(tmp_path: Path) -> None:
    truncated = tmp_path / "truncated.har"
    truncated.write_text('{"log": {"entries": [')
    wrong_shape = tmp_path / "shape.har"
    wrong_shape.write_text(json.dumps({"log": {"entries": "nope"}}))

    assert load_har_entries(tmp_path / "absent.har") == []
    assert load_har_entries(truncated) == []
    assert load_har_entries(wrong_shape) == []
    assert load_har_entries(tmp_path) == []  # a directory, not a file


def test_summarize_counts_hosts_and_decrypted_entries(tmp_path: Path) -> None:
    path = tmp_path / "mixed.har"
    path.write_text(
        json.dumps(
            _har(
                _entry("https://a.example/1"),
                _entry("https://a.example/2"),
                _entry("https://b.example/3", status=0),
                _entry("http://c.example/4"),
            )
        )
    )

    summary = summarize(load_har_entries(path))

    assert summary.startswith("4 entries (2 decrypted https), 3 host(s)")
    assert "a.example x2" in summary
    assert summarize([]) == "0 entries"


def test_emulator_serials_route_through_the_qemu_host_alias() -> None:
    assert proxy_host_for_device("192.168.1.20", "emulator-5554") == EMULATOR_HOST_ALIAS
    assert proxy_host_for_device("192.168.1.20", "emulator-5556") == EMULATOR_HOST_ALIAS


def test_physical_serials_route_through_the_host_lan_ip() -> None:
    assert proxy_host_for_device("192.168.1.20", "R58M12ABCDE") == "192.168.1.20"
