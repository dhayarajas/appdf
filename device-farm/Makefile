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
	collect validate clean

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

emulator: ## Boot a headless root-capable Android emulator (needs KVM)
	bash $(FARM_DIR)/scripts/emulator_up.sh

emulator-down: ## Shut the emulator down
	bash $(FARM_DIR)/scripts/emulator_up.sh --stop

install-ca: ## Install the mitmproxy CA into the device system trust store (rooted only)
	bash $(FARM_DIR)/scripts/install_system_ca.sh

har: ## Install the app under test, drive it, and assert on the exported HAR
	cd $(FARM_DIR) && DEVICE_FARM_ENABLE_PROXY=1 DEVICE_FARM_ENABLE_DEVICE_PROXY=1 \
		$(PYTHON) -m pytest tests/test_app_traffic_har.py $(PYTEST_ARGS)

smoke: ## Hardware-free end-to-end self-check of the scaffold
	bash $(FARM_DIR)/scripts/local_smoke_test.sh

collect: ## Hardware-free check: collect tests only
	cd $(FARM_DIR) && $(PYTHON) -m pytest --collect-only -q

validate: ## Validate the artifact structure of the most recent run
	$(PYTHON) $(FARM_DIR)/scripts/validate_run.py --latest --artifacts-root $(ARTIFACTS_ROOT)

clean: ## Remove artifacts and Python caches
	rm -rf $(ARTIFACTS_ROOT)
	find $(FARM_DIR) -name '__pycache__' -type d -prune -exec rm -rf {} +
	rm -rf $(FARM_DIR)/.pytest_cache
