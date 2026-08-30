# Self-hosted mobile device farm - developer entrypoints.
# All targets are safe to run without any device attached.

SHELL := /usr/bin/env bash
FARM_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
VENV := $(FARM_DIR)/.venv
PYTHON ?= $(if $(wildcard $(VENV)/bin/python),$(VENV)/bin/python,python3)
ARTIFACTS_ROOT ?= $(FARM_DIR)/artifacts
PYTEST_ARGS ?=

.DEFAULT_GOAL := help
.PHONY: help provision preflight install test smoke har emulator emulator-down install-ca \
	simulator simulator-down farm farm-check farm-down debug debug-android debug-ios \
	export-har list-runs check-har fix-har collect validate clean

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

provision: ## Phase 1: install/verify the host toolchain (idempotent)
	bash $(FARM_DIR)/scripts/provision_host.sh

preflight: ## Verify the environment without installing anything (never fatal)
	bash $(FARM_DIR)/scripts/provision_host.sh --check \
		|| echo "[make] preflight reported missing components; see the summary above (non-fatal)"

install: ## Create .venv and install Python dependencies
	python3 -m venv $(VENV)
	$(VENV)/bin/python -m pip install --upgrade pip
	$(VENV)/bin/python -m pip install -e $(FARM_DIR)

test: ## Phase 4: orchestrated E2E run (Appium + pytest + traces)
	bash $(FARM_DIR)/run_e2e_farm.sh $(PYTEST_ARGS)

emulator: ## Boot a headless root-capable Android emulator (KVM on Linux, Hypervisor.framework on macOS)
	bash $(FARM_DIR)/scripts/emulator_up.sh

emulator-down: ## Shut the emulator down
	bash $(FARM_DIR)/scripts/emulator_up.sh --stop

simulator: ## Boot a simulator (iOS simctl on macOS, Android emulator elsewhere)
	bash $(FARM_DIR)/scripts/simulator_up.sh $(SIM_ARGS)

simulator-down: ## Shut the simulator down
	bash $(FARM_DIR)/scripts/simulator_up.sh --stop $(SIM_ARGS)

farm: ## Dashboard + shared interception proxy for every attached device/simulator
	bash $(FARM_DIR)/scripts/farm_up.sh $(FARM_ARGS)

farm-check: ## Report farm tooling and device/simulator inventory only
	bash $(FARM_DIR)/scripts/farm_up.sh --check $(FARM_ARGS)

farm-down: ## Clear proxies left behind by an interrupted farm run
	bash $(FARM_DIR)/scripts/farm_up.sh --stop $(FARM_ARGS)

install-ca: ## Install the mitmproxy CA into the device system trust store (rooted only)
	bash $(FARM_DIR)/scripts/install_system_ca.sh

debug: ## Manual traffic debugging on the attached device (auto-detect platform)
	bash $(FARM_DIR)/scripts/debug_traffic.sh $(DEBUG_ARGS)

debug-android: ## Manual traffic debugging on an attached Android device
	bash $(FARM_DIR)/scripts/debug_traffic.sh --platform android $(DEBUG_ARGS)

debug-ios: ## Manual traffic debugging on an attached iPhone/iPad
	bash $(FARM_DIR)/scripts/debug_traffic.sh --platform ios $(DEBUG_ARGS)

har: ## Install the app under test, drive it, and assert on the exported HAR
	cd $(FARM_DIR) && DEVICE_FARM_ENABLE_PROXY=1 DEVICE_FARM_ENABLE_DEVICE_PROXY=1 \
		$(PYTHON) -m pytest tests/test_app_traffic_har.py $(PYTEST_ARGS)

smoke: ## Hardware-free end-to-end self-check of the scaffold
	bash $(FARM_DIR)/scripts/local_smoke_test.sh

collect: ## Hardware-free check: collect tests only
	cd $(FARM_DIR) && $(PYTHON) -m pytest --collect-only -q

export-har: ## Export the newest captured run to a HAR (HAR_ARGS='--out ~/Desktop/x.har')
	bash $(FARM_DIR)/scripts/export_har.sh $(HAR_ARGS)

list-runs: ## List runs that captured traffic and can be exported
	bash $(FARM_DIR)/scripts/export_har.sh --list

check-har: ## Say why a strict reader (Chrome DevTools) refuses a HAR (HAR=path)
	bash $(FARM_DIR)/scripts/export_har.sh --check $(HAR)

fix-har: ## Repair an already-exported HAR in place (HAR=path)
	$(PYTHON) $(FARM_DIR)/proxy/har_repair.py $(HAR)

validate: ## Validate the artifact structure of the most recent run
	$(PYTHON) $(FARM_DIR)/scripts/validate_run.py --latest --artifacts-root $(ARTIFACTS_ROOT)

clean: ## Remove artifacts and Python caches
	rm -rf $(ARTIFACTS_ROOT)
	find $(FARM_DIR) -name '__pycache__' -type d -prune -exec rm -rf {} +
	rm -rf $(FARM_DIR)/.pytest_cache
