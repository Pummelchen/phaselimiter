# C++26 build

The project now defaults to **C++26** (`CMAKE_CXX_STANDARD=26`). On macOS the
supported compiler is **GCC 16.2** (`/opt/homebrew/bin/g++-16`), which has the
broadest C++26 implementation available locally.

## Why GCC 16

| Feature | AppleClang 21 | Homebrew Clang 23.1 | GCC 16.2 |
|---|---:|---:|---:|
| `-std=c++26`, `__cplusplus=202400` | ✅ | ✅ | ✅ |
| `#embed`, pack indexing | ✅ | ✅ | ✅ |
| Contracts | ❌ | ❌ | ✅ |
| `<inplace_vector>` | ❌ | ❌ | ✅ |
| `<simd>` | ❌ | ❌ | ✅ |

The Clang builds also cannot compile Boost 1.78's Process locale header as
C++26: libc++ removed `std::codecvt_utf8`, which `boost/process/locale.hpp`
still uses. GCC/libstdc++ keeps it working.

## Requirements

- Xcode Command Line Tools (Accelerate, SDK).
- `brew install gcc eigen` — GCC 16 and Eigen >= 3.4.
- CMake >= 3.30 (the system CMake 4.4.4 is used; the conda CMake 3.27 does not
  know the C++26 dialect).

## Build

```sh
./script/build_macos_gcc26.sh
```

The script bootstraps what is missing and then:

1. Builds static Boost 1.92 and oneTBB 2023.1 **with GCC** into
   `build/gcc26-deps` (the AppleClang-built archives use libc++, which is
   ABI-incompatible with libstdc++).
2. Configures `build/gcc26` with `CMAKE_CXX_STANDARD=26`, Eigen 5 and the GCC
   shim below.
3. Builds, runs CTest, and installs the tools into `bin/`.

## GCC-specific adaptations

- `cmake/accelerate-gcc-shim/Accelerate/Accelerate.h`: GCC cannot parse
  vecLib's `vBasicOps.h` (pulled in by the real umbrella header). The shim
  includes only the vDSP/vForce/cblas/vImage headers the DSP backend uses.
- `deps/bakuage/include/bakuage/ffmpeg.h`: Boost 1.86+ moved Process v1 under
  `boost::process::v1`; the header selects that namespace when `BOOST_VERSION`
  is 1.86 or newer and keeps the old path for older Boost.
- Boost 1.92 is built with the filesystem v4 ABI. `ProjectOptions.cmake`
  defines `BOOST_FILESYSTEM_VERSION=4` for Boost >= 1.92 and puts the Boost
  include directory ahead of the Conda include directory (which contains an
  older Boost).
- `PHASELIMITER_EIGEN_INCLUDE_DIR`: the bundled Eigen 3.3 fails as C++26 with
  GCC, so the build uses Eigen >= 3.4. The cache variable defaults to a system
  Eigen when CMake can find one and otherwise to `deps/eigen`.
- Static `libstdc++`, `libgcc` and `libgomp.a` are linked so the resulting
  binary only depends on macOS system libraries. Homebrew GCC 16 is built for
  macOS 26, so the GCC binary's deployment target is **macOS 26** rather than
  the 11.0 used by the AppleClang build.

## Verification

- `ctest`: **15/15 passed** (the same suite as the AppleClang build).
- Full 8-minute reference output vs the AppleClang build: identical peak and
  loudness, max **25 LSB** difference (0.076 % FS), RMS 0.24 LSB.
- 10 s excerpt vs AppleClang: max 1 LSB.

## Performance

The C++26 build is essentially performance-neutral relative to the previous
AppleClang C++11 binary. Interleaved runs with the source-spectrum cache enabled:

| Build | 20 s excerpt, median CPU (4 rounds) | 120 s paired CPU |
|---|---:|---:|
| AppleClang 21 (C++11) | 22.15 s | 125.9 s |
| **GCC 16 (C++26, Boost 1.92)** | **22.20 s** | **127.8 s (+1.5 %)** |
| GCC 16 (C++20, Boost 1.78) | 22.48 s | — |
| GCC 16 (C++11, Boost 1.78/Eigen 3.3) | 20.38 s | — |

So C++26 costs about **0–2 % CPU** versus the previous binary. The larger
differences reported earlier (including a 152.5 s vs 121.9 s full-file
comparison) were measured under different external load/thermal states and were
not a fair A/B.

The one consistent effect is **GCC's own standard mode**: GCC 16 compiled as
C++11 is about 8 % faster than the same GCC compiled as C++20/C++26. This is a
codegen/ABI effect in the `simdpp` NEON hot loop, not an algorithm change.
Boost 1.92 is neutral (bit-identical output, not in the hot path) and Eigen 5
contributes only ~1–2 %.

For maximum speed while keeping the old toolchain, the AppleClang or GCC C++11
builds remain available:

```sh
build/build-macos.sh                 # C++11, AppleClang
```

They pass the same 15 tests and write the same tool names into `bin/`.
