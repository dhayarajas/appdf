"""Appium capability builder.

The capabilities produced here are deliberately *pool-oriented*: unless a
specific ``udid`` is configured, no device identity is pinned and the
appium-device-farm plugin picks a free device from its pool. Vendor
capabilities use the ``appium:`` prefix required by Appium 2.x / W3C.
"""

from __future__ import annotations

from typing import Any

from framework.config import FarmConfig


def build_capabilities(
    config: FarmConfig,
    *,
    udid: str | None = None,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build W3C capabilities for one session.

    Args:
        config: resolved run configuration.
        udid: pin the session to a specific device; when ``None`` the
            device-farm plugin allocates any healthy device from the pool.
        extra: additional capabilities merged last (already ``appium:``-prefixed
            where required).
    """
    if config.is_android:
        caps = _android_capabilities(config)
    else:
        caps = _ios_capabilities(config)

    target_udid = udid or config.udid
    if target_udid:
        caps["appium:udid"] = target_udid

    caps["appium:newCommandTimeout"] = config.appium_command_timeout
    # Consumed by the device-farm plugin dashboard / reports.
    caps["df:buildName"] = config.test_run_id

    if extra:
        caps.update(extra)
    return caps


def _android_capabilities(config: FarmConfig) -> dict[str, Any]:
    caps: dict[str, Any] = {
        "platformName": "Android",
        "appium:automationName": "UiAutomator2",
        # A generic deviceName keeps the request pool-wide; the plugin overrides
        # it with the device it allocates.
        "appium:deviceName": config.device_name or "Android",
        "appium:autoGrantPermissions": True,
        "appium:disableWindowAnimation": True,
        "appium:ignoreHiddenApiPolicyError": True,
        "appium:uiautomator2ServerInstallTimeout": 120_000,
        "appium:adbExecTimeout": 60_000,
        "appium:noReset": False,
        "appium:fullReset": False,
    }
    if config.platform_version:
        caps["appium:platformVersion"] = config.platform_version
    if config.app_path:
        caps["appium:app"] = config.app_path
    if config.app_package:
        caps["appium:appPackage"] = config.app_package
    if config.app_activity:
        caps["appium:appActivity"] = config.app_activity
    return caps


def _ios_capabilities(config: FarmConfig) -> dict[str, Any]:
    """iOS capabilities. Usable only on Darwin hosts with the xcuitest driver."""
    caps: dict[str, Any] = {
        "platformName": "iOS",
        "appium:automationName": "XCUITest",
        "appium:deviceName": config.device_name or "iPhone",
        "appium:autoAcceptAlerts": True,
        "appium:wdaLaunchTimeout": 180_000,
        "appium:wdaConnectionTimeout": 180_000,
    }
    if config.platform_version:
        caps["appium:platformVersion"] = config.platform_version
    if config.app_path:
        caps["appium:app"] = config.app_path
    if config.bundle_id:
        caps["appium:bundleId"] = config.bundle_id
    return caps


def with_proxy_capabilities(
    caps: dict[str, Any], host: str, port: int, *, platform_is_android: bool = True
) -> dict[str, Any]:
    """Return a copy of ``caps`` routed through an HTTP(S) proxy.

    Android sessions can be steered with the standard W3C ``proxy`` capability;
    it applies to the device's Wi-Fi/global proxy where the driver supports it.
    Device-side ``adb shell settings put global http_proxy`` (see
    ``proxy.proxy_manager``) is the more reliable path and is what the fixtures
    use by default.
    """
    merged = dict(caps)
    endpoint = f"{host}:{port}"
    merged["proxy"] = {
        "proxyType": "manual",
        "httpProxy": endpoint,
        "sslProxy": endpoint,
    }
    if platform_is_android:
        merged["appium:enforceAppInstall"] = True
    return merged
