EMACS ?= emacs

.PHONY: check test shell-test compile e2e

check: test shell-test compile

test:
	$(EMACS) --batch -Q -L . \
		-l test/brutal-paper-test.el \
		-f ert-run-tests-batch-and-exit

shell-test:
	bash test/e2e-script-test.sh

compile:
	@set -e; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	cp brutal-paper.el "$$tmp"/; \
	$(EMACS) --batch -Q -L "$$tmp" \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile \
		"$$tmp/brutal-paper.el"

e2e:
	./scripts/e2e.sh
