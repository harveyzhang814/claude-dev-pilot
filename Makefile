APP_NAME    = AgentDevPilot
BUILD_DIR   = .build/debug
APP_BUNDLE  = $(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents

.PHONY: build bundle run clean

build:
	swift build -c debug 2>&1

bundle: build
	mkdir -p $(CONTENTS)/MacOS
	cp $(BUILD_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Sources/App/Info.plist $(CONTENTS)/Info.plist
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Bundle ready: $(APP_BUNDLE)"

run: bundle
	pkill -x $(APP_NAME) 2>/dev/null || true
	sleep 0.5
	open $(APP_BUNDLE)
	@echo "App launched."

clean:
	rm -rf $(APP_BUNDLE)
	swift package clean
