#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BUNDLE_DIR="/dist/blur-Linux-Release-x64"

echo "==> Building AppImages from $BUNDLE_DIR"

[ -d "$BUNDLE_DIR" ] || { echo "Error: bundle not found at $BUNDLE_DIR. Run package-linux.sh first."; exit 1; }

# ── Download appimagetool once ────────────────────────────────────────────────
APPIMAGETOOL="/tmp/appimagetool-x86_64.AppImage"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo "--> Downloading appimagetool"
    wget -q -O "$APPIMAGETOOL" \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

export APPIMAGE_EXTRACT_AND_RUN=1

build_appimage() {
    local binary="$1"      # e.g. blur or blur-cli
    local output="$2"      # e.g. /dist/blur-Linux-x86_64.AppImage
    local appdir="/tmp/${binary}.AppDir"

    echo "--> Building $output"

    rm -rf "$appdir"
    cp -a "$BUNDLE_DIR" "$appdir"

    # AppRun: exec the target binary
    cat > "$appdir/AppRun" <<EOF
#!/bin/sh
APPDIR="\$(dirname "\$(readlink -f "\$0")")"
exec "\$APPDIR/$binary" "\$@"
EOF
    chmod +x "$appdir/AppRun"

    # Desktop file and icon (required by AppImage spec)
    sed "s/^Exec=.*/Exec=$binary/" "$PROJECT_DIR/resources/blur.desktop" > "$appdir/${binary}.desktop"
    cp "$PROJECT_DIR/resources/blur.png" "$appdir/blur.png"

    "$APPIMAGETOOL" "$appdir" "$output"
    echo "    Size: $(du -sh "$output" | cut -f1)"
}

build_appimage "blur"     "/dist/blur-Linux-x86_64.AppImage"
build_appimage "blur-cli" "/dist/blur-cli-Linux-x86_64.AppImage"

# Create no-fuse launcher wrappers. APPIMAGE_EXTRACT_AND_RUN must be set
# before the AppImage ELF runtime starts, so it cannot go inside AppRun.
for name in blur blur-cli; do
    cat > "/dist/${name}.sh" <<EOF
#!/bin/sh
APPIMAGE_EXTRACT_AND_RUN=1 "\$(dirname "\$(readlink -f "\$0")")/${name}-Linux-x86_64.AppImage" "\$@"
EOF
    chmod +x "/dist/${name}.sh"
done

echo ""
echo "==> AppImages ready:"
echo "    /dist/blur-Linux-x86_64.AppImage"
echo "    /dist/blur-cli-Linux-x86_64.AppImage"
echo "    /dist/blur.sh          (no-fuse launcher)"
echo "    /dist/blur-cli.sh      (no-fuse launcher)"
