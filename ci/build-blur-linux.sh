#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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

# build blur
cmake -S "$PROJECT_DIR" -B "$SCRIPT_DIR/build/blur" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_OVERLAY_PORTS="$SCRIPT_DIR/overlay-ports"

cmake --build "$SCRIPT_DIR/build/blur" --config Release --parallel

echo "Built: $(find "$PROJECT_DIR/bin/Release" -name 'blur' -type f)"
