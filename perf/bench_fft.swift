// FFT backend benchmark: CPU vDSP (complex + real) vs Metal GPU via MPSGraph.
// Build: swiftc -O -swift-version 5 -framework Metal -framework MetalPerformanceShadersGraph bench_fft.swift -o bench_fft
import Foundation
import Metal
import MetalPerformanceShadersGraph
import Accelerate
import AVFoundation

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count/2] }
func fmt(_ x: Double, _ p: Int = 2) -> String { String(format: "%.\(p)f", x) }

let args = CommandLine.arguments
let n = args.count > 1 ? Int(args[1])! : 1024
let batch = args.count > 2 ? Int(args[2])! : 64
let reps = args.count > 3 ? Int(args[3])! : 10
let threads = args.count > 4 ? Int(args[4])! : 1
let wavPath = args.count > 5 ? args[5] : ""

func loadWav(_ path: String, count: Int) -> [Float] {
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let frames = AVAudioFrameCount(min(Int64(count), file.length))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    } catch { return [] }
}
let wav = wavPath.isEmpty ? [] : loadWav(wavPath, count: n * batch)
let logn = vDSP_Length(round(log2(Double(n))))
let bytesIn = batch * n * 4

// ---- CPU: complex FFT, same shape bakuage uses (vDSP_fft_zip, interleaved) ----
var cplx = [Float](repeating: 0, count: 2 * n * batch)
for i in 0..<(2 * n * batch) { cplx[i] = (i % 2 == 0) ? (wav.isEmpty ? Float.random(in: -1...1) : wav[(i / 2) % wav.count]) : 0 }
var cplxSamples: [Double] = []
if let setup = vDSP_create_fftsetup(logn, FFTRadix(kFFTRadix2)) {
    for _ in 0..<reps {
        let t0 = now()
        cplx.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            let chunk = batch / threads
            if threads == 1 {
                for b in 0..<batch {
                    var split = DSPSplitComplex(realp: base + 2 * b * n, imagp: base + 2 * b * n + 1)
                    vDSP_fft_zip(setup, &split, 2, logn, FFTDirection(FFT_FORWARD))
                }
            } else {
                DispatchQueue.concurrentPerform(iterations: threads) { t in
                    for b in (t * chunk)..<((t + 1) * chunk) {
                        var split = DSPSplitComplex(realp: base + 2 * b * n, imagp: base + 2 * b * n + 1)
                        vDSP_fft_zip(setup, &split, 2, logn, FFTDirection(FFT_FORWARD))
                    }
                }
            }
        }
        cplxSamples.append(now() - t0)
    }
    vDSP_destroy_fftsetup(setup)
}

// ---- CPU: real FFT (vDSP_fft_zrip) ----
var real = [Float](repeating: 0, count: n)
var imag = [Float](repeating: 0, count: n)
for i in 0..<n { real[i] = wav.isEmpty ? Float.random(in: -1...1) : wav[i % wav.count] }
var realSamples: [Double] = []
if let setup = vDSP_create_fftsetup(logn, FFTRadix(kFFTRadix2)) {
    for _ in 0..<reps {
        let t0 = now()
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                for _ in 0..<batch {
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, logn, FFTDirection(FFT_FORWARD))
                }
            }
        }
        realSamples.append(now() - t0)
    }
    vDSP_destroy_fftsetup(setup)
}

// ---- GPU: MPSGraph real-to-Hermitean FFT, batched ----
let device = MTLCreateSystemDefaultDevice()!
let graph = MPSGraph()
let desc = MPSGraphFFTDescriptor()
desc.scalingMode = .none
desc.inverse = false
let inShape: [NSNumber] = [batch as NSNumber, n as NSNumber]
let inT = graph.placeholder(shape: inShape, dataType: .float32, name: nil)
let outT = graph.realToHermiteanFFT(inT, axes: [1], descriptor: desc, name: nil)
var input = [Float](repeating: 0, count: batch * n)
for i in 0..<input.count { input[i] = wav.isEmpty ? Float.random(in: -1...1) : wav[i % wav.count] }
let inBuf = device.makeBuffer(bytes: input, length: bytesIn, options: .storageModeShared)!
let inTD = MPSGraphTensorData(inBuf, shape: inShape, dataType: .float32)
// Warm up / compile.
for _ in 0..<3 { _ = graph.run(feeds: [inT: inTD], targetTensors: [outT], targetOperations: [outT.operation]) }
var gpuSamples: [Double] = []
for _ in 0..<reps {
    let t0 = now()
    let res = graph.run(feeds: [inT: inTD], targetTensors: [outT], targetOperations: [outT.operation])
    _ = res[outT]
    gpuSamples.append(now() - t0)
}
// End-to-end variant: host -> GPU copy every iteration.
let hostCopy = MPSGraphTensorData(inBuf, shape: inShape, dataType: .float32)
var gpuCopySamples: [Double] = []
for _ in 0..<reps {
    let t0 = now()
    memcpy(inBuf.contents(), input, bytesIn)
    let res = graph.run(feeds: [inT: hostCopy], targetTensors: [outT], targetOperations: [outT.operation])
    _ = res[outT]
    gpuCopySamples.append(now() - t0)
}

func emit(_ backend: String, _ samples: [Double]) {
    let t = median(samples)
    let tps = Double(batch) / t
    let gbps = Double(bytesIn) / t / 1e9
    print("\(backend),\(n),\(batch),\(fmt(tps,1)),\(fmt(t * 1e6 / Double(batch),1)),\(fmt(gbps,1))")
}
print("backend,n,batch,transforms_per_sec,us_per_transform,input_GBps")
if !cplxSamples.isEmpty { emit("cpu_complex_\(threads)t", cplxSamples) }
if !realSamples.isEmpty { emit("cpu_real_1t", realSamples) }
emit("gpu_real_mpsgraph", gpuSamples)
emit("gpu_real_mpsgraph_copy", gpuCopySamples)
