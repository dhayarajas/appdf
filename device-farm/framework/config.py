"""Environment-driven configuration for the device farm scaffold.

Every knob is an environment variable so the same code runs unchanged on a
provisioned farm host, on a laptop with a single emulator, and in a CI job with
no hardware at all (``DEVICE_FARM_DRY_RUN=1``).
"""

from __future__ import annotations

import os
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

FARM_ROOT = Path(__file__).resolve().parent.parent

_TRUTHY = {"1", "true", "yes", "on", "y"}
_FALSY = {"0", "false", "no", "off", "n", ""}


def env_flag(name: str, default: bool = False) -> bool:
    """Read a boolean environment variable, tolerating human spellings."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in _TRUTHY:
        return True
    if value in _FALSY:
        return False
    return default


def env_int(name: str, default: int) -> int:
    """Read an integer environment variable, falling back on garbage input."""
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw.strip())
    except ValueError:
        return default


def default_run_id() -> str:
    """Generate a sortable, unique test run id."""
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{uuid.uuid4().hex[:6]}"


@dataclass(frozen=True)
class FarmConfig:
    """Resolved configuration for one test run."""

    appium_url: str = "http://127.0.0.1:4723"
    test_run_id: str = field(default_factory=default_run_id)
    artifacts_root: Path = FARM_ROOT / "artifacts"
    app_path: str | None = None
    app_package: str | None = None
    app_activity: str | None = None
    bundle_id: str | None = None
    platform: str = "Android"
    platform_version: str | None = None
    device_name: str | None = None
    udid: str | None = None
    dry_run: bool = False
    enable_proxy: bool = True
    enable_pcap: bool = False
    enable_device_proxy: bool = False
    capture_interface: str = "any"
    max_parallel: int = 4
    appium_command_timeout: int = 120
    device_farm_config: Path = FARM_ROOT / "config" / "appium-device-farm.config.json"

    @property
    def is_android(self) -> bool:
        return self.platform.strip().lower() == "android"

    @property
    def run_dir(self) -> Path:
        """Artifact directory for this run: ``artifacts/<test_run_id>``."""
        return self.artifacts_root / self.test_run_id

    @property
    def appium_webdriver_url(self) -> str:
        """Appium 2.x default base path (no ``/wd/hub`` suffix)."""
        return self.appium_url.rstrip("/")

    def describe(self) -> str:
        flags = [
            f"platform={self.platform}",
            f"appium={self.appium_webdriver_url}",
            f"run_id={self.test_run_id}",
            f"dry_run={self.dry_run}",
            f"proxy={self.enable_proxy}",
            f"pcap={self.enable_pcap}",
            f"device_proxy={self.enable_device_proxy}",
        ]
        return "FarmConfig(" + ", ".join(flags) + ")"


def load_config() -> FarmConfig:
    """Build a :class:`FarmConfig` from ``DEVICE_FARM_*`` environment variables."""
    artifacts_root = Path(
        os.environ.get("DEVICE_FARM_ARTIFACTS_ROOT", str(FARM_ROOT / "artifacts"))
    ).expanduser()

    app_path = os.environ.get("DEVICE_FARM_APP_PATH") or None
    if app_path:
        app_path = str(Path(app_path).expanduser())

    return FarmConfig(
        appium_url=os.environ.get("DEVICE_FARM_APPIUM_URL", "http://127.0.0.1:4723"),
        test_run_id=os.environ.get("DEVICE_FARM_TEST_RUN_ID") or default_run_id(),
        artifacts_root=artifacts_root,
        app_path=app_path,
        app_package=os.environ.get("DEVICE_FARM_APP_PACKAGE") or None,
        app_activity=os.environ.get("DEVICE_FARM_APP_ACTIVITY") or None,
        bundle_id=os.environ.get("DEVICE_FARM_BUNDLE_ID") or None,
        platform=os.environ.get("DEVICE_FARM_PLATFORM", "Android"),
        platform_version=os.environ.get("DEVICE_FARM_PLATFORM_VERSION") or None,
        device_name=os.environ.get("DEVICE_FARM_DEVICE_NAME") or None,
        udid=os.environ.get("DEVICE_FARM_UDID") or None,
        dry_run=env_flag("DEVICE_FARM_DRY_RUN", False),
        enable_proxy=env_flag("DEVICE_FARM_ENABLE_PROXY", True),
        enable_pcap=env_flag("DEVICE_FARM_ENABLE_PCAP", False),
        enable_device_proxy=env_flag("DEVICE_FARM_ENABLE_DEVICE_PROXY", False),
        capture_interface=os.environ.get("DEVICE_FARM_CAPTURE_INTERFACE", "any"),
        max_parallel=max(1, env_int("DEVICE_FARM_MAX_PARALLEL", 4)),
        appium_command_timeout=env_int("DEVICE_FARM_COMMAND_TIMEOUT", 120),
        device_farm_config=Path(
            os.environ.get(
                "DEVICE_FARM_PLUGIN_CONFIG",
                str(FARM_ROOT / "config" / "appium-device-farm.config.json"),
            )
        ).expanduser(),
    )
