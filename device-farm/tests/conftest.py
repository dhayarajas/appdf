"""Pytest fixtures implementing the device farm session lifecycle.

Lifecycle per test
------------------
1. **Allocate** — ask the appium-device-farm plugin for a device (falling back
   to ``adb`` discovery); ``skip`` when the pool is empty, when Appium is
   unreachable, or when ``DEVICE_FARM_DRY_RUN=1``.
2. **Pre-test** — start a session-isolated mitmdump proxy (dynamic port, HAR
   output), begin PCAP capture, install the target build.
3. **Test** — the ``driver`` fixture yields a connected Appium ``WebDriver``.
4. **Post-test** — stop capture, dump ``.har``/``.pcap`` tagged with test id +
   timestamp, collect logcat/syslog, reset device state, quit the session.

Importing this module never touches hardware: collection works on a host with
no adb, no Appium and no devices.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Iterator
from pathlib import Path

import pytest

from capture.pcap_capture import PcapCapture, tcpdump_available
from framework.artifacts import ArtifactPaths, slugify, timestamp_slug
from framework.capabilities import build_capabilities
from framework.config import FarmConfig, load_config
from framework.devices import (
    adb_available,
    collect_ios_syslog,
    collect_logcat,
    detect_host_ip,
    install_app,
    list_devices,
    query_device_farm_pool,
    reset_device_state,
)
from proxy.proxy_manager import ProxyManager, mitmdump_available

LOGGER = logging.getLogger("device_farm.conftest")


# --------------------------------------------------------------- session scope
@pytest.fixture(scope="session")
def farm_config() -> FarmConfig:
    """Resolved run configuration (environment driven)."""
    config = load_config()
    LOGGER.info("%s", config.describe())
    return config


@pytest.fixture(scope="session")
def artifacts(farm_config: FarmConfig) -> ArtifactPaths:
    """Artifact tree for this run: ``artifacts/<test_run_id>/{reports,logs,traces}``."""
    paths = ArtifactPaths.for_run(farm_config.artifacts_root, farm_config.test_run_id)
    try:
        paths.ensure()
    except OSError as exc:
        pytest.skip(f"cannot create the artifact tree at {paths.run_dir}: {exc}")
    LOGGER.info("artifacts: %s", paths.run_dir)
    return paths


@pytest.fixture(scope="session")
def host_ip() -> str:
    return detect_host_ip()


@pytest.fixture(scope="session")
def device_pool(farm_config: FarmConfig) -> list[str]:
    """UDIDs available for this run.

    Prefers the appium-device-farm plugin's pool API; falls back to local ``adb``
    discovery. Returns an empty list when nothing is available — fixtures that
    need a device then skip with an informative message.
    """
    if farm_config.dry_run:
        LOGGER.warning("DEVICE_FARM_DRY_RUN=1: reporting an empty device pool")
        return []

    pool = query_device_farm_pool(farm_config.appium_webdriver_url)
    if pool:
        udids = [
            str(entry.get("udid") or entry.get("id") or "")
            for entry in pool
            if isinstance(entry, dict)
            and (entry.get("busy") is not True)
            and str(entry.get("platform", farm_config.platform)).lower()
            == farm_config.platform.lower()
        ]
        udids = [udid for udid in udids if udid]
        if udids:
            LOGGER.info("device-farm pool reports %d free device(s)", len(udids))
            return udids
        LOGGER.warning("device-farm plugin reachable but reported no free devices")

    if farm_config.is_android and adb_available():
        udids = [device.udid for device in list_devices()]
        if udids:
            LOGGER.info("adb discovered %d device(s): %s", len(udids), ", ".join(udids))
        else:
            LOGGER.warning("adb found no attached devices")
        return udids

    LOGGER.warning("no device source available (no plugin pool, no adb)")
    return []


@pytest.fixture(scope="session")
def pool_status(farm_config: FarmConfig, device_pool: list[str]) -> str | None:
    """``None`` when a device is usable, otherwise the reason to skip."""
    if farm_config.dry_run:
        return "DEVICE_FARM_DRY_RUN=1: device-dependent tests are skipped by design"
    if not device_pool:
        return (
            "no devices in the pool: attach a device (or start an emulator) and launch "
            "Appium with the device-farm plugin - see device-farm/README.md"
        )
    return None


# ------------------------------------------------------------ per-test scope
@pytest.fixture
def test_id(request: pytest.FixtureRequest) -> str:
    """Filename-safe pytest node id, used to tag every artifact."""
    return slugify(request.node.nodeid)


@pytest.fixture
def allocated_udid(device_pool: list[str], pool_status: str | None, worker_id: str) -> str:
    """Allocate one device to this test, sharded by xdist worker.

    Skips (never fails) when the pool is empty.
    """
    if pool_status is not None:
        pytest.skip(pool_status)
    index = 0
    if worker_id.startswith("gw"):
        with_suffix = worker_id[2:]
        if with_suffix.isdigit():
            index = int(with_suffix) % len(device_pool)
    udid = device_pool[index]
    LOGGER.info("worker %s allocated device %s", worker_id, udid)
    return udid


@pytest.fixture
def worker_id(request: pytest.FixtureRequest) -> str:
    """``gw0``/``gw1``/... under pytest-xdist, ``master`` otherwise."""
    workerinput = getattr(request.config, "workerinput", None)
    if isinstance(workerinput, dict):
        return str(workerinput.get("workerid", "master"))
    return os.environ.get("PYTEST_XDIST_WORKER", "master")


@pytest.fixture
def proxy_manager(
    farm_config: FarmConfig,
    artifacts: ArtifactPaths,
    test_id: str,
    host_ip: str,
) -> Iterator[ProxyManager | None]:
    """Session-isolated mitmdump proxy writing a tagged HAR.

    Yields a started :class:`ProxyManager`, or ``None`` when proxying is disabled
    or mitmdump is not installed.
    """
    if not farm_config.enable_proxy:
        LOGGER.info("proxy disabled (DEVICE_FARM_ENABLE_PROXY=0)")
        yield None
        return
    if not mitmdump_available():
        LOGGER.warning("mitmdump not installed; HAR capture skipped for %s", test_id)
        yield None
        return

    manager = ProxyManager(
        har_path=artifacts.trace_file(test_id, ".har"),
        log_path=artifacts.logs / f"{test_id}-mitmdump-{timestamp_slug()}.log",
        host_ip=host_ip,
    )
    manager.start()
    try:
        yield manager
    finally:
        manager.stop()


@pytest.fixture
def proxy_session(proxy_manager: ProxyManager | None) -> object:
    """The :class:`~proxy.proxy_manager.ProxySession` for this test, if any."""
    return proxy_manager.session if proxy_manager is not None else None


@pytest.fixture
def pcap_session(
    farm_config: FarmConfig, artifacts: ArtifactPaths, test_id: str
) -> Iterator[object]:
    """Per-test packet capture; yields ``None`` when unavailable or disabled."""
    if not farm_config.enable_pcap:
        LOGGER.info("PCAP capture disabled (DEVICE_FARM_ENABLE_PCAP=0)")
        yield None
        return
    if not tcpdump_available():
        LOGGER.warning("tcpdump not installed; PCAP capture skipped for %s", test_id)
        yield None
        return

    capture = PcapCapture.for_test(
        artifacts.traces, test_id, interface=farm_config.capture_interface
    )
    session = capture.start()
    try:
        yield session
    finally:
        capture.stop()


@pytest.fixture
def installed_build(
    farm_config: FarmConfig, allocated_udid: str, request: pytest.FixtureRequest
) -> str | None:
    """Install the target build on the allocated device, when one is configured.

    ``.apk`` builds are installed through adb here so the app is present before
    the Appium session starts; ``.ipa`` builds are left to the xcuitest driver
    (``appium:app``).
    """
    app_path = farm_config.app_path
    if not app_path:
        LOGGER.info("DEVICE_FARM_APP_PATH unset; using whatever build is already on the device")
        return None
    if not Path(app_path).is_file():
        pytest.skip(f"target build not found at {app_path}")
    if Path(app_path).suffix.lower() == ".ipa":
        LOGGER.info("iOS build will be installed by the xcuitest driver via appium:app")
        return app_path
    if not install_app(app_path, udid=allocated_udid):
        pytest.skip(f"could not install {app_path} on {allocated_udid}")
    return app_path


@pytest.fixture
def driver(
    farm_config: FarmConfig,
    artifacts: ArtifactPaths,
    allocated_udid: str,
    installed_build: str | None,
    proxy_manager: ProxyManager | None,
    pcap_session: object,
    test_id: str,
) -> Iterator[object]:
    """An Appium session against an allocated device.

    Pre-test: proxy + capture are already running (fixture ordering), the device
    proxy is applied when ``DEVICE_FARM_ENABLE_DEVICE_PROXY=1``, and the build is
    installed. Post-test: logs are collected and device state is reset.

    Skips with an informative message when the Appium client is not installed or
    the server/session cannot be created.
    """
    try:
        from appium import webdriver  # noqa: PLC0415 - optional at collection time
        from appium.options.android import UiAutomator2Options
        from appium.options.ios import XCUITestOptions
    except ImportError as exc:  # pragma: no cover - depends on env
        pytest.skip(f"Appium-Python-Client not installed ({exc}); pip install -e device-farm")

    if farm_config.enable_device_proxy and proxy_manager is not None:
        proxy_manager.set_device_proxy(allocated_udid)

    caps = build_capabilities(farm_config, udid=allocated_udid)
    options_cls = UiAutomator2Options if farm_config.is_android else XCUITestOptions
    options = options_cls().load_capabilities(caps)

    session = None
    try:
        session = webdriver.Remote(farm_config.appium_webdriver_url, options=options)
    except Exception as exc:  # noqa: BLE001 - any failure means "no session"
        pytest.skip(
            f"could not create an Appium session at {farm_config.appium_webdriver_url}: {exc}"
        )

    try:
        yield session
    finally:
        _post_test_teardown(session, farm_config, artifacts, allocated_udid, test_id)
        if farm_config.enable_device_proxy and proxy_manager is not None:
            proxy_manager.clear_device_proxy(allocated_udid)


def _post_test_teardown(
    session: object,
    farm_config: FarmConfig,
    artifacts: ArtifactPaths,
    udid: str,
    test_id: str,
) -> None:
    """Collect logs, reset the device and quit the session; never raises."""
    if farm_config.is_android:
        collect_logcat(artifacts.log_file(f"{test_id}-logcat"), udid=udid)
    else:
        collect_ios_syslog(artifacts.log_file(f"{test_id}-syslog"), udid=udid)

    try:
        quit_method = getattr(session, "quit", None)
        if callable(quit_method):
            quit_method()
    except Exception as exc:  # noqa: BLE001 - teardown must not mask results
        LOGGER.warning("error quitting the Appium session: %s", exc)

    reset_device_state(udid=udid, package=farm_config.app_package)


# ------------------------------------------------------------------- hooks
def pytest_configure(config: pytest.Config) -> None:
    """Point junit/report output at ``artifacts/<test_run_id>/reports``."""
    farm_config = load_config()
    os.environ.setdefault("DEVICE_FARM_TEST_RUN_ID", farm_config.test_run_id)
    if config.option.collectonly:
        # Collection-only runs produce no artifacts; do not create a run directory.
        return
    paths = ArtifactPaths.for_run(farm_config.artifacts_root, farm_config.test_run_id)
    try:
        paths.ensure()
    except OSError as exc:
        LOGGER.warning("cannot create the artifact tree at %s: %s", paths.run_dir, exc)
        return
    if config.option.xmlpath is None:
        config.option.xmlpath = str(paths.reports / "junit.xml")


def pytest_report_header(config: pytest.Config) -> list[str]:
    farm_config = load_config()
    devices = [device.udid for device in list_devices()] if adb_available() else []
    attached = ", ".join(devices) if devices else "none (device tests will skip)"
    return [
        f"device-farm: {farm_config.describe()}",
        f"device-farm: adb={'yes' if adb_available() else 'no'} "
        f"mitmdump={'yes' if mitmdump_available() else 'no'} "
        f"tcpdump={'yes' if tcpdump_available() else 'no'}",
        f"device-farm: attached devices: {attached}",
    ]
