NAME    := borgbackup
PHPIMG  := php:8.2-cli-alpine
SRC     := source/$(NAME)

.PHONY: build bump lint clean tree release

build:            ## Build the .txz at the version in the .plg
	./package.sh

bump:             ## Advance to today's next version, then build
	./package.sh --bump

lint:             ## Lint PHP (via Docker), shell, JS and XML
	@docker run --rm -v "$(PWD)":/w -w /w $(PHPIMG) \
	  sh -c 'find source -name "*.php" -o -name "*.page" | while read f; do php -l "$$f" || exit 1; done'
	@find $(SRC) -name '*.sh' -o -path '*/event/*' -type f | while read f; do bash -n "$$f" || exit 1; done
	@node --check $(SRC)/images/borg.js
	@xmllint --noout $(NAME).plg
	@echo "lint: ok"

release:          ## Upload the built .txz to a GitHub release for its version
	@v=$$(grep -o '<!ENTITY version *"[^"]*"' $(NAME).plg | sed -E 's/.*"([^"]*)"/\1/'); \
	 pkg="$(NAME)-$$v-x86_64-1.txz"; \
	 test -f "$$pkg" || { echo "no $$pkg - run make build first"; exit 1; }; \
	 gh release create "$$v" "$$pkg" --title "$(NAME) $$v" \
	   --notes "See CHANGES in $(NAME).plg"

clean:            ## Remove built packages
	rm -f *.txz

tree:             ## Show what ships in the package
	@find $(SRC) -type f | sed 's|^$(SRC)||' | sort
