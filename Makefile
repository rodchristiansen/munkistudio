# MunkiStudio — build & release
#
# `swift run` produces an unbundled executable that macOS 26 treats as
# untrusted — keyboard events silently drop into a sandbox jail. A real
# `.app` bundle with an Info.plist and a signature is required.
#
# Release (default) — a signed + notarized .pkg for the Munki repo:
#   make                  full pipeline → build/MunkiStudio-<version>.pkg
#   make verify           re-check signature / notarization on a built .pkg
#
# Development:
#   make app              debug build, ad-hoc signed, double-clickable .app
#   make run              build (debug) and launch
#   make release          release build of the .app (ad-hoc signed)
#
# `make` builds and signs the release app, then hands it to munkipkg,
# which builds, signs, notarizes, and staples the .pkg. Signing config
# is read from a gitignored .env file — copy .env.example to .env and
# fill in SIGNING_IDENTITY_APP, SIGNING_IDENTITY_INSTALLER, and
# NOTARIZATION_PROFILE (a notarytool keychain profile, created once with
# `xcrun notarytool store-credentials`). `make list-identities` prints
# the Developer ID certificates in your keychain.
#
# The app icon is an Icon Composer .icon bundle at resources/MunkiStudio.icon;
# when present it is compiled with actool into the bundle. Builds run fine
# without it — the app just ships with the default icon.

# Pull signing credentials from .env when the file is present.
-include .env
export

# Configuration — override via .env, the environment, or the command line.
CONFIGURATION ?= debug
BUNDLE_ID     ?= systems.focused.MunkiStudio
PKG_ID        ?= $(BUNDLE_ID)
SIGN_IDENTITY ?= -

# .env values are often wrapped in quotes; Make keeps the quotes
# literally, so strip them — codesign / notarytool need bare strings.
strip_quotes = $(subst ',,$(subst ",,$(1)))
SIGNING_IDENTITY_APP       := $(call strip_quotes,$(SIGNING_IDENTITY_APP))
SIGNING_IDENTITY_INSTALLER := $(call strip_quotes,$(SIGNING_IDENTITY_INSTALLER))
NOTARIZATION_PROFILE       := $(call strip_quotes,$(NOTARIZATION_PROFILE))
NOTARIZATION_APPLE_ID      := $(call strip_quotes,$(NOTARIZATION_APPLE_ID))
NOTARIZATION_PASSWORD      := $(call strip_quotes,$(NOTARIZATION_PASSWORD))
TEAM_ID                    := $(call strip_quotes,$(TEAM_ID))

# Version is a build timestamp — YYYY.MM.DD.HHMM — overridable via .env
# or the command line. macOS shows CFBundleShortVersionString and
# CFBundleVersion separately, so the trailing HHMM is split off as the
# build number: 2026.05.19.1430 → marketing "2026.05.19", build "1430".
#
# Pin the timestamp to America/Vancouver so local builds and CI builds
# (GitHub Actions runners default to UTC) produce comparable versions —
# otherwise an evening Pacific build can date-stamp the next day.
VERSION           := $(or $(call strip_quotes,$(VERSION)),$(shell TZ=America/Vancouver date '+%Y.%m.%d.%H%M'))
MARKETING_VERSION := $(shell echo $(VERSION) | sed 's/\.[^.]*$$//')
BUILD             := $(shell echo $(VERSION) | sed 's/.*\.//')

APP_NAME      := MunkiStudio
BUILD_DIR     := build
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
APP_CONTENTS  := $(APP_BUNDLE)/Contents
APP_MACOS     := $(APP_CONTENTS)/MacOS
APP_RESOURCES := $(APP_CONTENTS)/Resources
PKG_PROJECT   := $(BUILD_DIR)/munkipkg
PKG_OUTPUT    := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).pkg
BIN_PATH       = .build/$(CONFIGURATION)/$(APP_NAME)
INFO_PLIST    := resources/Info.plist
ENTITLEMENTS  := resources/MunkiStudio.entitlements

# munkipkg builds, signs, notarizes, and staples the installer package.
MUNKIPKG      ?= /usr/local/munki/munkipkg

# Icon Composer (.icon) bundle — the macOS 26 Liquid Glass app icon.
# Drop the artwork at $(ICON_SRC); builds without it ship iconless.
ICON_SRC      := resources/$(APP_NAME).icon
ICON_BUILD    := $(BUILD_DIR)/actool-out

.PHONY: all app release run test clean dist sign-app pkg verify \
        check-signing-config list-identities help

# Bare `make` builds the full signed + notarized release, matching the
# other Munki tooling repos. Use `make app` for a quick dev build.
all: dist

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

# Run the unit tests — the CoreTests and InfraTests suites.
test:
	swift test

# Build the SPM binary and assemble the .app bundle. The ad-hoc
# signature is enough for local runs; `make dist` re-signs with a real
# Developer ID identity before packaging.
$(APP_BUNDLE): FORCE | $(BUILD_DIR)
	swift build -c $(CONFIGURATION)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_MACOS) $(APP_RESOURCES)
	cp $(BIN_PATH) $(APP_MACOS)/$(APP_NAME)
	@chmod +x $(APP_MACOS)/$(APP_NAME)
	@# SwiftPM emits each target's resources as a flat `<App>_<Target>.bundle`
	@# directory next to the executable — no Info.plist, no Contents/.
	@# The hardened runtime + notarization seal can't validate that shape
	@# on a fresh Mac, so the app launches cleanly on the dev machine
	@# (launch-services cache) and crashes everywhere else. Re-shape into a
	@# proper macOS bundle (Contents/Resources/ + minimal Info.plist) via
	@# scripts/embed-resource-bundle.sh before embedding. Test fixture
	@# bundles (*Tests*.bundle) never belong in a shipped app — skip them.
	@for bundle in .build/$(CONFIGURATION)/*.bundle; do \
	    [ -e "$$bundle" ] || continue; \
	    case "$$(basename "$$bundle")" in *Tests*.bundle) \
	        echo "Skipping test bundle $$(basename "$$bundle")"; continue;; esac; \
	    echo "Embedding resource bundle $$(basename "$$bundle")"; \
	    ./scripts/embed-resource-bundle.sh \
	        "$$bundle" "$(APP_RESOURCES)" "$(BUNDLE_ID)"; \
	done
	@./scripts/render-info-plist.sh \
	    $(INFO_PLIST) \
	    "$(BUNDLE_ID)" "$(MARKETING_VERSION)" "$(BUILD)" \
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
	@# Sign every embedded resource bundle before the outer .app so the
	@# outer seal covers their CodeResources hashes. Without this the
	@# notarized .pkg installs cleanly but the app dies on first launch on
	@# any Mac other than the developer's. Fail the recipe on the first
	@# nested-bundle signing error so we never seal a half-signed tree.
	@for bundle in $(APP_RESOURCES)/*.bundle; do \
	    [ -e "$$bundle" ] || continue; \
	    codesign --force --options runtime \
	        --sign "$(SIGN_IDENTITY)" \
	        "$$bundle" || exit 1; \
	done
	codesign --force --options runtime \
	    --entitlements $(ENTITLEMENTS) \
	    --sign "$(SIGN_IDENTITY)" \
	    $(APP_BUNDLE)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

FORCE:

clean:
	rm -rf $(BUILD_DIR)
	swift package clean

# --- Release pipeline ----------------------------------------------------

dist: pkg verify
	@echo
	@echo "Release package ready: $(PKG_OUTPUT)"
	@echo "Import it into your Munki repo with munkiimport."

# Re-sign the release bundle with the Developer ID Application cert and
# a secure timestamp — notarization rejects ad-hoc or untimestamped code.
sign-app: check-signing-config release
	@echo "Signing $(APP_BUNDLE)"
	@# Same as the dev build: sign nested resource bundles first so the
	@# outer seal includes them and on-launch validation succeeds on Macs
	@# other than the developer's. Fail fast — notarization would reject
	@# the package anyway, better to surface the codesign error inline.
	@for bundle in $(APP_RESOURCES)/*.bundle; do \
	    [ -e "$$bundle" ] || continue; \
	    codesign --force --options runtime --timestamp \
	        --sign "$(SIGNING_IDENTITY_APP)" \
	        "$$bundle" || exit 1; \
	done
	codesign --force --options runtime --timestamp \
	    --entitlements $(ENTITLEMENTS) \
	    --sign "$(SIGNING_IDENTITY_APP)" \
	    $(APP_BUNDLE)

# Assemble a munkipkg project around the signed app, then let munkipkg
# build, sign, notarize, and staple the installer package. The project
# is generated fresh under build/ each run; build-info carries the
# installer identity and the notarytool keychain profile.
pkg: sign-app
	@rm -rf $(PKG_PROJECT)
	@rm -f $(BUILD_DIR)/$(APP_NAME)-*.pkg
	@mkdir -p $(PKG_PROJECT)/payload/Applications
	ditto $(APP_BUNDLE) $(PKG_PROJECT)/payload/Applications/$(APP_NAME).app
	@printf '%s\n' \
	    "name: $(APP_NAME)-$(VERSION).pkg" \
	    "identifier: $(PKG_ID)" \
	    "version: '$(VERSION)'" \
	    "distribution_style: true" \
	    "install_location: /" \
	    "ownership: recommended" \
	    "postinstall_action: none" \
	    "suppress_bundle_relocation: true" \
	    "signing_info:" \
	    "  identity: '$(SIGNING_IDENTITY_INSTALLER)'" \
	    "  timestamp: true" \
	    "notarization_info:" \
	    "  keychain_profile: $(NOTARIZATION_PROFILE)" \
	    > $(PKG_PROJECT)/build-info.yaml
	$(MUNKIPKG) --build --skip-import $(PKG_PROJECT)
	@cp $(PKG_PROJECT)/build/*.pkg $(PKG_OUTPUT)
	@echo "Built $(PKG_OUTPUT)"

verify:
	@pkg=$$(ls -t $(BUILD_DIR)/$(APP_NAME)-*.pkg 2>/dev/null | head -1); \
	if [ -z "$$pkg" ]; then echo "No package in $(BUILD_DIR)/ — run 'make' first."; exit 1; fi; \
	pkgutil --check-signature "$$pkg"; \
	xcrun stapler validate "$$pkg"; \
	spctl --assess --type install -vv "$$pkg"; \
	echo "Signature, notarization, and Gatekeeper checks passed."

check-signing-config:
	@test -n "$(SIGNING_IDENTITY_APP)" || { echo "SIGNING_IDENTITY_APP is not set — copy .env.example to .env and fill it in."; exit 1; }
	@test -n "$(SIGNING_IDENTITY_INSTALLER)" || { echo "SIGNING_IDENTITY_INSTALLER is not set — copy .env.example to .env and fill it in."; exit 1; }
	@test -n "$(NOTARIZATION_PROFILE)" || { echo "NOTARIZATION_PROFILE is not set — copy .env.example to .env and fill it in."; exit 1; }
	@echo "Signing configuration OK."

list-identities:
	@security find-identity -v -p codesigning

help:
	@echo "MunkiStudio build targets:"
	@echo "  make                  signed + notarized .pkg for the Munki repo"
	@echo "  make app              debug build, double-clickable .app"
	@echo "  make run              build (debug) and launch"
	@echo "  make release          release build of the .app"
	@echo "  make test             run the Core and Infra unit tests"
	@echo "  make verify           re-check an existing package"
	@echo "  make list-identities  show keychain signing identities"
	@echo "  make clean            remove build artifacts"
