#!/bin/bash
set -e

out_dir=out

echo "Building dependencies for Linux"

apt-get update
apt-get install -y libxxhash-dev \
  wget \
  unzip \
  xz-utils \
  git \
  meson \
  nasm \
  cmake \
  libfftw3-dev \
  llvm llvm-dev clang build-essential \
  fuse \
  libgl1-mesa-dev \
  kmod

# clean outputs every run
rm -rf $out_dir
mkdir -p $out_dir

download_library() {
  local url="$1"
  local filename="$2"
  local out_path="$3"

  dest_path="$out_dir/$out_path"
  mkdir -p "$dest_path"

  echo "Downloading $filename"
  wget -q "$url" -O "$dest_path/$filename"
}

download_archive() {
  local url="$1"
  local dir_name="$2"
  local out_path="$3"
  local subfolder="$4"

  original_dir=$(pwd)

  mkdir -p download
  cd download

  if [ -d "$dir_name" ]; then
    echo "$dir_name already exists. Skipping download."
    cd "$dir_name"
  else
    mkdir -p "$dir_name" && cd "$dir_name"

    echo "Downloading $dir_name"

    if [[ "$url" == *.zip ]]; then
      wget -q "$url" -O "$dir_name.zip"
      unzip "$dir_name.zip"
      rm "$dir_name.zip"
    elif [[ "$url" == *.tar.xz ]]; then
      wget -q "$url" -O "$dir_name.tar.xz"
      tar -xf "$dir_name.tar.xz"
      rm "$dir_name.tar.xz"
    else
      echo "Unsupported archive format: $url"
      cd "$original_dir"
      return 1
    fi
  fi

  dest_path="$original_dir/$out_dir/$out_path"

  echo "Copying files from $subfolder to $dest_path"

  cp -r "${subfolder:=.}" "$dest_path"

  cd "$original_dir"
}

build() {
  local repo="$1"
  local pull_args="$2"
  local name="$3"
  local build_cmd="$4"
  local lib_path="$5"
  local out_path="$6"

  echo "--- Building $name ---"

  mkdir -p build
  cd build

  if [ ! -d "$name" ]; then
    echo "Cloning $name..."
    # shellcheck disable=SC2086
    git clone $pull_args "$repo" "$name"
    cd "$name"
  else
    echo "Updating $name..."
    cd "$name"
    git pull
  fi

  eval "$build_cmd"

  # copy built stuff
  dest_path="../../$out_dir/$out_path"
  mkdir -p "$dest_path"

  if [[ -n "$lib_path" ]]; then
    echo "Copying $name libraries to $dest_path"
    find "$lib_path" -name "*.so" -exec cp {} "$dest_path" \;
  else
    echo "Skipping copy: lib_path is empty"
  fi

  cd ../..
}

# downloads / builds

## nv-codec-headers 12.1 — compatible with NVIDIA driver 530-549 (nvenc API 12.1).
## Pre-built BtbN archives old enough to use 12.1 are no longer available (2-year
## retention expired), so we pin the headers and build FFmpeg from source instead.
echo "--- Installing nv-codec-headers n12.1.14.0 ---"
mkdir -p download/nv-codec-headers
cd download/nv-codec-headers
if [ ! -f "Makefile" ]; then
  wget -q https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n12.1.14.0.tar.gz -O nv-codec-headers.tar.gz
  tar -xzf nv-codec-headers.tar.gz --strip-components=1
  rm nv-codec-headers.tar.gz
fi
make install PREFIX=/usr/local
cd ../..

## ffmpeg 7.1 — built from source with shared libs and nvenc 12.1 headers
echo "--- Building FFmpeg 7.1 ---"
apt-get install -y -q \
  libx264-dev libx265-dev libvpx-dev libmp3lame-dev libopus-dev \
  libvorbis-dev libass-dev libfreetype6-dev libfontconfig1-dev \
  libdav1d-dev libwebp-dev libxvidcore-dev libssl-dev libzimg-dev

mkdir -p download/ffmpeg-src
cd download/ffmpeg-src
if [ ! -f "configure" ]; then
  wget -q https://ffmpeg.org/releases/ffmpeg-7.1.tar.xz -O ffmpeg.tar.xz
  tar -xf ffmpeg.tar.xz --strip-components=1
  rm ffmpeg.tar.xz
fi
./configure \
  --prefix=/usr/local \
  --enable-shared --disable-static \
  --enable-gpl --enable-version3 \
  --disable-debug --disable-doc \
  --enable-libx264 --enable-libx265 \
  --enable-libvpx --enable-libmp3lame \
  --enable-libopus --enable-libvorbis \
  --enable-libass --enable-libfreetype \
  --enable-fontconfig --enable-libdav1d \
  --enable-libwebp --enable-libxvid \
  --enable-ffnvcodec \
  --enable-zlib --enable-bzlib --enable-lzma --enable-iconv \
  --extra-cflags="-I/usr/local/include" \
  --extra-ldflags="-L/usr/local/lib"
make -j"$(nproc)"
make install
ldconfig
cd ../..

mkdir -p "$out_dir/ffmpeg" "$out_dir/ffmpeg-shared/bin" "$out_dir/ffmpeg-shared/lib"
cp /usr/local/bin/ffmpeg  "$out_dir/ffmpeg/ffmpeg"
cp /usr/local/bin/ffmpeg  "$out_dir/ffmpeg-shared/bin/ffmpeg"
cp /usr/local/bin/ffprobe "$out_dir/ffmpeg-shared/bin/ffprobe"
find /usr/local/lib -maxdepth 1 \( -name "libav*.so*" -o -name "libsw*.so*" \) \
  -exec cp -aP {} "$out_dir/ffmpeg-shared/lib/" \;

## svpflow
download_archive \
  "https://web.archive.org/web/20190322064557/http://www.svp-team.com/files/gpl/svpflow-4.2.0.142.zip" \
  "svpflow" \
  "vapoursynth-plugins" \
  "svpflow-4.2.0.142/lib-linux"

## rife ncnn vulkan (prebuilt)
download_library \
  "https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan/releases/download/r9_mod_v33/librife_linux_x86-64.so" \
  "librife_linux_x86-64.so" \
  "vapoursynth-plugins"

## adjust
download_library \
  "https://github.com/f0e/Vapoursynth-adjust/releases/download/v1/libadjust.so" \
  "libadjust.so" \
  "vapoursynth-plugins"

## python for vapoursynth
mkdir -p download/python
cd download/python

if [ ! -d "python" ]; then
  wget -q https://github.com/astral-sh/python-build-standalone/releases/download/20250317/cpython-3.12.9+20250317-x86_64-unknown-linux-gnu-install_only.tar.gz -O python.tar.gz
  mkdir -p python
  tar -xzf python.tar.gz -C python --strip-components 1
  rm python.tar.gz
fi

# copy python to output directory
python_dest_path="../../$out_dir/python"
mkdir -p "$python_dest_path"
cp -R python/* "$python_dest_path"

cd ../..

$out_dir/python/bin/pip install --upgrade pip
$out_dir/python/bin/pip install cython meson ninja cmake

# builds
## vapoursynth

PATH="$PWD/$out_dir/python/bin:$PATH"
PYTHON_PREFIX="$PWD/$out_dir/python"

build "https://github.com/vapoursynth/vapoursynth.git" "--recurse-submodules" "vapoursynth" "
meson setup build-dev --prefix=/usr/local
ninja -C build-dev
ninja -C build-dev install
meson setup build-wheel --prefix=/usr/local -Dbuild_wheel=true
ninja -C build-wheel
ninja -C build-wheel install
" "" "vapoursynth"

### copy vspipe
cp /usr/local/lib/python3.12/site-packages/vapoursynth/vspipe $out_dir/vapoursynth

## bestsource
build "https://github.com/vapoursynth/bestsource.git" "--depth 1 --recurse-submodules --shallow-submodules --remote-submodules" "bestsource" "
meson setup build
ninja -C build
" "build" "vapoursynth-plugins"

## mvtools
build "https://github.com/dubhater/vapoursynth-mvtools.git" "" "mvtools" "
meson setup build
ninja -C build
" "build" "vapoursynth-plugins"

## akarin (requires LLVM < 17 — use llvm-config-16 explicitly)
rm -rf build/akarin
build "https://github.com/Jaded-Encoding-Thaumaturgy/akarin-vapoursynth-plugin.git" "" "akarin" "
git checkout 689cba74e7c71caf808b6feaaba0a32981c1956f
LLVM_CONFIG=llvm-config-16 meson build
ninja -C build
" "build" "vapoursynth-plugins"

## rife models
download_model_files() {
  local base_url="$1"
  local model_name="$2"
  local file_list=("${@:3}")

  echo "Downloading model: $model_name"
  local model_dir="$out_dir/models/$model_name"
  mkdir -p "$model_dir"

  for file in "${file_list[@]}"; do
    local file_url="$base_url/$file"
    local output_path="$model_dir/$file"
    echo "Downloading $file_url to $output_path"
    wget -q "$file_url" -O "$output_path"
  done

  echo "Model $model_name download completed"
}

echo "Starting model downloads..."

download_model_files \
  "https://raw.githubusercontent.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan/a2579e656dac7909a66e7da84578a2f80ccba41c/models/rife-v4.26_ensembleFalse" \
  "rife-v4.26_ensembleFalse" \
  "flownet.bin" "flownet.param"

echo "Model downloads completed"

echo "done"
