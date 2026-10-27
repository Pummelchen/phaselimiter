# phaselimiter deep performance audit

Scope: the `phase_limiter` path used by `bin/phaselimiter` (limiter, no mastering),
on Apple M3 / macOS 27.2. Hard constraint from the user: **no sound-quality
degradation**. Every change below is either bit-identical or removes a redundant
operation; no approximation, no fast-math, no resampling or iteration changes.

## Method

- Read the limiter call path: `main.cpp` → `GradCalculator` → `Tasks`/`TaskGroup`
  → `GradCore` → `bakuage` FFT/vector math.
- Profiled with `/usr/bin/sample` during the optimization loop.
- A/B measured with the real 8-minute `D07B53F5.wav` (tracked as `D07B53F5.wav.zip`) and 60 s excerpts.
- Compared decoded WAV samples against the previous binary; bit-identical means
  `max |diff| == 0` over all 42,332,472 samples.
- Ran the full CTest suite after each change (15/15).

## Progression on the 8-minute file

| Build | Wall | CPU time | Peak RSS | Speedup |
|---|---:|---:|---:|---:|
| Original (complex FFT on real data) | 381.61 s | 1797 s | ~1.9 GB | 1.00× |
| Real-FFT backend (previous round) | 176.67 s | 631 s | 1.9 GB | 2.16× |
| Real FFT + source-spectrum cache | **121.93 s** | **462 s** | 4.55 GB | **3.13×** |

The cache A/B was paired under the same external load: 164.15 s / 657 s CPU
without cache vs 121.93 s / 462 s CPU with it — **1.35× wall, 1.42× CPU**.

## Findings

### 1. Complex FFT used for real input (fixed earlier)

`dft_accelerate.cpp` packed real audio into a complex FFT with a zero imaginary
part (`vDSP_fft_zip`, stride 2). 92 % of sampled stacks were in the FFT. vDSP's
real FFT (`vDSP_fft_zrip`) is 5–7× faster per transform for identical math; the
backend now uses it for radix-2 lengths. Full-file result: 2.16×, output max
18 LSB different (rounding only). See `perf/real-fft.patch`.

### 2. Source spectrum recomputed on every evaluation (fixed now)

`GradCore::func` recomputed the windowed FFT of `waveSrc` on every call, even
though the source is constant across the whole optimization. Each evaluation
therefore did three FFTs per block where two suffice. The existing but
default-off `--perf_src_cache` option already caches this per block/context.

Changes in `src/phase_limiter/`:

- `perf_src_cache` now defaults to **on**.
- `GradCalculator::sourceCacheBytes()` (with `Tasks::sourceCacheBytes`) estimates
  the exact cache size from the task/context layout.
- The cache is disabled with a warning if the estimate exceeds **40 % of physical
  RAM**; otherwise it is enabled and the estimate is logged.
- `--perf_src_cache=false` still forces the old behaviour.

Measured: 8-minute file 164.15 → 121.93 s (1.35×), CPU 657 → 462 s (1.42×),
peak RSS 1.88 → 4.55 GB (estimate 2.30 GB; allocator overhead adds ~15 %).
The output is **bit-identical** to the uncached build (0 LSB difference).

### 3. Whole-wave cut FFT is an identity by default (not changed)

`outputUnitEval("src_with_cut")` does forward + inverse real FFTs of the entire
wave to zero bins above `max_available_freq`. With the default
`--max_available_freq_mode=disabled`, the cutoff equals Nyquist, so no bin is
removed — the roundtrip only multiplies by `memLen` and scales back. It is a pure
identity plus rounding, worth ~1.7 % of sampled stacks.

Skipping it when `max_available_freq >= sample_rate/2` would remove that work and
the rounding, but changes output bits (benignly). Left as an optional follow-up
because the gain is small and the current result is already validated.

### 4. Duplicate post-limiter evaluation for `limiting_error` (not changed)

After the limiter finishes, `main.cpp` constructs a second `GradCalculator` and
runs `unit_eval` + a full final evaluation solely to print `normalized_eval` /
`limiting_error` to stderr. Audio output does not depend on it. It costs one full
evaluation pass (roughly 1–2 % of runtime). Making it opt-in (e.g. only when the
error spectrogram/`--grad_output` is requested) would save that pass, at the cost
of losing the diagnostic line.

### 5. Parallel efficiency / tail (investigated, not changed)

Effective cores are 3.2–4.8 of 8 depending on the phase, external load and the
largest 16 K blocks. Worker counts 4/6/8/10/12 on a 60 s excerpt gave 15.2 / 12.2 /
11.0 / 10.3 / 10.3 s wall with cache enabled, but CPU time was flat
(48–53 s): 10 workers only helped under external load by filling scheduling gaps,
not by doing less work. Default stays automatic (8 here).

### 6. Non-power-of-two whole-wave FFT (not changed)

The same `outputUnitEval` uses `RealDft(memLen)` where `memLen` is the media length
rounded to 8192, so it falls into Eigen/KissFFT (1.7 % of samples). Making it a
power-of-two transform would change the DFT (zero-padding samples the spectrum
differently), so it is not an exact optimization.

### 7. Remaining hot path after the fixes

With the cache enabled, sampled stacks are 61 % FFT (forward 42 %, inverse 19 %),
36.7 % libvDSP leaves. The forward FFT of the changing signal and the inverse FFT
for the gradient are inherent to the algorithm. Further gains would require
algorithmic changes (different window/batching), not code cleanup.

### 8. Compiler flags (tested, no gain)

`-O2` is not faster than `-O3`; `-mcpu=apple-m3`, LTO and `-fno-math-errno` are
within noise; `-ffast-math` is ~7 % faster but changes audio by up to 39,077 LSB.
See “Compiler flags on M3” in `perf/README.md`.

## Verification

- CTest **15/15 passed** after the cache change (including `DspBackend`,
  `limiter-io`, `cli-regression`).
- Cached vs uncached full-file output: **0 LSB difference**, identical peak and
  loudness, identical iteration count.
- Cache estimate 2,301 MB vs measured peak delta 2,666 MB; the 40 %-of-RAM guard
  leaves ample headroom on this 24 GB machine and disables the cache for very long
  inputs before they can exhaust memory.
- The 60 s excerpt went from 12.48 s (no cache) to 9.90 s (cache), CPU 71.45 →
  51.85 s.

## What to use

Just run the binary; the cache is automatic and logged:

```
source FFT cache: 2301 MB (budget 9830 MB)
```

For memory-constrained runs or benchmarking the old behaviour use
`--perf_src_cache=false`. Sound output is identical either way.

## Reproduce

```sh
build/build-macos.sh                 # rebuild + install bin/
perf/prepare_reference.sh
bin/phaselimiter --input=D07B53F5.wav --output=/tmp/out.wav --worker_count=8
```
