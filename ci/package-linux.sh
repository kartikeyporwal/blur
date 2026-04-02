#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DIST_NAME="blur-Linux-Release-x64"
DIST_DIR="/dist/$DIST_NAME"

echo "==> Creating $DIST_NAME distribution"

# ── Verify prerequisites ──────────────────────────────────────────────────────
[ -f "$PROJECT_DIR/bin/Release/blur" ] || {
    echo "Error: blur binary not found at $PROJECT_DIR/bin/Release/blur"
    echo "Run ci/build-blur-linux.sh first."
    exit 1
}

# ── Create directory structure ────────────────────────────────────────────────
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/lib"
mkdir -p "$DIST_DIR/ffmpeg"
mkdir -p "$DIST_DIR/vapoursynth"
mkdir -p "$DIST_DIR/vapoursynth-plugins"

# ── blur binaries ─────────────────────────────────────────────────────────────
echo "--> Copying binaries"
cp "$PROJECT_DIR/bin/Release/blur"     "$DIST_DIR/blur"
cp "$PROJECT_DIR/bin/Release/blur-cli" "$DIST_DIR/blur-cli"
chmod +x "$DIST_DIR/blur" "$DIST_DIR/blur-cli"

# ── FFmpeg ────────────────────────────────────────────────────────────────────
echo "--> Copying FFmpeg"
cp "$SCRIPT_DIR/out/ffmpeg/ffmpeg"           "$DIST_DIR/ffmpeg/ffmpeg"
cp "$SCRIPT_DIR/out/ffmpeg-shared/bin/ffprobe" "$DIST_DIR/ffmpeg/ffprobe"
chmod +x "$DIST_DIR/ffmpeg/ffmpeg" "$DIST_DIR/ffmpeg/ffprobe"

# ── VapourSynth (vspipe + plugins) ───────────────────────────────────────────
echo "--> Copying VapourSynth"
cp "$SCRIPT_DIR/out/vapoursynth/vspipe" "$DIST_DIR/vapoursynth/vspipe-real"
chmod +x "$DIST_DIR/vapoursynth/vspipe-real"

# Wrapper: sets LD_LIBRARY_PATH / PYTHONHOME / PYTHONPATH so the bundled Python
# and its libraries are found, then exec's the real vspipe binary.
# Also writes ~/.config/vapoursynth/vapoursynth.toml at runtime so VSScript
# can find libpython regardless of where the bundle was extracted.
#
# VSScript (libvsscript.so.4) calls system("vapoursynth config") then reads
# ~/.config/vapoursynth/vapoursynth.toml. The key is the dladdr path to the
# loaded libvsscript.so.4 (= LIB_DIR/libvsscript.so.4 via vspipe-real RUNPATH).
cat > "$DIST_DIR/vapoursynth/vspipe" <<'WRAPPER'
#!/bin/sh
SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
VS_DIR="$(dirname "$SCRIPT")"
BUNDLE_DIR="$(dirname "$VS_DIR")"
LIB_DIR="$BUNDLE_DIR/lib"
PYTHON_DIR="$BUNDLE_DIR/python"

export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PYTHONHOME="$PYTHON_DIR"
export PYTHONPATH="$LIB_DIR:$PYTHON_DIR/lib/python3.12/site-packages"
export PYTHONDONTWRITEBYTECODE=1

# OpenCL ICD: use system vendor dir if present (bare-metal with NVIDIA driver),
# otherwise fall back to the bundled ICD (minimal Docker + --gpus=all).
if [ ! -d /etc/OpenCL/vendors ] || ! ls /etc/OpenCL/vendors/*.icd >/dev/null 2>&1; then
    export OCL_ICD_VENDORS="$BUNDLE_DIR/etc/OpenCL/vendors"
fi

# VSScript reads ~/.config/vapoursynth/vapoursynth.toml to locate libpython.
# The key must be the real path of the loaded libvsscript.so.4 (from dladdr).
# vspipe-real's RUNPATH ($ORIGIN/../lib) loads libvsscript from LIB_DIR, so
# LIB_DIR/libvsscript.so.4 is the key VSScript will look up.
mkdir -p "$HOME/.config/vapoursynth"
# The key must match exactly what dladdr returns for the loaded libvsscript.so.4.
# vspipe-real has RUNPATH $ORIGIN/../lib, so the linker opens it as:
#   <VS_DIR>/../lib/libvsscript.so.4  (with the ".." intact, not normalized)
printf '"%s" = ["%s","%s"]\n' \
    "$VS_DIR/../lib/libvsscript.so.4" \
    "$PYTHON_DIR/bin/python3" \
    "$LIB_DIR/libpython3.12.so.1.0" \
    > "$HOME/.config/vapoursynth/vapoursynth.toml"

exec "$VS_DIR/vspipe-real" "$@"
WRAPPER
chmod +x "$DIST_DIR/vapoursynth/vspipe"

if ls "$SCRIPT_DIR/out/vapoursynth-plugins/"*.so 1>/dev/null 2>&1; then
    cp "$SCRIPT_DIR/out/vapoursynth-plugins/"*.so "$DIST_DIR/vapoursynth-plugins/"
fi

# ── Shared libraries ──────────────────────────────────────────────────────────
echo "--> Copying shared libraries"

# Libs provided by the host — never bundle these:
#   · libc / libm / libpthread / libdl / librt / ld-linux  (glibc ABI, kernel-coupled)
#   · libGL / libEGL / libGLX / libGLdispatch / libvulkan  — GPU/driver (host-specific)
#   · libwayland / libxkbcommon                            — display server (host-specific)
#   · libdbus-1                                            — system bus
#
# libstdc++ and libgcc_s ARE bundled: plugins compiled on Ubuntu 24.04 may use
# newer GLIBCXX symbols not present on older host distros (e.g. Ubuntu 22.04).
SKIP_PATTERN="^libc\\.so|^libm\\.so|^libpthread|^libdl\\.so|^librt\\.so|^ld-linux|^libGL\\.so|^libEGL\\.so|^libGLX\\.so|^libGLdispatch|^libvulkan\\.so|^libwayland|^libxkbcommon\\.so|^libdbus-1\\.so"

# Copy all non-system ldd dependencies of a binary into $DIST_DIR/lib/
collect_deps() {
    local binary="$1"
    ldd "$binary" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read -r lib; do
        bn="$(basename "$lib")"
        echo "$bn" | grep -qE "$SKIP_PATTERN" && continue
        [ -f "$DIST_DIR/lib/$bn" ] || cp -Lp "$lib" "$DIST_DIR/lib/$bn" 2>/dev/null || true
    done
}

# FFmpeg shared libs first (plugins that need them can be scanned afterward)
cp -a "$SCRIPT_DIR/out/ffmpeg-shared/lib/." "$DIST_DIR/lib/"

# VapourSynth shared libraries (both lib variants needed at runtime)
if ls /usr/local/lib/libvapoursynth*.so* 1>/dev/null 2>&1; then
    cp -aP /usr/local/lib/libvapoursynth*.so* "$DIST_DIR/lib/"
    cp -aP /usr/local/lib/libvsscript*.so*    "$DIST_DIR/lib/"
else
    cp -aP "$SCRIPT_DIR/build/vapoursynth/build-dev/"libvapoursynth*.so* "$DIST_DIR/lib/"
    cp -aP "$SCRIPT_DIR/build/vapoursynth/build-dev/"libvsscript*.so*    "$DIST_DIR/lib/"
fi

# libpython3.12 — VSScript dlopen's this at runtime via vspyenv.cfg
find "$SCRIPT_DIR/out/python/lib" -maxdepth 1 -name "libpython*.so*" | while read -r lib; do
    bn="$(basename "$lib")"
    [ -f "$DIST_DIR/lib/$bn" ] || cp -Lp "$lib" "$DIST_DIR/lib/$bn" 2>/dev/null || true
done

# libOpenCL.so.1 — dlopen'd by SVP at runtime; invisible to ldd/collect_deps
# libnvidia-opencl.so.1 itself comes from the host NVIDIA driver, not bundled
find /usr/lib/x86_64-linux-gnu -maxdepth 1 -name "libOpenCL.so*" 2>/dev/null | while read -r lib; do
    cp -Lp "$lib" "$DIST_DIR/lib/$(basename "$lib")" 2>/dev/null || true
done

# OpenCL ICD vendor config — used when the host has no /etc/OpenCL/vendors
# (e.g. a minimal Docker container). libnvidia-opencl.so.1 is provided by the
# host NVIDIA driver (or injected by the NVIDIA Container Toolkit via --gpus=all).
mkdir -p "$DIST_DIR/etc/OpenCL/vendors"
echo "libnvidia-opencl.so.1" > "$DIST_DIR/etc/OpenCL/vendors/nvidia.icd"

# Scan binaries and plugins for remaining dependencies
collect_deps "$DIST_DIR/blur"
collect_deps "$DIST_DIR/blur-cli"
collect_deps "$DIST_DIR/vapoursynth/vspipe-real"

for plugin in "$DIST_DIR/vapoursynth-plugins/"*.so; do
    [ -f "$plugin" ] && collect_deps "$plugin"
done

collect_deps "$DIST_DIR/ffmpeg/ffmpeg"
collect_deps "$DIST_DIR/ffmpeg/ffprobe"

# ── Python environment ────────────────────────────────────────────────────────
echo "--> Copying Python environment"
cp -a "$SCRIPT_DIR/out/python/." "$DIST_DIR/python/"

# VapourSynth Python wheel — contains vapoursynth.abi3.so, libvsscript.so.4, vspipe, etc.
VS_MODULE="/usr/local/lib/python3.12/site-packages/vapoursynth"
if [ -d "$VS_MODULE" ]; then
    mkdir -p "$DIST_DIR/python/lib/python3.12/site-packages"
    cp -rp "$VS_MODULE" "$DIST_DIR/python/lib/python3.12/site-packages/vapoursynth"
fi

# Scan the VapourSynth Python extension now that it exists
VS_PY_SO=$(find "$DIST_DIR/python/lib/python3.12/site-packages/vapoursynth" -name "*.so" 2>/dev/null | head -1)
[ -n "$VS_PY_SO" ] && collect_deps "$VS_PY_SO"

# ── RIFE models ───────────────────────────────────────────────────────────────
echo "--> Copying RIFE models"
if [ -d "$SCRIPT_DIR/out/models" ]; then
    cp -a "$SCRIPT_DIR/out/models" "$DIST_DIR/models"
fi

# ── VapourSynth scripts (blur.py etc.) ───────────────────────────────────────
echo "--> Copying VapourSynth scripts"
cp -a "$PROJECT_DIR/bin/Release/lib/." "$DIST_DIR/lib/"

# ── Set rpath so binaries find their bundled libs via $ORIGIN ─────────────────
echo "--> Setting rpath"
patchelf --force-rpath --set-rpath '$ORIGIN/lib'    "$DIST_DIR/blur"
patchelf --force-rpath --set-rpath '$ORIGIN/lib'    "$DIST_DIR/blur-cli"
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$DIST_DIR/vapoursynth/vspipe-real"
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$DIST_DIR/ffmpeg/ffmpeg"
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$DIST_DIR/ffmpeg/ffprobe"

for plugin in "$DIST_DIR/vapoursynth-plugins/"*.so; do
    [ -f "$plugin" ] && patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$plugin" 2>/dev/null || true
done

# Patch the VapourSynth wheel's shared libs so they find bundled deps in lib/.
# $ORIGIN/../../../../../lib resolves to BUNDLE_DIR/lib from site-packages/vapoursynth/
VS_WHEEL_DIR="$DIST_DIR/python/lib/python3.12/site-packages/vapoursynth"
for f in "$VS_WHEEL_DIR"/*.so "$VS_WHEEL_DIR"/*.so.*; do
    [ -f "$f" ] && patchelf --set-rpath '$ORIGIN:$ORIGIN/../../../../../lib' "$f" 2>/dev/null || true
done

# Note: This VapourSynth build (R74+) does NOT use vspyenv.cfg.
# Instead VSScript calls system("vapoursynth config") then reads
# ~/.config/vapoursynth/vapoursynth.toml. The vspipe wrapper handles writing
# that file at runtime with the correct bundle-relative paths.

# ── Remove __pycache__ directories ───────────────────────────────────────────
find "$DIST_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# ── Strip debug symbols ───────────────────────────────────────────────────────
strip --strip-unneeded "$DIST_DIR/blur"     2>/dev/null || true
strip --strip-unneeded "$DIST_DIR/blur-cli" 2>/dev/null || true

echo ""
echo "==> Distribution ready: $DIST_DIR"
echo "    Size: $(du -sh "$DIST_DIR" | cut -f1)"
echo ""
echo "    To run:"
echo "      $DIST_NAME/blur          # GUI"
echo "      $DIST_NAME/blur-cli      # CLI"
