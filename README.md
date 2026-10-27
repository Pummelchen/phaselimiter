This Apple Silicon speficic fork of phaselimiter is about 3× faster than the original repository. Tested on Macbook Pro M3 24GB.

## Performance improvements

- Full 8-minute reference run reduced from 381.61 s to 115.20 s (3.31×).
- Real-FFT backend replaces the complex FFT on real input and is 2.16× faster.
- Exact source-spectrum cache adds a further 1.35× speedup with a 40 % RAM guard.
- Native Accelerate and NEON build removes Intel IPP.

## Technical changes

- Default C++26 build uses GCC 16 with contracts, `<inplace_vector>`, and `<simd>`.
- Boost 1.92 is supported through the Process v1 namespace and Filesystem v4 ABI.
- Dependencies are current: gflags 2.3.1, GoogleTest 1.18.0, CImg 3.7.6, and Armadillo 15.6.2.
- Fully static arm64 binaries need no Conda or Homebrew at runtime.
- Reproducible macOS build scripts and a zipped reference WAV are included.
- Deep audit plus Metal, ANE, AMX, and compiler-flag benchmarks live in `perf/`.
- Audio is preserved, with bit-identical cache output and rounding-only compiler differences.
