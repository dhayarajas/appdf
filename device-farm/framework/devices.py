"""Device discovery and device-side helpers.

All functions here are defensive: when ``adb`` is missing, the daemon is not
running, or no device is attached, they return empty results or ``False``
instead of raising, so callers can skip rather than fail. The only exception is
:func:`require_adb`, which raises :class:`AdbUnavailableError` when a caller
explicitly needs adb.
"""

from __future__ import annotations

import json
import logging
import shutil
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path

LOGGER = logging.getLogger(__name__)

ADB_TIMEOUT_SEC = 30


class AdbUnavailableError(RuntimeError):
    """Raised when adb is required but not usable on this host."""


@dataclass(frozen=True)
class DeviceInfo:
    """A device as reported by ``adb devices -l``."""

    udid: str
    state: str
    model: str | None = None
    android_version: str | None = None

    @property
    def is_ready(self) -> bool:
        return self.state == "device"


def adb_path() -> str | None:
    """Locate ``adb`` on PATH or under ``ANDROID_HOME``/``ANDROID_SDK_ROOT``."""
    found = shutil.which("adb")
    if found:
        return found
    import os

    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        root = os.environ.get(var)
        if not root:
            continue
        candidate = Path(root) / "platform-tools" / "adb"
        if candidate.is_file():
            return str(candidate)
    return None


def adb_available() -> bool:
    return adb_path() is not None


def require_adb() -> str:
    path = adb_path()
    if path is None:
        raise AdbUnavailableError(
            "adb not found. Install Android platform-tools and set "
            "ANDROID_HOME/PATH (see device-farm/README.md)."
        )
    return path


def run_adb(
    args: list[str], *, udid: str | None = None, timeout: int = ADB_TIMEOUT_SEC
) -> subprocess.CompletedProcess[str]:
    """Run an adb command, never raising on non-zero exit.

    Returns a :class:`subprocess.CompletedProcess` with ``returncode`` 127 when
    adb itself is unavailable, so callers can branch on a single value.
    """
    path = adb_path()
    if path is None:
        LOGGER.warning("adb unavailable; skipping: adb %s", " ".join(args))
        return subprocess.CompletedProcess(
            args=["adb", *args], returncode=127, stdout="", stderr="adb not found"
        )
    cmd = [path]
    if udid:
        cmd += ["-s", udid]
    cmd += args
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        LOGGER.warning("adb timed out after %ss: %s", timeout, " ".join(cmd))
        return subprocess.CompletedProcess(args=cmd, returncode=124, stdout="", stderr="timeout")
    except OSError as exc:  # pragma: no cover - depends on host state
        LOGGER.warning("adb failed to execute (%s): %s", exc, " ".join(cmd))
        return subprocess.CompletedProcess(args=cmd, returncode=127, stdout="", stderr=str(exc))


def list_devices(*, ready_only: bool = True) -> list[DeviceInfo]:
    """Enumerate attached Android devices. Returns ``[]`` when there are none."""
    result = run_adb(["devices", "-l"])
    if result.returncode != 0:
        return []

    devices: list[DeviceInfo] = []
    for line in result.stdout.splitlines()[1:]:
        line = line.strip()
        if not line or line.startswith("*"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        udid, state = parts[0], parts[1]
        model = next(
            (token.split(":", 1)[1] for token in parts[2:] if token.startswith("model:")), None
        )
        if state != "device":
            LOGGER.warning("device %s is in state '%s'; excluded from the ready pool", udid, state)
            if ready_only:
                continue
            devices.append(DeviceInfo(udid=udid, state=state, model=model))
            continue
        devices.append(
            DeviceInfo(
                udid=udid,
                state=state,
                model=model,
                android_version=getprop(udid, "ro.build.version.release"),
            )
        )
    return devices


def getprop(udid: str, prop: str) -> str | None:
    result = run_adb(["shell", "getprop", prop], udid=udid)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def device_count() -> int:
    return len(list_devices())


def detect_host_ip(target: str = "8.8.8.8") -> str:
    """Best-effort LAN IP of this host, as seen by devices on the same network.

    Falls back to ``127.0.0.1`` when there is no route (offline CI), which is
    still usable for emulators via ``10.0.2.2`` style host aliases.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect((target, 80))
        return sock.getsockname()[0]
    except OSError:
        LOGGER.warning("could not determine LAN IP; falling back to 127.0.0.1")
        return "127.0.0.1"
    finally:
        sock.close()


def install_app(app_path: str | Path, *, udid: str | None = None, reinstall: bool = True) -> bool:
    """Install an APK on a device. Returns ``False`` (with a warning) on failure.

    ``.ipa`` payloads are *not* installable through adb; on iOS the Appium
    ``appium:app`` capability handles installation, so this function refuses
    non-APK inputs.
    """
    path = Path(app_path)
    if not path.is_file():
        LOGGER.warning("target build not found at %s; skipping install", path)
        return False
    if path.suffix.lower() != ".apk":
        LOGGER.warning(
            "%s is not an .apk; iOS builds are installed by the xcuitest driver "
            "via the appium:app capability",
            path.name,
        )
        return False

    args = ["install"]
    if reinstall:
        args.append("-r")
    args.append(str(path))
    result = run_adb(args, udid=udid, timeout=300)
    if result.returncode != 0 or "Success" not in (result.stdout or ""):
        LOGGER.warning(
            "apk install failed (rc=%s): %s",
            result.returncode,
            (result.stderr or result.stdout).strip(),
        )
        return False
    LOGGER.info("installed %s on %s", path.name, udid or "the attached device")
    return True


def uninstall_app(package: str, *, udid: str | None = None) -> bool:
    result = run_adb(["uninstall", package], udid=udid, timeout=120)
    return result.returncode == 0 and "Success" in (result.stdout or "")


def clear_logcat(udid: str | None = None) -> bool:
    """Clear the ring buffer so per-test logcat dumps are scoped to the test."""
    return run_adb(["logcat", "-c"], udid=udid).returncode == 0


def collect_logcat(destination: Path, *, udid: str | None = None) -> Path | None:
    """Dump the device log to ``destination``.

    On Android this is ``adb logcat -d``. Returns the written path, or ``None``
    when no device/adb is available (a warning is logged, nothing raises).
    """
    result = run_adb(["logcat", "-d", "-v", "threadtime"], udid=udid, timeout=120)
    if result.returncode != 0:
        LOGGER.warning("could not collect logcat (rc=%s); no log written", result.returncode)
        return None
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(result.stdout, encoding="utf-8", errors="replace")
    LOGGER.info("wrote device log: %s", destination)
    return destination


def collect_ios_syslog(destination: Path, *, udid: str | None = None) -> Path | None:
    """Placeholder for iOS syslog collection.

    Requires a Darwin host with ``libimobiledevice`` (``idevicesyslog``) or the
    Appium ``mobile: startLogsBroadcast`` extension; both are unavailable on the
    Linux CI host this scaffold is validated on, so this logs and returns
    ``None`` rather than pretending to capture.
    """
    tool = shutil.which("idevicesyslog")
    if tool is None:
        LOGGER.warning("idevicesyslog not available; skipping iOS syslog collection")
        return None
    try:
        proc = subprocess.run(  # noqa: S603 - fixed argv, no shell
            [tool, *(["-u", udid] if udid else [])],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        LOGGER.warning("idevicesyslog failed: %s", exc)
        return None
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(proc.stdout, encoding="utf-8", errors="replace")
    return destination


def reset_device_state(*, udid: str | None = None, package: str | None = None) -> None:
    """Return a device to a neutral state between tests.

    Best effort by design: stops the app under test, clears its data, dismisses
    the keyguard and clears the logcat buffer. Every step tolerates failure so
    teardown never masks a test result.
    """
    if not adb_available():
        LOGGER.info("adb unavailable; skipping device state reset")
        return
    if package:
        run_adb(["shell", "am", "force-stop", package], udid=udid)
        run_adb(["shell", "pm", "clear", package], udid=udid)
    run_adb(["shell", "input", "keyevent", "KEYCODE_HOME"], udid=udid)
    run_adb(["shell", "wm", "dismiss-keyguard"], udid=udid)
    clear_logcat(udid)


def query_device_farm_pool(appium_url: str, timeout: float = 5.0) -> list[dict] | None:
    """Ask the appium-device-farm plugin for its device pool.

    Returns the parsed device list, or ``None`` when the Appium server or the
    plugin is not reachable (the caller then falls back to ``adb`` discovery or
    skips). Uses ``requests`` when installed and ``urllib`` otherwise.
    """
    url = appium_url.rstrip("/") + "/device-farm/api/device"
    body: str
    try:
        try:
            import requests  # noqa: PLC0415 - optional dependency

            response = requests.get(url, timeout=timeout)
            if response.status_code != 200:
                LOGGER.warning("device-farm pool query returned HTTP %s", response.status_code)
                return None
            body = response.text
        except ImportError:  # pragma: no cover - requests is a declared dependency
            from urllib.request import urlopen  # noqa: PLC0415

            with urlopen(url, timeout=timeout) as handle:  # noqa: S310 - fixed localhost URL
                body = handle.read().decode("utf-8", errors="replace")
    except Exception as exc:  # noqa: BLE001 - any transport error means "no pool"
        LOGGER.info("device-farm plugin not reachable at %s (%s)", url, exc)
        return None

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        LOGGER.warning("device-farm pool response was not JSON")
        return None

    if isinstance(payload, dict):
        for key in ("devices", "data", "result"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
        return []
    if isinstance(payload, list):
        return payload
    return []
