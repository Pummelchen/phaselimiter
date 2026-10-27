#!/usr/bin/env bash
# Native Apple Silicon build that produces self-contained ("raw") binaries.
#
# Runtime results in bin/ link only macOS system libraries plus Accelerate:
# no conda environment, no Homebrew dylibs, no rpath. The conda environment and
# the static archives under build/static-deps are build-time inputs only.
#
# Usage:
#   build/build-macos.sh              # bootstrap deps, build, run CTest
#   SKIP_TESTS=1 build/build-macos.sh # configure and build only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONDA_PREFIX="$REPO_ROOT/build/conda-env"
MAMBA="$REPO_ROOT/build/tools/bin/micromamba"
STATIC_DEPS="$REPO_ROOT/build/static-deps"
STATIC_SRC="$REPO_ROOT/build/static-src"
JOBS="$(sysctl -n hw.logicalcpu)"

# --- build-time dependency environment -------------------------------------
if [[ ! -x "$CONDA_PREFIX/bin/cmake" ]]; then
  echo "==> Creating conda environment in build/conda-env (build-time only)"
  mkdir -p build/tools
  if [[ ! -x "$MAMBA" ]]; then
    curl -sSL -o build/tools/micromamba.tar.bz2 \
      "https://micro.mamba.pm/api/micromamba/osx-arm64/latest"
    tar -xjf build/tools/micromamba.tar.bz2 -C build/tools
  fi
  MAMBA_ROOT_PREFIX="$REPO_ROOT/build/mamba-root" \
    "$MAMBA" create -y -p "$CONDA_PREFIX" -f environment/macos.yml
fi

echo "==> Updating submodules (only when they are missing)"
if [[ ! -f deps/bakuage/src/dft_accelerate.cpp || ! -f deps/eigen/Eigen/Core ]]; then
  git submodule update --init --recursive
fi

# Local performance patch: vDSP real FFT in bakuage (see perf/real-fft.patch).
if ! grep -q "vDSP_fft_zrip" deps/bakuage/src/dft_accelerate.cpp; then
  echo "==> Applying real-FFT patch"
  git -C deps/bakuage apply "$REPO_ROOT/perf/real-fft.patch"
fi

# --- static Boost 1.78 (Boost.Process v1 is required by bakuage/ffmpeg.h) ---
if [[ ! -f "$STATIC_DEPS/boost/lib/libboost_filesystem.a" ]]; then
  echo "==> Building static Boost 1.78"
  mkdir -p "$STATIC_SRC" "$STATIC_DEPS"
  if [[ ! -f "$STATIC_SRC/boost_1_78_0.tar.bz2" ]]; then
    curl -sSL -o "$STATIC_SRC/boost_1_78_0.tar.bz2" \
      "https://archives.boost.io/release/1.78.0/source/boost_1_78_0.tar.bz2"
  fi
  tar -xjf "$STATIC_SRC/boost_1_78_0.tar.bz2" -C "$STATIC_SRC"
  pushd "$STATIC_SRC/boost_1_78_0" >/dev/null
  ./bootstrap.sh --prefix="$STATIC_DEPS/boost" \
    --with-libraries=filesystem,serialization,system,math,iostreams \
    --with-toolset=clang
  ./b2 -j"$JOBS" --layout=system variant=release link=static \
    runtime-link=shared threading=multi cxxstd=11 \
    cxxflags="-mmacosx-version-min=11.0" \
    linkflags="-mmacosx-version-min=11.0" install
  popd >/dev/null
fi

# --- static libsndfile (WAV/AIFF; ffmpeg handles other input formats) ------
if [[ ! -f "$STATIC_DEPS/libsndfile/lib/libsndfile.a" ]]; then
  echo "==> Building static libsndfile 1.2.2"
  mkdir -p "$STATIC_SRC" "$STATIC_DEPS"
  if [[ ! -f "$STATIC_SRC/libsndfile-1.2.2.tar.xz" ]]; then
    curl -sSL -o "$STATIC_SRC/libsndfile-1.2.2.tar.xz" \
      "https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz"
  fi
  tar -xJf "$STATIC_SRC/libsndfile-1.2.2.tar.xz" -C "$STATIC_SRC"
  pushd "$STATIC_SRC/libsndfile-1.2.2" >/dev/null
  ./configure --prefix="$STATIC_DEPS/libsndfile" --enable-static \
    --disable-shared --disable-external-libs --disable-sqlite \
    CFLAGS="-O2 -mmacosx-version-min=11.0" \
    LDFLAGS="-mmacosx-version-min=11.0"
  make -j"$JOBS"
  make install
  popd >/dev/null
fi

# --- static TBB package (Homebrew ships only dylibs in its CMake config) ---
mkdir -p "$STATIC_DEPS/tbb-include" "$STATIC_DEPS/tbb-cmake" "$STATIC_DEPS/linklib"
ln -sfn /opt/homebrew/include/tbb "$STATIC_DEPS/tbb-include/tbb"
ln -sfn /opt/homebrew/include/oneapi "$STATIC_DEPS/tbb-include/oneapi"
cat > "$STATIC_DEPS/tbb-cmake/TBBConfig.cmake" <<EOF
add_library(TBB::tbb STATIC IMPORTED)
set_target_properties(TBB::tbb PROPERTIES
  IMPORTED_LOCATION "/opt/homebrew/lib/libtbb.a"
  INTERFACE_INCLUDE_DIRECTORIES "$STATIC_DEPS/tbb-include")
add_library(TBB::tbbmalloc STATIC IMPORTED)
set_target_properties(TBB::tbbmalloc PROPERTIES
  IMPORTED_LOCATION "/opt/homebrew/lib/libtbbmalloc.a"
  INTERFACE_INCLUDE_DIRECTORIES "$STATIC_DEPS/tbb-include")
set(TBB_FOUND TRUE)
set(TBB_tbb_FOUND TRUE)
set(TBB_tbbmalloc_FOUND TRUE)
EOF
cat > "$STATIC_DEPS/tbb-cmake/TBBConfigVersion.cmake" <<'EOF'
set(PACKAGE_VERSION "2023.1.0")
if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
EOF
# Bare -lbz2 / -lz from Boost.Iostreams must resolve to static archives.
ln -sfn "$CONDA_PREFIX/lib/libbz2.a" "$STATIC_DEPS/linklib/libbz2.a"
ln -sfn "$CONDA_PREFIX/lib/libz.a" "$STATIC_DEPS/linklib/libz.a"

echo "==> Configuring build/static"
"$CONDA_PREFIX/bin/cmake" -S . -B build/static -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DBUILD_TESTING=ON -DPHASELIMITER_STATIC_BOOST=ON \
  -DBoost_USE_STATIC_LIBS=ON \
  "-DBOOST_ROOT=$STATIC_DEPS/boost" \
  "-DCMAKE_PREFIX_PATH=$STATIC_DEPS/boost" \
  "-DARMADILLO_INCLUDE_DIR=$CONDA_PREFIX/include" \
  -DSndFile_DIR=SndFile_DIR-NOTFOUND \
  "-DSndFile_INCLUDE_DIR=$STATIC_DEPS/libsndfile/include" \
  "-DSndFile_LIBRARY=$STATIC_DEPS/libsndfile/lib/libsndfile.a" \
  "-DPNG_PNG_INCLUDE_DIR=$CONDA_PREFIX/include" \
  "-DPNG_LIBRARY_RELEASE=$CONDA_PREFIX/lib/libpng16.a" \
  "-DJPEG_INCLUDE_DIR=$CONDA_PREFIX/include" \
  "-DJPEG_LIBRARY_RELEASE=$CONDA_PREFIX/lib/libjpeg.a" \
  "-DZLIB_INCLUDE_DIR=$CONDA_PREFIX/include" \
  "-DZLIB_LIBRARY_RELEASE=$CONDA_PREFIX/lib/libz.a" \
  "-DTBB_DIR=$STATIC_DEPS/tbb-cmake" \
  "-DOpenMP_CXX_FLAGS=-Xpreprocessor -fopenmp" \
  "-DOpenMP_CXX_INCLUDE_DIR=/opt/homebrew/opt/libomp/include" \
  -DOpenMP_CXX_LIB_NAMES=omp \
  "-DOpenMP_omp_LIBRARY=/opt/homebrew/opt/libomp/lib/libomp.a" \
  "-DPython3_EXECUTABLE=$CONDA_PREFIX/bin/python3" \
  "-DCMAKE_EXE_LINKER_FLAGS=-L$STATIC_DEPS/linklib" \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;$CONDA_PREFIX"

echo "==> Building with $JOBS jobs"
"$CONDA_PREFIX/bin/cmake" --build build/static --parallel "$JOBS"

echo "==> Installing raw binaries into bin/ (underscores removed)"
mkdir -p bin
for name in phase_limiter audio_analyzer audio_detector audio_visualizer \
  clear_mixer effect_test snd_file_info spectrogram; do
  cp "build/static/bin/$name" "bin/${name//_/}"
done

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "==> Running CTest"
  PATH="$CONDA_PREFIX/bin:/opt/homebrew/bin:$PATH" \
    "$CONDA_PREFIX/bin/ctest" --test-dir build/static --output-on-failure
fi

echo "==> Done. Self-contained binaries: $REPO_ROOT/bin"
