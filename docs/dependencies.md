# Dependencies

Versions checked against Homebrew and upstream release tags on 2026-10-27.

## Runtime

- macOS 27.2 system libraries (`libSystem`, `libc++`).
- `Accelerate.framework` (vDSP, vForce, vImage) from the macOS SDK.
- `ffmpeg` 9.0.2_1, invoked as an external process for input/output conversion.

The C++26 binary is statically linked against every other C++/C dependency and
has no Conda or Homebrew runtime dependency.

## Build toolchain

- AppleClang 21.0.0 / Xcode 27.1 and the macOS 26 SDK.
- GCC 16.2.0 (Homebrew) for the C++26 build.
- CMake 4.4.4.
- Python 3.11.15 (build/test scripts only).

## Libraries

- Boost 1.92.0 (static, built with GCC; Process v1 and Filesystem v4).
- Eigen 5.0.1.
- oneTBB 2023.1.0 (static, built with GCC).
- libsndfile 1.2.2 (static, WAV/AIFF).
- libpng 1.6.59.
- libjpeg-turbo 3.2.0.
- zlib 1.3.1.
- bzip2 1.0.8.
- xz/liblzma 5.8.4.
- zstd 1.5.7.
- Armadillo 15.6.2 (headers).
- gflags 2.3.1.
- GoogleTest 1.18.0.
- CImg 3.7.6.
- libcmaes 0.10.2.
- libsimdpp 2.0-403-g58f357eb.
- hnswlib 0.9.0.
- picojson 1.3.0-51-g111c9be.
- optim 843b94c (DE-PRMM, per-candidate RNG).
