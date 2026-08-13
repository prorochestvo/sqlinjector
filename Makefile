SHELL := /bin/bash

GOLANGCI_VERSION := v2.12.2
# Revision the adoption gate compares against: only code newer than this is
# required to be clean while the standing findings are worked off.
LINT_BASE ?= origin/main

.PHONY: test lint lint-new format tidy

## test: vet and run the suite with the race detector
test: format
	CGO_ENABLED=0 go vet ./...
	CGO_ENABLED=0 go test -race ./...

## lint: golangci-lint over the whole tree, then the text-level review checks
lint:
	@command -v golangci-lint >/dev/null 2>&1 || { \
		echo "golangci-lint not found — install $(GOLANGCI_VERSION): https://golangci-lint.run/docs/welcome/install/local/"; \
		exit 1; \
	}
	CGO_ENABLED=0 golangci-lint run ./...
	@scripts/lint-checks.sh

## lint-new: lint only code changed since $(LINT_BASE); this is the mergeable gate
lint-new:
	@command -v golangci-lint >/dev/null 2>&1 || { \
		echo "golangci-lint not found — install $(GOLANGCI_VERSION): https://golangci-lint.run/docs/welcome/install/local/"; \
		exit 1; \
	}
	CGO_ENABLED=0 golangci-lint run --new-from-rev=$(LINT_BASE) ./...
	@scripts/lint-checks.sh

## format: gofmt the tree
format:
	go fmt ./...

## tidy: prune and verify the module graph
tidy:
	go mod tidy
