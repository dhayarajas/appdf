"""Per-session ``tcpdump`` wrapper writing timestamped ``.pcap`` files.

Packet capture needs privileges that a CI container usually does not have, so
every entry point is guarded:

* ``tcpdump`` missing            -> warn, ``started=False``
* no root and no ``CAP_NET_RAW`` -> warn, ``started=False``
* capture process dies early     -> warn, keep whatever bytes were written

None of these raise, so a test run is never failed by the absence of packet
capture. Grant capabilities once per host with::

    sudo setcap cap_net_raw,cap_net_admin=eip "$(command -v tcpdump)"
"""

from __future__ import annotations

import contextlib
import logging
import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from framework.artifacts import slugify, timestamp_slug

LOGGER = logging.getLogger(__name__)

SHUTDOWN_TIMEOUT_SEC = 10
STARTUP_GRACE_SEC = 1.5


def tcpdump_available() -> bool:
    return shutil.which("tcpdump") is not None


def capture_permitted() -> tuple[bool, str]:
    """Check whether this process may capture packets.

    Returns ``(permitted, reason)``; ``reason`` is a human-readable explanation
    when capture is not possible.
    """
    tool = shutil.which("tcpdump")
    if tool is None:
        return False, "tcpdump not installed (apt-get install tcpdump / brew install tcpdump)"
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        return True, "running as root"
    try:
        probe = subprocess.run(  # noqa: S603 - fixed argv, no shell
            [tool, "-D"], capture_output=True, text=True, timeout=15, check=False
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, f"tcpdump could not be executed: {exc}"
    if probe.returncode != 0:
        return False, (
            "tcpdump cannot list interfaces unprivileged; grant capabilities with "
            "'sudo setcap cap_net_raw,cap_net_admin=eip $(command -v tcpdump)' or run as root"
        )
    return True, "tcpdump usable unprivileged"


@dataclass
class PcapSession:
    """State of one packet capture."""

    pcap_path: Path
    interface: str
    process: subprocess.Popen[bytes] | None = None
    started: bool = False
    reason: str | None = None

    @property
    def artifact(self) -> Path | None:
        """The ``.pcap`` file if it exists and is non-empty."""
        if self.pcap_path.exists() and self.pcap_path.stat().st_size > 0:
            return self.pcap_path
        return None


class PcapCapture:
    """Start/stop a ``tcpdump`` capture scoped to a single test session."""

    def __init__(
        self,
        *,
        pcap_path: Path,
        interface: str = "any",
        bpf_filter: str | None = None,
        snaplen: int = 0,
        log_path: Path | None = None,
    ) -> None:
        self.pcap_path = Path(pcap_path)
        self.interface = interface
        self.bpf_filter = bpf_filter
        self.snaplen = snaplen
        self.log_path = Path(log_path) if log_path else self.pcap_path.with_suffix(".tcpdump.log")
        self.session: PcapSession | None = None

    @classmethod
    def for_test(
        cls,
        traces_dir: Path,
        test_id: str,
        *,
        interface: str = "any",
        bpf_filter: str | None = None,
    ) -> PcapCapture:
        """Build a capture whose filename carries the test id and a timestamp."""
        pcap_path = Path(traces_dir) / f"{slugify(test_id)}-{timestamp_slug()}.pcap"
        return cls(pcap_path=pcap_path, interface=interface, bpf_filter=bpf_filter)

    # ------------------------------------------------------------- lifecycle
    def start(self) -> PcapSession:
        """Start capturing. Always returns a session; check ``started``."""
        session = PcapSession(pcap_path=self.pcap_path, interface=self.interface)
        self.session = session

        permitted, reason = capture_permitted()
        if not permitted:
            session.reason = f"PCAP capture disabled: {reason}"
            LOGGER.warning(session.reason)
            return session

        self.pcap_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)

        cmd = [
            shutil.which("tcpdump") or "tcpdump",
            "-i",
            self.interface,
            "-s",
            str(self.snaplen),
            "-U",  # flush per packet so a killed capture still yields a readable file
            "-w",
            str(self.pcap_path),
        ]
        if self.bpf_filter:
            cmd.append(self.bpf_filter)

        try:
            handle = self.log_path.open("ab")
        except OSError as exc:
            session.reason = f"cannot open tcpdump log {self.log_path}: {exc}"
            LOGGER.warning(session.reason)
            return session
        try:
            session.process = subprocess.Popen(  # noqa: S603 - fixed argv, no shell
                cmd,
                stdout=handle,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            session.reason = f"failed to start tcpdump: {exc}"
            LOGGER.warning(session.reason)
            return session
        finally:
            handle.close()

        time.sleep(STARTUP_GRACE_SEC)
        if session.process.poll() is not None:
            session.reason = (
                f"tcpdump exited immediately (rc={session.process.returncode}); see {self.log_path}"
            )
            LOGGER.warning(session.reason)
            session.process = None
            return session

        session.started = True
        LOGGER.info("tcpdump capturing on '%s' -> %s", self.interface, self.pcap_path)
        return session

    def stop(self) -> PcapSession | None:
        """Stop the capture and report the resulting file (if any)."""
        session = self.session
        if session is None:
            return None
        process = session.process
        if process is not None and process.poll() is None:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGINT)
            except (OSError, AttributeError):
                process.terminate()
            try:
                process.wait(timeout=SHUTDOWN_TIMEOUT_SEC)
            except subprocess.TimeoutExpired:
                LOGGER.warning("tcpdump did not exit in time; killing it")
                with contextlib.suppress(OSError, AttributeError):
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=5)
        session.process = None
        session.started = False

        artifact = session.artifact
        if artifact is not None:
            LOGGER.info("PCAP written: %s (%d bytes)", artifact, artifact.stat().st_size)
        else:
            LOGGER.warning("no PCAP data captured at %s", session.pcap_path)
        return session

    def __enter__(self) -> PcapSession:
        return self.start()

    def __exit__(self, *_exc_info: object) -> None:
        self.stop()


def capture_on_device(
    udid: str | None = None,
    *,
    remote_path: str = "/sdcard/Download/device-capture.pcap",
) -> str:
    """Guidance for capturing *on* the device rather than on the host.

    Requires root (or a userdebug build) plus a ``tcpdump`` binary pushed to the
    device; not automated here because it modifies the device image. Returns the
    command sequence as a string for operators/docs.
    """
    target = f"-s {udid} " if udid else ""
    return (
        f"adb {target}push ./tcpdump /data/local/tmp/tcpdump\n"
        f"adb {target}shell chmod 755 /data/local/tmp/tcpdump\n"
        f"adb {target}shell su -c '/data/local/tmp/tcpdump -i any -s 0 -w {remote_path}'\n"
        f"adb {target}pull {remote_path} ./artifacts/\n"
        "# Requires a rooted / userdebug device; host-side capture is preferred."
    )
