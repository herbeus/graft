# graft - development tasks. No build step: bin/graft runs from the checkout.
SHELL := /bin/bash
SH_FILES := bin/graft $(wildcard lib/*.sh) install.sh uninstall.sh $(wildcard tests/helpers/*.bash)
FMT_FLAGS := -bn

.PHONY: help lint fmt fmt-check test check install uninstall

help: ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

lint: ## shellcheck everything
	@shellcheck -s bash -S style $(SH_FILES) && echo "shellcheck: clean"

fmt: ## reformat in place
	@shfmt -w $(FMT_FLAGS) $(SH_FILES) && echo "shfmt: formatted"

fmt-check: ## fail if formatting is off
	@shfmt -d $(FMT_FLAGS) $(SH_FILES) && echo "shfmt: clean"

test: ## run the bats suite
	@bats --print-output-on-failure tests/

check: lint fmt-check test ## everything CI runs

install: ## link bin/graft into ~/.local/bin
	@./install.sh

uninstall: ## remove that link
	@./uninstall.sh
