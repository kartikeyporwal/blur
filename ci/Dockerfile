FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Add extra apt repositories ────────────────────────────────────────────────
# LLVM 16: not in Ubuntu 22.04 default repos
# GCC 13: needed for std::format / std::format_string (C++20); ubuntu-toolchain-r PPA
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget gnupg ca-certificates lsb-release software-properties-common \
  && wget -qO /etc/apt/trusted.gpg.d/apt.llvm.org.asc https://apt.llvm.org/llvm-snapshot.gpg.key \
  && echo "deb http://apt.llvm.org/jammy/ llvm-toolchain-jammy-16 main" \
     > /etc/apt/sources.list.d/llvm-16.list \
  && add-apt-repository -y ppa:ubuntu-toolchain-r/test \
  && rm -rf /var/lib/apt/lists/*

# ── System build tools ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core toolchain — GCC 13 for std::format (C++20) support
    build-essential gcc-13 g++-13 ninja-build cmake pkg-config \
    git curl wget zip unzip tar xz-utils \
    autoconf automake autoconf-archive libtool libltdl-dev \
    # Python (for build tooling — VapourSynth uses meson/cython)
    python3 python3-pip \
    # Assembler (needed by FFmpeg codec builds)
    nasm \
    # LLVM/Clang — akarin requires >= 10 && < 17, so install 16 alongside the default
    llvm llvm-dev clang \
    llvm-16 llvm-16-dev clang-16 \
    # patchelf — embeds $ORIGIN rpath in binaries for portable distribution
    patchelf \
    # FUSE + kmod (used by some build tooling)
    fuse kmod \
    # VapourSynth build dependencies
    libxxhash-dev libfftw3-dev meson \
    # X11 / GL / Wayland headers — required so vcpkg builds SDL3 with display support
    libx11-dev libxext-dev libxrandr-dev libxft-dev \
    libdbus-1-dev \
    libwayland-dev libxkbcommon-dev \
    libgl1-mesa-dev libegl1-mesa-dev \
    libibus-1.0-dev \
    # Headers for vcpkg packages (lzma/zstd/lz4 used by sdbus-cpp / boost)
    liblz4-dev liblzma-dev libzstd-dev \
  && rm -rf /var/lib/apt/lists/* \
  && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100 \
  && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100 \
  && update-alternatives --install /usr/bin/cc  cc  /usr/bin/gcc-13 100 \
  && update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-13 100

# Install a recent meson via pip — the apt version (≤1.0) is too old for some VS builds
RUN pip3 install meson

WORKDIR /workspace

# ── Stage 1: build all dependencies (heavy — cached unless scripts change) ───
COPY ci/build-dependencies-linux.sh ci/
RUN cd ci && ./build-dependencies-linux.sh

# Additional Python packages required by vcpkg's libsystemd meson build
RUN pip3 install jinja2 docutils

# ── Stage 2: build blur ───────────────────────────────────────────────────────
# Copy only what build-blur-linux.sh needs — package-linux.sh and build-appimage.sh
# are copied later so changes to them don't invalidate this expensive cache layer.
COPY ci/build-blur-linux.sh ci/build-blur-linux.sh
COPY src/ src/
COPY tests/ tests/
COPY dependencies/ dependencies/
COPY CMakeLists.txt CMakePresets.json vcpkg.json ./

# Initialize submodules if they weren't pre-populated (fallback for Docker builds)
RUN if [ ! -f dependencies/imgui/imgui.h ]; then \
        git clone --depth 1 https://github.com/ocornut/imgui.git dependencies/imgui; \
    fi && \
    if [ ! -f dependencies/stb/stb_image.h ]; then \
        git clone --depth 1 https://github.com/nothings/stb.git dependencies/stb; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsystemd-dev \
  && rm -rf /var/lib/apt/lists/*
RUN ci/build-blur-linux.sh

# ── Stage 3: assemble the portable distribution directory ────────────────────
# Copy packaging scripts here — changes only invalidate from this point onward.
COPY ci/package-linux.sh ci/package-linux.sh
COPY resources/ resources/
# ocl-icd-libopencl1 provides libOpenCL.so.1 — the ICD loader used by SVP at
# runtime. It's bundled into the distribution so it works in minimal containers
# (e.g. Docker with --gpus=all) that don't have OpenCL packages installed.
RUN apt-get update && apt-get install -y --no-install-recommends ocl-icd-libopencl1 \
  && rm -rf /var/lib/apt/lists/*
RUN ci/package-linux.sh

# ── Stage 4: package as AppImage ─────────────────────────────────────────────
COPY ci/build-appimage.sh ci/build-appimage.sh
RUN ci/build-appimage.sh

# ── Runtime: minimal image that outputs the distribution ─────────────────────
FROM ubuntu:22.04

COPY --from=0 /dist /dist

# Default command: copy the directory bundle and AppImage to /out, then chown
# all output files to match the host user (identified by the owner of /out).
CMD ["sh", "-c", "\
  cp -r /dist/blur-Linux-Release-x64 /out/ && \
  cp /dist/blur-Linux-x86_64.AppImage /out/ && \
  cp /dist/blur-cli-Linux-x86_64.AppImage /out/ && \
  cp /dist/blur.sh /out/ && \
  cp /dist/blur-cli.sh /out/ && \
  chown -R \"$(stat -c '%u:%g' /out)\" \
    /out/blur-Linux-Release-x64/ \
    /out/blur-Linux-x86_64.AppImage \
    /out/blur-cli-Linux-x86_64.AppImage \
    /out/blur.sh \
    /out/blur-cli.sh \
"]
