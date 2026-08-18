"""Reading and summarising the HAR files produced by the proxy pipeline.

mitmdump writes the HAR when it exits, so callers must stop the proxy before
inspecting it (``ProxyManager.stop()``). Everything here tolerates a missing or
truncated file: no HAR is a *result*, not an exception.
"""

from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class HarEntry:
    """One request/response pair from a HAR log."""

    method: str
    url: str
    status: int
    mime_type: str
    response_bytes: int

    @property
    def host(self) -> str:
        return urlsplit(self.url).netloc

    @property
    def is_tls(self) -> bool:
        return urlsplit(self.url).scheme == "https"

    @property
    def decrypted(self) -> bool:
        """True when the HTTPS exchange was decrypted (a status is present).

        Pinned traffic that fails the TLS handshake never yields a response, so
        it shows up either as a missing entry or with ``status == 0``.
        """
        return self.is_tls and self.status > 0


def load_har_entries(har_path: str | Path) -> list[HarEntry]:
    """Parse a HAR file. Returns ``[]`` for a missing, empty or malformed file."""
    path = Path(har_path)
    try:
        payload = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    entries = payload.get("log", {}).get("entries")
    if not isinstance(entries, list):
        return []

    parsed: list[HarEntry] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        request = entry.get("request") or {}
        response = entry.get("response") or {}
        content = response.get("content") or {}
        parsed.append(
            HarEntry(
                method=str(request.get("method", "")),
                url=str(request.get("url", "")),
                status=int(response.get("status") or 0),
                mime_type=str(content.get("mimeType", "")),
                response_bytes=int(content.get("size") or 0),
            )
        )
    return parsed


def summarize(entries: list[HarEntry], *, top_hosts: int = 5) -> str:
    """One-line human summary used in logs, reports and assertion messages."""
    if not entries:
        return "0 entries"
    hosts = Counter(entry.host for entry in entries)
    decrypted = sum(1 for entry in entries if entry.decrypted)
    listed = ", ".join(f"{host} x{count}" for host, count in hosts.most_common(top_hosts))
    return f"{len(entries)} entries ({decrypted} decrypted https), {len(hosts)} host(s): {listed}"
