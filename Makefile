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
# .env.example to .env and fill in:
#   SIGNING_IDENTITY_APP   Developer ID Application certificate
#   SIGNING_IDENTITY_PKG   Developer ID Installer certificate
#   NOTARIZATION_PROFILE   notarytool keychain profile name
#
# `make list-identities` prints the Developer ID certificates in your
# keychain. Create the notarytool profile once, interactively, with
# `xcrun notarytool store-credentials`.

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
	productsign --sign "$(SIGNING_IDENTITY_PKG)" --timestamp \
	    $(PKG_OUTPUT) $(PKG_OUTPUT).signed
	@mv $(PKG_OUTPUT).signed $(PKG_OUTPUT)

notarize-pkg: sign-pkg
	@echo "Submitting $(PKG_OUTPUT) to Apple — this can take a few minutes."
	xcrun notarytool submit $(PKG_OUTPUT) \
	    --keychain-profile "$(NOTARIZATION_PROFILE)" --wait
	xcrun stapler staple $(PKG_OUTPUT)

verify:
	@test -f $(PKG_OUTPUT) || { echo "No package at $(PKG_OUTPUT) — run 'make dist' first."; exit 1; }
	pkgutil --check-signature $(PKG_OUTPUT)
	xcrun stapler validate $(PKG_OUTPUT)
	spctl --assess --type install -vv $(PKG_OUTPUT)
	@echo "Signature, notarization, and Gatekeeper checks passed."

check-signing-config:
	@test -n "$(SIGNING_IDENTITY_APP)" || { echo "SIGNING_IDENTITY_APP is not set — copy .env.example to .env and fill it in."; exit 1; }
	@test -n "$(SIGNING_IDENTITY_PKG)" || { echo "SIGNING_IDENTITY_PKG is not set — copy .env.example to .env and fill it in."; exit 1; }
	@test -n "$(NOTARIZATION_PROFILE)" || { echo "NOTARIZATION_PROFILE is not set — copy .env.example to .env and fill it in."; exit 1; }
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
