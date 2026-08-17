"""Supporting modules for the self-hosted mobile device farm E2E scaffold.

Nothing in this package touches hardware at import time: every device or
tooling interaction is an explicit call that reports absence instead of
raising, so the package can be imported and dry-run in CI.
"""

from framework.artifacts import ArtifactPaths, timestamp_slug
from framework.capabilities import build_capabilities
from framework.config import FarmConfig, load_config
from framework.devices import (
    AdbUnavailableError,
    collect_logcat,
    detect_host_ip,
    list_devices,
    reset_device_state,
)

__all__ = [
    "AdbUnavailableError",
    "ArtifactPaths",
    "FarmConfig",
    "build_capabilities",
    "collect_logcat",
    "detect_host_ip",
    "list_devices",
    "load_config",
    "reset_device_state",
    "timestamp_slug",
]
