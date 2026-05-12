# MunkiAdmin app bundle build
#
# `swift run` produces an unbundled executable that macOS 26 treats as
# untrusted — keyboard events silently drop into a sandbox jail. To get
# a working app for development you need a real `.app` bundle with an
# Info.plist and a valid signature.
#
# Targets:
#   make app           — debug build, ad-hoc signed, ready to double-click
#   make release       — release build, ad-hoc signed
#   make sign-dev      — sign with your Apple Developer ID
#                        (CODE_SIGN_IDENTITY="Developer ID Application: …")
#   make notarize      — submit to Apple for notarization
#                        (NOTARY_PROFILE=AC_PASSWORD APPLE_ID, etc.)
#   make clean         — remove .build and build/MunkiAdmin.app
#
# Variables (override on the command line):
#   CONFIGURATION       debug | release  (default: debug)
#   CODE_SIGN_IDENTITY  signing identity passed to codesign (default: "-")
#   BUNDLE_ID           CFBundleIdentifier in Info.plist
#                       (default: systems.focused.MunkiAdmin)
#   MARKETING_VERSION   CFBundleShortVersionString (default: 0.1.0)
#   BUILD_VERSION       CFBundleVersion (default: 1)

CONFIGURATION ?= debug
CODE_SIGN_IDENTITY ?= -
BUNDLE_ID ?= systems.focused.MunkiAdmin
MARKETING_VERSION ?= 0.1.0
BUILD_VERSION ?= 1

APP_PACKAGE := Packages/App
APP_NAME := MunkiAdmin
APP_BUNDLE := build/$(APP_NAME).app
APP_CONTENTS := $(APP_BUNDLE)/Contents
APP_MACOS := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources

BIN_PATH := $(APP_PACKAGE)/.build/$(CONFIGURATION)/$(APP_NAME)

.PHONY: app release sign-dev notarize clean run

app: CONFIGURATION = debug
app: build/MunkiAdmin.app
	@echo
	@echo "👉  Built $(APP_BUNDLE) — open it with:"
	@echo "    open $(APP_BUNDLE)"
	@echo

release: CONFIGURATION = release
release: build/MunkiAdmin.app
	@echo "Release build at $(APP_BUNDLE)"

build/$(APP_NAME).app: $(BIN_PATH) $(APP_PACKAGE)/Info.plist | build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_MACOS) $(APP_RESOURCES)
	cp $(BIN_PATH) $(APP_MACOS)/$(APP_NAME)
	@chmod +x $(APP_MACOS)/$(APP_NAME)
	@./scripts/render-info-plist.sh \
	    $(APP_PACKAGE)/Info.plist \
	    "$(BUNDLE_ID)" \
	    "$(MARKETING_VERSION)" \
	    "$(BUILD_VERSION)" \
	    > $(APP_CONTENTS)/Info.plist
	codesign --force --options runtime \
	    --entitlements $(APP_PACKAGE)/MunkiAdmin.entitlements \
	    --sign "$(CODE_SIGN_IDENTITY)" \
	    $(APP_BUNDLE)

$(BIN_PATH): FORCE
	cd $(APP_PACKAGE) && swift build -c $(CONFIGURATION)

FORCE:

build:
	@mkdir -p build

sign-dev: CODE_SIGN_IDENTITY ?= $(error CODE_SIGN_IDENTITY required, e.g. "Developer ID Application: Your Name (TEAMID)")
sign-dev: app

notarize: release
	@test -n "$(NOTARY_PROFILE)" || (echo "Set NOTARY_PROFILE to the keychain profile name from \`xcrun notarytool store-credentials\`" && exit 1)
	@cd build && ditto -c -k --keepParent $(APP_NAME).app $(APP_NAME).zip
	xcrun notarytool submit build/$(APP_NAME).zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf build
	cd $(APP_PACKAGE) && swift package clean
