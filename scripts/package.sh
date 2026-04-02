#!/bin/bash
# Agent Dev Pilot — one-shot packaging script
# Produces: dist/AgentDevPilot-<version>.dmg
#
# Usage:
#   ./scripts/package.sh           # release build
#   ./scripts/package.sh --debug   # debug build (faster, for local testing)
#
# Requirements: Xcode Command Line Tools (swift, codesign, hdiutil, plutil)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="AgentDevPilot"
BUNDLE_NAME="${APP_NAME}.app"
PLIST="Sources/App/Info.plist"
DIST_DIR="dist"

# ── Flags ─────────────────────────────────────────────────────────────────────
BUILD_CONFIG="release"
BUILD_DIR=".build/release"
if [[ "${1:-}" == "--debug" ]]; then
    BUILD_CONFIG="debug"
    BUILD_DIR=".build/debug"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
step() { echo; echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

# ── Version from Info.plist ───────────────────────────────────────────────────
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null) \
    || fail "Could not read CFBundleShortVersionString from $PLIST"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "╔══════════════════════════════════════════╗"
echo "║  Agent Dev Pilot — package v${VERSION}"
echo "║  Config: ${BUILD_CONFIG}"
echo "╚══════════════════════════════════════════╝"

# ── 1. Build ──────────────────────────────────────────────────────────────────
step "Building ($BUILD_CONFIG)…"
swift build -c "$BUILD_CONFIG" 2>&1 | grep -v "^$" || fail "swift build failed"
ok "Build complete"

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
step "Assembling ${BUNDLE_NAME}…"
CONTENTS="${BUNDLE_NAME}/Contents"
rm -rf "$BUNDLE_NAME"
mkdir -p "${CONTENTS}/MacOS"
cp "${BUILD_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "$PLIST"                   "${CONTENTS}/Info.plist"
ok "Bundle assembled"

# ── 3. Ad-hoc code sign ───────────────────────────────────────────────────────
step "Signing (ad-hoc)…"
codesign --force --deep --sign - "$BUNDLE_NAME"
ok "Signed"

# ── 4. Create DMG ─────────────────────────────────────────────────────────────
step "Creating DMG…"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Staging folder for hdiutil
STAGING=$(mktemp -d)
cp -R "$BUNDLE_NAME" "$STAGING/"
# Symlink to /Applications for drag-install UI
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Agent Dev Pilot ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "${DIST_DIR}/${DMG_NAME}" \
    > /dev/null

rm -rf "$STAGING"
ok "DMG created: ${DIST_DIR}/${DMG_NAME}"

# ── 5. Remove quarantine (local install only) ─────────────────────────────────
#
# Uncomment if you want to install directly to /Applications from this script:
#   xattr -cr "$BUNDLE_NAME"
#   cp -R "$BUNDLE_NAME" /Applications/

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "  Output: $(du -sh "${DIST_DIR}/${DMG_NAME}" | cut -f1)  ${DIST_DIR}/${DMG_NAME}"
echo
echo "  To install: open ${DIST_DIR}/${DMG_NAME}"
echo "  Then drag Agent Dev Pilot → Applications"
echo
