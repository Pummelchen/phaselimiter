#!/usr/bin/env bash
# Build phase_limiter with a specific optimization flag set for A/B testing.
#   perf/build_variant.sh <name> "<flags>"
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
NAME="$1"
FLAGS="$2"
CONDA="$REPO_ROOT/build/conda-env"
DEPS="$REPO_ROOT/build/static-deps"
DIR="build/flags-$NAME"

"$CONDA/bin/cmake" -S . -B "$DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DBUILD_TESTING=OFF -DPHASELIMITER_STATIC_BOOST=ON \
  -DBoost_USE_STATIC_LIBS=ON \
  "-DBOOST_ROOT=$DEPS/boost" \
  "-DCMAKE_PREFIX_PATH=$DEPS/boost" \
  "-DARMADILLO_INCLUDE_DIR=$CONDA/include" \
  -DSndFile_DIR=SndFile_DIR-NOTFOUND \
  "-DSndFile_INCLUDE_DIR=$DEPS/libsndfile/include" \
  "-DSndFile_LIBRARY=$DEPS/libsndfile/lib/libsndfile.a" \
  "-DPNG_PNG_INCLUDE_DIR=$CONDA/include" \
  "-DPNG_LIBRARY_RELEASE=$CONDA/lib/libpng16.a" \
  "-DJPEG_INCLUDE_DIR=$CONDA/include" \
  "-DJPEG_LIBRARY_RELEASE=$CONDA/lib/libjpeg.a" \
  "-DZLIB_INCLUDE_DIR=$CONDA/include" \
  "-DZLIB_LIBRARY_RELEASE=$CONDA/lib/libz.a" \
  "-DTBB_DIR=$DEPS/tbb-cmake" \
  "-DOpenMP_CXX_FLAGS=-Xpreprocessor -fopenmp" \
  "-DOpenMP_CXX_INCLUDE_DIR=/opt/homebrew/opt/libomp/include" \
  -DOpenMP_CXX_LIB_NAMES=omp \
  "-DOpenMP_omp_LIBRARY=/opt/homebrew/opt/libomp/lib/libomp.a" \
  "-DPython3_EXECUTABLE=$CONDA/bin/python3" \
  "-DCMAKE_EXE_LINKER_FLAGS=-L$DEPS/linklib" \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;$CONDA" \
  "-DCMAKE_C_FLAGS_RELEASE=$FLAGS -DNDEBUG" \
  "-DCMAKE_CXX_FLAGS_RELEASE=$FLAGS -DNDEBUG"

"$CONDA/bin/cmake" --build "$DIR" --target phase_limiter --parallel "$(sysctl -n hw.logicalcpu)"
echo "built $DIR/bin/phase_limiter"
