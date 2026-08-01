# Purpose: single check entry point for this repository. `make ci` runs every
# check the project defines and exits non-zero if any of them fails. A check
# whose input is not present yet, or that needs a running stack when the stack
# is down, is skipped with a named report. A skip is never reported as a pass.
# Each check is also a target you can run on its own.
# @agents-index: Root Makefile whose `make ci` runs every repository check and honestly skips checks it cannot run.

# Use bash so the recipes can use arrays and shopt for safe file globbing.
SHELL := /bin/bash

# The pinned edge image used to validate the proxy configuration without a
# local install of the proxy. Kept in sync with the compose file.
HAPROXY_IMAGE := haproxy:3.4.2-trixie

# Path to the proxy configuration, present once the stack is ported.
HAPROXY_CFG := stack/haproxy/haproxy.cfg

# The compose network the proxy configuration resolves its backend names on.
COMPOSE_NETWORK := agent-observability_otel

# Show the target list when make runs with no argument.
.DEFAULT_GOAL := help

.PHONY: help ci check-compose check-haproxy check-selftest lint-scripts verify

help: ## Show this target list
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

ci: check-selftest check-compose check-haproxy lint-scripts verify ## Run every check; skip what cannot run and never pass a skip
	@echo "ci: all checks complete"

check-compose: ## Validate the compose file, or skip when it is not present yet
	@if [ -f compose.yaml ]; then \
		echo "check-compose: validating compose.yaml"; \
		docker compose config >/dev/null \
			&& echo "check-compose: PASS" \
			|| { echo "check-compose: FAIL (run 'docker compose config' to see the error)"; exit 1; }; \
	else \
		echo "check-compose: SKIP (compose.yaml not present yet)"; \
	fi

# The proxy configuration names backends by compose service name, and one of
# them is a syslog target. Those names resolve only on the compose network, so
# a standalone validation reports a fatal address error for a configuration
# that is in fact correct. The check therefore joins the compose network. When
# that network does not exist, the stack has never started and the check is
# skipped with a named report rather than reported as a pass.
check-haproxy: ## Validate the proxy config on the compose network, or skip when it cannot run
	@if [ ! -f "$(HAPROXY_CFG)" ]; then \
		echo "check-haproxy: SKIP ($(HAPROXY_CFG) not present yet)"; \
	else \
		net=$$(docker network ls --format '{{.Name}}' | grep -x "$(COMPOSE_NETWORK)" | head -1); \
		if [ -z "$$net" ]; then \
			echo "check-haproxy: SKIP (network $(COMPOSE_NETWORK) absent; start the stack with scripts/stack.up.sh)"; \
		else \
			echo "check-haproxy: validating $(HAPROXY_CFG) in $(HAPROXY_IMAGE) on $$net"; \
			docker run --rm --network "$$net" \
				-v "$$PWD/$(HAPROXY_CFG):/tmp/haproxy.cfg:ro" \
				$(HAPROXY_IMAGE) haproxy -c -f /tmp/haproxy.cfg \
				&& echo "check-haproxy: PASS" \
				|| { echo "check-haproxy: FAIL (the proxy configuration is not valid)"; exit 1; }; \
		fi; \
	fi

lint-scripts: ## Shell-lint every script under scripts/, or skip when there are none
	@shopt -s nullglob; \
	files=(scripts/*.sh); \
	if [ $${#files[@]} -eq 0 ]; then \
		echo "lint-scripts: SKIP (no scripts under scripts/ yet)"; \
	else \
		echo "lint-scripts: shellcheck $${files[*]}"; \
		shellcheck "$${files[@]}" \
			&& echo "lint-scripts: PASS" \
			|| { echo "lint-scripts: FAIL (fix the reported shellcheck findings)"; exit 1; }; \
	fi

verify: ## Run every verification script; skip when none exist or the stack is down
	@shopt -s nullglob; \
	scripts=(scripts/*.verify.sh); \
	if [ $${#scripts[@]} -eq 0 ]; then \
		echo "verify: SKIP (no verification scripts present yet)"; \
	elif ! docker compose ps --status running -q 2>/dev/null | grep -q .; then \
		echo "verify: SKIP (stack is not running; start it with scripts/stack.up.sh)"; \
	else \
		for s in "$${scripts[@]}"; do \
			echo "verify: running $$s"; \
			bash "$$s" || { echo "verify: FAIL ($$s exited non-zero)"; exit 1; }; \
		done; \
		echo "verify: PASS"; \
	fi

# Self-test: prove that a failing check actually fails the build. A check that
# cannot fail is worse than no check, because it reports confidence it has not
# earned.
check-selftest: ## Prove the check harness reports a failure as a failure
	@echo "check-selftest: asserting a failing check exits non-zero"
	@if $(MAKE) --no-print-directory _selftest-failing-check >/dev/null 2>&1; then \
		echo "check-selftest: FAIL (a failing check reported success)"; exit 1; \
	else \
		echo "check-selftest: PASS"; \
	fi

.PHONY: _selftest-failing-check
_selftest-failing-check:
	@false && echo "PASS" || { echo "FAIL"; exit 1; }
