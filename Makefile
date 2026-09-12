SHELL := bash
SHELLCHECK ?= shellcheck

.PHONY: gates lint example-drift smoke migrate-test install-test

gates: lint example-drift smoke migrate-test install-test

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

# `migrate` against the sanitised legacy fixture and a fixture drop-in tree;
# tests/migrate.config redirects discovery and SYSTEMD_DIR there.
migrate-test:
	@bash tests/migrate-test.sh

# `install` under a temp prefix: fresh, upgrade, legacy+migrate, piped form
# (offline via a file:// UPGRADE_URL). Never needs root; a fake sudo on PATH
# makes any escalation a failure.
install-test:
	@bash tests/install-test.sh
