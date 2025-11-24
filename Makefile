SHELL := /bin/bash

# Default configuration
# The scheme for the CLI package is typically "osaurus-cli" (the package name)
SCHEME_CLI := osaurus-cli
SCHEME_APP := osaurus
CONFIG := Release
PROJECT := App/osaurus.xcodeproj
DERIVED := build/DerivedData

.PHONY: help cli app install-cli serve status clean

help:
	@echo "Targets:"
	@echo "  cli          Build CLI ($(SCHEME_CLI)) into $(DERIVED)"
	@echo "  app          Build app ($(SCHEME_APP)) and embed CLI"
	@echo "  install-cli  Install/update /usr/local/bin/osaurus symlink"
	@echo "  serve        Build CLI and start server (use PORT=XXXX, EXPOSE=1)"
	@echo "  status       Check if server is running"
	@echo "  clean        Remove DerivedData build output"

cli:
	@echo "Building CLI ($(SCHEME_CLI))…"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_CLI) -configuration $(CONFIG) -derivedDataPath $(DERIVED) build -quiet

app: cli
	@echo "Building app ($(SCHEME_APP))…"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME_APP) -configuration $(CONFIG) -derivedDataPath $(DERIVED) build -quiet
	@echo "Embedding CLI into App Bundle (Helpers)…"
	# Copy osaurus-cli to osaurus.app/Contents/Helpers/osaurus
	mkdir -p "$(DERIVED)/Build/Products/$(CONFIG)/osaurus.app/Contents/Helpers"
	cp "$(DERIVED)/Build/Products/$(CONFIG)/osaurus-cli" "$(DERIVED)/Build/Products/$(CONFIG)/osaurus.app/Contents/Helpers/osaurus"
	chmod +x "$(DERIVED)/Build/Products/$(CONFIG)/osaurus.app/Contents/Helpers/osaurus"

install-cli: cli
	@echo "Installing CLI symlink…"
	./scripts/install_cli_symlink.sh --dev

serve: install-cli
	@echo "Starting Osaurus server…"
	@if [[ -n "$(PORT)" ]]; then \
		ARGS="$$ARGS --port $(PORT)"; \
	fi; \
	if [[ "$(EXPOSE)" == "1" ]]; then \
		ARGS="$$ARGS --expose"; \
	fi; \
	osaurus serve $$ARGS

status:
	osaurus status

clean:
	rm -rf $(DERIVED)
	@echo "Cleaned $(DERIVED)"
