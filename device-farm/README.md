# Self-Hosted Mobile Device Farm + E2E Test Scaffold

A self-contained scaffold for running Appium-based end-to-end tests against a
self-hosted pool of Android (and, on macOS, iOS) devices, with per-session
network interception (HAR) and packet capture (PCAP).

> **Scope note.** This directory is a scaffold/design deliverable. Every
> hardware-dependent code path (adb, Appium, mitmdump, tcpdump) is
> feature-flagged and degrades gracefully: modules import, tests collect, and
> the orchestration entrypoint exits cleanly with a summary when **zero devices
> are attached**. Nothing here assumes live hardware.

## Phases

| Phase | Concern | Entry points |
| --- | --- | --- |
| 1 | Host & device farm provisioning | `scripts/provision_host.sh`, `config/appium-device-farm.config.json`, `docs/udev-rules.md` |
| 2 | Network interception / trace pipeline | `proxy/proxy_manager.py`, `capture/pcap_capture.py` |
| 3 | Pytest E2E framework | `pyproject.toml`, `tests/conftest.py`, `tests/test_sample_workflow.py`, `framework/` |
| 4 | Verification & orchestration | `run_e2e_farm.sh`, `Makefile`, `scripts/validate_run.py` |

### Phase 1 — Host & device farm provisioning

`scripts/provision_host.sh` is idempotent: it detects Node.js LTS, OpenJDK 17+,
Python 3.11+, Android platform-tools and Appium 2.x, installs what it can, and
otherwise prints copy-pasteable install guidance. It then verifies `adb`,
`appium` and the required environment variables, and installs the Appium
drivers (`uiautomator2` always; `xcuitest` only when `uname` reports `Darwin`).
A missing/absent device is reported as a warning, never a hard failure.

Plugin platform selection, session limits, and dashboard enablement live in
`config/appium-device-farm.config.json`, consumed by the
[`appium-device-farm`](https://github.com/AppiumTestDistribution/appium-device-farm)
plugin.

The checked-in configuration defaults to Android with `"platform": "android"`.
Driver selection belongs to the launcher rather than this file:
`run_e2e_farm.sh` passes `--use-drivers=uiautomator2` explicitly. This keeps the
configuration from silently removing iOS support on macOS hosts.

The checked-in plugin configuration contains only keys accepted by the installed
plugin schema. Devices are discovered dynamically through `adb` / `xcdevice`;
the plugin's include/exclude pool controls, allocation strategy, and health-check
settings are not schema-supported configuration options. `maxSessions` bounds
Appium-side concurrency, while the pytest-xdist worker count remains
`min(discovered devices, DEVICE_FARM_MAX_PARALLEL)`. Dashboard support is enabled
with the plugin's default `/device-farm` path.

The previous draft also used unsupported `android-device-type`,
`ios-device-type`, `derived-data-path`, `skip-chrome-download`,
`device-availability-timeout-ms`, `device-retry-interval-ms`, `max-sessions`,
`remote-connection-timeout-ms`, `bind-hostport`, `sendNodeDevicesToHub`, `pool`,
`parallel`, `allocation`, `healthChecks`, and `dashboard` keys, plus null-valued
`hub` and `cloud` options. The valid camelCase equivalents are retained where
the schema provides them; the remaining options are intentionally omitted.

On macOS, after installing Xcode and the Appium `xcuitest` driver, change the
`server.plugin.device-farm.platform` to `"ios"` for iOS-only discovery or
`"both"` for Android and iOS discovery. The installed plugin also exposes these
settings as `--plugin-device-farm-platform=ios` and
`--plugin-device-farm-platform=both`. Its schema has no environment-variable
mapping; the only platform-independent plugin environment variable found in
the installed runtime is `DEVICE_FARM_HOME`, which controls metadata storage.
Driver selection is still owned by the launcher, so an iOS or combined run must
select `xcuitest` there alongside `uiautomator2`.

### Phase 2 — Network interception / trace pipeline

Each test session gets its own `mitmdump` instance on a dynamically allocated
port writing a HAR file, plus an optional `tcpdump` capture. Device proxy
settings are applied with `adb shell settings put global http_proxy <ip>:<port>`
and reset afterwards. HTTPS bodies require the mitmproxy CA to be trusted on
the device (a manual, per-device step) and are still unreadable for
certificate-pinned traffic — see the docstrings in `proxy/proxy_manager.py`.

### Phase 3 — Pytest E2E framework

`tests/conftest.py` implements the session lifecycle:

- **Allocate** — build UiAutomator2 capabilities and request a device from the
  device-farm pool; `skip` with an informative message when the pool is empty
  or unreachable.
- **Pre-test** — start the session-isolated proxy, begin PCAP capture, install
  the target build (`.apk` / `.ipa`) when one is configured.
- **Post-test** — stop capture, dump `.har` / `.pcap` tagged with test id and
  timestamp, collect `logcat` / syslog, reset device state, close the session.

### Phase 4 — Verification & orchestration

`run_e2e_farm.sh` runs preflight checks, starts Appium with the device-farm
plugin, runs pytest in parallel (`-n` sized by the number of discovered
devices), tears everything down, and prints a run summary. Artifacts land in
`artifacts/{test_run_id}/`; `scripts/validate_run.py` asserts the expected
structure exists.

```
artifacts/<test_run_id>/
├── reports/     # junit xml, pytest output
├── logs/        # appium.log, logcat/syslog per test
└── traces/      # <test-id>-<timestamp>.har / .pcap
```

## Component diagram

```mermaid
flowchart TB
    subgraph Orchestration
        RUN[run_e2e_farm.sh]
        MAKE[Makefile]
        VALIDATE[scripts/validate_run.py]
    end

    subgraph PytestFramework["Pytest E2E framework"]
        CONFTEST[tests/conftest.py fixtures]
        TESTS[tests/test_sample_workflow.py]
        FRAMEWORK[framework: config, capabilities, artifacts]
    end

    subgraph TracePipeline["Trace pipeline"]
        PROXY[proxy_manager: mitmdump to HAR]
        PCAP[pcap_capture: tcpdump to PCAP]
    end

    subgraph Host["Self-hosted host"]
        APPIUM[Appium 2.x server]
        PLUGIN[appium-device-farm plugin]
        ADB[adb / platform-tools]
    end

    subgraph DevicePool["Device pool"]
        D1[Android device or emulator]
        D2[iOS device - macOS hosts only]
    end

    ARTIFACTS[(artifacts/test_run_id)]

    MAKE --> RUN
    RUN --> APPIUM
    RUN --> CONFTEST
    RUN --> VALIDATE
    CONFTEST --> FRAMEWORK
    CONFTEST --> TESTS
    CONFTEST --> PROXY
    CONFTEST --> PCAP
    CONFTEST --> APPIUM
    APPIUM --> PLUGIN
    PLUGIN --> ADB
    ADB --> D1
    PLUGIN --> D2
    PROXY -.proxy settings via adb.-> D1
    PCAP --> ARTIFACTS
    PROXY --> ARTIFACTS
    CONFTEST --> ARTIFACTS
    VALIDATE --> ARTIFACTS
```

## Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| Node.js | LTS (18 / 20 / 22) | Runtime for Appium 2.x and its plugins |
| OpenJDK | 17+ | Required by UiAutomator2 / Android tooling |
| Python | 3.11+ | Test framework and trace pipeline |
| Android SDK platform-tools | latest | `adb`, `sdkmanager` |
| Appium | 2.x | `npm i -g appium`, plus `uiautomator2` (and `xcuitest` on macOS) |
| mitmproxy | 10+ | `mitmdump` for HAR capture |
| tcpdump | any | Optional; needs root/CAP_NET_RAW for PCAP capture |
| Xcode + `xcuitest` driver | latest | macOS hosts only, for iOS devices |

Environment variables:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"          # or /usr/lib/android-sdk
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/tools:$JAVA_HOME/bin:$PATH"
```

`ANDROID_SDK_ROOT` is accepted as a fallback for `ANDROID_HOME`.

## Quick start

```bash
cd device-farm

make provision           # Phase 1: install/verify host toolchain
make preflight           # non-destructive environment report (never fails on missing devices)
make test                # Phase 4: full orchestrated run
make clean               # remove artifacts/

# Hardware-free dry run (used in CI):
DEVICE_FARM_DRY_RUN=1 ./run_e2e_farm.sh
python scripts/validate_run.py --run-id <test_run_id>
```

### Testing locally without a device

`make smoke` (`scripts/local_smoke_test.sh`) is the one-command local check: it
creates `.venv` if needed, then verifies imports, `pytest --collect-only`, shell
syntax, the plugin JSON, preflight, dry-run and zero-device orchestration,
artifact validation, malformed-env handling, and the mitmdump/HAR pipeline
against real HTTP traffic. Missing adb/Appium/tcpdump and absent devices are
reported, never fatal; generated artifacts are removed unless `--keep` is
passed. It exits non-zero only if a check genuinely fails.

```bash
./scripts/local_smoke_test.sh            # full check, cleans up after itself
./scripts/local_smoke_test.sh --keep     # keep the artifacts it produced
./scripts/local_smoke_test.sh --no-venv  # use the active interpreter instead of .venv
python scripts/smoke_proxy_probe.py      # just the proxy/HAR probe
```

### Launching Appium with the device-farm plugin

```bash
npm i -g appium
appium plugin install --source=npm appium-device-farm
appium driver install uiautomator2
# macOS only:
appium driver install xcuitest

appium server \
  --use-plugins=device-farm \
  --plugin-device-farm-platform=android \
  --config config/appium-device-farm.config.json \
  --port 4723 \
  --allow-cors
```

The plugin dashboard is served at `http://<host>:4723/device-farm/`. Point tests
at `http://<host>:4723/wd/hub` (or `/` for Appium 2 defaults) and the plugin
allocates a free device from the pool per session.

## App install + HAR capture (the end-to-end flow)

This is the flow that installs a real app, drives it through Appium, and exports
its network traffic as a HAR. It runs on a local Android emulator (no physical
hardware needed) and identically on a physical device.

```mermaid
sequenceDiagram
    participant Dev as run_e2e_farm.sh / pytest
    participant Emu as scripts/emulator_up.sh
    participant CA as scripts/install_system_ca.sh
    participant Proxy as proxy_manager (mitmdump)
    participant Appium as Appium + uiautomator2
    participant Device as Android device / AVD
    participant App as App under test
    participant Art as artifacts/run_id/traces

    Emu->>Device: boot AVD (-writable-system), wait sys.boot_completed
    CA->>Device: push mitmproxy CA into the system trust store
    Dev->>Proxy: start mitmdump on a free port, HAR path per test
    Dev->>Device: adb settings put global http_proxy 10.0.2.2:port
    Dev->>Appium: create session with app + UiAutomator2 caps
    Appium->>Device: install .apk, launch activity
    App->>Proxy: HTTPS requests (CA trusted, so decrypted)
    Proxy->>App: upstream responses
    Dev->>Proxy: stop -> mitmdump flushes the HAR
    Proxy->>Art: <test-id>-<timestamp>.har
    Dev->>Device: clear proxy, uninstall, collect logcat
```

### Android emulator (no hardware)

```bash
./scripts/emulator_up.sh --check          # accelerator, SDK, AVD readiness (never boots)
make emulator                             # boot headless AVD, wait for boot_completed
make install-ca                           # mitmproxy CA -> system store (rooted AVD only)

DEVICE_FARM_ENABLE_PROXY=1 \
DEVICE_FARM_ENABLE_DEVICE_PROXY=1 \
DEVICE_FARM_APP_PATH=/path/to/app.apk \
DEVICE_FARM_APP_PACKAGE=com.example.app \
DEVICE_FARM_APP_ACTIVITY=.MainActivity \
  make har                                # install, drive, assert on the exported HAR

make emulator-down
```

`tests/test_app_traffic_har.py` asserts that the HAR exists, has entries, and
that HTTPS entries were actually decrypted — every assertion message names the
likely cause (proxy not applied, CA not trusted, pinned app). Verified on this
scaffold with an Android 14 AOSP AVD and F-Droid: 6 decrypted HTTPS entries
across 3 hosts.

#### macOS host

macOS has no `/dev/kvm`: the Android emulator uses Apple's
Hypervisor.framework, which needs no user setup beyond a recent `emulator`
package, so `./scripts/emulator_up.sh --check` reports `ready to boot` once the
SDK and AVD are in place. A failing `emulator -accel-check` is reported as a
warning, never as a blocked preflight. Recommended environment:

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"   # Android Studio default, also the script's fallback
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
```

On Apple Silicon the script defaults `AVD_ABI` to `arm64-v8a` (Intel Macs keep
`x86_64`); override with `DEVICE_FARM_AVD_ABI`. Everything after boot —
`make install-ca`, `make har`, `make emulator-down` — is identical to Linux.

### Physical Android device

1. Enable Developer options → USB debugging, connect USB, accept the RSA prompt;
   confirm with `adb devices` (see `docs/udev-rules.md` for Linux udev rules).
2. Put host and phone on the same network. The device cannot use `10.0.2.2`, so
   `proxy_host_for_device()` sends it the host's LAN IP automatically; override
   with `DEVICE_FARM_HOST_IP` if the host has several interfaces.
3. Trust the CA. On a non-rooted phone the mitmproxy CA can only be installed as
   a *user* certificate (Settings → Security → Encryption & credentials → Install
   a certificate → CA certificate, from `http://mitm.it`). Android 7+ apps ignore
   user CAs unless the app opts in via `network_security_config`, so a non-rooted
   phone yields decrypted HTTPS only for apps you build with that opt-in.
   `scripts/install_system_ca.sh` refuses to run on a device without root rather
   than pretending the CA is trusted.
4. Run the same command as above; the fixtures are identical.

### iOS

iOS requires a macOS host with Xcode and the `xcuitest` driver
(`provision_host.sh` installs it only when `uname` reports Darwin), so it cannot
run on this Linux host. On macOS the flow is the same except: set
`DEVICE_FARM_PLATFORM=iOS` and `DEVICE_FARM_APP_PATH=<app>.app|.ipa`; there is no
`adb`, so the proxy is set in Settings → Wi-Fi → Configure Proxy (or in the
simulator, the host's system proxy), and the CA is trusted under Settings →
General → About → Certificate Trust Settings. Everything else — HAR/PCAP
naming, artifacts, fixtures — is shared.

### Pinned vs unpinned apps

| App | Result |
| --- | --- |
| No pinning, CA in the system store | Full HAR with headers and bodies |
| No pinning, CA only as a user cert | Decrypted only for apps opting in via `network_security_config` |
| Certificate pinning | Handshake fails: no HAR entry or `status == 0`. `HarEntry.decrypted` stays `False`, so a pinned app can never be misread as decrypted |

For a pinned app you own: add a debug-only `network_security_config` trusting
user CAs, or test a debuggable build. Otherwise capture PCAP
(`DEVICE_FARM_ENABLE_PCAP=1`) for connection-level evidence — endpoints and
timing, no plaintext.

## Configuration

All settings are environment variables (see `framework/config.py`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `DEVICE_FARM_APPIUM_URL` | `http://127.0.0.1:4723` | Appium server base URL |
| `DEVICE_FARM_TEST_RUN_ID` | generated timestamp | Artifact directory name |
| `DEVICE_FARM_ARTIFACTS_ROOT` | `<device-farm>/artifacts` | Artifact root |
| `DEVICE_FARM_APP_PATH` | unset | `.apk` / `.ipa` to install |
| `DEVICE_FARM_PLATFORM` | `Android` | `Android` or `iOS` |
| `DEVICE_FARM_DRY_RUN` | `0` | `1` = never touch hardware; tests skip |
| `DEVICE_FARM_ENABLE_PROXY` | `1` | Feature flag for mitmdump/HAR |
| `DEVICE_FARM_ENABLE_PCAP` | `0` | Feature flag for tcpdump/PCAP (needs root) |
| `DEVICE_FARM_ENABLE_DEVICE_PROXY` | `0` | Apply proxy settings on the device via adb |
| `DEVICE_FARM_CAPTURE_INTERFACE` | `any` | tcpdump interface |
| `DEVICE_FARM_MAX_PARALLEL` | `4` | Upper bound for pytest-xdist workers |
| `DEVICE_FARM_HOST_IP` | auto-detected | Host address a physical device should reach the proxy on |
| `DEVICE_FARM_AVD_NAME` | `farm34` | AVD used by `scripts/emulator_up.sh` |
| `DEVICE_FARM_AVD_API` | `34` | Emulator API level (also selects build-tools) |

## Troubleshooting

- **`adb devices` lists nothing** — check USB debugging, cable, and udev rules
  (`docs/udev-rules.md`). Tests skip with a message instead of failing.
- **`unauthorized` device** — accept the RSA prompt on the device screen, then
  `adb kill-server && adb start-server`.
- **Empty HAR** — mitmproxy CA not trusted on the device, or the app pins
  certificates. Only plaintext/metadata is captured in that case.
- **tcpdump permission denied** — run with root or grant
  `sudo setcap cap_net_raw,cap_net_admin=eip $(command -v tcpdump)`; otherwise
  leave `DEVICE_FARM_ENABLE_PCAP=0`.
- **Appium port in use** — override with `DEVICE_FARM_APPIUM_PORT`.
- **`Cannot verify the signature of <app>.apk` / `apksigner.jar` not found** —
  install Android build-tools (`sdkmanager "build-tools;34.0.0"`);
  `scripts/emulator_up.sh` installs them for you.
- **`Could not find a driver for automationName 'UiAutomator2'` with a
  `p-limit` ESM error** — a broken dependency combination in the installed
  Appium/uiautomator2 pair, not a config problem. Reinstall the driver
  (`appium driver uninstall uiautomator2 && appium driver install uiautomator2`)
  and, if it persists, pin a driver release known to work with your Appium
  version. The fixtures surface the server error verbatim and skip.
- **System CA disappears after an emulator reboot** — the Conscrypt bind mount
  is not persistent; re-run `scripts/install_system_ca.sh`.
