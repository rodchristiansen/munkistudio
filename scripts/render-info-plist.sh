#!/usr/bin/env bash
# Substitute build-time placeholders in Info.plist. Keeps the template
# tracked in git while letting the Makefile pass in bundle id and
# version without modifying the source file.
set -euo pipefail

template="$1"
bundle_id="$2"
marketing="$3"
build="$4"

sed \
    -e "s|__BUNDLE_ID__|${bundle_id}|g" \
    -e "s|__MARKETING_VERSION__|${marketing}|g" \
    -e "s|__BUILD_VERSION__|${build}|g" \
    "$template"
