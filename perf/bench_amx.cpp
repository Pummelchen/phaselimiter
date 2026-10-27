// AMX / Accelerate BLAS benchmark. On Apple Silicon cblas_sgemm dispatches to
// the AMX matrix coprocessor, so this measures the throughput reachable through
// the only public AMX path (Accelerate).
#include <Accelerate/Accelerate.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>

using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double>(b - a).count();
}

int main(int argc, char **argv) {
    int n = argc > 1 ? std::atoi(argv[1]) : 2048;
    int reps = argc > 2 ? std::atoi(argv[2]) : 5;
    std::vector<float> a((size_t)n * n), b((size_t)n * n), c((size_t)n * n);
    for (size_t i = 0; i < a.size(); ++i) { a[i] = 1.0f + (i % 17) * 0.001f; b[i] = 1.0f - (i % 13) * 0.001f; }
    const double flops = 2.0 * n * n * n;
    std::vector<double> samples;
    for (int r = 0; r < reps; ++r) {
        auto t0 = Clock::now();
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, n, n, n,
                    1.0f, a.data(), n, b.data(), n, 0.0f, c.data(), n);
        auto t1 = Clock::now();
        samples.push_back(seconds(t0, t1));
    }
    std::sort(samples.begin(), samples.end());
    double t = samples[samples.size() / 2];
    std::printf("backend,size,GFLOPS,seconds,checksum\n");
    std::printf("accelerate_sgemm,%d,%.1f,%.6f,%.3f\n", n, flops / t / 1e9, t, c[(size_t)n * n / 2]);
    return 0;
}
