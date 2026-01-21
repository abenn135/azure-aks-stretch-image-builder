# =============================================================================
# Makefile for AKS Stretch Image Builder (Local Chroot Build)
# =============================================================================
#
# This Makefile provides local development targets for testing the image
# build process. The actual CI/CD build runs via GitHub Actions.
#
# Usage:
#   make help                    - Show this help message
#   make lint                    - Lint shell scripts
#   make test-script             - Test install script syntax
#   make clean                   - Clean up generated files
#
# Note: Full image builds require Azure credentials and should be run
# via the GitHub Actions workflow (workflow_dispatch).
# =============================================================================

SCRIPTS_DIR := scripts

.PHONY: help lint test-script clean

help: ## Show this help message
	@echo "AKS Stretch Image Builder - Local Development Targets"
	@echo ""
	@echo "Note: Full image builds run via GitHub Actions workflow_dispatch."
	@echo "These targets are for local development and testing only."
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

lint: ## Lint shell scripts with shellcheck (if available)
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck on scripts..."; \
		shellcheck $(SCRIPTS_DIR)/*.sh; \
	else \
		echo "shellcheck not installed, skipping lint"; \
	fi

test-script: ## Test install script for syntax errors
	@echo "Checking script syntax..."
	@bash -n $(SCRIPTS_DIR)/install-packages.sh && echo "Syntax OK: install-packages.sh"

clean: ## Clean up generated files
	rm -f *.log
	rm -rf /tmp/vhd-work || true
