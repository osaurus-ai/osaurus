SHELL := /bin/bash

# Default configuration
# The scheme for the CLI package is typically "osaurus-cli" (the package name)
SCHEME_CLI := osaurus-cli
SCHEME_APP := osaurus
CONFIG := Release
PROJECT := App/osaurus.xcodeproj
WORKSPACE := osaurus.xcworkspace
DERIVED := build/DerivedData
XCODEBUILD_FLAGS ?=

.PHONY: help cli app install-cli serve status test ci-test computer-use-evidence clean bench-setup bench-ingest bench-ingest-chunks bench-run bench evals-prep evals evals-verbose evals-report evals-all evals-all-verbose evals-all-report evals-capture-screen evals-loop evals-matrix evals-diff evals-contribute evals-compat

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
	@echo "  bench-run           Run LOCOMO benchmark only (skip ingestion)"
	@echo "  bench               Full ingest + run LOCOMO benchmark"
	@echo "  evals               Run one OsaurusEvals suite (MODEL=, FILTER=, EVALS_SUITE=)"
	@echo "  evals-verbose       Same as 'evals' plus per-case raw LLM response (debugging prompt iter)"
	@echo "  evals-report        Same as 'evals' but also writes JSON to EVALS_OUT (build/evals.json)"
	@echo "  evals-all           Run every suite under Packages/OsaurusEvals/Suites/* (MODEL=, FILTER=)"
	@echo "  evals-all-verbose   Same as 'evals-all' plus per-case raw LLM response"
	@echo "  evals-all-report    Same as 'evals-all' but writes per-suite JSON to EVALS_OUT_DIR (build/evals/)"
	@echo "  evals-capture-screen Capture a real app's screen context into a (gitignored) fixture (APP=, OUT=)"
	@echo "  evals-loop          Optimization loop: run all suites per model + scoreboard + diff (MODELS=, BASELINE=, RECORD=1 LABEL= to commit reports/SNAPSHOT+history)"
	@echo "  evals-matrix        Cross-model scoreboard from a reports dir (DIR=, HISTORY= LABEL= to append a trend row)"
	@echo "  evals-diff          All-domain before/after diff (BASELINE=, CURRENT=)"
	@echo "  evals-contribute    Crowdsource: run one model on your Mac -> reports/community/<file>.json (MODEL=)"
	@echo "  evals-compat        Fold reports/community/* into the COMPATIBILITY.md leaderboard (COMPAT_DIR=)"
	@echo "  test           Run OsaurusCore package tests via 'swift test'"
	@echo "  evals-test     Run the OsaurusEvals harness unit tests (deterministic, token-free)"
	@echo "  ci-test        Reproduce the CI test-core job locally (xcodebuild + xcbeautify)"
	@echo "  computer-use-evidence Run local Computer Use proof lane into build/computer-use-evidence/"
	@echo "  clean          Remove DerivedData build output"

cli:
	@echo "Building CLI ($(SCHEME_CLI))…"
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_CLI) -configuration $(CONFIG) -derivedDataPath $(DERIVED) build -quiet $(XCODEBUILD_FLAGS)

app: cli
	@echo "Building app ($(SCHEME_APP))…"
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) -configuration $(CONFIG) -derivedDataPath $(DERIVED) build -quiet $(XCODEBUILD_FLAGS)
	@echo "Embedding CLI into App Bundle (Helpers)…"
	# Copy osaurus-cli to osaurus.app/Contents/Helpers/osaurus
	mkdir -p "$(DERIVED)/Build/Products/$(CONFIG)/osaurus.app/Contents/Helpers"
	cp "$(DERIVED)/Build/Products/$(CONFIG)/osaurus-cli" "$(DERIVED)/Build/Products/$(CONFIG)/osaurus.app/Contents/Helpers/osaurus"
	chmod +x "$(DERIVED)/Build/Products/$(CONFIG)/osaurus.app/Contents/Helpers/osaurus"

install-cli: cli
	@echo "Installing CLI symlink…"
	./scripts/release/install_cli_symlink.sh --dev

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

test:
	@echo "Running OsaurusCore tests…"
	swift test --package-path Packages/OsaurusCore

# Harness unit tests for the evals package itself (fixture decode, scoring,
# regression lab, judge resolution). Deterministic and token-free — no LLM
# calls — so this is safe for CI, unlike the eval suites themselves.
evals-test:
	@echo "Running OsaurusEvals harness tests…"
	OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 swift test --package-path Packages/OsaurusEvals

# Mirrors the CI `test-core` job: same xcodebuild flags, same xcbeautify
# pipe, same xcresult bundle. Run this locally to repro a failed CI run.
# After it finishes (pass or fail) you can `open build/Tests.xcresult` to
# get the same Test Navigator UI as Xcode.
ci-test:
	@command -v xcbeautify >/dev/null 2>&1 || { \
		echo "xcbeautify not found. Install with: brew install xcbeautify"; \
		exit 1; \
	}
	@mkdir -p build
	@rm -rf build/Tests.xcresult
	@set -o pipefail; xcodebuild test \
		-workspace osaurus.xcworkspace \
		-scheme OsaurusCoreTests \
		-resultBundlePath build/Tests.xcresult \
		-quiet \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		-enableCodeCoverage NO \
		-test-timeouts-enabled YES \
		-default-test-execution-time-allowance 60 \
		-maximum-test-execution-time-allowance 120 \
		COMPILER_INDEX_STORE_ENABLE=NO \
		SWIFT_COMPILATION_MODE=incremental \
		| xcbeautify --renderer terminal
	@echo ""
	@echo "Done. Inspect failures with: open build/Tests.xcresult"

computer-use-evidence:
	@OUT_DIR="$(OUT_DIR)" RUN_EVALS="$(RUN_EVALS)" MODEL="$(MODEL)" STRICT="$(STRICT)" \
		bash scripts/evals/computer-use-evidence.sh

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
	cd $(EASYLOCOMO_DIR) && git checkout -- . && git apply ../../scripts/benchmark/easylocomo.patch
	@echo "Installing Python dependencies…"
	cd $(EASYLOCOMO_DIR) && python -m venv .venv && .venv/bin/pip install -q -r requirements.txt
	@echo "Done. Run 'make bench-ingest' then 'make bench-run'."

bench-ingest:
	@echo "Ingesting LOCOMO conversations into Osaurus memory…"
	$(BENCH_PYTHON) scripts/benchmark/ingest_locomo.py --base-url $(BENCH_BASE_URL)

bench-ingest-chunks:
	@echo "Backfilling LOCOMO conversation chunks (no LLM, fast)…"
	$(BENCH_PYTHON) scripts/benchmark/ingest_locomo.py --base-url $(BENCH_BASE_URL) --chunks-only --delay 0

bench-run:
	@echo "Running LOCOMO benchmark (model=$(BENCH_MODEL), no-context, batch=$(BENCH_BATCH))…"
	cd $(EASYLOCOMO_DIR) && .venv/bin/python run_evaluation.py \
		--model $(BENCH_MODEL) \
		--no-context \
		--overwrite \
		--batch-size $(BENCH_BATCH)

bench: bench-ingest bench-run

## ── OsaurusEvals (off-CI behaviour evals) ────────────────────────
# Override on the command line, e.g.
#   make evals MODEL=foundation
#   make evals MODEL=openai/gpt-4o-mini FILTER=browser
#   make evals-report EVALS_OUT=reports/today.json
# Default model is `auto` (whatever ChatConfigurationStore is set to);
# see Packages/OsaurusEvals/README.md for the full --model grammar.

EVALS_ROOT := Packages/OsaurusEvals/Suites
EVALS_SUITE ?= $(EVALS_ROOT)/CapabilitySearch
EVALS_OUT ?= build/evals.json
EVALS_OUT_DIR ?= build/evals
# Auto-discovered list of every subdirectory under Suites/. Adding a new
# `Suites/MyDomain/` automatically picks it up here — no Makefile edit
# required when a new suite lands.
EVALS_ALL_SUITES := $(sort $(dir $(wildcard $(EVALS_ROOT)/*/)))

# Provision local assets the SwiftPM eval CLI can't self-provision: the
# MLX metallib (colocated beside the osaurus-evals binary) and the
# potion-base-4M embedder (Hugging Face cache). Idempotent; every evals*
# target depends on it so `make evals` works on a clean checkout. Skip
# with `make evals OSAURUS_EVALS_SKIP_PREP=1` if you've prepped manually.
evals-prep:
	@if [ "$(OSAURUS_EVALS_SKIP_PREP)" != "1" ]; then \
		bash scripts/evals/prepare-evals-env.sh; \
	fi

evals: evals-prep
	@echo "Running OsaurusEvals against $(EVALS_SUITE)…"
	swift run --package-path Packages/OsaurusEvals osaurus-evals run \
		--suite $(EVALS_SUITE) \
		$(if $(MODEL),--model $(MODEL),) \
		$(if $(FILTER),--filter $(FILTER),)

evals-verbose: evals-prep
	@echo "Running OsaurusEvals (verbose) against $(EVALS_SUITE)…"
	swift run --package-path Packages/OsaurusEvals osaurus-evals run \
		--suite $(EVALS_SUITE) \
		--verbose \
		$(if $(MODEL),--model $(MODEL),) \
		$(if $(FILTER),--filter $(FILTER),)

evals-report: evals-prep
	@mkdir -p $(dir $(EVALS_OUT))
	swift run --package-path Packages/OsaurusEvals osaurus-evals run \
		--suite $(EVALS_SUITE) \
		$(if $(MODEL),--model $(MODEL),) \
		$(if $(FILTER),--filter $(FILTER),) \
		--out $(EVALS_OUT)
	@echo "Wrote $(EVALS_OUT)"

# Run every suite directory under $(EVALS_ROOT). The CLI exits 1 on any
# failed/errored case, so we run each suite independently (don't `set -e`)
# and aggregate exit codes so a single failure doesn't mask later suites.
# Final exit is non-zero if ANY suite failed.
evals-all: evals-prep
	@echo "Discovered suites: $(notdir $(patsubst %/,%,$(EVALS_ALL_SUITES)))"
	@rc=0; for suite in $(EVALS_ALL_SUITES); do \
		echo ""; \
		echo "── $$suite ──"; \
		swift run --package-path Packages/OsaurusEvals osaurus-evals run \
			--suite $$suite \
			$(if $(MODEL),--model $(MODEL),) \
			$(if $(FILTER),--filter $(FILTER),) \
			|| rc=$$?; \
	done; \
	exit $$rc

evals-all-verbose: evals-prep
	@echo "Discovered suites: $(notdir $(patsubst %/,%,$(EVALS_ALL_SUITES)))"
	@rc=0; for suite in $(EVALS_ALL_SUITES); do \
		echo ""; \
		echo "── $$suite ──"; \
		swift run --package-path Packages/OsaurusEvals osaurus-evals run \
			--suite $$suite \
			--verbose \
			$(if $(MODEL),--model $(MODEL),) \
			$(if $(FILTER),--filter $(FILTER),) \
			|| rc=$$?; \
	done; \
	exit $$rc

# Writes one JSON report per suite under $(EVALS_OUT_DIR), named after
# the suite directory. Useful for CI dashboards / cross-run diffing.
evals-all-report: evals-prep
	@mkdir -p $(EVALS_OUT_DIR)
	@rc=0; for suite in $(EVALS_ALL_SUITES); do \
		name=$$(basename $$suite); \
		out="$(EVALS_OUT_DIR)/$$name.json"; \
		echo ""; \
		echo "── $$suite → $$out ──"; \
		swift run --package-path Packages/OsaurusEvals osaurus-evals run \
			--suite $$suite \
			$(if $(MODEL),--model $(MODEL),) \
			$(if $(FILTER),--filter $(FILTER),) \
			--out $$out \
			|| rc=$$?; \
	done; \
	echo ""; \
	echo "Wrote per-suite reports to $(EVALS_OUT_DIR)/"; \
	exit $$rc

# Capture a real app's screen context into a ScreenContextFixture JSON for the
# `screen_context` eval suite. Local-only: needs Accessibility permission for
# the process running it (grant your terminal in System Settings → Privacy &
# Security → Accessibility). Defaults to the frontmost app and a timestamped
# file under the gitignored Fixtures/ScreenContext/local/ dir. RENDER=1 also
# prints the exact injected block (the fast capture→diagnose loop).
#   make evals-capture-screen
#   make evals-capture-screen APP=Xcode RENDER=1
#   make evals-capture-screen APP=Safari OUT=/tmp/safari.json
evals-capture-screen:
	@swift run --package-path Packages/OsaurusEvals osaurus-evals capture-screen \
		$(if $(APP),--app "$(APP)",) \
		$(if $(OUT),--out $(OUT),) \
		$(if $(RENDER),--render,)

# Optimization-loop backbone: prep → run every suite per model into a
# timestamped dir → cross-model matrix (scoreboard) → optional diff vs a
# saved baseline. The maintainer pipeline; see
# scripts/evals/optimization-loop.sh for env overrides (MODELS=, BASELINE=,
# FILTER=, STRICT=, EVALS_REPEAT=, PARALLEL_REMOTE=).
#   make evals-loop
#   make evals-loop MODELS="foundation qwen3-4b xai/grok-4.3" BASELINE=build/evals/loop/<prev>
#   RECORD=1 LABEL="qwen fix" make evals-loop   # also refresh committed reports/SNAPSHOT + history
#   make evals-loop EVALS_REPEAT=3              # 3 trials per case; flaky rows marked, diff flake-aware
evals-loop:
	@MODELS="$(MODELS)" BASELINE="$(BASELINE)" FILTER="$(FILTER)" STRICT="$(STRICT)" \
		RECORD="$(RECORD)" LABEL="$(LABEL)" \
		EVALS_REPEAT="$(EVALS_REPEAT)" PARALLEL_REMOTE="$(PARALLEL_REMOTE)" \
		bash scripts/evals/optimization-loop.sh

# Cross-model scoreboard from an existing dir of *.json reports. Point
# MATRIX_OUT/MATRIX_MD at reports/SNAPSHOT.{json,md} and HISTORY at
# reports/history.jsonl to refresh the committed scoreboard by hand.
#   make evals-matrix DIR=build/evals/loop/latest
evals-matrix:
	@swift run --package-path Packages/OsaurusEvals osaurus-evals matrix $(DIR) \
		$(if $(MATRIX_OUT),--out $(MATRIX_OUT),) \
		$(if $(MATRIX_MD),--markdown $(MATRIX_MD),) \
		$(if $(HISTORY),--history $(HISTORY),) \
		$(if $(LABEL),--label "$(LABEL)",)

# All-domain before/after diff between two report dirs/files.
#   make evals-diff BASELINE=build/evals/loop/<prev> CURRENT=build/evals/loop/latest
evals-diff:
	@swift run --package-path Packages/OsaurusEvals osaurus-evals diff $(BASELINE) $(CURRENT) \
		$(if $(DIFF_OUT),--out $(DIFF_OUT),) \
		$(if $(DIFF_MD),--markdown $(DIFF_MD),) \
		$(if $(STRICT),--fail-on-regression,)

# Crowdsource model compatibility: run the per-model LLM suites for ONE model on
# your hardware and emit a single contribution file under reports/community/.
# Export a strong judge key (e.g. XAI_API_KEY) or JUDGE_MODEL to avoid a
# self-judged (weaker) run. See reports/community/README.md.
#   MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
evals-contribute:
	@MODEL="$(MODEL)" bash scripts/evals/contribute.sh $(MODEL)

# Fold every contribution under reports/community/ into the committed
# COMPATIBILITY.{md,json} leaderboard. Run VALIDATE=1 for the PR gate (verify
# each contribution decodes and carries provenance) without rebuilding.
#   make evals-compat
#   VALIDATE=1 make evals-compat
COMPAT_DIR ?= reports/community
evals-compat:
	@swift run --package-path Packages/OsaurusEvals osaurus-evals compat $(COMPAT_DIR) \
		$(if $(VALIDATE),--validate,--out reports/COMPATIBILITY.json --markdown reports/COMPATIBILITY.md)

## ── Housekeeping ─────────────────────────────────────────────────

clean:
	rm -rf $(DERIVED)
	@echo "Cleaned $(DERIVED)"
