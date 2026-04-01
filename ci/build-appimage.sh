#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BUNDLE_DIR="/dist/blur-Linux-Release-x64"
APPDIR="/tmp/blur.AppDir"
OUTPUT="/dist/blur-Linux-x86_64.AppImage"

echo "==> Building AppImage from $BUNDLE_DIR"

[ -d "$BUNDLE_DIR" ] || { echo "Error: bundle not found at $BUNDLE_DIR. Run package-linux.sh first."; exit 1; }

# ── Build AppDir from the existing bundle ─────────────────────────────────────
rm -rf "$APPDIR"
cp -a "$BUNDLE_DIR" "$APPDIR"

# ── AppRun: entry point invoked by the AppImage runtime ───────────────────────
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
APPDIR="$(dirname "$(readlink -f "$0")")"
exec "$APPDIR/blur" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# ── Desktop file and icon (required by AppImage spec) ─────────────────────────
cp "$PROJECT_DIR/resources/blur.desktop" "$APPDIR/blur.desktop"
cp "$PROJECT_DIR/resources/blur.png"     "$APPDIR/blur.png"

# ── Download appimagetool ─────────────────────────────────────────────────────
APPIMAGETOOL="/tmp/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo "--> Downloading appimagetool"
    wget -q -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ── Package ───────────────────────────────────────────────────────────────────
# APPIMAGE_EXTRACT_AND_RUN=1: run appimagetool without FUSE (required in Docker)
export APPIMAGE_EXTRACT_AND_RUN=1
"$APPIMAGETOOL" "$APPDIR" "$OUTPUT"

echo ""
echo "==> AppImage ready: $OUTPUT"
echo "    Size: $(du -sh "$OUTPUT" | cut -f1)"
