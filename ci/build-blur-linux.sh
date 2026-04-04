#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --configure-only: run cmake configure (triggers vcpkg install) but skip the build.
# Used in Docker to cache the expensive vcpkg step in an earlier layer.
CONFIGURE_ONLY=0
if [ "${1:-}" = "--configure-only" ]; then
  CONFIGURE_ONLY=1
fi

echo "Building blur for Linux"

git config --global --add safe.directory "$PROJECT_DIR"

# initialize submodules (imgui, stb) — skipped in Docker where .git is absent
if [ -d "$PROJECT_DIR/.git" ]; then
  git -C "$PROJECT_DIR" submodule update --init --depth 1
fi

# install vcpkg
if [ ! -d "$SCRIPT_DIR/vcpkg" ]; then
  git clone https://github.com/microsoft/vcpkg.git --depth 1 "$SCRIPT_DIR/vcpkg"
  "$SCRIPT_DIR/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
fi

# ensure overlay-ports dir exists (may be absent if .dockerignore excluded all its files)
mkdir -p "$SCRIPT_DIR/overlay-ports"

# cmake configure — also runs vcpkg install
cmake -S "$PROJECT_DIR" -B "$SCRIPT_DIR/build/blur" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_OVERLAY_PORTS="$SCRIPT_DIR/overlay-ports"

[ "$CONFIGURE_ONLY" = "1" ] && exit 0

cmake --build "$SCRIPT_DIR/build/blur" --config Release --parallel

echo "Built: $(find "$PROJECT_DIR/bin/Release" -name 'blur' -type f)"
