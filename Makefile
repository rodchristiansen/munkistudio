# MunkiStudio — build & release
#
# `swift run` produces an unbundled executable that macOS 26 treats as
# untrusted — keyboard events silently drop into a sandbox jail. A real
# `.app` bundle with an Info.plist and a signature is required.
#
# Development:
#   make app              debug build, ad-hoc signed, double-clickable .app
#   make run              build (debug) and launch
#   make release          release build of the .app (ad-hoc signed)
#
# Release — a signed + notarized .pkg to import into the Munki repo:
#   make dist             full pipeline → build/MunkiStudio-<version>.pkg
#   make verify           re-check signature / notarization on a built .pkg
#
# Signing credentials are read from a gitignored .env file. Copy
# .env.example to .env and fill in the SIGNING_IDENTITY_* and
# NOTARIZATION_* values. `make list-identities` prints the Developer ID
# certificates in your keychain.
#
# The app icon is an Icon Composer .icon bundle at resources/MunkiStudio.icon;
# when present it is compiled with actool into the bundle. Builds run fine
# without it — the app just ships with the default icon.

# Pull signing credentials from .env when the file is present.
-include .env
export

# Configuration — override via .env, the environment, or the command line.
CONFIGURATION ?= debug
VERSION       ?= 1.0.0
BUILD         ?= 1
BUNDLE_ID     ?= systems.focused.MunkiStudio
PKG_ID        ?= $(BUNDLE_ID)
SIGN_IDENTITY ?= -

# .env values are often wrapped in quotes; Make keeps the quotes
# literally, so strip them — codesign / notarytool need bare strings.
strip_quotes = $(subst ',,$(subst ",,$(1)))
VERSION                    := $(call strip_quotes,$(VERSION))
SIGNING_IDENTITY_APP       := $(call strip_quotes,$(SIGNING_IDENTITY_APP))
SIGNING_IDENTITY_INSTALLER := $(call strip_quotes,$(SIGNING_IDENTITY_INSTALLER))
NOTARIZATION_PROFILE       := $(call strip_quotes,$(NOTARIZATION_PROFILE))
NOTARIZATION_APPLE_ID      := $(call strip_quotes,$(NOTARIZATION_APPLE_ID))
NOTARIZATION_PASSWORD      := $(call strip_quotes,$(NOTARIZATION_PASSWORD))
TEAM_ID                    := $(call strip_quotes,$(TEAM_ID))

APP_PACKAGE   := Packages/App
APP_NAME      := MunkiStudio
BUILD_DIR     := build
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS  := $(APP_BUNDLE)/Contents
APP_MACOS     := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources
PKG_PAYLOAD   := $(BUILD_DIR)/pkg-payload
COMPONENT     := $(BUILD_DIR)/component.plist
PKG_OUTPUT    := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).pkg
BIN_PATH       = $(APP_PACKAGE)/.build/$(CONFIGURATION)/$(APP_NAME)

# Icon Composer (.icon) bundle — the macOS 26 Liquid Glass app icon.
# Drop the artwork at $(ICON_SRC); builds without it ship iconless.
ICON_SRC      := resources/$(APP_NAME).icon
ICON_BUILD    := $(BUILD_DIR)/actool-out

.PHONY: app release run clean dist sign-app build-pkg sign-pkg \
        notarize-pkg verify check-signing-config list-identities help

# --- Development ---------------------------------------------------------

app: CONFIGURATION = debug
app: $(APP_BUNDLE)
	@echo
	@echo "Built $(APP_BUNDLE) — open it with:"
	@echo "    open $(APP_BUNDLE)"
	@echo

release: CONFIGURATION = release
release: $(APP_BUNDLE)
	@echo "Release build at $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

# Build the SPM binary and assemble the .app bundle. The ad-hoc
# signature is enough for local runs; `make dist` re-signs with a real
# Developer ID identity before packaging.
$(APP_BUNDLE): FORCE | $(BUILD_DIR)
	cd $(APP_PACKAGE) && swift build -c $(CONFIGURATION)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_MACOS) $(APP_RESOURCES)
	cp $(BIN_PATH) $(APP_MACOS)/$(APP_NAME)
	@chmod +x $(APP_MACOS)/$(APP_NAME)
	@./scripts/render-info-plist.sh \
	    $(APP_PACKAGE)/Info.plist \
	    "$(BUNDLE_ID)" "$(VERSION)" "$(BUILD)" \
	    > $(APP_CONTENTS)/Info.plist
	@if [ -d "$(ICON_SRC)" ]; then \
	    echo "Compiling app icon from $(ICON_SRC)"; \
	    rm -rf "$(ICON_BUILD)"; mkdir -p "$(ICON_BUILD)"; \
	    xcrun actool --compile "$(ICON_BUILD)" \
	        --platform macosx --minimum-deployment-target 26.0 \
	        --app-icon "$(APP_NAME)" \
	        --output-partial-info-plist "$(ICON_BUILD)/partial-info.plist" \
	        --warnings --errors "$(ICON_SRC)" >/dev/null; \
	    cp "$(ICON_BUILD)/Assets.car" "$(APP_RESOURCES)/Assets.car"; \
	    [ -f "$(ICON_BUILD)/$(APP_NAME).icns" ] \
	        && cp "$(ICON_BUILD)/$(APP_NAME).icns" "$(APP_RESOURCES)/$(APP_NAME).icns" || true; \
	else \
	    echo "No app icon at $(ICON_SRC) — building without one."; \
	fi
	codesign --force --options runtime \
	    --entitlements $(APP_PACKAGE)/MunkiStudio.entitlements \
	    --sign "$(SIGN_IDENTITY)" \
	    $(APP_BUNDLE)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

FORCE:

clean:
	rm -rf $(BUILD_DIR)
	cd $(APP_PACKAGE) && swift package clean

# --- Release pipeline ----------------------------------------------------

dist: notarize-pkg verify
	@echo
	@echo "Release package ready: $(PKG_OUTPUT)"
	@echo "Import it into your Munki repo with munkiimport."

# Re-sign the release bundle with the Developer ID Application cert and
# a secure timestamp — notarization rejects ad-hoc or untimestamped code.
sign-app: check-signing-config release
	@echo "Signing $(APP_BUNDLE)"
	codesign --force --options runtime --timestamp \
	    --entitlements $(APP_PACKAGE)/MunkiStudio.entitlements \
	    --sign "$(SIGNING_IDENTITY_APP)" \
	    $(APP_BUNDLE)

# Wrap the signed app in a component package that installs to
# /Applications. Bundle relocation is disabled so an existing copy
# elsewhere on disk cannot redirect the install.
build-pkg: sign-app
	@rm -rf $(PKG_PAYLOAD)
	@mkdir -p $(PKG_PAYLOAD)
	ditto $(APP_BUNDLE) $(PKG_PAYLOAD)/$(APP_NAME).app
	pkgbuild --analyze --root $(PKG_PAYLOAD) $(COMPONENT)
	/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" $(COMPONENT)
	pkgbuild --root $(PKG_PAYLOAD) \
	    --component-plist $(COMPONENT) \
	    --install-location /Applications \
	    --identifier $(PKG_ID) \
	    --version $(VERSION) \
	    $(PKG_OUTPUT)

sign-pkg: build-pkg
	@echo "Signing $(PKG_OUTPUT)"
	productsign --sign "$(SIGNING_IDENTITY_INSTALLER)" --timestamp \
	    $(PKG_OUTPUT) $(PKG_OUTPUT).signed
	@mv $(PKG_OUTPUT).signed $(PKG_OUTPUT)

# Notarize via a notarytool keychain profile when one is configured,
# otherwise fall back to an Apple ID + app-specific password.
notarize-pkg: sign-pkg
	@echo "Submitting $(PKG_OUTPUT) to Apple — this can take a few minutes."
	@if [ -n "$(NOTARIZATION_PROFILE)" ]; then \
	    xcrun notarytool submit "$(PKG_OUTPUT)" \
	        --keychain-profile "$(NOTARIZATION_PROFILE)" --wait; \
	else \
	    xcrun notarytool submit "$(PKG_OUTPUT)" \
	        --apple-id "$(NOTARIZATION_APPLE_ID)" \
	        --password "$(NOTARIZATION_PASSWORD)" \
	        --team-id "$(TEAM_ID)" --wait; \
	fi
	xcrun stapler staple $(PKG_OUTPUT)

verify:
	@test -f $(PKG_OUTPUT) || { echo "No package at $(PKG_OUTPUT) — run 'make dist' first."; exit 1; }
	pkgutil --check-signature $(PKG_OUTPUT)
	xcrun stapler validate $(PKG_OUTPUT)
	spctl --assess --type install -vv $(PKG_OUTPUT)
	@echo "Signature, notarization, and Gatekeeper checks passed."

check-signing-config:
	@test -n "$(SIGNING_IDENTITY_APP)" || { echo "SIGNING_IDENTITY_APP is not set — copy .env.example to .env and fill it in."; exit 1; }
	@test -n "$(SIGNING_IDENTITY_INSTALLER)" || { echo "SIGNING_IDENTITY_INSTALLER is not set — copy .env.example to .env and fill it in."; exit 1; }
	@test -n "$(NOTARIZATION_PROFILE)$(NOTARIZATION_APPLE_ID)" || { echo "Set NOTARIZATION_PROFILE, or NOTARIZATION_APPLE_ID + NOTARIZATION_PASSWORD + TEAM_ID, in .env."; exit 1; }
	@echo "Signing configuration OK."

list-identities:
	@security find-identity -v -p codesigning

help:
	@echo "MunkiStudio build targets:"
	@echo "  make app              debug build, double-clickable .app"
	@echo "  make run              build (debug) and launch"
	@echo "  make release          release build of the .app"
	@echo "  make dist             signed + notarized .pkg for the Munki repo"
	@echo "  make verify           re-check an existing package"
	@echo "  make list-identities  show keychain signing identities"
	@echo "  make clean            remove build artifacts"
