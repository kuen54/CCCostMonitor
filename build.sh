#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CCCostMonitor"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$SCRIPT_DIR/dist"
DMG_NAME="$APP_NAME.dmg"

echo "🔨 Building $APP_NAME..."

# ── Step 1: Compile Swift (Universal Binary: arm64 + x86_64) ──
echo "  [1/4] Compiling Swift (universal binary)..."
mkdir -p "$BUILD_DIR"
swiftc "$SCRIPT_DIR/Sources/main.swift" \
    -o "$BUILD_DIR/${APP_NAME}_arm64" \
    -framework Cocoa \
    -O \
    -target arm64-apple-macosx13.0
swiftc "$SCRIPT_DIR/Sources/main.swift" \
    -o "$BUILD_DIR/${APP_NAME}_x86_64" \
    -framework Cocoa \
    -O \
    -target x86_64-apple-macosx13.0
lipo -create \
    "$BUILD_DIR/${APP_NAME}_arm64" \
    "$BUILD_DIR/${APP_NAME}_x86_64" \
    -output "$BUILD_DIR/$APP_NAME"
rm -f "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

echo "  ✅ Compiled (universal: arm64 + x86_64)"

# ── Step 1.5: Generate app icon ──
echo "  [1.5/4] Generating app icon..."
swiftc "$SCRIPT_DIR/generate_icon.swift" \
    -framework Cocoa -framework ImageIO \
    -o "$BUILD_DIR/generate_icon" \
    -target arm64-apple-macosx13.0
# Icon generator only runs at build time on this machine, no need for universal
"$BUILD_DIR/generate_icon" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
echo "  ✅ Icon generated"

# ── Step 2: Create .app bundle ──
echo "  [2/4] Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME"   "$APP_BUNDLE/Contents/MacOS/"
cp "$SCRIPT_DIR/Info.plist"  "$APP_BUNDLE/Contents/"
cp "$BUILD_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Bundle the analysis script
ANALYSIS_SCRIPT="$HOME/.claude/skills/local-cc-cost/scripts/analyze_usage.py"
if [ -f "$ANALYSIS_SCRIPT" ]; then
    cp "$ANALYSIS_SCRIPT" "$APP_BUNDLE/Contents/Resources/"
    echo "  ✅ Bundled analyze_usage.py"
elif [ -f "$SCRIPT_DIR/Resources/analyze_usage.py" ]; then
    cp "$SCRIPT_DIR/Resources/analyze_usage.py" "$APP_BUNDLE/Contents/Resources/"
    echo "  ✅ Bundled analyze_usage.py (from Resources/)"
else
    echo "  ⚠️  analyze_usage.py not found — app will look for it at runtime"
fi

# Ad-hoc code sign (allows running without Gatekeeper warning on same machine)
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null && echo "  ✅ Ad-hoc signed" || echo "  ⚠️  Skipped signing"

echo "  ✅ Bundle ready: $APP_BUNDLE"

# ── Step 3: Create DMG ──
echo "  [3/4] Creating DMG..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Stage files for DMG
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Create README
cat > "$STAGING/README.txt" << 'EOF'
CC Cost Monitor v1.0
====================

Monitor your Claude Code token usage & cost from the macOS menu bar.

Installation:
  1. Drag CCCostMonitor.app to Applications
  2. Launch it (first time: right-click > Open to bypass Gatekeeper)
  3. Done! Claude logo appears in your menu bar

Requirements:
  - macOS 13+ (Intel & Apple Silicon)
  - Python 3 (comes with Xcode Command Line Tools)
  - Claude Code installed (with session data in ~/.claude/projects/)

Features:
  - Cost & Tokens dual view with per-model breakdown (Opus/Sonnet/Haiku)
  - Today / This Week / This Month summary cards
  - Daily bar chart with hover details
  - Month navigation with historical data cache
  - Multi-language: English, 简体中文, 繁體中文, 日本語
  - Auto-refreshes every 30 minutes & on screen wake
  - Manual refresh (⌘R)
  - No Dock icon — lives purely in the menu bar

Data source:
  Reads local session logs from ~/.claude/projects/
  Pricing fetched from LiteLLM (cached 24h)
  All data stays on your machine — nothing is sent anywhere.
EOF

# Create DMG
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DIST_DIR/$DMG_NAME"

echo "  ✅ DMG created"

# ── Step 4: Summary ──
echo ""
echo "========================================="
echo "✅ Build complete!"
echo ""
echo "  App:  $APP_BUNDLE"
echo "  DMG:  $DIST_DIR/$DMG_NAME"
echo ""
echo "  To run now:  open \"$APP_BUNDLE\""
echo "  To share:    send $DIST_DIR/$DMG_NAME"
echo "========================================="
