"""Artifact path layout for a test run.

artifacts/<test_run_id>/
    reports/   junit xml, pytest summaries
    logs/      appium.log, per-test logcat / syslog
    traces/    <test-id>-<timestamp>.har / .pcap
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

SUBDIRS = ("reports", "logs", "traces")

_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


def timestamp_slug(moment: datetime | None = None) -> str:
    """UTC timestamp usable inside a filename, e.g. ``20250817T132500Z``."""
    moment = moment or datetime.now(UTC)
    return moment.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")


def slugify(value: str, max_length: int = 120) -> str:
    """Make a pytest node id (or any label) safe for use in a filename."""
    slug = _UNSAFE.sub("-", value).strip("-.")
    slug = re.sub(r"-{2,}", "-", slug)
    if len(slug) > max_length:
        slug = slug[:max_length].rstrip("-.")
    return slug or "unnamed"


@dataclass(frozen=True)
class ArtifactPaths:
    """Resolves and creates the artifact tree for a single run."""

    run_dir: Path

    @classmethod
    def for_run(cls, artifacts_root: Path, test_run_id: str) -> ArtifactPaths:
        return cls(run_dir=Path(artifacts_root) / test_run_id)

    def ensure(self) -> ArtifactPaths:
        """Create ``run_dir`` and all standard subdirectories (idempotent)."""
        for name in SUBDIRS:
            (self.run_dir / name).mkdir(parents=True, exist_ok=True)
        return self

    @property
    def reports(self) -> Path:
        return self.run_dir / "reports"

    @property
    def logs(self) -> Path:
        return self.run_dir / "logs"

    @property
    def traces(self) -> Path:
        return self.run_dir / "traces"

    def trace_file(self, test_id: str, suffix: str, moment: datetime | None = None) -> Path:
        """Path for a trace tagged with test id + timestamp, e.g. ``.har``/``.pcap``."""
        suffix = suffix if suffix.startswith(".") else f".{suffix}"
        return self.traces / f"{slugify(test_id)}-{timestamp_slug(moment)}{suffix}"

    def log_file(self, name: str, suffix: str = ".log", moment: datetime | None = None) -> Path:
        suffix = suffix if suffix.startswith(".") else f".{suffix}"
        return self.logs / f"{slugify(name)}-{timestamp_slug(moment)}{suffix}"

    def report_file(self, name: str) -> Path:
        return self.reports / slugify(name)

    def summary(self) -> dict[str, int]:
        """Count files per subdirectory; used by the run summary and validator."""
        counts: dict[str, int] = {}
        for name in SUBDIRS:
            directory = self.run_dir / name
            counts[name] = (
                sum(1 for path in directory.iterdir() if path.is_file())
                if directory.is_dir()
                else 0
            )
        return counts
