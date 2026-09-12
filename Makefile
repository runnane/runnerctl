SHELL := bash
SHELLCHECK ?= shellcheck

.PHONY: gates lint example-drift smoke

gates: lint example-drift smoke

lint:
	$(SHELLCHECK) -S style runnerctl

# config.example is generated from `runnerctl config-example`; keep them equal.
example-drift:
	@diff -u config.example <(./runnerctl config-example) && echo "config.example in sync"

# Commands that need neither systemd units nor root.
smoke:
	@bash -n runnerctl
	@./runnerctl version | grep -q '^runnerctl [0-9]'
	@./runnerctl help | grep -q '^Usage:'
	@./runnerctl profiles | grep -q '^ci\*'
	@./runnerctl --config config.example profiles | grep -q '^deploy .*config .*Prod deploy runner'
	@./runnerctl bogus 2>/dev/null; test $$? -eq 1
	@echo "smoke ok"
