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

## Performance trade-off

GCC 16 is slower on this workload than AppleClang 21. Paired 60 s runs with the
source-spectrum cache enabled:

| Compiler | Wall | CPU time |
|---|---:|---:|
| AppleClang 21 (C++11) | 9.95–10.49 s | 52.9–55.9 s |
| GCC 16 (C++26) | 11.92–12.11 s | 63.5–64.9 s |

That is roughly **15–20 % slower wall time / 20–25 % more CPU**; the limiter's
NEON/vDSP hot loops are vectorized better by Clang. The full 8-minute run was
152.5 s with GCC versus 121.9 s with AppleClang under different load conditions.

If maximum speed matters more than C++26, the previous AppleClang build remains
available:

```sh
build/build-macos.sh                 # C++11, AppleClang, fastest binary
```

It passes the same 15 tests and writes the same tool names into `bin/`.
