NAME    := borgbackup
PHPIMG  := php:8.2-cli-alpine
SRC     := src/usr/local/emhttp/plugins/$(NAME)

.PHONY: build lint clean tree

build:            ## Package the .txz and update the .plg
	./build.sh

lint:             ## Lint PHP (via Docker), shell, JS and XML
	@docker run --rm -v "$(PWD)":/w -w /w $(PHPIMG) \
	  sh -c 'find src -name "*.php" -o -name "*.page" | while read f; do php -l "$$f" || exit 1; done'
	@find src -name '*.sh' -o -path '*/event/*' -type f | while read f; do bash -n "$$f" || exit 1; done
	@node --check $(SRC)/images/borg.js
	@xmllint --noout plugin/$(NAME).plg
	@echo "lint: ok"

clean:            ## Remove built packages
	rm -f archive/*.txz

tree:             ## Show what ships in the package
	@find src -type f | sed 's|^src||' | sort
