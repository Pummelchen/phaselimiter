#!/usr/bin/env bash
# Reproduce the GPU / ANE / AMX feasibility benchmarks for phaselimiter.
#
#   perf/run_all.sh [input.wav]
#   SKIP_BASELINE=1 perf/run_all.sh [input.wav]
#
# The full-file baseline takes roughly as long as a normal limiter run
# (~7 minutes for the 8-minute reference WAV on an M3).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
WAV="${1:-D07B53F5.wav}"
RESULTS="perf/results"
PYTHON="build/conda-env/bin/python"
mkdir -p "$RESULTS" perf/models

echo "==> Building microbenchmarks"
clang++ -O3 -std=c++11 -Wno-deprecated-declarations -framework Accelerate perf/bench_amx.cpp -o perf/bench_amx
swiftc -O -swift-version 5 \
  -framework Metal -framework MetalPerformanceShadersGraph -framework AVFoundation \
  perf/bench_fft.swift -o perf/bench_fft

if [[ ! -d perf/models/conv.mlpackage ]]; then
  echo "==> Building Core ML model for the ANE probe"
  "$PYTHON" perf/make_ane_model.py
fi

if [[ "${SKIP_BASELINE:-0}" != "1" ]]; then
  echo "==> Baseline: full-file limiter run"
  /usr/bin/time -p -o "$RESULTS/baseline.time" \
    ./bin/phaselimiter --input="$WAV" --output=/tmp/phaselimiter-perf-output.wav \
    --worker_count=8 > "$RESULTS/baseline-run.log" 2>&1
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" > "$RESULTS/input-duration.txt"
fi

echo "==> FFT: vDSP vs MPSGraph"
echo "backend,n,batch,transforms_per_sec,us_per_transform,input_GBps" > "$RESULTS/fft.csv"
for n in 256 1024 4096 16384; do
  perf/bench_fft "$n" 512 10 8 "$WAV" | tail -n +2 >> "$RESULTS/fft.csv"
done

echo "==> AMX: Accelerate sgemm"
echo "backend,size,GFLOPS,seconds,checksum" > "$RESULTS/amx.csv"
for n in 512 1024 2048 4096; do
  perf/bench_amx "$n" 5 | tail -n +2 >> "$RESULTS/amx.csv"
done

echo "==> ANE: Core ML conv probe"
"$PYTHON" perf/bench_ane.py | grep -v '^Torch version' > "$RESULTS/ane.csv"

echo
echo "Results written to $RESULTS"
if [[ -f "$RESULTS/baseline.time" ]]; then cat "$RESULTS/baseline.time"; fi
