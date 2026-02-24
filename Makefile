SHELL := /bin/bash

# Default configuration
# The scheme for the CLI package is typically "osaurus-cli" (the package name)
SCHEME_CLI := osaurus-cli
SCHEME_APP := osaurus
CONFIG := Release
PROJECT := App/osaurus.xcodeproj
DERIVED := build/DerivedData

.PHONY: help cli app install-cli serve status clean bench-setup bench-ingest bench-ingest-chunks bench-clear-chunks bench-run bench

help:
	@echo "Targets:"
	@echo "  cli            Build CLI ($(SCHEME_CLI)) into $(DERIVED)"
	@echo "  app            Build app ($(SCHEME_APP)) and embed CLI"
	@echo "  install-cli    Install/update /usr/local/bin/osaurus symlink"
	@echo "  serve          Build CLI and start server (use PORT=XXXX, EXPOSE=1)"
	@echo "  status         Check if server is running"
	@echo "  bench-setup         Clone EasyLocomo + apply patches + install deps"
	@echo "  bench-ingest        Full LOCOMO ingestion (LLM extraction + chunks)"
	@echo "  bench-ingest-chunks Fast chunk-only backfill (no LLM, ~minutes)"
	@echo "  bench-clear-chunks  Wipe existing chunks before re-ingesting"
	@echo "  bench-run           Run LOCOMO benchmark only (skip ingestion)"
	@echo "  bench               Full ingest + run LOCOMO benchmark"
	@echo "  clean          Remove DerivedData build output"

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

## ── LOCOMO Benchmark ──────────────────────────────────────────────

BENCH_MODEL ?= openrouter/google/gemini-2.5-flash
BENCH_BASE_URL ?= http://localhost:1337
BENCH_BATCH ?= 20
EASYLOCOMO_REPO ?= https://github.com/playeriv65/EasyLocomo.git
EASYLOCOMO_DIR := benchmarks/EasyLocomo
BENCH_PYTHON := $(EASYLOCOMO_DIR)/.venv/bin/python

bench-setup:
	@echo "Setting up EasyLocomo benchmark…"
	@if [ ! -d "$(EASYLOCOMO_DIR)/.git" ]; then \
		mkdir -p benchmarks && \
		git clone $(EASYLOCOMO_REPO) $(EASYLOCOMO_DIR); \
	else \
		echo "EasyLocomo already cloned."; \
	fi
	@echo "Applying Osaurus patches…"
	cd $(EASYLOCOMO_DIR) && git checkout -- . && git apply ../../scripts/easylocomo.patch
	@echo "Installing Python dependencies…"
	cd $(EASYLOCOMO_DIR) && python -m venv .venv && .venv/bin/pip install -q -r requirements.txt
	@echo "Done. Run 'make bench-ingest' then 'make bench-run'."

bench-ingest:
	@echo "Ingesting LOCOMO conversations into Osaurus memory…"
	$(BENCH_PYTHON) scripts/ingest_locomo.py --base-url $(BENCH_BASE_URL)

bench-clear-chunks:
	@echo "Clearing existing LOCOMO conversation chunks…"
	$(BENCH_PYTHON) scripts/clear_locomo_chunks.py --base-url $(BENCH_BASE_URL)

bench-ingest-chunks:
	@echo "Backfilling LOCOMO conversation chunks (no LLM, fast)…"
	$(BENCH_PYTHON) scripts/ingest_locomo.py --base-url $(BENCH_BASE_URL) --chunks-only --delay 0

bench-run:
	@echo "Running LOCOMO benchmark (model=$(BENCH_MODEL), no-context, batch=$(BENCH_BATCH))…"
	cd $(EASYLOCOMO_DIR) && .venv/bin/python run_evaluation.py \
		--model $(BENCH_MODEL) \
		--no-context \
		--overwrite \
		--batch-size $(BENCH_BATCH)

bench: bench-ingest bench-run

## ── Housekeeping ─────────────────────────────────────────────────

clean:
	rm -rf $(DERIVED)
	@echo "Cleaned $(DERIVED)"
