"""End-to-end proof of the ultimate requirement: install an app, drive it, and
export its network traffic as a HAR.

Requires a device (physical or emulator) plus the mitmproxy CA in the *system*
trust store for HTTPS bodies to decrypt — see ``scripts/emulator_up.sh`` and
``scripts/install_system_ca.sh``. Without hardware, or with the proxy disabled,
every test here skips with an actionable message; nothing fails.

Run:
    DEVICE_FARM_ENABLE_PROXY=1 DEVICE_FARM_ENABLE_DEVICE_PROXY=1 \
    DEVICE_FARM_APP_PATH=/path/app.apk DEVICE_FARM_APP_PACKAGE=com.example \
    DEVICE_FARM_APP_ACTIVITY=.MainActivity \
    pytest tests/test_app_traffic_har.py -v
"""

from __future__ import annotations

import logging
import time

import pytest

from framework.config import FarmConfig
from framework.devices import run_adb
from framework.har import load_har_entries, summarize
from proxy.proxy_manager import ProxyManager

LOGGER = logging.getLogger("device_farm.har")

pytestmark = pytest.mark.har

#: How long the app is left running to produce traffic before the HAR is closed.
TRAFFIC_WINDOW_SEC = 25


@pytest.fixture
def routed_proxy(
    farm_config: FarmConfig, proxy_manager: ProxyManager | None, allocated_udid: str
) -> ProxyManager:
    """A started proxy that the allocated device is actually routed through."""
    if proxy_manager is None or proxy_manager.session is None or not proxy_manager.session.started:
        pytest.skip("no proxy for this run: set DEVICE_FARM_ENABLE_PROXY=1 and install mitmproxy")
    if not farm_config.enable_device_proxy:
        pytest.skip("device proxy plumbing is off: set DEVICE_FARM_ENABLE_DEVICE_PROXY=1")
    # The driver fixture also routes the device; applying it here keeps the
    # plumbing test independent of an Appium session.
    if proxy_manager.session.device_endpoint is None and not proxy_manager.set_device_proxy(
        allocated_udid
    ):
        pytest.skip(f"could not route {allocated_udid} through the proxy via adb")
    return proxy_manager


def test_app_traffic_is_exported_as_har(
    driver: object,
    routed_proxy: ProxyManager,
    farm_config: FarmConfig,
    allocated_udid: str,
) -> None:
    """The installed app's traffic lands in a HAR with decrypted HTTPS entries."""
    session = routed_proxy.session
    assert session is not None
    LOGGER.info("device %s routed through %s", allocated_udid, session.device_endpoint)

    # The Appium session already launched the app; give it a window to talk.
    time.sleep(TRAFFIC_WINDOW_SEC)

    # mitmdump flushes the HAR on exit, so close the proxy before reading it.
    routed_proxy.stop()
    entries = load_har_entries(session.har_path)
    LOGGER.info("HAR %s: %s", session.har_path, summarize(entries))

    assert entries, (
        f"no HAR entries at {session.har_path}. The app produced no proxied traffic: check "
        f"'adb -s {allocated_udid} shell settings get global http_proxy' and that the app is "
        f"not bypassing the system proxy."
    )
    assert any(entry.status > 0 for entry in entries), (
        f"every HAR entry lacks a response ({summarize(entries)}); the proxy saw connections "
        "but no exchange completed - typically an untrusted CA or a pinned app."
    )
    tls = [entry for entry in entries if entry.is_tls]
    if tls:
        assert any(entry.decrypted for entry in tls), (
            f"HTTPS was seen but never decrypted ({summarize(entries)}); install the mitmproxy "
            "CA into the system store: scripts/install_system_ca.sh"
        )


def test_device_proxy_setting_is_applied_and_cleared(
    routed_proxy: ProxyManager, allocated_udid: str
) -> None:
    """``settings get global http_proxy`` reflects the session's proxy, then resets."""
    session = routed_proxy.session
    assert session is not None and session.device_endpoint is not None

    applied = run_adb(["shell", "settings", "get", "global", "http_proxy"], udid=allocated_udid)
    assert applied.returncode == 0, f"adb could not read the proxy setting: {applied.stderr}"
    assert session.device_endpoint in applied.stdout, (
        f"device proxy is {applied.stdout.strip()!r}, expected {session.device_endpoint!r}"
    )

    assert routed_proxy.clear_device_proxy(allocated_udid)
    cleared = run_adb(["shell", "settings", "get", "global", "http_proxy"], udid=allocated_udid)
    assert session.device_endpoint not in cleared.stdout, (
        f"proxy setting survived the reset: {cleared.stdout.strip()!r}"
    )
