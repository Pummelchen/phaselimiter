# Can phaselimiter use the GPU, Neural Engine, or AMX?

Short answer: **no — not for the current algorithm, and none of the three can make
the existing binary materially faster.** The limiter is dominated by thousands of
small, independent FFTs. The Metal/ANE/AMX paths either cannot express that work
(ANE, AMX) or only reach parity with one CPU core once transfer costs are included
(GPU). The largest available speedup was on the CPU: switching the FFT backend from
complex FFTs on real input to vDSP's real FFT. That change is now implemented in
`deps/bakuage/src/dft_accelerate.cpp`, and a source-spectrum cache now removes a
redundant FFT per block and evaluation. Together they cut the full-file run from
**381.6 s to 121.9 s (3.1×)**; the cache itself is bit-identical, and the real-FFT
change is within 0.24 LSB RMS.

All numbers below were measured on this machine with the 8-minute WAV in the
repository root.

## Test environment

| | |
|---|---|
| Machine | MacBook Pro, Apple M3 |
| CPU | 8 cores (4P + 4E) |
| GPU | 10 cores, Metal 4 |
| Neural Engine | 16 cores |
| Memory | 24 GB |
| OS | macOS 27.2 (26B123) |
| Toolchain | Xcode 27.1 / AppleClang 21, Swift 6.4 |
| Input | `D07B53F5.wav`, 48 kHz stereo 16-bit, 479.96 s, 88 MB (tracked as `D07B53F5.wav.zip`; auto-extracted by `perf/prepare_reference.sh`) |
| Binary | `bin/phaselimiter` (static arm64 build) |

## End-to-end baseline

`perf/prepare_reference.sh && bin/phaselimiter --input=D07B53F5.wav --output=/tmp/out.wav --worker_count=8`
(limiter only, no mastering; FFmpeg converts 48 kHz → 44.1 kHz first).

| Metric | Value |
|---|---|
| Wall time | **381.6 s** |
| CPU time | 1816.3 s (user 1797.3 + sys 19.0) |
| Realtime factor | **0.795** (1.26× realtime) |
| Effective cores | **4.76** |

Profiling with `/usr/bin/sample` (8 s during the main optimization loop of a 60 s
excerpt) put **92 % of sampled stacks inside `RealForward`/`RealBackward`**, i.e.
the FFT, and 86.5 % of leaf samples in `libvDSP`. The limiter is an FFT-bound
workload.

## Microbenchmarks

Sources:

- `bench_fft.swift` — CPU vDSP (complex FFT as used by bakuage, and real FFT)
  versus Metal via `MPSGraph` `realToHermiteanFFT`. Input frames are read from the
  supplied WAV, not synthetic noise.
- `bench_amx.cpp` — FP32 `cblas_sgemm` through Accelerate, the only public path to
  the AMX matrix coprocessor.
- `make_ane_model.py` / `bench_ane.py` — a 20-layer 64-channel 3×3 convolution
  network (24.2 GFLOP/inference) converted to a Core ML mlprogram (FP16) and run
  with different `computeUnits`, to measure what the ANE can actually do.

Run everything with `perf/run_all.sh` (add `SKIP_BASELINE=1` to skip the 7-minute
end-to-end run).

### 1. GPU (Metal) vs CPU FFT

Batch 512, 10 repetitions, median; input from the WAV. `copy` includes a host →
shared-buffer memcpy each iteration.

| FFT size | CPU complex (8 threads, current) | CPU real (1 thread) | GPU real (MPSGraph) | GPU + copy |
|---:|---:|---:|---:|---:|
| 256 | 5.22 M/s (0.2 µs) | 10.99 M/s (0.1 µs) | 0.90 M/s (1.1 µs) | 1.16 M/s (0.9 µs) |
| 1,024 | 1.38 M/s (0.7 µs) | 2.58 M/s (0.4 µs) | 0.90 M/s (1.1 µs) | 0.81 M/s (1.2 µs) |
| 4,096 | 271 k/s (3.7 µs) | 589 k/s (1.7 µs) | 407 k/s (2.5 µs) | 365 k/s (2.7 µs) |
| 16,384 | 62 k/s (16.2 µs) | 126 k/s (7.9 µs) | 101 k/s (9.9 µs) | 92 k/s (10.9 µs) |

Only at 4K and 16K does the GPU beat the current CPU path (1.5–1.6×), and it
is still ~20 % slower than a **single CPU core** running vDSP's real FFT. At the
smaller sizes that dominate the block count, the GPU is 4–10× slower. MPSGraph also
adds a graph dispatch per launch; the limiter would have to batch across thousands
of blocks and keep data resident to hide it.

Amdahl estimate for a hypothetical perfect integration (92 % FFT, GPU 1.6× at the
dominant size, zero overhead): **≈1.5× end-to-end**. With the measured copy cost it
is ≈1.4×. That is not "much faster", and it requires rewriting the limiter's block
scheduler around a GPU command queue.

### 2. Neural Engine

Core ML convolution probe (24.2 GFLOP per inference):

| Compute units | Median | Effective FP16 throughput |
|---|---:|---:|
| CPU only | 10.5 ms | 2.3 TFLOPS |
| CPU + Neural Engine | 3.0 ms | 8.2 TFLOPS |
| All (ANE + GPU) | 2.8 ms | 8.7 TFLOPS |

The ANE is real and fast for convolution (≈3.5× the CPU), but it is only reachable
through Core ML. Core ML has **no FFT op**, no arbitrary control flow, and runs
FP16 (the probe's output already differs from CPU in the fourth decimal). The
limiter is an iterative, phase-aware optimization over FFT bins; expressing it as a
Core ML graph would mean reformulating the algorithm and accepting different output.
There is no path that accelerates the existing binary.

### 3. AMX

`cblas_sgemm` through Accelerate:

| Size | GFLOPS |
|---:|---:|
| 512 | 1,509 |
| 1,024 | 1,091 |
| 2,048 | 1,156 |
| 4,096 | 1,272 |

Those numbers are far above the NEON-only FP32 peak, consistent with a matrix
coprocessor path (AMX/SME) being used by Accelerate's GEMM. But the limiter has **no matrix multiply**: it is FFT + SIMD
element-wise math + reductions. Recasting a 16,384-point FFT as a DFT matrix
multiply costs ~2·N² ≈ 5×10⁸ FLOPs per transform; at ~1.2 TFLOPS that is ~1.4 ms,
versus 8 µs for an FFT — roughly 100–200× slower. AMX cannot help.

## Implemented: real FFT (CPU)

`deps/bakuage/src/dft_accelerate.cpp` used to implement the real DFT by packing a
real signal into a complex FFT with a zero imaginary part and calling
`vDSP_fft_zip` with stride 2. `RealForward`/`RealBackward` now use vDSP's real FFT
(`vDSP_fft_zrip`/`vDSP_fft_zripD`) for radix-2 lengths, converting the packed
split-complex layout to/from the existing CCS/Pack/Perm formats; other lengths keep
the old complex fallback. vDSP returns 2× the unnormalised DFT, so the forward path
folds a 0.5 factor into the input copy, and the inverse scaling then matches the
IPP complex path exactly.

Measured on the same file and 8 workers:

| Run | Before | After | Speedup |
|---|---:|---:|---:|
| Full file (479.96 s) | 381.61 s | **176.67 s** | **2.16×** |
| 60 s excerpt | 37.58 s | 12.87 s | 2.92× |
| 10 s excerpt | 6.23 s | 3.03 s | 2.06× |

Verification:

- CTest **15/15 passed** on the optimized build (including `DspBackend` format,
  in-place, float and double round-trip tests, and `cli-regression`; the latter
  dropped from 48.6 s to 24.8 s).
- Full-file output vs the previous binary: identical peak and loudness, identical
  iteration count (101), max difference 18 LSB (0.055 % of full scale), RMS
  difference 0.24 LSB, 4.99 % of samples differ by rounding only.
- After the change, 76.2 % of sampled stacks are still in the FFT (forward 63.4 %,
  inverse 12.9 %; `libvDSP` leaves 53.6 %), so the FFT remains the dominant cost —
  but it is now the efficient real transform. The full-file gain (2.16×) is smaller
  than the 60 s gain (2.92×) because the 8-minute working set is more memory-bound
  and sustains fewer effective cores.

### Source-spectrum cache (implemented)

The source signal is constant across the optimization, but `GradCore` recomputed
its windowed FFT on every evaluation. The existing `--perf_src_cache` option now
defaults to **on**; `GradCalculator::sourceCacheBytes()` estimates the cache size
from the task layout, and the cache is refused with a warning if it would exceed
40 % of physical RAM. `--perf_src_cache=false` restores the old behaviour.

### Current C++26 build

The final C++26/GCC 16 build (Boost 1.92, current dependencies) runs the
8-minute reference in **115.20 s** (503.03 s CPU, RTF 0.240), which is **3.31×**
faster than the original 381.61 s build. Its output is bit-identical to the
previous GCC build and within 25 LSB of AppleClang, with the same peak and
loudness. Raw values: `results/cxx26.csv`.

| Full file, paired A/B | Force cache off | Cache on |
|---|---:|---:|
| Wall | 164.15 s | **121.93 s (1.35×)** |
| CPU | 657.21 s | **462.30 s (1.42×)** |
| Peak RSS | 1.88 GB | 4.55 GB (estimate 2.30 GB) |
| Audio | — | **bit-identical (0 LSB)** |

At 60 s: 12.48 s → 9.90 s (CPU 71.45 → 51.85 s). The full audit, including the
bottlenecks deliberately left alone and why, is in [AUDIT.md](AUDIT.md).

The FFT diff is saved as `perf/real-fft.patch`. Rebuild and run tests with
`build/build-macos.sh`, which installs the optimized binaries into `bin/`.

## Compiler flags on M3

Built `phase_limiter` with each flag set (`perf/build_variant.sh`) and ran a
20-second excerpt six times per variant, interleaved and in rotating order. The
machine had heavy external load during the run (Roblox/Chrome, load average up to
31), so **wall times are noisy; median process CPU time is the comparison metric**.

| Variant | Median CPU time | vs `-O3` | Audio vs `-O3` |
|---|---:|---:|---:|
| `-O3` (current) | 25.22 s | 1.000× | — |
| `-O2` | 25.16 s | 1.003× | identical |
| `-O3 -mcpu=apple-m3` | 25.11 s | 1.004× | identical |
| `-O3 -mcpu=native` | 25.13 s | 1.004× | identical |
| `-O3 -flto=thin` | 24.98 s | 1.010× | identical |
| `-O3 -fno-math-errno` | 25.03 s | 1.008× | identical |
| `-O3 -ffast-math` | 23.61 s | **1.068×** | **max diff 39,077 LSB** |

Conclusions:

- **`-O2` is not faster than `-O3`** (0.3 %, inside noise); it produces the same
  bit-identical audio.
- **`-mcpu=apple-m3`/`native` does nothing measurable** (0.4 %): the hot loops are
  NEON/vDSP calls, and AppleClang already targets `apple-m1` with FMA by default.
  It would also make the binary require M3-class instructions.
- **Thin LTO and `-fno-math-errno` are within noise** (≈1 %).
- **`-ffast-math` is genuinely ~7 % faster in CPU time but corrupts the output**
  (39,077 LSB ≈ 60 % of full scale). It also violates the documented no-fast-math
  rule and the limiter's NaN handling. Not usable.

So there is no free compiler-flag win on this workload; the build stays at `-O3`
without fast-math. The real gains came from the real-FFT change above. Raw data:
`perf/results/flags/summary.csv` and `raw.csv`.

## Reproduce

```sh
perf/run_all.sh                 # full baseline + all microbenchmarks
SKIP_BASELINE=1 perf/run_all.sh # microbenchmarks only
```

Results land in `perf/results/` (`fft.csv`, `amx.csv`, `ane.csv`,
`baseline.time`, `optimized.csv`, `cache.csv`, `profile-after.txt`). The Core ML dependency (`coremltools`, `torch`) lives only in
`build/conda-env`; the ANE probe is the only part that needs it.

Notes:

- GPU numbers vary by ~±20 % between runs with GPU clock state.
- The FFT comparison is deliberately unfair in one direction: the CPU complex
  baseline is what the binary actually does today; the real-FFT column is what an
  optimized CPU implementation achieves. The GPU column is a best-case batched
  MPSGraph implementation.
- `MPSGraph` real FFT requires macOS 14+.
