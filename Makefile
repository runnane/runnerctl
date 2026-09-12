SHELL := bash
SHELLCHECK ?= shellcheck

.PHONY: gates lint example-drift smoke sim migrate-test

gates: lint example-drift smoke sim migrate-test

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
	@d=$$(mktemp -d) && printf 'DROPIN_NAME="../x.conf"\n' > "$$d/config" && chmod 644 "$$d/config" && ( ./runnerctl --config "$$d/config" profiles >/dev/null 2>"$$d/err"; test "$$?" -eq 1 ) && grep -q "DROPIN_NAME" "$$d/err" && rm -rf "$$d"
	@d=$$(mktemp -d) && printf '' > "$$d/config" && chmod 660 "$$d/config" && ( ./runnerctl --config "$$d/config" profiles >/dev/null 2>"$$d/err"; test "$$?" -eq 1 ) && grep -qi "group-writable" "$$d/err" && chmod 644 "$$d/config" && ./runnerctl --config "$$d/config" profiles | grep -q '^ci\*' && rm -rf "$$d"
	@echo "smoke ok"

# Everything that touches units, run against tests/stub.config (systemd
# replaced by a call log). See tests/run.sh for how to add a case.
sim:
	@bash tests/run.sh

# `migrate` against the sanitised legacy fixture and a fixture drop-in tree;
# tests/migrate.config redirects discovery and SYSTEMD_DIR there.
migrate-test:
	@bash tests/migrate-test.sh
