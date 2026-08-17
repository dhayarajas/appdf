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
.venv/bin/python -m pytest --collect-only -q                 # expect 6 tests
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

## Proving the tracing path really works (no device needed)

Start `ProxyManager(har_path=...)` with `.venv/bin` on PATH, then drive real traffic through it and
assert the HAR is non-empty:

```python
r = requests.get("http://example.com/", proxies={"http": f"http://127.0.0.1:{sess.port}"})
# after mgr.stop(): json.loads(har.read_text())["log"]["entries"] must be non-empty
```

## Devin Secrets Needed

None.
