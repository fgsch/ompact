.DEFAULT_GOAL := help

ENVIRONMENTS ?=
BUILD_ARGS := $(if $(strip $(ENVIRONMENTS)),$(ENVIRONMENTS))

.PHONY: help build test runtime-test syntax lint check smoke

help: ## Show available targets
	@awk 'BEGIN { FS = ":.*## " } \
		/^[[:alnum:]_-]+:.*## / { printf "\033[36m%-30s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)

build: ## Build ompact
	./build.sh $(BUILD_ARGS)

test: ## Run repository tests
	./tests/build.sh.test
	./tests/env.test
	./tests/update-omp.test

runtime-test: ## Run tests against ./ompact
	./tests/runtime.test

syntax: ## Check shell syntax
	bash -n build.sh scripts/*.sh tests/*.test
	sh -n env/*.sh

lint: ## Run ShellCheck
	shellcheck build.sh scripts/*.sh tests/*.test env/*.sh
check: syntax lint test ## Run syntax, lint, and build tests

smoke: build runtime-test ## Build ompact and run the runtime test
