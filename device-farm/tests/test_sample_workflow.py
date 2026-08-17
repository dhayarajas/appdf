"""Example end-to-end workflow plus hardware-free scaffold self-checks.

The E2E test exercises a realistic shape — launch, navigate, assert UI state,
assert captured network traffic — and skips gracefully (never fails) when no
device pool is available. The remaining tests validate the scaffold itself and
run anywhere, including CI with no devices.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from framework.artifacts import ArtifactPaths, slugify
from framework.capabilities import build_capabilities
from framework.config import FarmConfig

LOGGER = logging.getLogger(__name__)


@pytest.mark.e2e
@pytest.mark.android
@pytest.mark.requires_device
def test_search_and_open_product(driver, proxy_session, artifacts: ArtifactPaths, test_id: str):
    """Golden path: open the app, search, open the first result, verify traffic.

    Locators below are placeholders for the app under test; replace the
    accessibility ids / resource ids with the real ones once a build is wired up
    via ``DEVICE_FARM_APP_PATH``.
    """
    from appium.webdriver.common.appiumby import AppiumBy

    # 1. app under test is in the foreground
    assert driver.session_id, "Appium session was not created"

    # 2. drive the UI
    search = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "search-input")
    search.click()
    search.send_keys("running shoes")
    driver.find_element(AppiumBy.ACCESSIBILITY_ID, "search-submit").click()

    results = driver.find_elements(AppiumBy.ACCESSIBILITY_ID, "product-card")
    assert results, "no product cards rendered for the search query"
    results[0].click()

    # 3. assert the detail screen
    title = driver.find_element(AppiumBy.ACCESSIBILITY_ID, "product-title")
    assert title.text.strip(), "product title was empty on the detail screen"

    # 4. screenshot into the run artifacts
    screenshot = artifacts.logs / f"{slugify(test_id)}-detail.png"
    driver.get_screenshot_as_file(str(screenshot))
    assert screenshot.exists()

    # 5. assert on the intercepted traffic when the proxy captured anything
    if proxy_session is not None and getattr(proxy_session, "started", False):
        har_path: Path = proxy_session.har_path
        if har_path.exists() and har_path.stat().st_size > 0:
            entries = json.loads(har_path.read_text(encoding="utf-8"))["log"]["entries"]
            assert entries, "HAR was written but contains no entries"
            LOGGER.info("captured %d HTTP entries for %s", len(entries), test_id)
        else:
            LOGGER.warning(
                "no HAR content for %s (certificate pinning, no CA trust, or no HTTP traffic)",
                test_id,
            )


@pytest.mark.requires_device
def test_device_reports_its_platform(driver, farm_config: FarmConfig):
    """Smoke check that the allocated device answers basic driver queries."""
    caps = driver.capabilities
    assert caps.get("platformName", "").lower() == farm_config.platform.lower()
    LOGGER.info(
        "session on %s (%s %s)",
        caps.get("deviceUDID") or caps.get("udid"),
        caps.get("platformName"),
        caps.get("platformVersion"),
    )


# ------------------------------------------------- hardware-free self-checks
def test_capabilities_are_pool_oriented(farm_config: FarmConfig):
    """Without a pinned udid the capability set stays pool-wide."""
    caps = build_capabilities(farm_config)
    assert caps["platformName"] in {"Android", "iOS"}
    if farm_config.is_android:
        assert caps["appium:automationName"] == "UiAutomator2"
    if not farm_config.udid:
        assert "appium:udid" not in caps
    assert caps["df:buildName"] == farm_config.test_run_id


def test_capabilities_pin_requested_device(farm_config: FarmConfig):
    caps = build_capabilities(farm_config, udid="emulator-5554")
    assert caps["appium:udid"] == "emulator-5554"


def test_artifact_tree_is_created(artifacts: ArtifactPaths, test_id: str):
    """The run directory and its subdirectories exist and accept tagged files."""
    assert artifacts.run_dir.is_dir()
    for directory in (artifacts.reports, artifacts.logs, artifacts.traces):
        assert directory.is_dir()

    har = artifacts.trace_file(test_id, ".har")
    assert har.parent == artifacts.traces
    assert har.name.endswith(".har")
    assert slugify(test_id) in har.name

    marker = artifacts.log_file("scaffold-selfcheck")
    marker.write_text("device-farm scaffold self-check\n", encoding="utf-8")
    assert marker.is_file()


def test_pool_status_is_informative(pool_status, device_pool):
    """An empty pool must produce a message, not an exception."""
    if device_pool:
        assert pool_status is None
    else:
        assert pool_status and "device" in pool_status.lower()
