# ClankerTyper development commands. Run `make` or `make help` to list them.
# Needs macOS 14+ and Swift 5.10+ (Xcode or the Command Line Tools).

APP := /Applications/ClankerTyper.app
BIN := $(APP)/Contents/MacOS/ClankerTyper
LOG := $(HOME)/Library/Logs/ClankerTyper/clanker.log
STYLE ?= grammar
TEXT ?= their going too the park tomorow

.DEFAULT_GOAL := help
.PHONY: help build test app install run quit restart logs rewrite check clean

help: ## List the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  make %-9s %s\n", $$1, $$2}'

build: ## Compile (debug), without making the app
	swift build

test: ## Run the unit tests
	./scripts/test.sh

app: ## Build build/ClankerTyper.app (release, signed for this Mac)
	./scripts/build-app.sh

install: ## Build and install to /Applications, without opening it
	./scripts/install.sh --no-open

run: ## Build, install to /Applications and open it
	./scripts/install.sh

quit: ## Quit the running app
	-pkill -f "ClankerTyper.app/Contents/MacOS/ClankerTyper"

restart: quit ## Reopen the installed app without rebuilding
	open "$(APP)"

logs: ## Follow the app's log (Ctrl-C to stop)
	@touch "$(LOG)"
	tail -f "$(LOG)"

rewrite: ## Try a writing action on the model: make rewrite STYLE=formal TEXT="hey u there"
	"$(BIN)" --rewrite "$(STYLE)" "$(TEXT)" --raw

check: test app ## Tests, then a release build of the app

clean: ## Remove build output
	rm -rf .build build
