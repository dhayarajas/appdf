"""Per-session ``mitmdump`` proxy management and device proxy plumbing.

Responsibilities
----------------
* allocate a free TCP port per test session (so parallel xdist workers never
  collide),
* start / stop a ``mitmdump`` process that writes a HAR file for the session,
* point the device at that proxy via
  ``adb shell settings put global http_proxy <host_ip>:<port>`` and reset it
  afterwards,
* document (and partially automate) the mitmproxy CA trust steps.

Everything degrades gracefully: when ``mitmdump`` is not installed or no device
is attached, the manager logs a warning and yields a session with
``started is False`` so tests can continue (or skip) rather than error.

HAR support: mitmproxy >= 10.2 ships a built-in HAR export enabled with
``--set hardump=<file>``. Older versions need the bundled ``har_dump.py``
example script; when the ``hardump`` option is unsupported this module falls
back to writing a raw flow dump (``.flows``) next to the expected HAR path and
logs how to convert it (``mitmdump -nr <file>.flows --set hardump=<file>.har``).
"""

from __future__ import annotations

import contextlib
import logging
import os
import shutil
import signal
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from framework.devices import adb_available, detect_host_ip, proxy_host_for_device, run_adb

LOGGER = logging.getLogger(__name__)

MITM_STARTUP_TIMEOUT_SEC = 15
MITM_SHUTDOWN_TIMEOUT_SEC = 10
DEFAULT_CONFDIR = Path.home() / ".mitmproxy"


def allocate_port(preferred: int | None = None) -> int:
    """Return a free TCP port on the loopback interface.

    ``preferred`` is tried first; if it is busy an ephemeral port is chosen.
    """
    if preferred is not None:
        with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("", preferred))
                return preferred
            except OSError:
                LOGGER.info("port %s busy; allocating an ephemeral port instead", preferred)

    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.bind(("", 0))
        return int(sock.getsockname()[1])


def mitmdump_available() -> bool:
    return shutil.which("mitmdump") is not None


@dataclass
class ProxySession:
    """State of one session-scoped proxy."""

    port: int
    host_ip: str
    har_path: Path
    log_path: Path
    process: subprocess.Popen[bytes] | None = None
    started: bool = False
    device_proxy_applied: bool = False
    udid: str | None = None
    reason: str | None = None
    #: endpoint as configured *on the device* (``10.0.2.2:<port>`` for emulators)
    device_endpoint: str | None = None
    _extra_paths: list[Path] = field(default_factory=list)

    @property
    def endpoint(self) -> str:
        return f"{self.host_ip}:{self.port}"

    @property
    def artifacts(self) -> list[Path]:
        """Trace artifacts that actually exist on disk."""
        candidates = [self.har_path, *self._extra_paths]
        return [path for path in candidates if path.exists()]


class ProxyManager:
    """Starts and stops a ``mitmdump`` instance for a single test session."""

    def __init__(
        self,
        *,
        har_path: Path,
        log_path: Path | None = None,
        port: int | None = None,
        host_ip: str | None = None,
        confdir: Path = DEFAULT_CONFDIR,
        extra_args: list[str] | None = None,
    ) -> None:
        self.har_path = Path(har_path)
        self.log_path = Path(log_path) if log_path else self.har_path.with_suffix(".mitmdump.log")
        self.requested_port = port
        self.host_ip = host_ip or detect_host_ip()
        self.confdir = Path(confdir)
        self.extra_args = list(extra_args or [])
        self.session: ProxySession | None = None

    # ------------------------------------------------------------- lifecycle
    def start(self) -> ProxySession:
        """Start ``mitmdump``; returns a :class:`ProxySession` either way.

        When mitmdump is unavailable or fails to come up, ``session.started`` is
        ``False`` and ``session.reason`` explains why. No exception is raised so
        a missing trace pipeline never fails a test run.
        """
        port = allocate_port(self.requested_port)
        session = ProxySession(
            port=port,
            host_ip=self.host_ip,
            har_path=self.har_path,
            log_path=self.log_path,
        )
        self.session = session

        if not mitmdump_available():
            session.reason = "mitmdump not installed (pip install mitmproxy); HAR capture disabled"
            LOGGER.warning(session.reason)
            return session

        self.har_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)

        cmd = self._build_command(port, har_output=True)
        session.process = self._spawn(cmd)
        if session.process is None:
            session.reason = "could not spawn mitmdump"
            return session

        if self._wait_until_listening(port, session.process):
            session.started = True
            LOGGER.info("mitmdump listening on %s (HAR -> %s)", session.endpoint, self.har_path)
            return session

        # The most common startup failure on older mitmproxy builds is an
        # unknown 'hardump' option: retry once with a raw flow dump.
        LOGGER.warning("mitmdump did not start with HAR export; retrying with a raw flow dump")
        self._terminate(session.process)
        flows_path = self.har_path.with_suffix(".flows")
        session._extra_paths.append(flows_path)
        session.process = self._spawn(
            self._build_command(port, har_output=False, flows_path=flows_path)
        )
        if session.process is not None and self._wait_until_listening(port, session.process):
            session.started = True
            session.reason = (
                f"HAR export unsupported by this mitmproxy build; wrote flows to {flows_path}. "
                f"Convert with: mitmdump -nr {flows_path} --set hardump={self.har_path}"
            )
            LOGGER.warning(session.reason)
            return session

        session.reason = f"mitmdump failed to start; see {self.log_path}"
        LOGGER.warning(session.reason)
        return session

    def stop(self) -> ProxySession | None:
        """Stop the proxy (and clear the device proxy if this manager set it)."""
        session = self.session
        if session is None:
            return None
        if session.device_proxy_applied:
            self.clear_device_proxy(session.udid)
        if session.process is not None:
            self._terminate(session.process)
            session.process = None
        session.started = False
        if session.har_path.exists():
            LOGGER.info(
                "HAR written: %s (%d bytes)", session.har_path, session.har_path.stat().st_size
            )
        else:
            LOGGER.warning(
                "no HAR at %s - the app may pin certificates, route around the "
                "proxy, or have generated no HTTP traffic",
                session.har_path,
            )
        return session

    def __enter__(self) -> ProxySession:
        return self.start()

    def __exit__(self, *_exc_info: object) -> None:
        self.stop()

    # ------------------------------------------------------- device plumbing
    def set_device_proxy(self, udid: str | None = None) -> bool:
        """Point the device at this proxy.

        Runs ``adb shell settings put global http_proxy <host_ip>:<port>``.
        Returns ``False`` (logging a warning) when adb or the device is absent,
        or when the proxy is not running.

        The address written to the device is host-aware: emulators get the QEMU
        host alias ``10.0.2.2``, physical devices get this host's LAN IP.

        Note: the global ``http_proxy`` setting affects Wi-Fi traffic for most
        apps; apps using their own HTTP stack with hardcoded proxy bypass, or
        traffic over mobile data, may ignore it.
        """
        session = self.session
        if session is None or not session.started:
            LOGGER.warning("proxy is not running; not setting a device proxy")
            return False
        if not adb_available():
            LOGGER.warning("adb unavailable; cannot set the device proxy")
            return False

        endpoint = f"{proxy_host_for_device(session.host_ip, udid)}:{session.port}"
        result = run_adb(["shell", "settings", "put", "global", "http_proxy", endpoint], udid=udid)
        if result.returncode != 0:
            LOGGER.warning(
                "failed to set device proxy to %s (rc=%s): %s",
                endpoint,
                result.returncode,
                (result.stderr or "").strip(),
            )
            return False

        session.device_proxy_applied = True
        session.udid = udid
        session.device_endpoint = endpoint
        LOGGER.info("device proxy set to %s", endpoint)
        return True

    def clear_device_proxy(self, udid: str | None = None) -> bool:
        """Reset the device's global proxy to ``:0`` (Android's "no proxy")."""
        if not adb_available():
            LOGGER.info("adb unavailable; nothing to clear")
            return False

        ok = True
        for args in (
            ["shell", "settings", "put", "global", "http_proxy", ":0"],
            ["shell", "settings", "delete", "global", "global_http_proxy_host"],
            ["shell", "settings", "delete", "global", "global_http_proxy_port"],
        ):
            result = run_adb(args, udid=udid)
            if result.returncode != 0:
                ok = False
                LOGGER.warning(
                    "proxy reset step failed: adb %s (rc=%s)", " ".join(args), result.returncode
                )
        if self.session is not None:
            self.session.device_proxy_applied = False
        if ok:
            LOGGER.info("device proxy cleared")
        return ok

    # ------------------------------------------------------------- CA certs
    def ensure_ca_cert(self) -> Path | None:
        """Ensure the mitmproxy CA exists locally and return its PEM path.

        mitmproxy generates ``~/.mitmproxy/mitmproxy-ca-cert.pem`` on first run.
        This helper only *locates* it (starting mitmdump briefly if needed) —
        installing it on a device is a separate, partly manual step, see
        :func:`install_ca_cert_on_device`.
        """
        pem = self.confdir / "mitmproxy-ca-cert.pem"
        if pem.is_file():
            return pem
        if not mitmdump_available():
            LOGGER.warning("mitmdump not installed; cannot generate a CA certificate")
            return None
        LOGGER.info("generating mitmproxy CA in %s", self.confdir)
        port = allocate_port()
        process = self._spawn(self._build_command(port, har_output=False))
        if process is not None:
            time.sleep(3)
            self._terminate(process)
        return pem if pem.is_file() else None

    def install_ca_cert_on_device(self, udid: str | None = None) -> bool:
        """Push the mitmproxy CA to the device and open the import UI.

        **This cannot be fully automated on stock Android.** What it does:

        1. locates/creates ``mitmproxy-ca-cert.pem``,
        2. converts it to a ``.crt`` and pushes it to ``/sdcard/Download/``,
        3. opens *Settings → Security → Encryption & credentials → Install a
           certificate* so an operator can confirm the import.

        The final confirmation is a **manual, on-device step** (a hardware task
        performed once per farm device). Fully automated installs require either
        a rooted device (remount ``/system`` and drop the hashed cert into
        ``/system/etc/security/cacerts``) or an emulator image with a writable
        system partition (``emulator -writable-system``).

        **SSL-pinning caveat:** even with the CA trusted, apps that pin
        certificates (or that target Android 7+ without opting into user CAs via
        ``network_security_config.xml``) will reject the intercepted chain. For
        those apps only connection metadata is visible in the HAR; use a debug
        build with pinning disabled, a Frida-based unpinning hook, or fall back
        to the PCAP capture in ``capture.pcap_capture``.

        Returns ``True`` only when the push and intent dispatch both succeeded;
        it never asserts that the operator completed the import.
        """
        pem = self.ensure_ca_cert()
        if pem is None:
            return False
        if not adb_available():
            LOGGER.warning("adb unavailable; cannot push the CA certificate")
            return False

        remote = "/sdcard/Download/mitmproxy-ca-cert.crt"
        push = run_adb(["push", str(pem), remote], udid=udid, timeout=60)
        if push.returncode != 0:
            LOGGER.warning("failed to push CA cert to the device: %s", (push.stderr or "").strip())
            return False

        intent = run_adb(
            [
                "shell",
                "am",
                "start",
                "-a",
                "android.settings.SECURITY_SETTINGS",
            ],
            udid=udid,
        )
        LOGGER.warning(
            "CA certificate pushed to %s. MANUAL STEP: on the device open "
            "Settings > Security > Encryption & credentials > Install a certificate "
            "> CA certificate, and pick mitmproxy-ca-cert.crt.",
            remote,
        )
        return intent.returncode == 0

    @staticmethod
    def ca_cert_install_notes() -> str:
        """Operator-facing summary of the CA trust steps (per device, one-off)."""
        return (
            "1. pip install mitmproxy && mitmdump  # generates ~/.mitmproxy/mitmproxy-ca-cert.pem\n"
            "2. adb push ~/.mitmproxy/mitmproxy-ca-cert.pem"
            " /sdcard/Download/mitmproxy-ca-cert.crt\n"
            "3. On device: Settings > Security > Encryption & credentials > Install a certificate\n"
            "4. Android 7+: the app must trust user CAs via network_security_config.xml,\n"
            "   otherwise use a debug build, a rooted device (/system/etc/security/cacerts),\n"
            "   or 'emulator -writable-system'.\n"
            "5. Certificate-pinned apps stay opaque regardless of CA trust; capture PCAP instead."
        )

    # --------------------------------------------------------------- helpers
    def _build_command(
        self, port: int, *, har_output: bool, flows_path: Path | None = None
    ) -> list[str]:
        cmd = [
            "mitmdump",
            "--listen-host",
            "0.0.0.0",
            "--listen-port",
            str(port),
            "--set",
            f"confdir={self.confdir}",
            "--set",
            "termlog_verbosity=info",
            "--set",
            "flow_detail=1",
        ]
        if har_output:
            cmd += ["--set", f"hardump={self.har_path}"]
        elif flows_path is not None:
            cmd += ["-w", str(flows_path)]
        cmd += self.extra_args
        return cmd

    def _spawn(self, cmd: list[str]) -> subprocess.Popen[bytes] | None:
        LOGGER.debug("starting: %s", " ".join(cmd))
        try:
            handle = self.log_path.open("ab")
        except OSError as exc:
            LOGGER.warning("cannot open mitmdump log %s: %s", self.log_path, exc)
            return None
        try:
            return subprocess.Popen(  # noqa: S603 - fixed argv, no shell
                cmd,
                stdout=handle,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            LOGGER.warning("failed to start mitmdump: %s", exc)
            return None
        finally:
            handle.close()

    @staticmethod
    def _wait_until_listening(port: int, process: subprocess.Popen[bytes]) -> bool:
        deadline = time.monotonic() + MITM_STARTUP_TIMEOUT_SEC
        while time.monotonic() < deadline:
            if process.poll() is not None:
                return False
            with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as probe:
                probe.settimeout(0.5)
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    return True
            time.sleep(0.3)
        return False

    @staticmethod
    def _terminate(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (OSError, AttributeError):
            process.terminate()
        try:
            process.wait(timeout=MITM_SHUTDOWN_TIMEOUT_SEC)
        except subprocess.TimeoutExpired:
            LOGGER.warning("mitmdump did not exit in time; killing it")
            with contextlib.suppress(OSError, AttributeError):
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=5)
