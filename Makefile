APP     := Vignette
CONFIG  ?= Debug
DERIVED := build
APP_DIR := $(DERIVED)/Build/Products/$(CONFIG)/$(APP).app
BIN     := $(APP_DIR)/Contents/MacOS/$(APP)

.PHONY: gen build run open kill test fmt clean tcc-reset

gen: ## Regenerate Vignette.xcodeproj from project.yml
	@xcodegen generate --quiet

build: gen ## Build the app
	@set -o pipefail && xcodebuild -project $(APP).xcodeproj -scheme $(APP) \
		-configuration $(CONFIG) -derivedDataPath $(DERIVED) build | xcbeautify

run: build kill ## Build and run in the foreground (logs land in this terminal)
	@echo "--- running $(BIN) (ctrl-c to stop) ---"
	@$(BIN)

open: build kill ## Build and launch detached via LaunchServices
	@open $(APP_DIR)

kill: ## Stop any running instance
	@pkill -x $(APP) 2>/dev/null || true

test: gen ## Run the test suite
	@set -o pipefail && xcodebuild -project $(APP).xcodeproj -scheme $(APP) \
		-configuration $(CONFIG) -derivedDataPath $(DERIVED) test | xcbeautify

fmt: ## Format sources
	@swiftformat Sources Tests

clean: ## Remove build artifacts and the generated project
	@rm -rf $(DERIVED) $(APP).xcodeproj

tcc-reset: ## Forget the Accessibility grant (useful for testing onboarding)
	@tccutil reset Accessibility dev.maxhafs.vignette.debug
