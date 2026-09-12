SHELL := bash
SHELLCHECK ?= shellcheck

.PHONY: gates lint example-drift smoke sim

gates: lint example-drift smoke sim

# tests/stub.config has no shebang (it is sourced), hence -s bash for the set.
lint:
	$(SHELLCHECK) -S style -s bash runnerctl tests/run.sh tests/stub.config

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

# Everything that touches units, run against tests/stub.config (systemd
# replaced by a call log). See tests/run.sh for how to add a case.
sim:
	@bash tests/run.sh
