#!/usr/bin/env bash
# Native Apple Silicon build using GCC 16 in C++26 mode.
#
# GCC 16 has the broadest C++26 support available on this machine (contracts,
# <inplace_vector>, <simd>). The bundled Eigen 3.3 does not compile as C++26, so
# this script requires a system Eigen >= 3.4 (Homebrew: brew install eigen).
#
# Prerequisites: Xcode command line tools, Homebrew gcc/eigen.
# The script bootstraps the conda environment and static libsndfile on first use.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GCC="/opt/homebrew/bin/gcc-16"
GXX="/opt/homebrew/bin/g++-16"
EIGEN="/opt/homebrew/include/eigen3"
CONDA="$REPO_ROOT/build/conda-env"
DEPS="$REPO_ROOT/build/static-deps"
GCC_DEPS="$REPO_ROOT/build/gcc26-deps"
SRC="$GCC_DEPS/src"
JOBS="$(sysctl -n hw.logicalcpu)"

[[ -x "$GCC" && -x "$GXX" ]] || { echo "GCC 16 not found (brew install gcc)" >&2; exit 1; }
[[ -d "$EIGEN" ]] || { echo "Eigen >= 3.4 not found at $EIGEN (brew install eigen)" >&2; exit 1; }

if [[ ! -x "$CONDA/bin/python3" ]]; then
  echo "==> Creating conda environment (build-time only)"
  mkdir -p build/tools
  if [[ ! -x build/tools/bin/micromamba ]]; then
    curl -sSL -o build/tools/micromamba.tar.bz2 \
      "https://micro.mamba.pm/api/micromamba/osx-arm64/latest"
    tar -xjf build/tools/micromamba.tar.bz2 -C build/tools
  fi
  MAMBA_ROOT_PREFIX="$REPO_ROOT/build/mamba-root" \
    build/tools/bin/micromamba create -y -p "$CONDA" -f environment/macos.yml
fi

if [[ ! -f "$DEPS/libsndfile/lib/libsndfile.a" ]]; then
  echo "==> Building static libsndfile"
  mkdir -p "$SRC" "$DEPS"
  [[ -f "$SRC/libsndfile-1.2.2.tar.xz" ]] || curl -sSL \
    -o "$SRC/libsndfile-1.2.2.tar.xz" \
    "https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz"
  tar -xJf "$SRC/libsndfile-1.2.2.tar.xz" -C "$SRC"
  (cd "$SRC/libsndfile-1.2.2" && ./configure --prefix="$DEPS/libsndfile" \
    --enable-static --disable-shared --disable-external-libs --disable-sqlite \
    CFLAGS="-O2 -mmacosx-version-min=11.0" LDFLAGS="-mmacosx-version-min=11.0" \
    && make -j"$JOBS" && make install)
fi

if [[ ! -f "$GCC_DEPS/boost192/lib/libboost_filesystem.a" ]]; then
  echo "==> Building static Boost 1.92 with GCC"
  mkdir -p "$SRC" "$GCC_DEPS"
  [[ -f "$SRC/boost_1_92_0.tar.bz2" ]] || curl -sSL \
    -o "$SRC/boost_1_92_0.tar.bz2" \
    "https://archives.boost.io/release/1.92.0/source/boost_1_92_0.tar.bz2"
  tar -xjf "$SRC/boost_1_92_0.tar.bz2" -C "$SRC"
  (cd "$SRC/boost_1_92_0" \
    && echo "using gcc : 16 : $GXX ;" > user-config.jam \
    && ./bootstrap.sh --prefix="$GCC_DEPS/boost192" \
       --with-libraries=filesystem,serialization,system,math,iostreams \
    && ./b2 -j"$JOBS" --user-config="$PWD/user-config.jam" toolset=gcc-16 \
       --layout=system variant=release link=static runtime-link=shared \
       threading=multi cxxstd=17 cxxflags="-mmacosx-version-min=11.0" \
       linkflags="-mmacosx-version-min=11.0" install)
fi

if [[ ! -f "$GCC_DEPS/tbb/lib/libtbb.a" ]]; then
  echo "==> Building static oneTBB 2023.1 with GCC"
  mkdir -p "$SRC"
  [[ -f "$SRC/oneTBB.tar.gz" ]] || curl -sSL -o "$SRC/oneTBB.tar.gz" \
    "https://github.com/oneapi-src/oneTBB/archive/refs/tags/v2023.1.0.tar.gz"
  tar -xzf "$SRC/oneTBB.tar.gz" -C "$SRC"
  cmake -S "$SRC/oneTBB-2023.1.0" -B "$GCC_DEPS/tbb-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$GCC" -DCMAKE_CXX_COMPILER="$GXX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DBUILD_SHARED_LIBS=OFF -DTBB_TEST=OFF \
    -DTBB_EXAMPLES=OFF -DCMAKE_INSTALL_PREFIX="$GCC_DEPS/tbb"
  cmake --build "$GCC_DEPS/tbb-build" --target install --parallel "$JOBS"
fi

GOMP="$("$GXX" -print-file-name=libgomp.a)"
cmake -S . -B build/gcc26 -G Ninja \
  -U "Boost_*" -U "boost_*" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="" -DCMAKE_CXX_FLAGS="" \
  -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG" \
  -DCMAKE_C_COMPILER="$GCC" -DCMAKE_CXX_COMPILER="$GXX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_CXX_STANDARD=26 -DPHASELIMITER_WARNINGS_AS_ERRORS=OFF \
  -DPHASELIMITER_EIGEN_INCLUDE_DIR="$EIGEN" \
  -DPHASELIMITER_STATIC_BOOST=ON -DBoost_USE_STATIC_LIBS=ON \
  "-DBOOST_ROOT=$GCC_DEPS/boost192" "-DBoost_DIR=$GCC_DEPS/boost192/lib/cmake/Boost-1.92.0" \
  "-DCMAKE_PREFIX_PATH=$GCC_DEPS/boost192" \
  "-DARMADILLO_INCLUDE_DIR=/opt/homebrew/include" \
  -DSndFile_DIR=SndFile_DIR-NOTFOUND \
  "-DSndFile_INCLUDE_DIR=$DEPS/libsndfile/include" \
  "-DSndFile_LIBRARY=$DEPS/libsndfile/lib/libsndfile.a" \
  "-DPNG_PNG_INCLUDE_DIR=$CONDA/include" "-DPNG_LIBRARY_RELEASE=$CONDA/lib/libpng16.a" \
  "-DJPEG_INCLUDE_DIR=$CONDA/include" "-DJPEG_LIBRARY_RELEASE=$CONDA/lib/libjpeg.a" \
  "-DZLIB_INCLUDE_DIR=$CONDA/include" "-DZLIB_LIBRARY_RELEASE=$CONDA/lib/libz.a" \
  "-DTBB_DIR=$GCC_DEPS/tbb/lib/cmake/TBB" \
  "-DPython3_EXECUTABLE=$CONDA/bin/python3" \
  "-DOpenMP_gomp_LIBRARY=$GOMP" \
  "-DCMAKE_EXE_LINKER_FLAGS=-L$DEPS/linklib -static-libstdc++ -static-libgcc" \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;$CONDA;$GCC_DEPS"

cmake --build build/gcc26 --parallel "$JOBS"
PATH="$CONDA/bin:/opt/homebrew/bin:$PATH" \
  ctest --test-dir build/gcc26 --output-on-failure

mkdir -p bin
for name in phase_limiter audio_analyzer audio_detector audio_visualizer \
  clear_mixer effect_test snd_file_info spectrogram; do
  cp "build/gcc26/bin/$name" "bin/${name//_/}"
done
echo "==> Done. C++26 binaries are in $REPO_ROOT/bin"
