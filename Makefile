ACTIONLINT ?= actionlint
BASH ?= bash

.PHONY: lint test render adr-index

lint:
	$(ACTIONLINT) -config-file .github/actionlint.yaml -shellcheck=shellcheck -color

test:
	$(BASH) scripts/repo-hygiene.test.sh

render:
	$(BASH) scripts/render-next.sh

adr-index:
	$(BASH) scripts/gen-adr-index.sh --check
