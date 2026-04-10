APP_NAME    = AgentDevPilot
BUILD_DIR   = .build/debug
RELEASE_DIR = .build/release
APP_BUNDLE  = $(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents

.PHONY: build bundle run release dist install clean

build:
	swift build -c debug 2>&1

bundle: build
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Sources/App/Info.plist $(CONTENTS)/Info.plist
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	cp Sources/App/Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Bundle ready: $(APP_BUNDLE)"

run: bundle
	pkill -x $(APP_NAME) 2>/dev/null || true
	sleep 0.5
	open $(APP_BUNDLE)
	@echo "App launched."

# Release build — optimized binary, suitable for installing to /Applications
release:
	swift build -c release 2>&1

dist: release
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(RELEASE_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Sources/App/Info.plist $(CONTENTS)/Info.plist
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	cp Sources/App/Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo ""
	@echo "✓ $(APP_BUNDLE) ready — drag to /Applications to install."

install: dist
	cp -R $(APP_BUNDLE) /Applications/$(APP_BUNDLE)
	@echo "✓ Installed to /Applications/$(APP_BUNDLE)"

clean:
	rm -rf $(APP_BUNDLE)
	swift package clean
