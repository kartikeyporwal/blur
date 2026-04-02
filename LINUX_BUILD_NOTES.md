# blur Linux Port — Build, Debug & Fix Notes

A full record of every issue encountered, the root cause analysis, the fix applied, and the
underlying technical learning. Useful for future maintainers or when revisiting the Linux build.

---

## Table of Contents

1. [Build Pipeline Overview](#1-build-pipeline-overview)
2. [Issue: "Failed to initialize VSScript"](#2-issue-failed-to-initialize-vsscript)
3. [Issue: Docker creates root-owned output files](#3-issue-docker-creates-root-owned-output-files)
4. [Issue: ffmpeg "cannot open shared object file"](#4-issue-ffmpeg-cannot-open-shared-object-file)
5. [Issue: `env` not passed to child processes](#5-issue-env-not-passed-to-child-processes)
6. [Issue: GPU not used (CPU fallback)](#6-issue-gpu-not-used-cpu-fallback)
7. [Issue: overlay-ports missing in Docker context](#7-issue-overlay-ports-missing-in-docker-context)
8. [Issue: nvenc API version mismatch](#8-issue-nvenc-api-version-mismatch)
9. [Issue: BtbN pinned URL fails inside Docker](#9-issue-btbn-pinned-url-fails-inside-docker)
10. [Key Architecture Decisions](#10-key-architecture-decisions)
11. [File Reference](#11-file-reference)

---

## 1. Build Pipeline Overview

```
docker build -t blur-linux -f ci/Dockerfile .
docker run --rm -v "$(pwd):/out" blur-linux
```

The Dockerfile has four logical stages, structured to maximise Docker layer caching:

| Stage | Script | What it does | Invalidated when |
|---|---|---|---|
| 1 – deps | `build-dependencies-linux.sh` | Builds FFmpeg, VapourSynth, Python, plugins, RIFE models | Script changes |
| 2 – blur | `build-blur-linux.sh` | Clones vcpkg, runs cmake + ninja | `src/`, `CMakeLists.txt`, `vcpkg.json` change |
| 3 – package | `package-linux.sh` | Assembles `blur-Linux-Release-x64/` dir, patches rpath, copies libs | `resources/`, packaging script changes |
| 4 – AppImage | `build-appimage.sh` | Wraps the dist dir into an AppImage | AppImage script changes |

The final image is a minimal ubuntu:22.04 that copies `/dist` on `docker run`.

**Target compatibility**: Ubuntu 22.04 (glibc 2.35). The packaging script enforces this with a
glibc version check over every bundled binary.

---

## 2. Issue: "Failed to initialize VSScript"

### Symptom
```
Failed to initialize VSScript
```
Running `./vapoursynth/vspipe --version` reproduced it immediately.

### Investigation
Used `strace` on `vspipe-real` and `strings` on `libvsscript.so.4`.

Key findings:
- `strings libvsscript.so.4 | grep vspyenv` → **zero results**. The string `vspyenv.cfg` does
  not exist in the binary at all.
- `strings libvsscript.so.4 | grep toml` → found `vapoursynth.toml`.
- `strace` showed: `system("vapoursynth config >/dev/null 2>&1")` is called first (to populate
  the toml), then `open("~/.config/vapoursynth/vapoursynth.toml", ...)`.

### Root cause
VapourSynth **R74+** dropped `vspyenv.cfg` entirely. It now reads
`~/.config/vapoursynth/vapoursynth.toml`. The existing vspipe wrapper was writing a
`vspyenv.cfg` that was completely ignored.

### toml format
```toml
"/abs/path/to/libvsscript.so.4" = ["/abs/path/to/python3", "/abs/path/to/libpython3.12.so.1.0"]
```
The **key is the `dladdr` path** — i.e., the exact filesystem path the dynamic linker opened
`libvsscript.so.4` from. Because `vspipe-real` has RUNPATH `$ORIGIN/../lib`, the linker opens:
```
<vs_dir>/../lib/libvsscript.so.4
```
with the `..` intact (not normalised). The key must use this same un-normalised path.

### Fix — `ci/package-linux.sh` vspipe wrapper
The wrapper now writes `vapoursynth.toml` at runtime, deriving all paths from `$0`:

```sh
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

mkdir -p "$HOME/.config/vapoursynth"
# Key must use the un-normalised path that dladdr returns:
#   VS_DIR/../lib/libvsscript.so.4   (NOT the resolved absolute path)
printf '"%s" = ["%s","%s"]\n' \
    "$VS_DIR/../lib/libvsscript.so.4" \
    "$PYTHON_DIR/bin/python3" \
    "$LIB_DIR/libpython3.12.so.1.0" \
    > "$HOME/.config/vapoursynth/vapoursynth.toml"

exec "$VS_DIR/vspipe-real" "$@"
```

### Learning
- `vspyenv.cfg` is a **VapourSynth pre-R74 artefact**. Do not reference it for R74+.
- The toml key must match exactly what `dladdr()` returns for the loaded `.so`, including any
  non-canonical `..` path components from the RUNPATH expansion.
- `strace` + `strings` on the `.so` is the fastest way to discover what config mechanism a
  closed binary actually uses.

---

## 3. Issue: Docker creates root-owned output files

### Symptom
After `docker run --rm -v "$(pwd):/out" blur-linux`, the output directory
`blur-Linux-Release-x64/` was owned by `root:root`, making the user unable to delete or edit files.

### Root cause
Processes inside Docker containers run as root by default. All files created (via `cp`) inherit
root ownership. The host volume mount sees the same UIDs as-is.

### Fix — `Dockerfile` CMD
The CMD uses `stat -c '%u:%g' /out` to read the host user's UID:GID from the mounted volume
directory, then `chown -R` all output files to match:

```dockerfile
CMD ["sh", "-c", "\
  cp -r /dist/blur-Linux-Release-x64 /out/ && \
  cp /dist/blur-Linux-x86_64.AppImage /out/ && \
  chown -R \"$(stat -c '%u:%g' /out)\" \
    /out/blur-Linux-Release-x64/ \
    /out/blur-Linux-x86_64.AppImage \
"]
```

### Learning
- Always chown Docker output to the volume directory owner, not hardcoded UIDs.
- `stat -c '%u:%g' /out` is the portable one-liner to get the host user's UID:GID from inside
  a container.

---

## 4. Issue: ffmpeg "cannot open shared object file"

### Symptom
Running `./ffmpeg/ffmpeg` directly from the bundle:
```
ffmpeg: error while loading shared libraries: libavdevice.so.62: cannot open shared object file
```

### Root cause
The `ffmpeg` binary had no RUNPATH embedded. It could only find `libavdevice.so.62` via
`LD_LIBRARY_PATH`. When invoked directly by a user (not through blur's child-process code which
sets `LD_LIBRARY_PATH`), the loader found nothing.

### Fix — `ci/package-linux.sh`
```bash
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$DIST_DIR/ffmpeg/ffmpeg"
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$DIST_DIR/ffmpeg/ffprobe"
```
`$ORIGIN` expands to the directory containing the binary at runtime. `../lib` from
`bundle/ffmpeg/` resolves to `bundle/lib/` where all bundled `.so` files live.

### Note on blur's internal calls
When blur launches ffmpeg as a child process, it always sets `LD_LIBRARY_PATH` in the child
environment. So internal rendering was never broken — only direct invocation by users failed.

### Learning
- `patchelf --set-rpath` (with `--force-rpath` to override any existing RUNPATH) is the standard
  way to make a binary self-contained without requiring `LD_LIBRARY_PATH`.
- `$ORIGIN` is a dynamic linker special token meaning "directory of this ELF file".
- RPATH (legacy) is searched before `LD_LIBRARY_PATH`; RUNPATH (modern) is searched after.
  `--force-rpath` writes the old-style RPATH tag which has higher priority and is non-transitive.

---

## 5. Issue: `env` not passed to child processes

### Symptom
- `ffprobe` (used in `get_video_info()`) silently ran without bundle libs — no explicit error,
  but library loading failures caused silent wrong-path issues.
- GPU encoder detection (`get_hardware_encoding_devices()`) would fail or return wrong results
  on Linux because the second ffmpeg call ran without `LD_LIBRARY_PATH`.

### Root cause (`src/common/utils.cpp`)
Two separate bugs in `boost::process` child construction:

**Bug 1** — `get_video_info()`: `env` object was built with `LD_LIBRARY_PATH` set but was never
passed to the `bp::child` constructor:
```cpp
// BEFORE (broken):
bp::child c(blur.ffprobe_path.wstring(), ..., bp::std_out > pipe_stream, bp::std_err > bp::null);
//                                                          ^^^^^^^^^^^^^ env missing

// AFTER (fixed):
bp::child c(blur.ffprobe_path.wstring(), ..., bp::std_out > pipe_stream, bp::std_err > bp::null, env);
```

**Bug 2** — `get_hardware_encoding_devices()`: `env` was passed to the first `bp::child c`
(the `-hwaccels` query) but **not** to the second `bp::child c2` (the `-encoders` query):
```cpp
// AFTER (fixed):
bp::child c2(
    blur.ffmpeg_path.wstring(),
    "-v", "error", "-hide_banner", "-encoders",
    bp::std_out > encoder_stream,
    bp::std_err > bp::null,
    env    // ← was missing
);
```

### Learning
- `boost::process::environment` is not implicitly inherited by children — it must be passed
  **explicitly** to every `bp::child(...)` constructor call.
- Creating an `env` object but forgetting to pass it is a silent bug: the child just uses the
  parent's environment unmodified, which on Linux means no `LD_LIBRARY_PATH` pointing to the
  bundle.
- When in doubt, grep for every `bp::child(` in the codebase and verify `env` appears in each.

---

## 6. Issue: GPU not used (CPU fallback)

### Symptom
`./blur` would open, load a video, and render using CPU instead of GPU for RIFE interpolation.
Logs showed CPU-based processing and no GPU index was selected.

### Root cause (two sub-issues)

**Sub-issue A** — `src/vapoursynth/get_rife_gpus.py` only handled `macos_bundled`, not
`linux_bundled`:
```python
# BEFORE — macOS only:
if vars().get("macos_bundled") == "true":
    for dylib in plugin_dir.glob("*.dylib"):
        core.std.LoadPlugin(path=str(dylib))

# Result on Linux: core.rife doesn't exist → "No attribute with the name rife exists"
core.rife.RIFE(video, list_gpu=True)  # ← crashes
```

The RIFE ncnn plugin was never loaded on Linux, so `core.rife` was unavailable and GPU
enumeration always failed silently, leaving the GPU map empty.

**Sub-issue B** — `src/common/utils.cpp` `get_rife_gpus()` did not pass `-a linux_bundled=true`
to vspipe, so even after fixing the script it would never receive the flag:
```cpp
// BEFORE — no linux_bundled argument:
bp::child c(blur.vspipe_path.wstring(), L"-c", L"y4m", get_gpus_script_path, L"-", ...);

// AFTER:
bp::child c(
    blur.vspipe_path.wstring(),
    L"-c", L"y4m",
#ifdef __linux__
    L"-a", L"linux_bundled=true",
#endif
    get_gpus_script_path, L"-", ...
);
```

### Fix — `src/vapoursynth/get_rife_gpus.py`
```python
if vars().get("linux_bundled") == "true":
    plugin_dir = Path(__file__).parent.parent / "vapoursynth-plugins"
    for plugin in sorted(plugin_dir.glob("*.so")):
        core.std.LoadPlugin(path=str(plugin))
```

This mirrors the pattern already in `blur.py` for `linux_bundled`.

### Learning
- VapourSynth plugins must be explicitly `LoadPlugin`'d on Linux — there's no auto-discovery
  for bundled `.so` files. `blur.py` has the pattern; any other script that uses ncnn plugins
  must replicate it.
- The `-a key=value` vspipe argument injects a Python variable into the script namespace
  (accessible via `vars().get("key")`). It's the mechanism for passing runtime flags to scripts.
- When GPU detection silently fails, the default GPU index (0 or -1) is used, which may still
  work but bypass the benchmark-based selection.

---

## 7. Issue: overlay-ports missing in Docker context

### Symptom
```
Overlay path "/workspace/ci/overlay-ports" must be an existing directory.
-- Running vcpkg install - failed
CMake Error: vcpkg install failed.
```

### Root cause
`.dockerignore` excludes `ci/overlay-ports/sdl3/fix-freebsd.patch` (the only file in that
directory). Docker never creates an empty directory, so `ci/overlay-ports/` did not exist inside
the container. vcpkg's cmake toolchain then rejected the `-DVCPKG_OVERLAY_PORTS` path.

### Fix — `ci/build-blur-linux.sh`
```bash
# ensure overlay-ports dir exists (may be absent if .dockerignore excluded all its files)
mkdir -p "$SCRIPT_DIR/overlay-ports"
```
Added before the `cmake` call. `mkdir -p` is idempotent — safe if the directory already exists.

### Learning
- `.dockerignore` excludes files, not directories. If you exclude every file inside a directory,
  the directory itself disappears from the Docker context.
- Defensive `mkdir -p` before referencing an expected-but-possibly-absent directory is good
  practice in build scripts, especially when `.dockerignore` is involved.

---

## 8. Issue: nvenc API version mismatch

### Symptom (first encounter)
```
[h264_nvenc] Driver does not support the required nvenc API version. Required: 13.0 Found: 12.1
[h264_nvenc] The minimum required Nvidia driver for nvenc is 570.0 or newer
```

### Symptom (second encounter — after pinning to Dec 2024 build)
```
[h264_nvenc] Driver does not support the required nvenc API version. Required: 12.2 Found: 12.1
[h264_nvenc] The minimum required Nvidia driver for nvenc is 550.54.14 or newer
```

### Root cause
The bundled FFmpeg binary was compiled against `nv-codec-headers` that define a minimum nvenc API
version higher than what the host NVIDIA driver provides.

NVIDIA driver / nvenc API compatibility matrix:

| nv-codec-headers version | Min nvenc API required | Min NVIDIA driver |
|---|---|---|
| n12.1.x | 12.1 | 530.41.03 |
| n12.2.x | 12.2 | 550.54.14 |
| n13.0.x (released 2025-01-30) | 13.0 | 570.0 |

The host driver is **535**, which supports nvenc API **12.1 only**.

Using the BtbN `latest` build (March 2026) requires nvenc 13.0.  
Pinning to the BtbN December 2024 autobuild still required nvenc 12.2.

### Resolution strategy
Pre-built BtbN archives old enough to use nvenc 12.1 headers are no longer reliably available
(2-year CDN retention window). The BtbN download URLs also fail inside Docker because the GitHub
CDN redirect behaves differently in some network environments.

**Solution: build FFmpeg 7.1 from source inside Docker** with `nv-codec-headers` pinned to
`n12.1.14.0` (the last release requiring only nvenc 12.1):

In `ci/build-dependencies-linux.sh`:
```bash
# Install nv-codec-headers 12.1 — compatible with driver 530-549
mkdir -p download/nv-codec-headers && cd download/nv-codec-headers
wget -q https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n12.1.14.0.tar.gz \
     -O nv-codec-headers.tar.gz
tar -xzf nv-codec-headers.tar.gz --strip-components=1
make install PREFIX=/usr/local
cd ../..

# Build FFmpeg 7.1 from source
./configure \
  --prefix=/usr/local \
  --enable-shared --disable-static \
  --enable-gpl --enable-version3 \
  --enable-ffnvcodec \     # enables NVENC/NVDEC via the installed nv-codec-headers
  --enable-libx264 --enable-libx265 \
  ...
make -j"$(nproc)" && make install && ldconfig
```

### Learning
- nvenc API version is a **compile-time constant** baked into the FFmpeg binary from the
  `nv-codec-headers` it was built against. It cannot be changed at runtime.
- BtbN "latest" builds roll forward constantly. Never use `latest` for a production bundle —
  always pin to a specific version or build from source.
- Building FFmpeg from source inside Docker is the most reliable approach for version-controlled
  nvenc support. It adds ~5 minutes to the build but is fully reproducible.
- GitHub release asset CDN URLs (`releases/download/...`) can behave differently from inside
  Docker vs from a host machine (different network routing, missing cookies/redirects).
- The `--enable-ffnvcodec` flag is what tells FFmpeg to use the installed `nv-codec-headers`.
  Without it, nvenc support is omitted even if the headers are installed.
- `libssl-dev` and other codec libraries must be present in the Docker build image before
  `./configure` is run.

---

## 9. Issue: BtbN pinned URL fails inside Docker

### Symptom
```
ERROR: failed to build: ... exit code: 8
```
`wget` exit code 8 = "Server issued an error response".

### Investigation
```bash
# Works from host:
wget -q --spider "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-.../..." 2>&1
# exit: 0

# Works from inside Docker too (confirmed):
docker run --rm ubuntu:24.04 sh -c "apt-get install -y -q wget 2>/dev/null && \
  wget -q --spider 'https://github.com/.../...' 2>&1; echo exit:$?"
# exit: 0
```

The URL was reachable from both environments, meaning the issue was either:
- An incorrect asset filename (asset name in autobuild releases includes a commit hash, e.g.
  `ffmpeg-N-118197-gbb85423142-linux64-gpl-shared.tar.xz`, which may be wrong)
- Docker layer caching serving a layer built with the old broken URL

### Root cause (confirmed)
Docker layer caching: the `COPY ci/build-dependencies-linux.sh` step was CACHED with the old URL
because the build was run without `--no-cache` after the fix was applied. The container ran the
old script with the old (404) URL.

Always use `--no-cache` after changing `build-dependencies-linux.sh` since that layer is near
the start of the Dockerfile.

### Learning
- Docker caches COPY layers by file content hash. If you change a file, the cache is
  invalidated — but only if `--no-cache` is NOT passed and the hash really changed. When unsure,
  use `--no-cache`.
- Asset filenames in BtbN autobuild releases include commit hashes (`N-XXXXXX-gHASH`) that
  cannot be guessed. Use the GitHub API (`/repos/BtbN/FFmpeg-Builds/releases?per_page=50`) to
  discover the real asset names for a specific tag.
- Building from source avoids all of these URL fragility issues.

---

## 10. Key Architecture Decisions

### RPATH embedding (`patchelf`)
Every binary in the bundle has `$ORIGIN`-relative RPATH embedded so it can find bundled
libraries without `LD_LIBRARY_PATH`:

| Binary | RPATH set |
|---|---|
| `blur`, `blur-cli` | `$ORIGIN/lib` |
| `vapoursynth/vspipe-real` | `$ORIGIN/../lib` |
| `ffmpeg/ffmpeg`, `ffmpeg/ffprobe` | `$ORIGIN/../lib` |
| `vapoursynth-plugins/*.so` | `$ORIGIN/../lib` |
| `python/.../vapoursynth/*.so` | `$ORIGIN:$ORIGIN/../../../../../lib` |

### Library bundling policy
System/GPU libraries are intentionally **not** bundled:

| Library | Reason |
|---|---|
| `libc`, `libm`, `libpthread`, etc. | glibc ABI is kernel-coupled |
| `libGL`, `libEGL`, `libGLX`, `libvulkan` | GPU/driver-specific |
| `libwayland`, `libxkbcommon` | display-server-specific |
| `libdbus-1` | system bus |
| `libnvidia-opencl.so.1` | provided by NVIDIA driver |

These are intentionally NOT bundled and must come from the host.

`libstdc++` and `libgcc_s` **are** bundled because VapourSynth plugins compiled on Ubuntu 24.04
may reference newer `GLIBCXX` symbols absent on Ubuntu 22.04.

### OpenCL ICD handling
The bundle ships `libOpenCL.so.1` (the ICD loader from `ocl-icd-libopencl1`) and a minimal
`etc/OpenCL/vendors/nvidia.icd` containing `libnvidia-opencl.so.1`. The `vspipe` wrapper sets
`OCL_ICD_VENDORS` to point to the bundled ICD only when the host `/etc/OpenCL/vendors/` is
absent (e.g. in a minimal Docker container with `--gpus=all`). On a real Linux desktop with the
NVIDIA driver installed, the host ICD directory takes precedence.

### vapoursynth.toml — why it's written at runtime not at package time
The toml key must be an absolute path. The bundle can be extracted anywhere by the user, so the
absolute path cannot be known at package time. The vspipe wrapper resolves `$0` at runtime to
construct the correct path.

### glibc version enforcement
`package-linux.sh` scans every bundled ELF file for the highest `GLIBC_x.y` version symbol
it requires and fails the build if any binary needs glibc > 2.35 (Ubuntu 22.04's version).
This catches accidental linkage against too-new system libraries before the bundle ships.

---

## 11. File Reference

| File | Purpose |
|---|---|
| `ci/Dockerfile` | Multi-stage Docker build; 4 stages + minimal runtime image |
| `ci/build-dependencies-linux.sh` | Builds FFmpeg (from source), VapourSynth, Python, plugins, models |
| `ci/build-blur-linux.sh` | Builds the blur application via vcpkg + cmake + ninja |
| `ci/package-linux.sh` | Assembles portable bundle; writes vspipe wrapper; patches rpath |
| `ci/build-appimage.sh` | Packages bundle as AppImage |
| `src/common/utils.cpp` | `get_rife_gpus()`, `get_hardware_encoding_devices()`, `get_video_info()` |
| `src/common/rendering.cpp` | `do_render()` — sets Linux env vars for vspipe/ffmpeg child processes |
| `src/common/rendering_frame.cpp` | Preview renderer child process env setup |
| `src/common/blur.cpp` | Sets `vspipe_path`, `ffmpeg_path`, `ffprobe_path` for Linux |
| `src/vapoursynth/blur.py` | Main VapourSynth script; handles `linux_bundled` plugin loading |
| `src/vapoursynth/get_rife_gpus.py` | GPU enumeration script; must load plugins for Linux |
| `.dockerignore` | Excludes `ci/vcpkg/`, `ci/build/`, `ci/download/`, `ci/out/`, `blur-Linux-Release-x64/`, `.git/` |

### Quick diagnostics

```bash
# Test vspipe works
./vapoursynth/vspipe --version

# Test ffmpeg can find its bundled libs
./ffmpeg/ffmpeg -version

# Test nvenc is functional with host driver
./ffmpeg/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=black:s=1280x720 -vframes 1 -an \
  -c:v h264_nvenc -f null -

# Manually test GPU detection script
./vapoursynth/vspipe -c y4m -a linux_bundled=true lib/get_rife_gpus.py - 2>&1

# Check what toml is currently written
cat ~/.config/vapoursynth/vapoursynth.toml

# Check what driver supports
nvidia-smi  # shows driver version
# Driver 530+ → nvenc 12.1
# Driver 550+ → nvenc 12.2
# Driver 570+ → nvenc 13.0
```

### nvenc API / NVIDIA Driver quick reference

| You have | nvenc API | Need FFmpeg built with |
|---|---|---|
| Driver 530–549 | 12.1 | nv-codec-headers n12.1.x |
| Driver 550–569 | 12.2 | nv-codec-headers n12.1.x or n12.2.x |
| Driver 570+ | 13.0 | any version |
| Ubuntu 22.04 default (535) | 12.1 | **nv-codec-headers n12.1.14.0** ← current build pins to this |
