"""Measure Neural Engine vs CPU throughput for a conv-heavy Core ML mlprogram."""
import os, statistics, time
import numpy as np
import coremltools as ct

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "models", "conv.mlpackage")
C, H, W = 64, 128, 128
x = np.random.default_rng(0).standard_normal((1, C, H, W)).astype(np.float32)
gflops = 20 * 2 * C * H * W * C * 9 / 1e9

print("compute_units,median_ms,gflops,output_sum")
for name, cu in [("CPU_ONLY", ct.ComputeUnit.CPU_ONLY),
                 ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE),
                 ("ALL", ct.ComputeUnit.ALL)]:
    model = ct.models.MLModel(MODEL, compute_units=cu)
    for _ in range(2):
        y = model.predict({"input": x})
    ts = []
    for _ in range(10):
        t0 = time.perf_counter()
        y = model.predict({"input": x})
        ts.append(time.perf_counter() - t0)
    med = statistics.median(ts)
    out = list(y.values())[0]
    print(f"{name},{med*1000:.2f},{gflops/med:.1f},{float(np.asarray(out).sum()):.4f}", flush=True)
