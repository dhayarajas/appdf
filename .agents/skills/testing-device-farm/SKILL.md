---
name: testing-device-farm
description: How to set up and verify the device-farm/ Appium + Pytest scaffold on a host with no phone, emulator, adb, or Appium attached (zero-device CI-style verification).
---

# Testing the `device-farm/` scaffold with zero devices

The scaffold is CLI-only — there is no web UI, so verification is shell-based and
screen recording is not useful.

## Setup (2 minutes)

```bash
cd device-farm
python3 -m venv .venv
.venv/bin/python -m pip install -q --upgrade pip
.venv/bin/python -m pip install -q -e .      # Appium client, pytest, xdist, mitmproxy, requests
```

Notes:
- `run_e2e_farm.sh` and the `Makefile` auto-prefer `device-farm/.venv/bin/python`, so creating the
  venv is all that is needed; no activation required.
- `mitmdump` lands in `.venv/bin`, which is NOT on PATH for subprocess lookups. `mitmdump_available()`
  uses `shutil.which`, so pytest/preflight report `mitmdump=no` unless you export
  `PATH="$PWD/.venv/bin:$PATH"`. Do that when you want the proxy/HAR path exercised.
- `tcpdump` and `adb` are typically absent on the box; that is the intended degradation scenario —
  do NOT install them or attach/emulate a device when the point is graceful degradation.

## Useful commands

```bash
.venv/bin/python -m pytest --collect-only -q                 # 15 tests as of PR #7 (grows over time)
bash scripts/provision_host.sh --check                       # preflight; exits 1 when adb/appium missing
DEVICE_FARM_DRY_RUN=1 DEVICE_FARM_TEST_RUN_ID=r1 bash run_e2e_farm.sh
DEVICE_FARM_TEST_RUN_ID=r2 bash run_e2e_farm.sh              # non-dry, zero devices -> skips
.venv/bin/python scripts/validate_run.py --latest
make preflight collect validate clean
```

Extra CLI args to `run_e2e_farm.sh` are forwarded to pytest (`-k`, a test path, ...). Passing an
external failing test file is a good way to prove the exit code is not hardcoded to 0.

## Gotchas discovered

- `scripts/provision_host.sh --check` exits 1 on an unprovisioned host (missing adb/Appium/Android
  SDK count as MISSING, not warnings; only *devices* are warning-only). `make preflight` and
  `run_e2e_farm.sh` deliberately tolerate that non-zero exit.
- Always check the real shell exit code, not just the `[e2e]` summary block; the summary prints
  `pytest exit : not run` when a run aborts before pytest starts.
- `pytest --collect-only` / `make collect` intentionally create no `artifacts/` tree, so `make
  validate` (`--latest`) still points at the last real run.
- Leak check after every run: `pgrep -fa 'mitmdump|appium|tcpdump'` — beware that your own
  `bash -c ...` command string matches the pattern, so ignore self-matches.

## Verifying `scripts/emulator_up.sh` without KVM, an emulator, or a Mac

`--check` is the only mode safe to run on a bare box; it never boots. On a typical Devin box
`/dev/kvm` exists but is not writable and the user is not in group `kvm`, so the Linux path prints
`accel    : kvm unwritable`, the `grant KVM access: sudo usermod -aG kvm ...` hint, and exits 1.
`--stop` exits 0 (`emulator-5554 is not running`) and `--help` prints the header block.

The macOS branch can be exercised on Linux by stubbing the host probes on PATH — no Mac needed:

```bash
# uname stub: echo Darwin for -s, $FAKE_ARCH for -m; sg stub: print a loud TRAP and exit 99
env -i PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" FAKE_ARCH=arm64 \
  bash ./scripts/emulator_up.sh --check
```

Tips:
- Use `env -i` so a real `ANDROID_SDK_ROOT`/`ANDROID_HOME` cannot leak and mask the
  `$HOME/Library/Android/sdk` default; the fake HOME then proves the Darwin SDK-root default.
- Prove the Linux-only KVM logic is really skipped with `strace -f -qq -e trace=%file -o trace.log`
  and `grep -c /dev/kvm trace.log` (want 0 on the Darwin path). Run the same trace on the real Linux
  path as a control — it must be > 0, otherwise the assertion is vacuous.
- A `sg` stub that exits 99 with a loud message is a cheap trap for the `with_kvm` Darwin skip.
- To reach `status : ready to boot` on the stub host, drop executable stubs at
  `${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager` (exit 0) and, for the advisory `degraded` accel
  state, `${SDK_ROOT}/emulator/emulator` that exits non-zero for `-accel-check`.
- Always run the `origin/main` version of the script (`git show origin/main:path > scripts/_old.sh`)
  through the identical stub environment as a negative control; if old and new behave the same, the
  test proves nothing. Delete the temp copy afterwards.

## Proving the tracing path really works (no device needed)

Start `ProxyManager(har_path=...)` with `.venv/bin` on PATH, then drive real traffic through it and
assert the HAR is non-empty:

```python
r = requests.get("http://example.com/", proxies={"http": f"http://127.0.0.1:{sess.port}"})
# after mgr.stop(): json.loads(har.read_text())["log"]["entries"] must be non-empty
```

## Devin Secrets Needed

None.
